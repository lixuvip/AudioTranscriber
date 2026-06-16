import Foundation

@main
struct CallRecordArchiveCheck {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CallRecordArchiveCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("章文@153 9711 1188_20240826172813.m4a")
        try Data().write(to: source)
        let metadata = try require(
            CallRecordFilenameParser.parse(fileURL: source),
            "metadata should parse"
        )
        let outputDir = root
            .appendingPathComponent("Archive/Calls/2024/2024-08/20240826_172813_章文_15397111188", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        try "transcript".write(to: outputDir.appendingPathComponent("章文@153 9711 1188_20240826172813_通话记录.md"), atomically: true, encoding: .utf8)
        try "{}".write(to: outputDir.appendingPathComponent("章文@153 9711 1188_20240826172813_speaker_map.json"), atomically: true, encoding: .utf8)
        try "整理版".write(to: outputDir.appendingPathComponent("章文@153 9711 1188_20240826172813_整理版.md"), atomically: true, encoding: .utf8)
        try "AI 摘要".write(to: outputDir.appendingPathComponent("章文@153 9711 1188_20240826172813_摘要.md"), atomically: true, encoding: .utf8)

        var job = CallRecordBatchJob(
            id: metadata.id,
            sourcePath: source.path,
            outputDirectoryPath: outputDir.path,
            metadata: metadata,
            status: .completed,
            durationSeconds: 42,
            progress: 1,
            errorMessage: nil,
            engine: "whisperMLX",
            modelID: "mlx-community/whisper-large-v3-turbo",
            createdAt: Date(timeIntervalSince1970: 0),
            startedAt: Date(timeIntervalSince1970: 1),
            finishedAt: Date(timeIntervalSince1970: 2)
        )

        try CallRecordArchiveWriter.write(job: job, allJobs: [job])

        let metadataURL = outputDir.appendingPathComponent("metadata.json")
        let metadataData = try Data(contentsOf: metadataURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let written = try decoder.decode(CallRecordArchiveMetadata.self, from: metadataData)
        assertEqual(written.displayName, "章文", "metadata display name")
        assertEqual(written.normalizedPhone, "15397111188", "metadata phone")
        assertEqual(written.transcriptPath.hasSuffix("_通话记录.md"), true, "metadata transcript path")
        assertEqual(written.summaryPath.hasSuffix("_摘要.md"), true, "metadata summary path")

        let indexURL = root.appendingPathComponent("Archive/call_index.json")
        let indexData = try Data(contentsOf: indexURL)
        let entries = try decoder.decode([CallRecordIndexEntry].self, from: indexData)
        assertEqual(entries.count, 1, "index count")
        assertEqual(entries[0].displayName, "章文", "index display name")

        let markdown = try String(contentsOf: root.appendingPathComponent("Archive/通话记录索引.md"), encoding: .utf8)
        assertEqual(markdown.contains("章文"), true, "markdown contains contact")
        assertEqual(markdown.contains("153 9711 1188"), true, "markdown contains raw phone")
        assertEqual(markdown.contains("摘要:"), true, "markdown links summary")

        let contactPage = try String(
            contentsOf: root.appendingPathComponent("Archive/Contacts/15397111188_章文.md"),
            encoding: .utf8
        )
        assertEqual(contactPage.contains("2024-08-26 17:28:13"), true, "contact page contains call time")
        assertEqual(contactPage.contains("摘要:"), true, "contact page links summary")

        job.status = .failed
        try CallRecordArchiveWriter.writeIndex(allJobs: [job], archiveRoot: root.appendingPathComponent("Archive", isDirectory: true))
        let emptyIndexData = try Data(contentsOf: indexURL)
        let emptyEntries = try decoder.decode([CallRecordIndexEntry].self, from: emptyIndexData)
        assertEqual(emptyEntries.count, 0, "failed jobs are excluded")
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else {
            throw CheckError(message)
        }
        return value
    }

    private static func assertEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
        if lhs != rhs {
            fatalError("\(message): expected \(rhs), got \(lhs)")
        }
    }

    private struct CheckError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
