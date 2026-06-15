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

    private static func assertEqual<T: Equatable>(
        _ lhs: T,
        _ rhs: T,
        _ message: String
    ) {
        if lhs != rhs {
            fatalError("\(message): expected \(rhs), got \(lhs)")
        }
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
}
