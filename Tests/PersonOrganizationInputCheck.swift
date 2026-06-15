import Foundation

@main
struct PersonOrganizationInputCheck {
    static func main() throws {
        try checkPreferredSourcesUnavailableAndFrozenSnapshot()
        try checkInputErrors()
        try checkCallOrdering()
        print("PersonOrganizationInputCheck passed")
    }

    private static func checkPreferredSourcesUnavailableAndFrozenSnapshot() throws {
        try withTemporaryDirectory("preferred-sources") { root in
            let person = PersonRecord(
                id: "person-a",
                displayName: "章文",
                phoneNumbers: ["153 9711 1188", "131 0213 3750"]
            )
            let callAProofreadURL = root.appendingPathComponent("call-a_整理版.md")
            let callATranscriptURL = root.appendingPathComponent("call-a_通话记录.md")
            let callBTranscriptURL = root.appendingPathComponent("call-b_通话记录.md")
            try "人工校对内容".write(
                to: callAProofreadURL,
                atomically: true,
                encoding: .utf8
            )
            try "原始转写内容 A".write(
                to: callATranscriptURL,
                atomically: true,
                encoding: .utf8
            )
            try "原始转写内容".write(
                to: callBTranscriptURL,
                atomically: true,
                encoding: .utf8
            )

            let callA = makeCall(
                root: root,
                id: "call-a",
                name: "章文",
                phone: "153 9711 1188",
                time: 100,
                transcriptPath: callATranscriptURL.path,
                speakerTextPath: callAProofreadURL.path
            )
            let callB = makeCall(
                root: root,
                id: "call-b",
                name: "章文",
                phone: "131 0213 3750",
                time: 200,
                transcriptPath: callBTranscriptURL.path,
                speakerTextPath: ""
            )
            let callC = makeCall(
                root: root,
                id: "call-c",
                name: "章文",
                phone: "153 9711 1188",
                time: 300,
                transcriptPath: root.appendingPathComponent("missing-transcript.md").path,
                speakerTextPath: root.appendingPathComponent("missing-proofread.md").path
            )

            let preparation = try PersonOrganizationInputBuilder.prepare(
                person: person,
                selectedCallIDs: Set(["call-a", "call-b", "call-c"]),
                calls: [callC, callB, callA]
            )

            assertEqual(
                preparation.personSnapshot,
                PersonSnapshot(
                    displayName: "章文",
                    phoneNumbers: ["131 0213 3750", "153 9711 1188"]
                ),
                "person snapshot freezes sorted phone numbers"
            )
            assertEqual(preparation.callIDs, ["call-a", "call-b"], "readable call IDs")
            assertEqual(
                preparation.sources.map(\.sourceKind),
                [.proofread, .transcript],
                "source priority"
            )
            assertEqual(
                preparation.unavailableCallIDs,
                ["call-c"],
                "unavailable calls"
            )
            assertEqual(
                preparation.markdown.contains("人工校对内容"),
                true,
                "markdown includes proofread content"
            )
            assertEqual(
                preparation.markdown.contains("原始转写内容"),
                true,
                "markdown includes transcript fallback content"
            )
            assertEqual(
                preparation.markdown.contains("原始转写内容 A"),
                false,
                "markdown excludes transcript when proofread exists"
            )
            assertEqual(
                preparation.sources.allSatisfy { $0.contentHash.hasPrefix("sha256:") },
                true,
                "source hashes include sha256 prefix"
            )

            let frozenMarkdown = preparation.markdown
            let frozenHash = preparation.sources[0].contentHash
            try "覆盖后内容".write(
                to: callAProofreadURL,
                atomically: true,
                encoding: .utf8
            )
            assertEqual(
                preparation.markdown,
                frozenMarkdown,
                "prepared markdown remains frozen"
            )
            assertEqual(
                preparation.sources[0].contentHash,
                frozenHash,
                "prepared hash remains frozen"
            )
            assertEqual(
                preparation.markdown.contains("覆盖后内容"),
                false,
                "prepared markdown does not follow source file changes"
            )
        }
    }

    private static func checkInputErrors() throws {
        try withTemporaryDirectory("input-errors") { root in
            let person = PersonRecord(displayName: "章文", phoneNumbers: ["15397111188"])
            let unreadable = makeCall(
                root: root,
                id: "call-unreadable",
                name: "章文",
                phone: "15397111188",
                time: 100,
                transcriptPath: root.appendingPathComponent("missing-transcript.md").path,
                speakerTextPath: ""
            )

            do {
                _ = try PersonOrganizationInputBuilder.prepare(
                    person: person,
                    selectedCallIDs: [],
                    calls: [unreadable]
                )
                fatalError("empty selection should throw noSelectedCalls")
            } catch PersonOrganizationInputError.noSelectedCalls {
                assertEqual(
                    PersonOrganizationInputError.noSelectedCalls.errorDescription,
                    "请至少选择一条通话",
                    "empty selection error description"
                )
            } catch {
                fatalError("expected noSelectedCalls, got \(error)")
            }

            do {
                _ = try PersonOrganizationInputBuilder.prepare(
                    person: person,
                    selectedCallIDs: Set(["call-unreadable"]),
                    calls: [unreadable]
                )
                fatalError("all unreadable calls should throw noReadableCalls")
            } catch PersonOrganizationInputError.noReadableCalls {
                assertEqual(
                    PersonOrganizationInputError.noReadableCalls.errorDescription,
                    "所选通话没有可读取的转写内容",
                    "no readable calls error description"
                )
            } catch {
                fatalError("expected noReadableCalls, got \(error)")
            }
        }
    }

    private static func checkCallOrdering() throws {
        try withTemporaryDirectory("ordering") { root in
            let person = PersonRecord(displayName: "章文", phoneNumbers: ["15397111188"])
            let late = try makeReadableCall(
                root: root,
                id: "call-late",
                name: "章文",
                phone: "15397111188",
                time: 300,
                content: "late"
            )
            let early = try makeReadableCall(
                root: root,
                id: "call-early",
                name: "章文",
                phone: "15397111188",
                time: 100,
                content: "early"
            )
            let middle = try makeReadableCall(
                root: root,
                id: "call-middle",
                name: "章文",
                phone: "15397111188",
                time: 200,
                content: "middle"
            )

            let preparation = try PersonOrganizationInputBuilder.prepare(
                person: person,
                selectedCallIDs: Set(["call-late", "call-early", "call-middle"]),
                calls: [late, middle, early]
            )
            assertEqual(
                preparation.callIDs,
                ["call-early", "call-middle", "call-late"],
                "readable calls are sorted by callDate"
            )
        }
    }

    private static func makeReadableCall(
        root: URL,
        id: String,
        name: String,
        phone: String,
        time: TimeInterval,
        content: String
    ) throws -> CallRecordIndexEntry {
        let url = root.appendingPathComponent("\(id)_通话记录.md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return makeCall(
            root: root,
            id: id,
            name: name,
            phone: phone,
            time: time,
            transcriptPath: url.path,
            speakerTextPath: ""
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
        let outputDir = root.appendingPathComponent(id, isDirectory: true)
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
                "PersonOrganizationInputCheck-\(label)-\(UUID().uuidString)",
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
