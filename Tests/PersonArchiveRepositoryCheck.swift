import Foundation

@main
struct PersonArchiveRepositoryCheck {
    static func main() throws {
        try checkModelDefaultsAndPlannedFieldsRoundTrip()
        try checkMissingFileUsesWritableDefault()
        try checkMissingPrimaryRecoversValidBackup()
        try checkFirstSaveRoundTrip()
        try checkBackupRecovery()
        try checkSavingAfterRecoveryPreservesValidBackup()
        try checkReadOnlyWhenPrimaryAndBackupAreCorrupt()
        try checkLossyRoundTripThrowsMismatch()
        try checkIndexHelpersAndTimelineAvailability()
        try checkPeopleBootstrapMergeSplitReassignAndRename()
        try checkPhoneConflictErrors()
        print("PersonArchiveRepositoryCheck passed")
    }

    private static func checkModelDefaultsAndPlannedFieldsRoundTrip() throws {
        let defaults = PeopleFile()
        assertEqual(defaults.schemaVersion, 1, "default schema version")
        assertEqual(defaults.people, [], "default people")
        assertEqual(defaults.mergeHistory, [], "default merge history")
        assertEqual(defaults.unassignedPhoneNumbers, [], "default unassigned phone numbers")

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let emptyData = Data("{}".utf8)
        assertEqual(
            try decoder.decode(PeopleFile.self, from: emptyData),
            PeopleFile(),
            "people file decodes missing fields with defaults"
        )
        assertEqual(
            try decoder.decode(SelectionDraftsFile.self, from: emptyData),
            SelectionDraftsFile(),
            "selection drafts file decodes missing fields with defaults"
        )
        assertEqual(
            try decoder.decode(OrganizationVersionsFile.self, from: emptyData),
            OrganizationVersionsFile(),
            "organization versions file decodes missing fields with defaults"
        )

        let createdAt = Date(timeIntervalSince1970: 1_700_000_000.123)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_001.456)
        let revertedAt = Date(timeIntervalSince1970: 1_700_000_002.789)
        let person = PersonRecord(
            id: "person-1",
            displayName: "章文",
            phoneNumbers: ["15397111188"],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let beforePerson = PersonRecord(
            id: "person-old",
            displayName: "旧联系人",
            phoneNumbers: ["10086"],
            createdAt: createdAt,
            updatedAt: updatedAt
        )
        let people = PeopleFile(
            people: [person],
            mergeHistory: [
                PersonMergeRecord(
                    id: "merge-1",
                    targetPersonID: person.id,
                    beforePeople: [beforePerson],
                    createdAt: updatedAt,
                    revertedAt: revertedAt
                )
            ],
            unassignedPhoneNumbers: ["10010"]
        )
        assertIdentifiable(person, "person record identifiable")
        assertIdentifiable(people.mergeHistory[0], "merge record identifiable")
        let drafts = SelectionDraftsFile(
            drafts: [
                person.id: PersonSelectionDraft(
                    callIDs: ["call-1", "call-2"],
                    updatedAt: updatedAt
                )
            ]
        )
        let versions = OrganizationVersionsFile(
            versions: [
                PersonOrganizationVersion(
                    id: "version-1",
                    personID: person.id,
                    personSnapshot: PersonSnapshot(
                        displayName: person.displayName,
                        phoneNumbers: person.phoneNumbers
                    ),
                    callIDs: ["call-1", "call-2"],
                    sourceSnapshots: [
                        PersonOrganizationSourceSnapshot(
                            callID: "call-1",
                            sourceKind: .proofread,
                            sourcePath: "Calls/2024/call-1/proofread.md",
                            contentHash: "sha256-proofread"
                        ),
                        PersonOrganizationSourceSnapshot(
                            callID: "call-2",
                            sourceKind: .transcript,
                            sourcePath: "Calls/2024/call-2/transcript.md",
                            contentHash: "sha256-transcript"
                        )
                    ],
                    modelID: "qwen3",
                    templateID: "default-person-archive",
                    customPrompt: "保留业务事实",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_003.123),
                    resultPath: "People/person-1/archive.md"
                )
            ]
        )
        assertIdentifiable(versions.versions[0], "organization version identifiable")

        assertCodableRoundTrip(people, "planned people file")
        assertCodableRoundTrip(drafts, "planned selection drafts file")
        assertCodableRoundTrip(versions, "planned organization versions file")
    }

    private static func checkMissingFileUsesWritableDefault() throws {
        try withTemporaryDirectory("missing-file") { root in
            let fallback = PeopleFile(unassignedPhoneNumbers: ["fallback"])
            let result = AtomicJSONFileStore.load(
                PeopleFile.self,
                from: root.appendingPathComponent("people.json"),
                defaultValue: fallback
            )
            assertEqual(result.value, fallback, "missing primary uses default")
            assertEqual(result.access, .writable, "missing primary remains writable")
        }
    }

    private static func checkMissingPrimaryRecoversValidBackup() throws {
        try withTemporaryDirectory("missing-primary-valid-backup") { root in
            let url = root.appendingPathComponent("people.json")
            let expected = PeopleFile(
                people: [
                    PersonRecord(
                        id: "person-backup",
                        displayName: "备份联系人",
                        phoneNumbers: ["10086"]
                    )
                ]
            )

            try AtomicJSONFileStore.save(expected, to: url)
            try FileManager.default.moveItem(
                at: url,
                to: url.appendingPathExtension("backup")
            )

            let result = AtomicJSONFileStore.load(
                PeopleFile.self,
                from: url,
                defaultValue: PeopleFile()
            )
            assertEqual(result.value, expected, "missing primary recovers backup value")
            assertEqual(result.access, .recoveredFromBackup, "missing primary backup access")
        }
    }

    private static func checkFirstSaveRoundTrip() throws {
        try withTemporaryDirectory("first-save") { root in
            let url = root.appendingPathComponent("people.json")
            let expected = PeopleFile(
                people: [
                    PersonRecord(
                        id: "person-1",
                        displayName: "章文",
                        phoneNumbers: ["15397111188"],
                        createdAt: Date(timeIntervalSince1970: 1_700_000_000.123),
                        updatedAt: Date(timeIntervalSince1970: 1_700_000_001.456)
                    )
                ],
                unassignedPhoneNumbers: ["10010"]
            )

            try AtomicJSONFileStore.save(expected, to: url)
            let result = AtomicJSONFileStore.load(
                PeopleFile.self,
                from: url,
                defaultValue: PeopleFile()
            )

            assertEqual(result.value, expected, "first save round trip value")
            assertEqual(result.access, .writable, "first save round trip access")
            assertEqual(
                FileManager.default.fileExists(atPath: url.appendingPathExtension("backup").path),
                false,
                "first save should not create backup"
            )

            let json = try String(contentsOf: url, encoding: .utf8)
            assertEqual(json.contains("\"schema_version\""), true, "snake case keys")
            assertEqual(json.contains(".123"), true, "fractional seconds are encoded")
            assertEqual(json.contains("\n"), true, "pretty printed JSON")
        }
    }

    private static func checkBackupRecovery() throws {
        try withTemporaryDirectory("backup-recovery") { root in
            let url = root.appendingPathComponent("people.json")
            let first = PeopleFile(
                people: [PersonRecord(id: "person-1", displayName: "旧内容")]
            )
            let second = PeopleFile(
                people: [PersonRecord(id: "person-2", displayName: "新内容")]
            )

            try AtomicJSONFileStore.save(first, to: url)
            try AtomicJSONFileStore.save(second, to: url)

            let backupURL = url.appendingPathExtension("backup")
            let backup = AtomicJSONFileStore.load(
                PeopleFile.self,
                from: backupURL,
                defaultValue: PeopleFile()
            )
            assertEqual(backup.value, first, "backup keeps previous content")
            assertEqual(backup.access, .writable, "valid backup loads normally")

            try Data("{broken-primary".utf8).write(to: url)
            let recovered = AtomicJSONFileStore.load(
                PeopleFile.self,
                from: url,
                defaultValue: PeopleFile()
            )
            assertEqual(recovered.value, first, "corrupt primary recovers backup")
            assertEqual(recovered.access, .recoveredFromBackup, "backup recovery access")
        }
    }

    private static func checkSavingAfterRecoveryPreservesValidBackup() throws {
        try withTemporaryDirectory("save-after-recovery") { root in
            let url = root.appendingPathComponent("people.json")
            let backupValue = PeopleFile(
                people: [PersonRecord(id: "person-backup", displayName: "备份内容")]
            )
            let savedAfterRecovery = PeopleFile(
                people: [PersonRecord(id: "person-new", displayName: "恢复后新内容")]
            )

            try AtomicJSONFileStore.save(backupValue, to: url)
            try FileManager.default.moveItem(
                at: url,
                to: url.appendingPathExtension("backup")
            )
            try Data("{broken-primary".utf8).write(to: url)

            let recovered = AtomicJSONFileStore.load(
                PeopleFile.self,
                from: url,
                defaultValue: PeopleFile()
            )
            assertEqual(recovered.value, backupValue, "pre-save recovery value")
            assertEqual(recovered.access, .recoveredFromBackup, "pre-save recovery access")

            try AtomicJSONFileStore.save(savedAfterRecovery, to: url)

            let current = AtomicJSONFileStore.load(
                PeopleFile.self,
                from: url,
                defaultValue: PeopleFile()
            )
            assertEqual(current.value, savedAfterRecovery, "save after recovery writes primary")

            let backup = AtomicJSONFileStore.load(
                PeopleFile.self,
                from: url.appendingPathExtension("backup"),
                defaultValue: PeopleFile()
            )
            assertEqual(backup.value, backupValue, "save after recovery preserves valid backup")
            assertEqual(backup.access, .writable, "preserved backup remains readable")
        }
    }

    private static func checkReadOnlyWhenPrimaryAndBackupAreCorrupt() throws {
        try withTemporaryDirectory("read-only") { root in
            let url = root.appendingPathComponent("people.json")
            let backupURL = url.appendingPathExtension("backup")
            try Data("{broken-primary".utf8).write(to: url)
            try Data("{broken-backup".utf8).write(to: backupURL)

            let fallback = PeopleFile(unassignedPhoneNumbers: ["fallback"])
            let result = AtomicJSONFileStore.load(
                PeopleFile.self,
                from: url,
                defaultValue: fallback
            )

            assertEqual(result.value, fallback, "double corruption uses default")
            switch result.access {
            case .readOnly(let reason):
                assertEqual(reason.isEmpty, false, "read-only reason is present")
                assertEqual(reason.contains("主文件"), true, "reason mentions primary")
                assertEqual(reason.contains("备份"), true, "reason mentions backup")
            default:
                fatalError("double corruption should enter read-only mode")
            }
        }
    }

    private static func checkLossyRoundTripThrowsMismatch() throws {
        try withTemporaryDirectory("lossy-round-trip") { root in
            let url = root.appendingPathComponent("lossy.json")
            do {
                try AtomicJSONFileStore.save(
                    LossyRoundTripFixture(value: 41),
                    to: url
                )
                fatalError("lossy fixture should fail save round-trip validation")
            } catch AtomicJSONFileStore.StoreError.roundTripMismatch {
                assertEqual(
                    FileManager.default.fileExists(atPath: url.path),
                    false,
                    "round-trip mismatch should not write primary file"
                )
            } catch {
                fatalError("expected roundTripMismatch, got \(error)")
            }
        }
    }

    private static func checkIndexHelpersAndTimelineAvailability() throws {
        try withTemporaryDirectory("index-helpers") { root in
            let archiveRoot = root.appendingPathComponent("Archive", isDirectory: true)
            let outputDir = archiveRoot
                .appendingPathComponent("Calls/2024/2024-08/call-a", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outputDir,
                withIntermediateDirectories: true
            )
            let transcript = outputDir.appendingPathComponent("call-a_通话记录.md")
            let speakerText = outputDir.appendingPathComponent("call-a_整理版.md")
            try "transcript".write(to: transcript, atomically: true, encoding: .utf8)
            try "speaker".write(to: speakerText, atomically: true, encoding: .utf8)

            let entry = makeCall(
                id: "call-a",
                name: "章文",
                phone: "15397111188",
                time: 100,
                outputDirectoryPath: outputDir.path,
                transcriptPath: transcript.path,
                speakerTextPath: speakerText.path
            )
            try writeIndex([entry], to: archiveRoot)

            assertEqual(
                try CallRecordArchiveWriter.loadIndex(from: archiveRoot),
                [entry],
                "load index helper decodes entries"
            )
            assertEqual(
                CallRecordArchiveWriter.archiveRoot(forIndexEntry: entry).path,
                archiveRoot.path,
                "archive root helper walks up from entry output directory"
            )

            let timelineCall = PersonTimelineCall(entry: entry)
            assertEqual(
                timelineCall.preferredSourcePath,
                speakerText.path,
                "timeline prefers speaker text path"
            )
            assertEqual(timelineCall.isAvailable, true, "timeline source exists")

            let transcriptOnly = makeCall(
                id: "call-b",
                name: "章文",
                phone: "15397111188",
                time: 200,
                outputDirectoryPath: outputDir.path,
                transcriptPath: transcript.path,
                speakerTextPath: ""
            )
            assertEqual(
                PersonTimelineCall(entry: transcriptOnly).preferredSourcePath,
                transcript.path,
                "timeline falls back to transcript path"
            )
            let missing = makeCall(
                id: "call-c",
                name: "章文",
                phone: "15397111188",
                time: 300,
                outputDirectoryPath: outputDir.path,
                transcriptPath: outputDir.appendingPathComponent("missing.md").path,
                speakerTextPath: ""
            )
            assertEqual(
                PersonTimelineCall(entry: missing).isAvailable,
                false,
                "timeline requires an existing source file"
            )
        }
    }

    private static func checkPeopleBootstrapMergeSplitReassignAndRename() throws {
        try withTemporaryDirectory("people-mapping") { root in
            let calls = [
                makeCall(id: "call-a", name: "章文", phone: "15397111188", time: 100),
                makeCall(id: "call-b", name: "章文", phone: "13102133750", time: 200),
                makeCall(id: "call-c", name: "章文", phone: "15397111188", time: 300)
            ]
            let repository = PersonArchiveRepository(
                archiveRoot: root,
                now: { Date(timeIntervalSince1970: 500) }
            )
            try repository.load(indexEntries: calls)

            assertEqual(repository.people.count, 2, "same name different phone does not auto merge")
            let first = try require(
                repository.person(containing: "15397111188"),
                "first phone person"
            )
            assertEqual(
                repository.calls(for: first.id).map(\.id),
                ["call-c", "call-a"],
                "calls for first person are descending"
            )
            let second = try require(
                repository.person(containing: "13102133750"),
                "second phone person"
            )

            let merged = try repository.mergePeople(
                personIDs: [first.id, second.id],
                targetPersonID: first.id,
                displayName: " 章文 "
            )
            assertEqual(
                merged.phoneNumbers.sorted(),
                ["13102133750", "15397111188"],
                "merged phone numbers"
            )
            assertEqual(repository.people.count, 1, "merged people count")
            let merge = try require(
                repository.peopleFile.mergeHistory.last,
                "merge history"
            )
            assertEqual(
                merge.beforePeople.sorted { $0.id < $1.id },
                [first, second].sorted { $0.id < $1.id },
                "merge history stores complete before people"
            )

            try repository.revertMerge(merge.id)
            assertEqual(repository.people.count, 2, "revert restores both people")
            assertEqual(
                repository.peopleFile.mergeHistory.last?.revertedAt != nil,
                true,
                "revert marks merge history"
            )

            let restoredFirst = try require(
                repository.person(containing: "15397111188"),
                "restored first phone person"
            )
            let detached = try repository.splitPhones(
                from: restoredFirst.id,
                phones: ["15397111188"],
                newDisplayName: nil
            )
            assertEqual(detached, nil, "split can leave phone unassigned")
            assertEqual(
                repository.peopleFile.unassignedPhoneNumbers,
                ["15397111188"],
                "split phone becomes unassigned"
            )

            try repository.load(indexEntries: calls)
            assertEqual(
                repository.person(containing: "15397111188"),
                nil,
                "load does not auto bootstrap explicitly unassigned phone"
            )
            assertEqual(
                repository.peopleFile.unassignedPhoneNumbers,
                ["15397111188"],
                "explicitly unassigned phone persists after reload"
            )

            let reassigned = try repository.createPerson(
                displayName: "章文新档案",
                phones: ["15397111188"]
            )
            assertEqual(
                repository.peopleFile.unassignedPhoneNumbers,
                [],
                "create person removes unassigned marker"
            )
            let renamed = try repository.renamePerson(reassigned.id, displayName: " 章文 ")
            assertEqual(renamed.displayName, "章文", "rename trims display name")
        }
    }

    private static func checkPhoneConflictErrors() throws {
        try withTemporaryDirectory("phone-conflicts") { root in
            let calls = [
                makeCall(id: "call-a", name: "章文", phone: "15397111188", time: 100),
                makeCall(id: "call-b", name: "章文", phone: "13102133750", time: 200),
                makeCall(id: "call-c", name: "王强", phone: "18600000000", time: 300)
            ]
            let repository = PersonArchiveRepository(
                archiveRoot: root,
                now: { Date(timeIntervalSince1970: 500) }
            )
            try repository.load(indexEntries: calls)

            let first = try require(
                repository.person(containing: "15397111188"),
                "first phone person"
            )
            let second = try require(
                repository.person(containing: "13102133750"),
                "second phone person"
            )
            let third = try require(
                repository.person(containing: "18600000000"),
                "third phone person"
            )

            assertThrowsPhoneConflict(phone: "18600000000", ownerID: third.id) {
                _ = try repository.createPerson(
                    displayName: "冲突新人物",
                    phones: ["18600000000"]
                )
            }
            assertThrowsPhoneConflict(phone: "15397111188", ownerID: first.id) {
                _ = try repository.assignUnassignedPhones(
                    ["15397111188"],
                    to: second.id
                )
            }

            try repository.deletePersonKeepingPhonesUnassigned(third.id)
            assertEqual(
                repository.peopleFile.unassignedPhoneNumbers.contains("18600000000"),
                true,
                "deleted person phone becomes unassigned"
            )
            let adopted = try repository.assignUnassignedPhones(
                ["18600000000"],
                to: second.id
            )
            assertEqual(
                adopted.phoneNumbers.sorted(),
                ["13102133750", "18600000000"],
                "assign can adopt unassigned phone"
            )

        }

        try withTemporaryDirectory("merge-phone-conflict") { root in
            let conflictPhone = "13102133750"
            try AtomicJSONFileStore.save(
                PeopleFile(
                    people: [
                        PersonRecord(
                            id: "person-a",
                            displayName: "章文 A",
                            phoneNumbers: ["15397111188"]
                        ),
                        PersonRecord(
                            id: "person-b",
                            displayName: "章文 B",
                            phoneNumbers: [conflictPhone]
                        ),
                        PersonRecord(
                            id: "person-c",
                            displayName: "第三方",
                            phoneNumbers: [conflictPhone]
                        )
                    ]
                ),
                to: root.appendingPathComponent("people.json")
            )
            let repository = PersonArchiveRepository(
                archiveRoot: root,
                now: { Date(timeIntervalSince1970: 500) }
            )
            try repository.load(indexEntries: [])

            assertThrowsPhoneConflict(phone: conflictPhone, ownerID: "person-c") {
                _ = try repository.mergePeople(
                    personIDs: ["person-a", "person-b"],
                    targetPersonID: "person-a",
                    displayName: "章文"
                )
            }
        }
    }

    private static func assertCodableRoundTrip<T: Codable & Equatable>(
        _ value: T,
        _ message: String
    ) {
        do {
            try withTemporaryDirectory("codable-round-trip") { root in
                let url = root.appendingPathComponent("round-trip.json")
                try AtomicJSONFileStore.save(value, to: url)
                let decoded = AtomicJSONFileStore.load(
                    T.self,
                    from: url,
                    defaultValue: value
                )
                assertEqual(decoded.value, value, "\(message) Codable round trip")
                assertEqual(decoded.access, .writable, "\(message) access")
            }
        } catch {
            fatalError("\(message) Codable round trip failed: \(error)")
        }
    }

    private static func withTemporaryDirectory(
        _ label: String,
        body: (URL) throws -> Void
    ) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "PersonArchiveRepositoryCheck-\(label)-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private static func makeCall(
        id: String,
        name: String,
        phone: String,
        time: TimeInterval,
        outputDirectoryPath: String = "",
        transcriptPath: String = "",
        speakerTextPath: String = ""
    ) -> CallRecordIndexEntry {
        CallRecordIndexEntry(
            id: id,
            displayName: name,
            contactName: name,
            rawPhone: phone,
            normalizedPhone: phone.filter(\.isNumber),
            callDate: Date(timeIntervalSince1970: time),
            callDateText: "time\(Int(time))",
            durationSeconds: nil,
            outputDirectoryPath: outputDirectoryPath,
            transcriptPath: transcriptPath,
            speakerTextPath: speakerTextPath,
            summaryPath: "",
            engine: "test-engine",
            modelID: "test-model"
        )
    }

    private static func writeIndex(
        _ entries: [CallRecordIndexEntry],
        to archiveRoot: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: archiveRoot,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: archiveRoot.appendingPathComponent("call_index.json"))
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw CheckError(message)
        }
        return value
    }

    private static func assertThrowsPhoneConflict(
        phone: String,
        ownerID: String,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            fatalError("expected phone conflict for \(phone)")
        } catch PersonArchiveError.phoneConflict(let conflictPhone, let conflictOwnerID) {
            assertEqual(conflictPhone, phone, "phone conflict phone")
            assertEqual(conflictOwnerID, ownerID, "phone conflict owner")
        } catch {
            fatalError("expected phoneConflict, got \(error)")
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

    private static func assertIdentifiable<T: Identifiable>(
        _ value: T,
        _ message: String
    ) where T.ID == String {
        assertEqual(value.id.isEmpty, false, message)
    }

    private struct LossyRoundTripFixture: Codable, Equatable {
        let value: Int

        init(value: Int) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            value = try container.decode(Int.self, forKey: .value) + 1
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(value, forKey: .value)
        }

        private enum CodingKeys: String, CodingKey {
            case value
        }
    }

    private struct CheckError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
