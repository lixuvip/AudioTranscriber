import Foundation

@main
struct PersonSelectionDraftCheck {
    static func main() async throws {
        try checkBasicPrunePersistAndClear()
        try checkUnavailableCallsArePruned()
        try checkSplitPrunesDraftsAfterOwnershipChange()
        try checkStaleDraftsArePrunedOnLoad()
        try checkDraftBackupRecoveryRestoresPrimary()
        try checkDraftBackupRecoverySaveFailureUsesSafeMessage()
        try checkDraftSaveFailureAfterPeopleSaveMarksReadOnly()
        try checkDraftCorruptionMakesRepositoryReadOnly()
        try await checkStoreTogglePersistsDraft()
        try await checkStoreCallSummaryCoversEveryPerson()
        try await checkStoreSelectRecent30Days()
        try await checkStorePrepareOrganizationUsesCurrentSelection()
        try await checkStoreCommitRepairAndClearDraft()
        try await checkStoreCommitRefreshesAfterDraftClearFails()
        try await checkStoreRepairPreservesPendingWhenDraftClearFails()
        print("PersonSelectionDraftCheck passed")
    }

    private static func checkBasicPrunePersistAndClear() throws {
        try withTemporaryDirectory("basic-prune-persist-clear") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188"],
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 10)
            )
            try savePeople([person], to: root)

            let callA = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )
            let callB = try makeAvailableCall(
                root: root,
                id: "call-b",
                name: "章文",
                phone: "15397111188",
                time: 200
            )
            let entries = [callA, callB]

            let repository = PersonArchiveRepository(
                archiveRoot: root,
                now: { Date(timeIntervalSince1970: 500) }
            )
            try repository.load(indexEntries: entries)

            try repository.setDraftCallIDs(
                Set(["call-a", "call-b", "missing-call"]),
                for: person.id
            )
            assertEqual(
                repository.draftCallIDs(for: person.id),
                Set(["call-a", "call-b"]),
                "setDraftCallIDs prunes unknown call IDs"
            )
            assertEqual(
                repository.draftsFile.drafts[person.id]?.callIDs,
                ["call-a", "call-b"],
                "draft persists sorted call IDs in memory"
            )

            let reloaded = PersonArchiveRepository(archiveRoot: root)
            try reloaded.load(indexEntries: entries)
            assertEqual(
                reloaded.draftCallIDs(for: person.id),
                Set(["call-a", "call-b"]),
                "draft reloads from selection_drafts.json"
            )

            try reloaded.selectRecentCalls(
                for: person.id,
                since: Date(timeIntervalSince1970: 150)
            )
            assertEqual(
                reloaded.draftCallIDs(for: person.id),
                Set(["call-b"]),
                "selectRecentCalls keeps available calls on or after cutoff"
            )

            try reloaded.clearDraft(for: person.id)
            assertEqual(
                reloaded.draftCallIDs(for: person.id),
                [],
                "clearDraft removes in-memory draft"
            )

            let cleared = PersonArchiveRepository(archiveRoot: root)
            try cleared.load(indexEntries: entries)
            assertEqual(
                cleared.draftCallIDs(for: person.id),
                [],
                "clearDraft persists removed draft"
            )
            assertEqual(
                cleared.draftsFile.drafts[person.id],
                nil,
                "cleared draft key is absent after reload"
            )
        }
    }

    private static func checkUnavailableCallsArePruned() throws {
        try withTemporaryDirectory("unavailable-pruning") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            )
            try savePeople([person], to: root)

            let available = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )
            let unavailable = makeCall(
                root: root,
                id: "call-missing",
                name: "章文",
                phone: "15397111188",
                time: 200,
                transcriptPath: root.appendingPathComponent("missing-transcript.md").path,
                speakerTextPath: ""
            )

            let repository = PersonArchiveRepository(archiveRoot: root)
            try repository.load(indexEntries: [available, unavailable])

            try repository.setDraftCallIDs(
                Set(["call-a", "call-missing"]),
                for: person.id
            )
            assertEqual(
                repository.draftCallIDs(for: person.id),
                Set(["call-a"]),
                "unavailable call is pruned from draft"
            )

            try repository.selectAllAvailableCalls(for: person.id)
            assertEqual(
                repository.draftCallIDs(for: person.id),
                Set(["call-a"]),
                "selectAllAvailableCalls ignores unavailable calls"
            )
        }
    }

    private static func checkSplitPrunesDraftsAfterOwnershipChange() throws {
        try withTemporaryDirectory("split-prunes-drafts") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188", "13102133750"]
            )
            try savePeople([person], to: root)

            let callA = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )
            let callB = try makeAvailableCall(
                root: root,
                id: "call-b",
                name: "章文",
                phone: "13102133750",
                time: 200
            )
            let entries = [callA, callB]

            let repository = PersonArchiveRepository(archiveRoot: root)
            try repository.load(indexEntries: entries)
            try repository.setDraftCallIDs(Set(["call-a", "call-b"]), for: person.id)

            _ = try repository.splitPhones(
                from: person.id,
                phones: ["13102133750"],
                newDisplayName: "章文拆分"
            )
            assertEqual(
                repository.draftCallIDs(for: person.id),
                Set(["call-a"]),
                "splitPhones prunes calls moved away from source person"
            )

            let reloaded = PersonArchiveRepository(archiveRoot: root)
            try reloaded.load(indexEntries: entries)
            assertEqual(
                reloaded.draftCallIDs(for: person.id),
                Set(["call-a"]),
                "splitPhones pruning persists selection_drafts.json"
            )
        }
    }

    private static func checkDraftCorruptionMakesRepositoryReadOnly() throws {
        try withTemporaryDirectory("draft-corruption-read-only") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            )
            try savePeople([person], to: root)
            let call = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )

            let draftsURL = root.appendingPathComponent("selection_drafts.json")
            try Data("{broken-primary".utf8).write(to: draftsURL)
            try Data("{broken-backup".utf8).write(
                to: draftsURL.appendingPathExtension("backup")
            )

            let repository = PersonArchiveRepository(archiveRoot: root)
            try repository.load(indexEntries: [call])
            switch repository.access {
            case .readOnly(let reason):
                assertEqual(reason.isEmpty, false, "draft corruption read-only reason")
            default:
                fatalError("draft corruption should make repository read-only")
            }

            assertThrowsReadOnly("setDraftCallIDs") {
                try repository.setDraftCallIDs(Set(["call-a"]), for: person.id)
            }
            assertThrowsReadOnly("selectAllAvailableCalls") {
                try repository.selectAllAvailableCalls(for: person.id)
            }
            assertThrowsReadOnly("selectRecentCalls") {
                try repository.selectRecentCalls(
                    for: person.id,
                    since: Date(timeIntervalSince1970: 0)
                )
            }
            assertThrowsReadOnly("clearDraft") {
                try repository.clearDraft(for: person.id)
            }
        }
    }

    private static func checkStaleDraftsArePrunedOnLoad() throws {
        try withTemporaryDirectory("stale-drafts-pruned-on-load") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            )
            try savePeople([person], to: root)

            let available = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )
            let unavailable = makeCall(
                root: root,
                id: "call-missing-source",
                name: "章文",
                phone: "15397111188",
                time: 200,
                transcriptPath: root.appendingPathComponent("missing-source.md").path,
                speakerTextPath: ""
            )
            try saveDrafts(
                SelectionDraftsFile(
                    drafts: [
                        person.id: PersonSelectionDraft(
                            callIDs: [
                                "call-a",
                                "call-missing-source",
                                "call-not-in-index"
                            ],
                            updatedAt: Date(timeIntervalSince1970: 20)
                        ),
                        "stale-person": PersonSelectionDraft(
                            callIDs: ["call-a"],
                            updatedAt: Date(timeIntervalSince1970: 20)
                        )
                    ]
                ),
                to: root
            )

            let repository = PersonArchiveRepository(archiveRoot: root)
            try repository.load(indexEntries: [available, unavailable])
            assertEqual(
                repository.draftCallIDs(for: person.id),
                Set(["call-a"]),
                "load prunes missing and unavailable draft call IDs"
            )
            assertEqual(
                repository.draftsFile.drafts["stale-person"],
                nil,
                "load removes stale person draft"
            )

            let reloaded = PersonArchiveRepository(archiveRoot: root)
            try reloaded.load(indexEntries: [available, unavailable])
            assertEqual(
                reloaded.draftCallIDs(for: person.id),
                Set(["call-a"]),
                "load-time pruning is persisted"
            )
            assertEqual(
                reloaded.draftsFile.drafts["stale-person"],
                nil,
                "stale person draft stays removed after reload"
            )
        }
    }

    private static func checkDraftBackupRecoveryRestoresPrimary() throws {
        try withTemporaryDirectory("draft-backup-recovery") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            )
            try savePeople([person], to: root)
            let call = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )

            let draftsURL = root.appendingPathComponent("selection_drafts.json")
            try saveDrafts(
                SelectionDraftsFile(
                    drafts: [
                        person.id: PersonSelectionDraft(
                            callIDs: ["call-a"],
                            updatedAt: Date(timeIntervalSince1970: 20)
                        )
                    ]
                ),
                to: root
            )
            try FileManager.default.moveItem(
                at: draftsURL,
                to: draftsURL.appendingPathExtension("backup")
            )
            try Data("{broken-primary".utf8).write(to: draftsURL)

            let repository = PersonArchiveRepository(archiveRoot: root)
            try repository.load(indexEntries: [call])
            assertWritable(repository.access, "draft backup recovery access")
            assertEqual(
                repository.draftCallIDs(for: person.id),
                Set(["call-a"]),
                "draft backup recovery loads valid draft"
            )

            let restored = AtomicJSONFileStore.load(
                SelectionDraftsFile.self,
                from: draftsURL,
                defaultValue: SelectionDraftsFile()
            )
            assertEqual(
                restored.value.drafts[person.id]?.callIDs,
                ["call-a"],
                "draft backup recovery restores primary file"
            )
            assertEqual(restored.access, .writable, "restored draft primary is readable")
        }
    }

    private static func checkDraftBackupRecoverySaveFailureUsesSafeMessage() throws {
        try withTemporaryDirectory("draft-backup-recovery-save-failure") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            )
            try savePeople([person], to: root)
            let call = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )

            let draftsURL = root.appendingPathComponent("selection_drafts.json")
            try saveDrafts(
                SelectionDraftsFile(
                    drafts: [
                        person.id: PersonSelectionDraft(
                            callIDs: ["call-a"],
                            updatedAt: Date(timeIntervalSince1970: 20)
                        )
                    ]
                ),
                to: root
            )
            try FileManager.default.moveItem(
                at: draftsURL,
                to: draftsURL.appendingPathExtension("backup")
            )
            try Data("{broken-primary".utf8).write(to: draftsURL)
            try FileManager.default.setAttributes(
                [.immutable: true],
                ofItemAtPath: draftsURL.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.immutable: false],
                    ofItemAtPath: draftsURL.path
                )
            }

            let repository = PersonArchiveRepository(archiveRoot: root)
            try repository.load(indexEntries: [call])
            switch repository.access {
            case .readOnly(let reason):
                assertEqual(
                    reason,
                    "已读取备份，但无法恢复 selection_drafts.json，请重新载入归档",
                    "draft recovery save failure uses sanitized reason"
                )
            default:
                fatalError("draft recovery save failure should enter read-only")
            }
        }
    }

    private static func checkDraftSaveFailureAfterPeopleSaveMarksReadOnly() throws {
        try withTemporaryDirectory("draft-save-failure-after-people-save") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188", "13102133750"]
            )
            try savePeople([person], to: root)
            let callA = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )
            let callB = try makeAvailableCall(
                root: root,
                id: "call-b",
                name: "章文",
                phone: "13102133750",
                time: 200
            )
            let repository = PersonArchiveRepository(archiveRoot: root)
            try repository.load(indexEntries: [callA, callB])
            try repository.setDraftCallIDs(
                Set(["call-a", "call-b"]),
                for: person.id
            )

            let draftsURL = root.appendingPathComponent("selection_drafts.json")
            try FileManager.default.setAttributes(
                [.immutable: true],
                ofItemAtPath: draftsURL.path
            )
            defer {
                try? FileManager.default.setAttributes(
                    [.immutable: false],
                    ofItemAtPath: draftsURL.path
                )
            }

            do {
                _ = try repository.splitPhones(
                    from: person.id,
                    phones: ["13102133750"],
                    newDisplayName: "章文拆分"
                )
                fatalError("split should surface draft save failure")
            } catch {
                switch repository.access {
                case .readOnly(let reason):
                    assertEqual(
                        reason,
                        "人物归档已保存，但选择草稿未能同步，请重新载入归档",
                        "draft save failure uses sanitized read-only reason"
                    )
                default:
                    fatalError("draft save failure should mark repository read-only")
                }
            }
        }
    }

    private static func checkStoreTogglePersistsDraft() async throws {
        try await withTemporaryDirectoryAsync("store-toggle-persists-draft") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            )
            try savePeople([person], to: root)
            let callA = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )
            let callB = try makeAvailableCall(
                root: root,
                id: "call-b",
                name: "章文",
                phone: "15397111188",
                time: 200
            )
            try saveIndex([callA, callB], to: root)

            let store = await MainActor.run { PersonTimelineStore() }
            try await MainActor.run {
                try store.openArchive(root)
                store.selectPerson(person.id)
                try store.toggleCall("call-a")
            }
            assertEqual(
                await MainActor.run { store.selectedCallIDs },
                Set(["call-a"]),
                "store toggles whole call"
            )

            let reloaded = await MainActor.run { PersonTimelineStore() }
            try await MainActor.run {
                try reloaded.openArchive(root)
                reloaded.selectPerson(person.id)
            }
            assertEqual(
                await MainActor.run { reloaded.selectedCallIDs },
                Set(["call-a"]),
                "store draft reloads after opening archive"
            )
        }
    }

    private static func checkStoreCallSummaryCoversEveryPerson() async throws {
        try await withTemporaryDirectoryAsync("store-call-summary") { root in
            let personA = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            )
            let personB = PersonRecord(
                id: "person-b",
                displayName: "李雷",
                phoneNumbers: ["13102133750"]
            )
            try savePeople([personA, personB], to: root)

            let callAOld = try makeAvailableCall(
                root: root,
                id: "call-a-old",
                name: "章文",
                phone: "15397111188",
                time: 100
            )
            let callB = try makeAvailableCall(
                root: root,
                id: "call-b",
                name: "李雷",
                phone: "13102133750",
                time: 200
            )
            let callANew = try makeAvailableCall(
                root: root,
                id: "call-a-new",
                name: "章文",
                phone: "15397111188",
                time: 300
            )
            try saveIndex([callAOld, callB, callANew], to: root)

            let store = await MainActor.run { PersonTimelineStore() }
            try await MainActor.run {
                try store.openArchive(root)
            }

            let summaryA = await MainActor.run {
                store.callSummary(for: personA.id)
            }
            assertEqual(summaryA.count, 2, "store summary counts all person calls")
            assertEqual(
                summaryA.latestDateText,
                "time300",
                "store summary uses latest person call date"
            )

            let summaryB = await MainActor.run {
                store.callSummary(for: personB.id)
            }
            assertEqual(summaryB.count, 1, "store summary counts non-selected person")
            assertEqual(
                summaryB.latestDateText,
                "time200",
                "store summary latest date works for non-selected person"
            )

            let missing = await MainActor.run {
                store.callSummary(for: "missing-person")
            }
            assertEqual(missing.count, 0, "missing person summary has zero calls")
            assertEqual(missing.latestDateText, nil, "missing person summary has no latest date")
        }
    }

    private static func checkStoreSelectRecent30Days() async throws {
        try await withTemporaryDirectoryAsync("store-recent-thirty-days") { root in
            let referenceDate = Date(timeIntervalSince1970: 1_000_000)
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            )
            try savePeople([person], to: root)
            let recent = try makeAvailableCall(
                root: root,
                id: "call-recent",
                name: "章文",
                phone: "15397111188",
                time: referenceDate.timeIntervalSince1970 - 10 * 24 * 60 * 60
            )
            let old = try makeAvailableCall(
                root: root,
                id: "call-old",
                name: "章文",
                phone: "15397111188",
                time: referenceDate.timeIntervalSince1970 - 31 * 24 * 60 * 60
            )
            let unavailableRecent = makeCall(
                root: root,
                id: "call-missing",
                name: "章文",
                phone: "15397111188",
                time: referenceDate.timeIntervalSince1970 - 2 * 24 * 60 * 60,
                transcriptPath: root.appendingPathComponent("missing.md").path,
                speakerTextPath: ""
            )
            try saveIndex([recent, old, unavailableRecent], to: root)

            let store = await MainActor.run { PersonTimelineStore() }
            try await MainActor.run {
                try store.openArchive(root)
                store.selectPerson(person.id)
                try store.selectRecent30Days(referenceDate: referenceDate)
            }
            assertEqual(
                await MainActor.run { store.selectedCallIDs },
                Set(["call-recent"]),
                "store recent shortcut selects only recent available calls"
            )
        }
    }

    private static func checkStorePrepareOrganizationUsesCurrentSelection() async throws {
        try await withTemporaryDirectoryAsync("store-prepare-current-selection") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            )
            try savePeople([person], to: root)
            let callA = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )
            let callB = try makeAvailableCall(
                root: root,
                id: "call-b",
                name: "章文",
                phone: "15397111188",
                time: 200
            )
            try saveIndex([callB, callA], to: root)

            let store = await MainActor.run { PersonTimelineStore() }
            let preparation = try await MainActor.run {
                try store.openArchive(root)
                store.selectPerson(person.id)
                try store.toggleCall("call-b")
                return try store.prepareOrganization()
            }
            assertEqual(
                preparation.callIDs,
                ["call-b"],
                "store prepare uses current selected IDs"
            )
            assertEqual(
                preparation.markdown.contains("call-a"),
                false,
                "store prepare excludes unselected calls"
            )
        }
    }

    private static func checkStoreCommitRepairAndClearDraft() async throws {
        try await withTemporaryDirectoryAsync("store-commit-repair-clear-draft") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            )
            try savePeople([person], to: root)
            let call = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )
            try saveIndex([call], to: root)

            let committedResult = root.appendingPathComponent("committed.md")
            try "committed".write(to: committedResult, atomically: true, encoding: .utf8)
            let store = await MainActor.run { PersonTimelineStore() }
            try await MainActor.run {
                try store.openArchive(root)
                store.selectPerson(person.id)
                try store.toggleCall("call-a")
                try store.commitOrganizationVersion(
                    makeVersion(
                        id: "version-committed",
                        personID: person.id,
                        createdAt: Date(timeIntervalSince1970: 200),
                        resultPath: committedResult.path
                    )
                )
            }
            assertEqual(
                await MainActor.run { store.selectedCallIDs },
                [],
                "store commit clears draft"
            )
            assertEqual(
                await MainActor.run { store.versions.map(\.id) },
                ["version-committed"],
                "store commit appends version"
            )

            let repairResult = root.appendingPathComponent("repair.md")
            let repairVersion = makeVersion(
                id: "version-repair",
                personID: person.id,
                createdAt: Date(timeIntervalSince1970: 300),
                resultPath: repairResult.path
            )
            do {
                try await MainActor.run {
                    try store.toggleCall("call-a")
                    try store.commitOrganizationVersion(repairVersion)
                }
                fatalError("missing result should leave a pending repair")
            } catch let error as CocoaError {
                assertEqual(
                    error.code,
                    CocoaError.Code.fileNoSuchFile,
                    "store failed append surfaces missing result"
                )
            } catch {
                fatalError("expected missing result CocoaError, got \(error)")
            }

            assertEqual(
                await MainActor.run { store.pendingVersionRepair?.id },
                "version-repair",
                "store keeps failed version for repair"
            )
            assertEqual(
                await MainActor.run { store.selectedCallIDs },
                Set(["call-a"]),
                "store failed commit preserves draft"
            )

            try "repaired".write(to: repairResult, atomically: true, encoding: .utf8)
            try await MainActor.run {
                try store.repairVersionIndex()
            }
            assertEqual(
                await MainActor.run { store.pendingVersionRepair },
                nil,
                "store repair clears pending version"
            )
            assertEqual(
                await MainActor.run { store.selectedCallIDs },
                [],
                "store repair clears draft"
            )
            assertEqual(
                await MainActor.run { store.versions.map(\.id) },
                ["version-repair", "version-committed"],
                "store repair appends version after fixing result"
            )
        }
    }

    private static func checkStoreCommitRefreshesAfterDraftClearFails() async throws {
        try await withTemporaryDirectoryAsync("store-commit-clear-draft-failure") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            )
            try savePeople([person], to: root)
            let call = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )
            try saveIndex([call], to: root)

            let result = root.appendingPathComponent("commit-clear-failure.md")
            try "committed".write(to: result, atomically: true, encoding: .utf8)
            let version = makeVersion(
                id: "version-commit-clear-failure",
                personID: person.id,
                createdAt: Date(timeIntervalSince1970: 300),
                resultPath: result.path
            )
            let store = await MainActor.run { PersonTimelineStore() }
            try await MainActor.run {
                try store.openArchive(root)
                store.selectPerson(person.id)
                try store.toggleCall("call-a")
            }

            let draftsURL = root.appendingPathComponent("selection_drafts.json")
            try FileManager.default.setAttributes(
                [.immutable: true],
                ofItemAtPath: draftsURL.path
            )
            var didThrow = false
            do {
                try await MainActor.run {
                    try store.commitOrganizationVersion(version)
                }
            } catch {
                didThrow = true
            }
            try FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: draftsURL.path
            )

            assertEqual(didThrow, true, "commit should surface draft clear failure")
            assertEqual(
                await MainActor.run { store.pendingVersionRepair?.id },
                Optional(version.id),
                "store keeps pending repair when commit draft clear fails"
            )
            assertEqual(
                await MainActor.run { store.versions.map(\.id) },
                [version.id],
                "store refreshes versions after commit append succeeds"
            )
            assertEqual(
                await MainActor.run { store.selectedCallIDs },
                Set(["call-a"]),
                "store keeps draft selection after failed clear"
            )

            try await MainActor.run {
                try store.repairVersionIndex()
            }
            assertEqual(
                await MainActor.run { store.pendingVersionRepair },
                nil,
                "store clears pending repair after retry clears draft"
            )
            assertEqual(
                await MainActor.run { store.versions.map(\.id) },
                [version.id],
                "store retry does not duplicate committed version"
            )
            assertEqual(
                await MainActor.run { store.selectedCallIDs },
                [],
                "store retry clears draft"
            )
        }
    }

    private static func checkStoreRepairPreservesPendingWhenDraftClearFails() async throws {
        try await withTemporaryDirectoryAsync("store-repair-clear-draft-failure") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            )
            try savePeople([person], to: root)
            let call = try makeAvailableCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100
            )
            try saveIndex([call], to: root)

            let repairResult = root.appendingPathComponent("repair-clear-failure.md")
            let repairVersion = makeVersion(
                id: "version-repair-clear-failure",
                personID: person.id,
                createdAt: Date(timeIntervalSince1970: 300),
                resultPath: repairResult.path
            )
            let store = await MainActor.run { PersonTimelineStore() }
            try await MainActor.run {
                try store.openArchive(root)
                store.selectPerson(person.id)
                try store.toggleCall("call-a")
            }
            do {
                try await MainActor.run {
                    try store.commitOrganizationVersion(repairVersion)
                }
                fatalError("missing result should leave a pending repair")
            } catch let error as CocoaError {
                assertEqual(
                    error.code,
                    CocoaError.Code.fileNoSuchFile,
                    "store failed append surfaces missing result"
                )
            } catch {
                fatalError("expected missing result CocoaError, got \(error)")
            }
            assertEqual(
                await MainActor.run { store.pendingVersionRepair?.id },
                Optional(repairVersion.id),
                "store keeps pending repair after append failure"
            )

            try "repaired".write(to: repairResult, atomically: true, encoding: .utf8)
            let draftsURL = root.appendingPathComponent("selection_drafts.json")
            try FileManager.default.setAttributes(
                [.immutable: true],
                ofItemAtPath: draftsURL.path
            )
            var didThrow = false
            do {
                try await MainActor.run {
                    try store.repairVersionIndex()
                }
            } catch {
                didThrow = true
            }
            try FileManager.default.setAttributes(
                [.immutable: false],
                ofItemAtPath: draftsURL.path
            )

            assertEqual(didThrow, true, "repair should surface draft clear failure")
            assertEqual(
                await MainActor.run { store.pendingVersionRepair?.id },
                Optional(repairVersion.id),
                "store keeps pending repair when draft clear fails"
            )
            assertEqual(
                await MainActor.run { store.versions.map(\.id) },
                [repairVersion.id],
                "store refreshes versions after repair append succeeds"
            )

            try await MainActor.run {
                try store.repairVersionIndex()
            }
            assertEqual(
                await MainActor.run { store.pendingVersionRepair },
                nil,
                "store clears pending repair after retry clears draft"
            )
            assertEqual(
                await MainActor.run { store.versions.map(\.id) },
                [repairVersion.id],
                "store repair retry does not duplicate version"
            )
        }
    }

    private static func savePeople(_ people: [PersonRecord], to root: URL) throws {
        try AtomicJSONFileStore.save(
            PeopleFile(people: people),
            to: root.appendingPathComponent("people.json")
        )
    }

    private static func saveDrafts(
        _ drafts: SelectionDraftsFile,
        to root: URL
    ) throws {
        try AtomicJSONFileStore.save(
            drafts,
            to: root.appendingPathComponent("selection_drafts.json")
        )
    }

    private static func saveIndex(
        _ entries: [CallRecordIndexEntry],
        to root: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: root.appendingPathComponent("call_index.json"))
    }

    private static func makeVersion(
        id: String,
        personID: String,
        createdAt: Date,
        resultPath: String
    ) -> PersonOrganizationVersion {
        PersonOrganizationVersion(
            id: id,
            personID: personID,
            personSnapshot: PersonSnapshot(
                displayName: "章文",
                phoneNumbers: ["15397111188"]
            ),
            callIDs: ["call-a"],
            sourceSnapshots: [
                PersonOrganizationSourceSnapshot(
                    callID: "call-a",
                    sourceKind: .proofread,
                    sourcePath: "/tmp/call-a.md",
                    contentHash: "sha256:abc"
                )
            ],
            modelID: "gpt-test",
            templateID: "template-a",
            customPrompt: "prompt",
            createdAt: createdAt,
            resultPath: resultPath
        )
    }

    private static func makeAvailableCall(
        root: URL,
        id: String,
        name: String,
        phone: String,
        time: TimeInterval
    ) throws -> CallRecordIndexEntry {
        let outputDir = root
            .appendingPathComponent("Calls", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )
        let transcriptURL = outputDir.appendingPathComponent("\(id)_通话记录.md")
        let speakerURL = outputDir.appendingPathComponent("\(id)_整理版.md")
        try "transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)
        try "speaker".write(to: speakerURL, atomically: true, encoding: .utf8)
        return makeCall(
            root: root,
            id: id,
            name: name,
            phone: phone,
            time: time,
            transcriptPath: transcriptURL.path,
            speakerTextPath: speakerURL.path
        )
    }

    private static func makeCall(
        root: URL,
        id: String,
        name: String,
        phone: String,
        time: TimeInterval,
        transcriptPath: String,
        speakerTextPath: String
    ) -> CallRecordIndexEntry {
        let outputDir = root
            .appendingPathComponent("Calls", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        return CallRecordIndexEntry(
            id: id,
            displayName: name,
            contactName: name,
            rawPhone: phone,
            normalizedPhone: phone.filter(\.isNumber),
            callDate: Date(timeIntervalSince1970: time),
            callDateText: "time\(Int(time))",
            durationSeconds: nil,
            outputDirectoryPath: outputDir.path,
            transcriptPath: transcriptPath,
            speakerTextPath: speakerTextPath,
            summaryPath: "",
            engine: "test-engine",
            modelID: "test-model"
        )
    }

    private static func withTemporaryDirectory(
        _ label: String,
        body: (URL) throws -> Void
    ) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "PersonSelectionDraftCheck-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private static func withTemporaryDirectoryAsync(
        _ label: String,
        body: (URL) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "PersonSelectionDraftCheck-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    private static func assertThrowsReadOnly(
        _ message: String,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            fatalError("\(message) should throw readOnly")
        } catch PersonArchiveError.readOnly(let reason) {
            assertEqual(reason.isEmpty, false, "\(message) read-only reason")
        } catch {
            fatalError("\(message) expected readOnly, got \(error)")
        }
    }

    private static func assertWritable(
        _ access: PersonArchiveAccess,
        _ message: String
    ) {
        if access != .writable {
            fatalError("\(message): expected writable, got \(access)")
        }
    }

    private static func assertEqual<T: Equatable>(
        _ lhs: T,
        _ rhs: T,
        _ message: String
    ) {
        if lhs != rhs {
            fatalError("\(message): expected \(rhs), got \(lhs)")
        }
    }
}
