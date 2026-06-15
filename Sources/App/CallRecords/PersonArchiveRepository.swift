import Foundation

final class PersonArchiveRepository {
    private static let peopleRecoveryFailureReason = "已读取备份，但无法恢复 people.json，请重新载入归档"
    private static let draftsRecoveryFailureReason = "已读取备份，但无法恢复 selection_drafts.json，请重新载入归档"
    private static let versionsRecoveryFailureReason = "已读取备份，但无法恢复 organization_versions.json，请重新载入归档"
    private static let draftSyncFailureReason = "人物归档已保存，但选择草稿未能同步，请重新载入归档"

    private(set) var peopleFile = PeopleFile()
    private(set) var draftsFile = SelectionDraftsFile()
    private(set) var versionsFile = OrganizationVersionsFile()
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

    private var draftsURL: URL {
        archiveRoot.appendingPathComponent("selection_drafts.json")
    }

    private var versionsURL: URL {
        archiveRoot.appendingPathComponent("organization_versions.json")
    }

    init(archiveRoot: URL, now: @escaping () -> Date = Date.init) {
        self.archiveRoot = archiveRoot
        self.now = now
    }

    func load(indexEntries: [CallRecordIndexEntry]? = nil) throws {
        self.indexEntries = try indexEntries
            ?? CallRecordArchiveWriter.loadIndex(from: archiveRoot)

        let peopleResult = AtomicJSONFileStore.load(
            PeopleFile.self,
            from: peopleURL,
            defaultValue: PeopleFile()
        )
        peopleFile = peopleResult.value
        let sanitizedPeopleFile = sanitizePeopleFile()

        let draftsResult = AtomicJSONFileStore.load(
            SelectionDraftsFile.self,
            from: draftsURL,
            defaultValue: SelectionDraftsFile()
        )
        draftsFile = draftsResult.value

        let versionsResult = AtomicJSONFileStore.load(
            OrganizationVersionsFile.self,
            from: versionsURL,
            defaultValue: OrganizationVersionsFile()
        )
        versionsFile = versionsResult.value

        let readOnlyReasons = [
            readOnlyReason(for: peopleResult.access, fileName: "people.json"),
            readOnlyReason(for: draftsResult.access, fileName: "selection_drafts.json"),
            readOnlyReason(for: versionsResult.access, fileName: "organization_versions.json")
        ].compactMap { $0 }
        guard readOnlyReasons.isEmpty else {
            access = .readOnly(reason: readOnlyReasons.joined(separator: "\n"))
            return
        }

        var savedPeopleDuringRecovery = false
        if case .recoveredFromBackup = peopleResult.access {
            do {
                try AtomicJSONFileStore.save(peopleFile, to: peopleURL)
                savedPeopleDuringRecovery = true
            } catch {
                access = .readOnly(reason: Self.peopleRecoveryFailureReason)
                return
            }
        }

        if case .recoveredFromBackup = draftsResult.access {
            do {
                try AtomicJSONFileStore.save(draftsFile, to: draftsURL)
            } catch {
                access = .readOnly(reason: Self.draftsRecoveryFailureReason)
                return
            }
        }

        if case .recoveredFromBackup = versionsResult.access {
            do {
                try AtomicJSONFileStore.save(versionsFile, to: versionsURL)
            } catch {
                access = .readOnly(reason: Self.versionsRecoveryFailureReason)
                return
            }
        }

        access = .writable
        if sanitizedPeopleFile && !savedPeopleDuringRecovery {
            try savePeople()
        }
        try bootstrapMissingPhones()
        do {
            try pruneAllDrafts()
        } catch {
            access = .readOnly(reason: Self.draftSyncFailureReason)
        }
    }

    func draftCallIDs(for personID: String) -> Set<String> {
        Set(draftsFile.drafts[personID]?.callIDs ?? [])
            .intersection(availableCallIDs(for: personID))
    }

    func setDraftCallIDs(_ callIDs: Set<String>, for personID: String) throws {
        try requireWritable()
        let pruned = callIDs.intersection(availableCallIDs(for: personID))
        var stagedDraftsFile = draftsFile
        if pruned.isEmpty {
            stagedDraftsFile.drafts.removeValue(forKey: personID)
        } else {
            stagedDraftsFile.drafts[personID] = PersonSelectionDraft(
                callIDs: pruned.sorted(),
                updatedAt: stableNow()
            )
        }
        try saveDrafts(stagedDraftsFile)
        draftsFile = stagedDraftsFile
    }

    func versions(for personID: String) -> [PersonOrganizationVersion] {
        versionsFile.versions
            .filter { $0.personID == personID }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id < rhs.id
                }
                return lhs.createdAt > rhs.createdAt
            }
    }

    func appendOrganizationVersion(_ version: PersonOrganizationVersion) throws {
        try requireWritable()
        guard !versionsFile.versions.contains(where: { $0.id == version.id }) else {
            return
        }
        try requireExistingResultFile(atPath: version.resultPath)
        var stagedVersionsFile = versionsFile
        stagedVersionsFile.versions.append(version)
        try AtomicJSONFileStore.save(stagedVersionsFile, to: versionsURL)
        versionsFile = stagedVersionsFile
    }

    func clearDraft(for personID: String) throws {
        try setDraftCallIDs([], for: personID)
    }

    func selectAllAvailableCalls(for personID: String) throws {
        try setDraftCallIDs(availableCallIDs(for: personID), for: personID)
    }

    func selectRecentCalls(for personID: String, since date: Date) throws {
        let recentCallIDs = Set(
            calls(for: personID)
                .filter {
                    $0.callDate >= date
                        && PersonTimelineCall(entry: $0).isAvailable
                }
                .map(\.id)
        )
        try setDraftCallIDs(recentCallIDs, for: personID)
    }

    func person(containing phone: String) -> PersonRecord? {
        let normalized = normalizePhone(phone)
        guard !normalized.isEmpty else { return nil }
        return peopleFile.people.first {
            Set($0.phoneNumbers.map(normalizePhone)).contains(normalized)
        }
    }

    func calls(for personID: String) -> [CallRecordIndexEntry] {
        guard let person = peopleFile.people.first(where: { $0.id == personID }) else {
            return []
        }
        let phones = Set(person.phoneNumbers.map(normalizePhone))
        return indexEntries
            .filter { phones.contains(normalizePhone($0.normalizedPhone)) }
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

        let timestamp = stableNow()
        let person = PersonRecord(
            displayName: displayName,
            phoneNumbers: normalizedPhones,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        peopleFile.people.append(person)
        removeUnassignedPhones(normalizedPhones)
        try savePeopleThenPruneDrafts()
        return person
    }

    @discardableResult
    func renamePerson(_ personID: String, displayName: String) throws -> PersonRecord {
        try requireWritable()
        let displayName = try validatedDisplayName(displayName)
        let index = try personIndex(for: personID)
        peopleFile.people[index].displayName = displayName
        peopleFile.people[index].updatedAt = stableNow()
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
        peopleFile.people[index].updatedAt = stableNow()
        removeUnassignedPhones(normalizedPhones)
        let person = peopleFile.people[index]
        try savePeopleThenPruneDrafts()
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
        target.updatedAt = stableNow()

        peopleFile.people.removeAll { selectedIDSet.contains($0.id) }
        peopleFile.people.append(target)
        peopleFile.mergeHistory.append(
            PersonMergeRecord(
                targetPersonID: targetPersonID,
                beforePeople: beforePeople,
                createdAt: stableNow()
            )
        )
        removeUnassignedPhones(target.phoneNumbers)
        try savePeopleThenPruneDrafts()
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
        let sourcePhones = Set(peopleFile.people[sourceIndex].phoneNumbers.map(normalizePhone))
        let movedPhones = requestedPhones.filter { sourcePhones.contains($0) }
        guard !movedPhones.isEmpty else {
            return nil
        }
        let newPersonDisplayName: String?
        if let newDisplayName {
            newPersonDisplayName = try validatedDisplayName(newDisplayName)
        } else {
            newPersonDisplayName = nil
        }

        peopleFile.people[sourceIndex].phoneNumbers = uniquePhones(
            peopleFile.people[sourceIndex].phoneNumbers.filter {
                !movedPhones.contains(normalizePhone($0))
            }
        )
        peopleFile.people[sourceIndex].updatedAt = stableNow()

        if let displayName = newPersonDisplayName {
            let timestamp = stableNow()
            let person = PersonRecord(
                displayName: displayName,
                phoneNumbers: movedPhones,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            peopleFile.people.append(person)
            removeUnassignedPhones(movedPhones)
            try savePeopleThenPruneDrafts()
            return person
        }

        addUnassignedPhones(movedPhones)
        try savePeopleThenPruneDrafts()
        return nil
    }

    func deletePersonKeepingPhonesUnassigned(_ personID: String) throws {
        try requireWritable()
        let index = try personIndex(for: personID)
        let phones = peopleFile.people[index].phoneNumbers
        peopleFile.people.remove(at: index)
        addUnassignedPhones(phones)
        try savePeopleThenPruneDrafts()
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
        peopleFile.mergeHistory[mergeIndex].revertedAt = stableNow()
        removeUnassignedPhones(merge.beforePeople.flatMap(\.phoneNumbers))
        try savePeopleThenPruneDrafts()
    }

    private func readOnlyReason(
        for fileAccess: PersonArchiveAccess,
        fileName: String
    ) -> String? {
        if case .readOnly(let reason) = fileAccess {
            return "\(fileName)：\(reason)"
        }
        return nil
    }

    private func sanitizePeopleFile() -> Bool {
        var sanitized = peopleFile
        sanitized.people = sanitized.people.map(sanitizedPerson)
        sanitized.mergeHistory = sanitized.mergeHistory.map { merge in
            var sanitizedMerge = merge
            sanitizedMerge.beforePeople = merge.beforePeople.map(sanitizedPerson)
            return sanitizedMerge
        }
        sanitized.unassignedPhoneNumbers = uniquePhones(sanitized.unassignedPhoneNumbers)

        guard sanitized != peopleFile else { return false }
        peopleFile = sanitized
        return true
    }

    private func sanitizedPerson(_ person: PersonRecord) -> PersonRecord {
        var sanitized = person
        sanitized.phoneNumbers = uniquePhones(person.phoneNumbers)
        return sanitized
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
            let timestamp = stableNow()
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

    private func saveDrafts() throws {
        try saveDrafts(draftsFile)
    }

    private func saveDrafts(_ draftsFile: SelectionDraftsFile) throws {
        try AtomicJSONFileStore.save(draftsFile, to: draftsURL)
    }

    private func savePeopleThenPruneDrafts() throws {
        try savePeople()
        do {
            try pruneAllDrafts()
        } catch {
            access = .readOnly(reason: Self.draftSyncFailureReason)
            throw PersonArchiveError.readOnly(Self.draftSyncFailureReason)
        }
    }

    private func requireExistingResultFile(atPath path: String) throws {
        var isDirectory: ObjCBool = false
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw CocoaError(
                .fileNoSuchFile,
                userInfo: [NSFilePathErrorKey: path]
            )
        }
    }

    private func availableCallIDs(for personID: String) -> Set<String> {
        Set(
            calls(for: personID)
                .filter { PersonTimelineCall(entry: $0).isAvailable }
                .map(\.id)
        )
    }

    private func pruneAllDrafts() throws {
        var prunedDrafts = draftsFile.drafts
        var didChange = false

        for (personID, draft) in draftsFile.drafts {
            let validCallIDs = availableCallIDs(for: personID)
            let prunedCallIDs = Set(draft.callIDs)
                .intersection(validCallIDs)
                .sorted()

            if prunedCallIDs.isEmpty {
                prunedDrafts.removeValue(forKey: personID)
                didChange = true
            } else if prunedCallIDs != draft.callIDs {
                var prunedDraft = draft
                prunedDraft.callIDs = prunedCallIDs
                prunedDrafts[personID] = prunedDraft
                didChange = true
            }
        }

        guard didChange else { return }
        draftsFile.drafts = prunedDrafts
        try saveDrafts()
    }

    private func stableNow() -> Date {
        let milliseconds = floor(now().timeIntervalSince1970 * 1_000) / 1_000
        return Date(timeIntervalSince1970: milliseconds)
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
            !excludedIDs.contains($0.id)
                && Set($0.phoneNumbers.map(normalizePhone)).contains(normalized)
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
