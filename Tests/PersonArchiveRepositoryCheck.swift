import Foundation

@main
struct PersonArchiveRepositoryCheck {
    static func main() throws {
        try checkModelDefaultsAndRoundTrip()
        try checkMissingFileUsesWritableDefault()
        try checkFirstSaveRoundTrip()
        try checkBackupRecovery()
        try checkReadOnlyWhenPrimaryAndBackupAreCorrupt()
        print("PersonArchiveRepositoryCheck passed")
    }

    private static func checkModelDefaultsAndRoundTrip() throws {
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

        let source = PersonOrganizationSourceSnapshot(
            kind: .proofread,
            relativePath: "calls/001/proofread.md",
            content: "校对稿",
            capturedAt: Date(timeIntervalSince1970: 10)
        )
        let person = PersonRecord(
            id: "person-1",
            displayName: "章文",
            aliases: ["章总"],
            phoneNumbers: ["15397111188"],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let people = PeopleFile(
            people: [person],
            mergeHistory: [
                PersonMergeRecord(
                    id: "merge-1",
                    sourcePersonIDs: ["person-legacy"],
                    targetPersonID: person.id,
                    mergedAt: Date(timeIntervalSince1970: 3)
                )
            ],
            unassignedPhoneNumbers: ["10086"]
        )
        let drafts = SelectionDraftsFile(
            drafts: [
                PersonSelectionDraft(
                    personID: person.id,
                    selectedCallIDs: ["call-1"],
                    updatedAt: Date(timeIntervalSince1970: 4)
                )
            ]
        )
        let versions = OrganizationVersionsFile(
            versions: [
                PersonOrganizationVersion(
                    id: "version-1",
                    personID: person.id,
                    personSnapshot: PersonSnapshot(person: person),
                    sources: [
                        source,
                        PersonOrganizationSourceSnapshot(
                            kind: .transcript,
                            relativePath: "calls/001/transcript.md",
                            content: "转写稿",
                            capturedAt: Date(timeIntervalSince1970: 11)
                        )
                    ],
                    content: "人物归档",
                    createdAt: Date(timeIntervalSince1970: 12)
                )
            ]
        )

        assertCodableRoundTrip(people, "people file")
        assertCodableRoundTrip(drafts, "selection drafts file")
        assertCodableRoundTrip(versions, "organization versions file")
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

    private static func checkFirstSaveRoundTrip() throws {
        try withTemporaryDirectory("first-save") { root in
            let url = root.appendingPathComponent("people.json")
            let expected = PeopleFile(
                people: [
                    PersonRecord(
                        id: "person-1",
                        displayName: "章文",
                        phoneNumbers: ["15397111188"]
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

    private static func assertCodableRoundTrip<T: Codable & Equatable>(
        _ value: T,
        _ message: String
    ) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(value)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let decoded = try decoder.decode(T.self, from: data)
            assertEqual(decoded, value, "\(message) Codable round trip")
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
}
