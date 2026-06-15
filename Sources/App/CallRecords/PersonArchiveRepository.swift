import Foundation

final class PersonArchiveRepository {
    private(set) var peopleFile = PeopleFile()
    private(set) var indexEntries: [CallRecordIndexEntry] = []
    private(set) var access: PersonArchiveAccess = .writable

    var people: [PersonRecord] {
        peopleFile.people.sorted { lhs, rhs in
            let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if comparison == .orderedSame {
                return lhs.id < rhs.id
            }
            return comparison == .orderedAscending
        }
    }

    private let archiveRoot: URL
    private let now: () -> Date

    private var peopleURL: URL {
        archiveRoot.appendingPathComponent("people.json")
    }

    init(archiveRoot: URL, now: @escaping () -> Date = Date.init) {
        self.archiveRoot = archiveRoot
        self.now = now
    }

    func load(indexEntries: [CallRecordIndexEntry]? = nil) throws {
        self.indexEntries = try indexEntries
            ?? CallRecordArchiveWriter.loadIndex(from: archiveRoot)

        let result = AtomicJSONFileStore.load(
            PeopleFile.self,
            from: peopleURL,
            defaultValue: PeopleFile()
        )
        peopleFile = result.value
        access = result.access

        if case .recoveredFromBackup = access {
            do {
                try AtomicJSONFileStore.save(peopleFile, to: peopleURL)
                access = .writable
            } catch {
                access = .readOnly(reason: "已读取备份，但无法恢复 people.json：\(error.localizedDescription)")
            }
        }

        guard case .readOnly = access else {
            try bootstrapMissingPhones()
            return
        }
    }

    func person(containing phone: String) -> PersonRecord? {
        let normalized = normalizePhone(phone)
        guard !normalized.isEmpty else { return nil }
        return peopleFile.people.first {
            $0.phoneNumbers.contains(normalized)
        }
    }

    func calls(for personID: String) -> [CallRecordIndexEntry] {
        guard let person = peopleFile.people.first(where: { $0.id == personID }) else {
            return []
        }
        let phones = Set(person.phoneNumbers)
        return indexEntries
            .filter { phones.contains($0.normalizedPhone) }
            .sorted { lhs, rhs in
                if lhs.callDate == rhs.callDate {
                    return lhs.id < rhs.id
                }
                return lhs.callDate > rhs.callDate
            }
    }

    @discardableResult
    func createPerson(displayName: String, phones: [String]) throws -> PersonRecord {
        try requireWritable()
        let displayName = try validatedDisplayName(displayName)
        let normalizedPhones = uniquePhones(phones)
        try ensurePhonesAreUnowned(normalizedPhones)

        let timestamp = now()
        let person = PersonRecord(
            displayName: displayName,
            phoneNumbers: normalizedPhones,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        peopleFile.people.append(person)
        removeUnassignedPhones(normalizedPhones)
        try savePeople()
        return person
    }

    @discardableResult
    func renamePerson(_ personID: String, displayName: String) throws -> PersonRecord {
        try requireWritable()
        let displayName = try validatedDisplayName(displayName)
        let index = try personIndex(for: personID)
        peopleFile.people[index].displayName = displayName
        peopleFile.people[index].updatedAt = now()
        let person = peopleFile.people[index]
        try savePeople()
        return person
    }

    @discardableResult
    func assignUnassignedPhones(
        _ phones: [String],
        to personID: String
    ) throws -> PersonRecord {
        try requireWritable()
        let index = try personIndex(for: personID)
        let normalizedPhones = uniquePhones(phones)
        try ensurePhonesAreUnowned(normalizedPhones, allowingOwnerID: personID)

        let existingPhones = Set(peopleFile.people[index].phoneNumbers)
        let appendedPhones = normalizedPhones.filter { !existingPhones.contains($0) }
        peopleFile.people[index].phoneNumbers = uniquePhones(
            peopleFile.people[index].phoneNumbers + appendedPhones
        )
        peopleFile.people[index].updatedAt = now()
        removeUnassignedPhones(normalizedPhones)
        let person = peopleFile.people[index]
        try savePeople()
        return person
    }

    @discardableResult
    func mergePeople(
        personIDs: [String],
        targetPersonID: String,
        displayName: String
    ) throws -> PersonRecord {
        try requireWritable()
        let displayName = try validatedDisplayName(displayName)
        var seenIDs = Set<String>()
        let uniqueIDs = personIDs.filter { seenIDs.insert($0).inserted }
        guard uniqueIDs.count >= 2,
              uniqueIDs.contains(targetPersonID) else {
            throw PersonArchiveError.invalidMerge
        }

        let selectedIDSet = Set(uniqueIDs)
        let beforePeople = try uniqueIDs.map { id in
            guard let person = peopleFile.people.first(where: { $0.id == id }) else {
                throw PersonArchiveError.personNotFound(id)
            }
            return person
        }
        for phone in uniquePhones(beforePeople.flatMap(\.phoneNumbers)) {
            if let ownerID = ownerID(for: phone, excluding: selectedIDSet) {
                throw PersonArchiveError.phoneConflict(phone: phone, ownerID: ownerID)
            }
        }

        guard var target = beforePeople.first(where: { $0.id == targetPersonID }) else {
            throw PersonArchiveError.personNotFound(targetPersonID)
        }
        target.displayName = displayName
        target.phoneNumbers = uniquePhones(beforePeople.flatMap(\.phoneNumbers))
        target.updatedAt = now()

        peopleFile.people.removeAll { selectedIDSet.contains($0.id) }
        peopleFile.people.append(target)
        peopleFile.mergeHistory.append(
            PersonMergeRecord(
                targetPersonID: targetPersonID,
                beforePeople: beforePeople,
                createdAt: now()
            )
        )
        removeUnassignedPhones(target.phoneNumbers)
        try savePeople()
        return target
    }

    @discardableResult
    func splitPhones(
        from personID: String,
        phones: [String],
        newDisplayName: String?
    ) throws -> PersonRecord? {
        try requireWritable()
        let sourceIndex = try personIndex(for: personID)
        let requestedPhones = uniquePhones(phones)
        let sourcePhones = Set(peopleFile.people[sourceIndex].phoneNumbers)
        let movedPhones = requestedPhones.filter { sourcePhones.contains($0) }
        guard !movedPhones.isEmpty else {
            return nil
        }

        peopleFile.people[sourceIndex].phoneNumbers = uniquePhones(
            peopleFile.people[sourceIndex].phoneNumbers.filter {
                !movedPhones.contains($0)
            }
        )
        peopleFile.people[sourceIndex].updatedAt = now()

        if let newDisplayName {
            let displayName = try validatedDisplayName(newDisplayName)
            let timestamp = now()
            let person = PersonRecord(
                displayName: displayName,
                phoneNumbers: movedPhones,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            peopleFile.people.append(person)
            removeUnassignedPhones(movedPhones)
            try savePeople()
            return person
        }

        addUnassignedPhones(movedPhones)
        try savePeople()
        return nil
    }

    func deletePersonKeepingPhonesUnassigned(_ personID: String) throws {
        try requireWritable()
        let index = try personIndex(for: personID)
        let phones = peopleFile.people[index].phoneNumbers
        peopleFile.people.remove(at: index)
        addUnassignedPhones(phones)
        try savePeople()
    }

    func revertMerge(_ mergeID: String) throws {
        try requireWritable()
        guard let mergeIndex = peopleFile.mergeHistory.firstIndex(
            where: { $0.id == mergeID && $0.revertedAt == nil }
        ) else {
            throw PersonArchiveError.mergeNotFound(mergeID)
        }

        let merge = peopleFile.mergeHistory[mergeIndex]
        let restoredIDs = Set(merge.beforePeople.map(\.id))
        let allowedExistingOwnerIDs = restoredIDs.union([merge.targetPersonID])
        for phone in uniquePhones(merge.beforePeople.flatMap(\.phoneNumbers)) {
            if let ownerID = ownerID(for: phone, excluding: allowedExistingOwnerIDs) {
                throw PersonArchiveError.phoneConflict(phone: phone, ownerID: ownerID)
            }
        }

        peopleFile.people.removeAll {
            restoredIDs.contains($0.id) || $0.id == merge.targetPersonID
        }
        peopleFile.people.append(contentsOf: merge.beforePeople)
        peopleFile.mergeHistory[mergeIndex].revertedAt = now()
        removeUnassignedPhones(merge.beforePeople.flatMap(\.phoneNumbers))
        try savePeople()
    }

    private func bootstrapMissingPhones() throws {
        let unassigned = Set(peopleFile.unassignedPhoneNumbers.map(normalizePhone))
        var owned = Set(peopleFile.people.flatMap(\.phoneNumbers).map(normalizePhone))
        var addedPeople: [PersonRecord] = []

        for entry in indexEntries {
            let phone = normalizePhone(entry.normalizedPhone)
            guard !phone.isEmpty,
                  !owned.contains(phone),
                  !unassigned.contains(phone) else {
                continue
            }

            let contactName = entry.contactName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawPhone = entry.rawPhone
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = contactName.isEmpty
                ? (rawPhone.isEmpty ? phone : rawPhone)
                : contactName
            let timestamp = now()
            addedPeople.append(
                PersonRecord(
                    displayName: displayName,
                    phoneNumbers: [phone],
                    createdAt: timestamp,
                    updatedAt: timestamp
                )
            )
            owned.insert(phone)
        }

        guard !addedPeople.isEmpty else { return }
        peopleFile.people.append(contentsOf: addedPeople)
        try savePeople()
    }

    private func requireWritable() throws {
        if case .readOnly(let reason) = access {
            throw PersonArchiveError.readOnly(reason)
        }
    }

    private func savePeople() throws {
        try AtomicJSONFileStore.save(peopleFile, to: peopleURL)
    }

    private func personIndex(for personID: String) throws -> Int {
        guard let index = peopleFile.people.firstIndex(where: { $0.id == personID }) else {
            throw PersonArchiveError.personNotFound(personID)
        }
        return index
    }

    private func validatedDisplayName(_ displayName: String) throws -> String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PersonArchiveError.invalidMerge
        }
        return trimmed
    }

    private func ensurePhonesAreUnowned(
        _ phones: [String],
        allowingOwnerID: String? = nil
    ) throws {
        for phone in phones {
            if let ownerID = ownerID(for: phone),
               ownerID != allowingOwnerID {
                throw PersonArchiveError.phoneConflict(phone: phone, ownerID: ownerID)
            }
        }
    }

    private func ownerID(
        for phone: String,
        excluding excludedIDs: Set<String> = []
    ) -> String? {
        let normalized = normalizePhone(phone)
        guard !normalized.isEmpty else { return nil }
        return peopleFile.people.first {
            !excludedIDs.contains($0.id) && $0.phoneNumbers.contains(normalized)
        }?.id
    }

    private func addUnassignedPhones(_ phones: [String]) {
        peopleFile.unassignedPhoneNumbers = uniquePhones(
            peopleFile.unassignedPhoneNumbers + phones
        )
    }

    private func removeUnassignedPhones(_ phones: [String]) {
        let removed = Set(phones.map(normalizePhone))
        peopleFile.unassignedPhoneNumbers = uniquePhones(
            peopleFile.unassignedPhoneNumbers.filter {
                !removed.contains(normalizePhone($0))
            }
        )
    }

    private func uniquePhones(_ phones: [String]) -> [String] {
        Array(Set(phones.map(normalizePhone).filter { !$0.isEmpty })).sorted()
    }

    private func normalizePhone(_ phone: String) -> String {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.filter(\.isNumber)
        return digits.isEmpty ? trimmed : digits
    }
}
