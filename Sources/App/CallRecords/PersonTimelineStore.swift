import Combine
import Foundation

@MainActor
final class PersonTimelineStore: ObservableObject {
    @Published private(set) var archiveRoot: URL?
    @Published private(set) var people: [PersonRecord] = []
    @Published private(set) var selectedPersonID: String?
    @Published private(set) var calls: [PersonTimelineCall] = []
    @Published private(set) var selectedCallIDs: Set<String> = []
    @Published private(set) var versions: [PersonOrganizationVersion] = []
    @Published private(set) var access: PersonArchiveAccess = .writable
    @Published private(set) var unassignedPhoneNumbers: [String] = []
    @Published private(set) var pendingVersionRepair: PersonOrganizationVersion?
    @Published var searchText = ""
    @Published var errorMessage: String?

    private var repository: PersonArchiveRepository?

    var filteredPeople: [PersonRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return people }

        return people.filter { person in
            person.displayName.localizedCaseInsensitiveContains(query)
                || person.phoneNumbers.contains {
                    $0.localizedCaseInsensitiveContains(query)
                }
        }
    }

    var selectedPerson: PersonRecord? {
        guard let selectedPersonID else { return nil }
        return people.first { $0.id == selectedPersonID }
    }

    var mergeSuggestions: [[PersonRecord]] {
        let namedPeople = people.filter { person in
            !person.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let groups = Dictionary(grouping: namedPeople) { person in
            person.displayName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }

        return groups.values
            .filter { $0.count > 1 }
            .map { group in
                group.sorted { lhs, rhs in
                    if lhs.displayName == rhs.displayName {
                        return lhs.id < rhs.id
                    }
                    return lhs.displayName.localizedStandardCompare(rhs.displayName)
                        == .orderedAscending
                }
            }
            .sorted { lhs, rhs in
                guard let lhsName = lhs.first?.displayName,
                      let rhsName = rhs.first?.displayName else {
                    return lhs.count > rhs.count
                }
                let comparison = lhsName.localizedStandardCompare(rhsName)
                if comparison == .orderedSame {
                    return lhs.map(\.id).joined() < rhs.map(\.id).joined()
                }
                return comparison == .orderedAscending
            }
    }

    var activeMergeRecords: [PersonMergeRecord] {
        repository?.peopleFile.mergeHistory
            .filter { $0.revertedAt == nil }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id > rhs.id
                }
                return lhs.createdAt > rhs.createdAt
            } ?? []
    }

    func openArchive(_ root: URL) throws {
        let previousSelection = selectedPersonID
        let nextRepository = PersonArchiveRepository(archiveRoot: root)
        try nextRepository.load()

        repository = nextRepository
        archiveRoot = root
        pendingVersionRepair = nextRepository.pendingVersionRepair
        refreshArchiveState(preferredPersonID: previousSelection)
    }

    func reload() throws {
        guard let archiveRoot else { return }
        try openArchive(archiveRoot)
    }

    func callSummary(for personID: String) -> (count: Int, latestDateText: String?) {
        guard let repository else {
            return (0, nil)
        }
        let personCalls = repository.calls(for: personID)
        return (personCalls.count, personCalls.first?.callDateText)
    }

    func callCount(for personID: String) -> Int {
        callSummary(for: personID).count
    }

    func selectPerson(_ id: String) {
        guard people.contains(where: { $0.id == id }) else {
            refreshSelectedPerson(nil)
            return
        }
        refreshSelectedPerson(id)
    }

    func toggleCall(_ id: String) throws {
        guard let selectedPersonID,
              let call = calls.first(where: { $0.id == id }),
              let repository else {
            return
        }

        var nextSelection = selectedCallIDs
        if nextSelection.contains(id) {
            nextSelection.remove(id)
        } else {
            guard call.isAvailable else { return }
            nextSelection.insert(id)
        }
        try repository.setDraftCallIDs(nextSelection, for: selectedPersonID)
        refreshSelectionOnly()
    }

    func selectAll() throws {
        guard let selectedPersonID, let repository else { return }
        try repository.selectAllAvailableCalls(for: selectedPersonID)
        refreshSelectionOnly()
    }

    func clearSelection() throws {
        guard let selectedPersonID, let repository else { return }
        try repository.clearDraft(for: selectedPersonID)
        refreshSelectionOnly()
    }

    func selectRecent30Days(referenceDate: Date = Date()) throws {
        guard let selectedPersonID, let repository else { return }
        let cutoff = referenceDate.addingTimeInterval(-30 * 24 * 60 * 60)
        try repository.selectRecentCalls(for: selectedPersonID, since: cutoff)
        refreshSelectionOnly()
    }

    func createPerson(displayName: String, phones: [String]) throws {
        guard let repository else { return }
        let person = try repository.createPerson(displayName: displayName, phones: phones)
        refreshArchiveState(preferredPersonID: person.id)
    }

    func renamePerson(_ id: String, displayName: String) throws {
        guard let repository else { return }
        _ = try repository.renamePerson(id, displayName: displayName)
        refreshArchiveState(preferredPersonID: id)
    }

    func assignUnassignedPhones(_ phones: [String], to personID: String) throws {
        guard let repository else { return }
        _ = try repository.assignUnassignedPhones(phones, to: personID)
        refreshArchiveState(preferredPersonID: personID)
    }

    func deletePersonKeepingPhonesUnassigned(_ id: String) throws {
        guard let repository else { return }
        try repository.deletePersonKeepingPhonesUnassigned(id)
        refreshArchiveState(preferredPersonID: selectedPersonID)
    }

    func mergePeople(
        personIDs: [String],
        targetID: String,
        displayName: String
    ) throws {
        guard let repository else { return }
        let target = try repository.mergePeople(
            personIDs: personIDs,
            targetPersonID: targetID,
            displayName: displayName
        )
        refreshArchiveState(preferredPersonID: target.id)
    }

    func splitPhones(
        personID: String,
        phones: [String],
        newDisplayName: String?
    ) throws {
        guard let repository else { return }
        let newPerson = try repository.splitPhones(
            from: personID,
            phones: phones,
            newDisplayName: newDisplayName
        )
        refreshArchiveState(preferredPersonID: newPerson?.id ?? personID)
    }

    func revertMerge(_ id: String) throws {
        guard let repository else { return }
        try repository.revertMerge(id)
        refreshArchiveState(preferredPersonID: selectedPersonID)
    }

    func prepareOrganization() throws -> PersonOrganizationPreparation {
        guard let repository,
              let selectedPersonID,
              let person = people.first(where: { $0.id == selectedPersonID }) else {
            throw PersonArchiveError.personNotFound(selectedPersonID ?? "")
        }

        return try PersonOrganizationInputBuilder.prepare(
            person: person,
            selectedCallIDs: selectedCallIDs,
            calls: repository.calls(for: selectedPersonID),
            archiveRoot: archiveRoot
        )
    }

    func commitOrganizationVersion(_ version: PersonOrganizationVersion) throws {
        guard let repository else { return }

        do {
            try repository.appendOrganizationVersion(version)
        } catch {
            if let repairPersistenceError = rememberPendingVersionRepair(
                version,
                repository: repository
            ) {
                throw repairPersistenceError
            }
            throw error
        }

        do {
            try repository.clearDraft(for: version.personID)
        } catch {
            if let repairPersistenceError = rememberPendingVersionRepair(
                version,
                repository: repository
            ) {
                throw repairPersistenceError
            }
            refreshArchiveState(preferredPersonID: version.personID)
            throw error
        }
        try repository.clearPendingVersionRepair()
        pendingVersionRepair = nil
        refreshArchiveState(preferredPersonID: version.personID)
    }

    func preserveDraftAfterFailedRun() {
        // Persisted selection drafts remain authoritative after a failed run.
    }

    func repairVersionIndex() throws {
        guard let repository,
              let version = pendingVersionRepair else {
            return
        }

        try repository.appendOrganizationVersion(version)
        do {
            try repository.clearDraft(for: version.personID)
        } catch {
            if let repairPersistenceError = rememberPendingVersionRepair(
                version,
                repository: repository
            ) {
                throw repairPersistenceError
            }
            refreshArchiveState(preferredPersonID: version.personID)
            throw error
        }
        try repository.clearPendingVersionRepair()
        pendingVersionRepair = nil
        refreshArchiveState(preferredPersonID: version.personID)
    }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    func present(_ message: String) {
        errorMessage = message
    }

    private func refreshArchiveState(preferredPersonID: String?) {
        guard let repository else {
            clearArchiveState()
            return
        }

        people = repository.people
        unassignedPhoneNumbers = repository.peopleFile.unassignedPhoneNumbers.sorted()
        access = repository.access
        pendingVersionRepair = repository.pendingVersionRepair

        let selectedID = stablePersonID(preferredPersonID)
            ?? stablePersonID(selectedPersonID)
            ?? people.first?.id
        refreshSelectedPerson(selectedID)
    }

    private func refreshSelectedPerson(_ id: String?) {
        selectedPersonID = id

        guard let id, let repository else {
            calls = []
            selectedCallIDs = []
            versions = []
            return
        }

        calls = repository.calls(for: id).map { entry in
            PersonTimelineCall(
                entry: entry,
                resolvedSource: PersonTimelineCall.resolveSource(
                    for: entry,
                    archiveRoot: archiveRoot
                )
            )
        }
        selectedCallIDs = repository.draftCallIDs(for: id)
        versions = repository.versions(for: id)
    }

    /// 仅刷新选择状态。选择类操作（勾选/全选/清空）不改变通话列表与版本，
    /// 因此无需重建 calls（避免对全部通话重复做文件可用性 stat）。
    private func refreshSelectionOnly() {
        guard let selectedPersonID, let repository else {
            selectedCallIDs = []
            return
        }
        selectedCallIDs = repository.draftCallIDs(for: selectedPersonID)
    }

    private func stablePersonID(_ id: String?) -> String? {
        guard let id,
              people.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }

    private func clearArchiveState() {
        archiveRoot = nil
        people = []
        selectedPersonID = nil
        calls = []
        selectedCallIDs = []
        versions = []
        access = .writable
        unassignedPhoneNumbers = []
        pendingVersionRepair = nil
    }

    private func rememberPendingVersionRepair(
        _ version: PersonOrganizationVersion,
        repository: PersonArchiveRepository
    ) -> Error? {
        pendingVersionRepair = version
        do {
            try repository.recordPendingVersionRepair(version)
            return nil
        } catch {
            errorMessage = error.localizedDescription
            return error
        }
    }
}
