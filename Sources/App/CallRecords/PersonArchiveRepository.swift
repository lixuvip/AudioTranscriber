import Foundation

final class PersonArchiveRepository {
    private static let peopleRecoveryFailureReason = "已读取备份，但无法恢复 people.json，请重新载入归档"
    private static let draftsRecoveryFailureReason = "已读取备份，但无法恢复 selection_drafts.json，请重新载入归档"
    private static let versionsRecoveryFailureReason = "已读取备份，但无法恢复 organization_versions.json，请重新载入归档"
    private static let pendingRepairRecoveryFailureReason = "已读取备份，但无法恢复 organization_pending_repair.json，请重新载入归档"
    private static let draftSyncFailureReason = "人物归档已保存，但选择草稿未能同步，请重新载入归档"

    private(set) var peopleFile = PeopleFile()
    private(set) var draftsFile = SelectionDraftsFile()
    private(set) var versionsFile = OrganizationVersionsFile()
    private(set) var pendingRepairFile = PendingOrganizationRepairFile()
    private(set) var indexEntries: [CallRecordIndexEntry] = []
    private(set) var access: PersonArchiveAccess = .writable

    /// 归一化电话号码 → 该号码的所有通话条目。随 indexEntries 一同重建，
    /// 让 calls(for:) 从每次 O(全部条目) 降到 O(人物电话数)。
    private var entriesByPhone: [String: [CallRecordIndexEntry]] = [:]

    var people: [PersonRecord] {
        peopleFile.people.sorted { lhs, rhs in
            let comparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
            if comparison == .orderedSame {
                return lhs.id < rhs.id
            }
            return comparison == .orderedAscending
        }
    }

    var pendingVersionRepair: PersonOrganizationVersion? {
        pendingRepairFile.version
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

    private var pendingRepairURL: URL {
        archiveRoot.appendingPathComponent("organization_pending_repair.json")
    }

    init(archiveRoot: URL, now: @escaping () -> Date = Date.init) {
        self.archiveRoot = archiveRoot
        self.now = now
    }

    func load(indexEntries: [CallRecordIndexEntry]? = nil) throws {
        self.indexEntries = try indexEntries
            ?? CallRecordArchiveWriter.loadIndex(from: archiveRoot)
        rebuildPhoneIndex()

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

        let pendingRepairResult = AtomicJSONFileStore.load(
            PendingOrganizationRepairFile.self,
            from: pendingRepairURL,
            defaultValue: PendingOrganizationRepairFile()
        )
        pendingRepairFile = pendingRepairResult.value

        let readOnlyReasons = [
            readOnlyReason(for: peopleResult.access, fileName: "people.json"),
            readOnlyReason(for: draftsResult.access, fileName: "selection_drafts.json"),
            readOnlyReason(for: versionsResult.access, fileName: "organization_versions.json"),
            readOnlyReason(
                for: pendingRepairResult.access,
                fileName: "organization_pending_repair.json"
            )
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

        if case .recoveredFromBackup = pendingRepairResult.access {
            do {
                try AtomicJSONFileStore.save(pendingRepairFile, to: pendingRepairURL)
            } catch {
                access = .readOnly(reason: Self.pendingRepairRecoveryFailureReason)
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
            .intersection(personCallIDs(for: personID))
    }

    func setDraftCallIDs(_ callIDs: Set<String>, for personID: String) throws {
        try requireWritable()
        let pruned = callIDs.intersection(personCallIDs(for: personID))
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
        try setDraftCallIDs(readableCallIDs(for: personID), for: personID)
    }

    func selectRecentCalls(for personID: String, since date: Date) throws {
        let recentCallIDs = Set(
            calls(for: personID)
                .filter {
                    $0.callDate >= date
                        && PersonTimelineCall(entry: $0, resolvedSource: source(for: $0)).isAvailable
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
        // 每个号码归一化后唯一指向一组条目，号码互不重叠，无需再去重。
        return phones
            .flatMap { entriesByPhone[$0] ?? [] }
            .sorted { lhs, rhs in
                if lhs.callDate == rhs.callDate {
                    return lhs.id < rhs.id
                }
                return lhs.callDate > rhs.callDate
            }
    }

    private func rebuildPhoneIndex() {
        var index: [String: [CallRecordIndexEntry]] = [:]
        for entry in indexEntries {
            index[normalizePhone(entry.normalizedPhone), default: []].append(entry)
        }
        entriesByPhone = index
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
        let draftsBeforeMerge = draftsFile
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
        migrateDraftsAfterMerge(
            selectedPersonIDs: selectedIDSet,
            targetPersonID: targetPersonID
        )
        try savePeopleThenPruneDrafts(forceDraftSave: draftsFile != draftsBeforeMerge)
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
        guard let targetBeforeMerge = merge.beforePeople.first(
            where: { $0.id == merge.targetPersonID }
        ) else {
            throw PersonArchiveError.personNotFound(merge.targetPersonID)
        }
        let sourcePeople = merge.beforePeople.filter { $0.id != merge.targetPersonID }
        let sourceIDs = Set(sourcePeople.map(\.id))
        let allowedExistingOwnerIDs = sourceIDs.union([merge.targetPersonID])
        let sourcePhones = uniquePhones(sourcePeople.flatMap(\.phoneNumbers))
        for phone in sourcePhones {
            if let ownerID = ownerID(for: phone, excluding: allowedExistingOwnerIDs) {
                throw PersonArchiveError.phoneConflict(phone: phone, ownerID: ownerID)
            }
        }

        let draftsBeforeRevert = draftsFile
        peopleFile.people.removeAll {
            sourceIDs.contains($0.id)
        }
        if let targetIndex = peopleFile.people.firstIndex(where: { $0.id == merge.targetPersonID }) {
            peopleFile.people[targetIndex].phoneNumbers = uniquePhones(
                peopleFile.people[targetIndex].phoneNumbers.filter {
                    !sourcePhones.contains(normalizePhone($0))
                }
            )
            peopleFile.people[targetIndex].updatedAt = stableNow()
        } else {
            for phone in targetBeforeMerge.phoneNumbers {
                if let ownerID = ownerID(for: phone, excluding: [merge.targetPersonID]) {
                    throw PersonArchiveError.phoneConflict(phone: phone, ownerID: ownerID)
                }
            }
            peopleFile.people.append(targetBeforeMerge)
        }
        peopleFile.people.append(contentsOf: sourcePeople)
        peopleFile.mergeHistory[mergeIndex].revertedAt = stableNow()
        removeUnassignedPhones(merge.beforePeople.flatMap(\.phoneNumbers))
        migrateDraftsAfterRevertingMerge(merge)
        try savePeopleThenPruneDrafts(forceDraftSave: draftsFile != draftsBeforeRevert)
    }

    func recordPendingVersionRepair(_ version: PersonOrganizationVersion) throws {
        try requireWritable()
        pendingRepairFile = PendingOrganizationRepairFile(version: version)
        try AtomicJSONFileStore.save(pendingRepairFile, to: pendingRepairURL)
    }

    func clearPendingVersionRepair() throws {
        try requireWritable()
        pendingRepairFile = PendingOrganizationRepairFile()
        try AtomicJSONFileStore.save(pendingRepairFile, to: pendingRepairURL)
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

    private func savePeopleThenPruneDrafts(forceDraftSave: Bool = false) throws {
        try savePeople()
        do {
            try pruneAllDrafts(forceSave: forceDraftSave)
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

    private func personCallIDs(for personID: String) -> Set<String> {
        Set(calls(for: personID).map(\.id))
    }

    private func readableCallIDs(for personID: String) -> Set<String> {
        Set(
            calls(for: personID)
                .filter { PersonTimelineCall(entry: $0, resolvedSource: source(for: $0)).isAvailable }
                .map(\.id)
        )
    }

    private func pruneAllDrafts(forceSave: Bool = false) throws {
        var prunedDrafts = draftsFile.drafts
        var didChange = false

        for (personID, draft) in draftsFile.drafts {
            let validCallIDs = personCallIDs(for: personID)
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

        guard didChange || forceSave else { return }
        draftsFile.drafts = prunedDrafts
        try saveDrafts()
    }

    private func source(for entry: CallRecordIndexEntry) -> PersonTimelineCall.SourceResolution {
        PersonTimelineCall.resolveSource(for: entry, archiveRoot: archiveRoot)
    }

    private func migrateDraftsAfterMerge(
        selectedPersonIDs: Set<String>,
        targetPersonID: String
    ) {
        let mergedCallIDs = Set(
            selectedPersonIDs.flatMap { draftsFile.drafts[$0]?.callIDs ?? [] }
        )
        var stagedDraftsFile = draftsFile
        for personID in selectedPersonIDs where personID != targetPersonID {
            stagedDraftsFile.drafts.removeValue(forKey: personID)
        }

        let targetCallIDs = mergedCallIDs
            .union(Set(stagedDraftsFile.drafts[targetPersonID]?.callIDs ?? []))
            .intersection(personCallIDs(for: targetPersonID))
            .sorted()
        if targetCallIDs.isEmpty {
            stagedDraftsFile.drafts.removeValue(forKey: targetPersonID)
        } else {
            stagedDraftsFile.drafts[targetPersonID] = PersonSelectionDraft(
                callIDs: targetCallIDs,
                updatedAt: stableNow()
            )
        }
        draftsFile = stagedDraftsFile
    }

    private func migrateDraftsAfterRevertingMerge(_ merge: PersonMergeRecord) {
        let targetDraftCallIDs = Set(
            draftsFile.drafts[merge.targetPersonID]?.callIDs ?? []
        )
        guard !targetDraftCallIDs.isEmpty else { return }

        let sourcePeople = merge.beforePeople.filter { $0.id != merge.targetPersonID }
        var stagedDraftsFile = draftsFile
        var remainingTargetCallIDs = targetDraftCallIDs

        for sourcePerson in sourcePeople {
            let sourceCallIDs = personCallIDs(for: sourcePerson.id)
            let movedCallIDs = targetDraftCallIDs.intersection(sourceCallIDs)
            guard !movedCallIDs.isEmpty else { continue }

            let existingCallIDs = Set(
                stagedDraftsFile.drafts[sourcePerson.id]?.callIDs ?? []
            )
            let nextSourceCallIDs = existingCallIDs
                .union(movedCallIDs)
                .intersection(sourceCallIDs)
                .sorted()
            stagedDraftsFile.drafts[sourcePerson.id] = PersonSelectionDraft(
                callIDs: nextSourceCallIDs,
                updatedAt: stableNow()
            )
            remainingTargetCallIDs.subtract(movedCallIDs)
        }

        let targetCallIDs = remainingTargetCallIDs
            .intersection(personCallIDs(for: merge.targetPersonID))
            .sorted()
        if targetCallIDs.isEmpty {
            stagedDraftsFile.drafts.removeValue(forKey: merge.targetPersonID)
        } else {
            stagedDraftsFile.drafts[merge.targetPersonID] = PersonSelectionDraft(
                callIDs: targetCallIDs,
                updatedAt: stableNow()
            )
        }
        draftsFile = stagedDraftsFile
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
