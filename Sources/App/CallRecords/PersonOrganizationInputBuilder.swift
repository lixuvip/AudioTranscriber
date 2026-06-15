import CryptoKit
import Foundation

enum PersonOrganizationInputBuilder {
    static func prepare(
        person: PersonRecord,
        selectedCallIDs: Set<String>,
        calls: [CallRecordIndexEntry],
        archiveRoot: URL? = nil
    ) throws -> PersonOrganizationPreparation {
        guard !selectedCallIDs.isEmpty else {
            throw PersonOrganizationInputError.noSelectedCalls
        }

        let orderedCalls = calls
            .filter { selectedCallIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.callDate != rhs.callDate {
                    return lhs.callDate < rhs.callDate
                }
                return lhs.id < rhs.id
            }

        var readableCalls: [ReadableCallSource] = []
        var unavailableCallIDs: [String] = []

        for call in orderedCalls {
            if let source = readableSource(for: call, archiveRoot: archiveRoot) {
                readableCalls.append(source)
            } else {
                unavailableCallIDs.append(call.id)
            }
        }

        guard !readableCalls.isEmpty else {
            throw PersonOrganizationInputError.noReadableCalls
        }

        let personSnapshot = PersonSnapshot(
            displayName: person.displayName,
            phoneNumbers: person.phoneNumbers.sorted()
        )
        let sources = readableCalls.map { source in
            PersonOrganizationSourceSnapshot(
                callID: source.call.id,
                sourceKind: source.kind,
                sourcePath: source.path,
                contentHash: source.contentHash
            )
        }
        let callIDs = readableCalls.map { $0.call.id }
        let markdown = buildMarkdown(
            personSnapshot: personSnapshot,
            readableCalls: readableCalls
        )

        return PersonOrganizationPreparation(
            personSnapshot: personSnapshot,
            callIDs: callIDs,
            sources: sources,
            unavailableCallIDs: unavailableCallIDs,
            markdown: markdown
        )
    }

    private static func readableSource(
        for call: CallRecordIndexEntry,
        archiveRoot: URL?
    ) -> ReadableCallSource? {
        let resolvedSource = PersonTimelineCall.resolveSource(
            for: call,
            archiveRoot: archiveRoot
        )
        guard let kind = resolvedSource.kind,
              let content = readMarkdown(atPath: resolvedSource.path) else {
            return nil
        }
        return ReadableCallSource(
            call: call,
            kind: kind,
            path: resolvedSource.path,
            content: content.markdown,
            contentHash: content.hash
        )
    }

    private static func readMarkdown(
        atPath path: String
    ) -> (markdown: String, hash: String)? {
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard isRegularFile(url) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let markdown = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (markdown, sha256Hash(for: data))
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }

    private static func sha256Hash(for data: Data) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "sha256:\(hex)"
    }

    private static func buildMarkdown(
        personSnapshot: PersonSnapshot,
        readableCalls: [ReadableCallSource]
    ) -> String {
        let phoneText = personSnapshot.phoneNumbers.isEmpty
            ? "无"
            : personSnapshot.phoneNumbers.joined(separator: "、")
        var lines = [
            "# \(personSnapshot.displayName) 通话合并整理输入",
            "",
            "- 号码: \(phoneText)",
            "- 通话数量: \(readableCalls.count)",
            ""
        ]

        for source in readableCalls {
            lines.append("## \(source.call.callDateText) | \(source.call.rawPhone)")
            lines.append("- 通话 ID: \(source.call.id)")
            lines.append("- 来源: \(source.kind.title)")
            lines.append("- 文件: \(source.path)")
            lines.append("")
            lines.append(source.content)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private struct ReadableCallSource {
        let call: CallRecordIndexEntry
        let kind: PersonOrganizationSourceKind
        let path: String
        let content: String
        let contentHash: String
    }
}

private extension PersonOrganizationSourceKind {
    var title: String {
        switch self {
        case .proofread:
            return "整理版"
        case .transcript:
            return "通话记录"
        }
    }
}
