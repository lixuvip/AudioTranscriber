import Foundation

struct CallRecordArchiveMetadata: Codable, Equatable {
    let id: String
    let sourcePath: String
    let outputDirectoryPath: String
    let originalFileName: String
    let displayName: String
    let contactName: String?
    let rawPhone: String
    let normalizedPhone: String
    let callDate: Date
    let callDateText: String
    let durationSeconds: Double?
    let engine: String
    let modelID: String
    let transcriptPath: String
    let speakerMapPath: String
    let speakerTextPath: String
    let summaryPath: String
    let status: String
}

struct CallRecordIndexEntry: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let contactName: String?
    let rawPhone: String
    let normalizedPhone: String
    let callDate: Date
    let callDateText: String
    let durationSeconds: Double?
    let outputDirectoryPath: String
    let transcriptPath: String
    let speakerTextPath: String
    let summaryPath: String
    let engine: String
    let modelID: String
}

enum CallRecordArchiveWriter {
    static func write(job: CallRecordBatchJob, allJobs: [CallRecordBatchJob]) throws {
        guard job.status == .completed,
              let metadata = job.metadata else {
            return
        }

        let outputDir = job.outputDirectoryURL
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let archiveMetadata = archiveMetadata(for: job, metadata: metadata)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(archiveMetadata)
        try data.write(to: outputDir.appendingPathComponent("metadata.json"))
        let archiveRoot = archiveRoot(for: outputDir)
        try writeIndex(allJobs: allJobs, archiveRoot: archiveRoot)
        NotificationCenter.default.post(name: .callRecordArchiveWriterDidWrite, object: archiveRoot)
    }

    static func writeIndex(allJobs: [CallRecordBatchJob], archiveRoot: URL) throws {
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        let entries = allJobs.compactMap(indexEntry)
            .sorted { $0.callDate > $1.callDate }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(entries).write(to: archiveRoot.appendingPathComponent("call_index.json"))

        let markdown = buildIndexMarkdown(entries: entries)
        try markdown.write(to: archiveRoot.appendingPathComponent("通话记录索引.md"), atomically: true, encoding: .utf8)
        try writeContactPages(entries: entries, archiveRoot: archiveRoot)
    }

    static func loadIndex(from archiveRoot: URL) throws -> [CallRecordIndexEntry] {
        let data = try Data(contentsOf: archiveRoot.appendingPathComponent("call_index.json"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CallRecordIndexEntry].self, from: data)
    }

    static func archiveRoot(forIndexEntry entry: CallRecordIndexEntry) -> URL {
        archiveRoot(
            for: URL(fileURLWithPath: entry.outputDirectoryPath, isDirectory: true)
        )
    }

    private static func archiveRoot(for outputDir: URL) -> URL {
        outputDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func archiveMetadata(
        for job: CallRecordBatchJob,
        metadata: CallRecordMetadata
    ) -> CallRecordArchiveMetadata {
        let artifacts = artifactPaths(for: job)
        return CallRecordArchiveMetadata(
            id: job.id,
            sourcePath: job.sourcePath,
            outputDirectoryPath: job.outputDirectoryPath,
            originalFileName: metadata.originalFileName,
            displayName: metadata.displayName,
            contactName: metadata.contactName,
            rawPhone: metadata.rawPhone,
            normalizedPhone: metadata.normalizedPhone,
            callDate: metadata.callDate,
            callDateText: metadata.timestampText,
            durationSeconds: job.durationSeconds,
            engine: job.engine,
            modelID: job.modelID,
            transcriptPath: artifacts.transcript,
            speakerMapPath: artifacts.speakerMap,
            speakerTextPath: artifacts.speakerText,
            summaryPath: artifacts.summary,
            status: job.status.rawValue
        )
    }

    private static func indexEntry(for job: CallRecordBatchJob) -> CallRecordIndexEntry? {
        guard job.status == .completed, let metadata = job.metadata else { return nil }
        let artifacts = artifactPaths(for: job)
        return CallRecordIndexEntry(
            id: job.id,
            displayName: metadata.displayName,
            contactName: metadata.contactName,
            rawPhone: metadata.rawPhone,
            normalizedPhone: metadata.normalizedPhone,
            callDate: metadata.callDate,
            callDateText: metadata.timestampText,
            durationSeconds: job.durationSeconds,
            outputDirectoryPath: job.outputDirectoryPath,
            transcriptPath: artifacts.transcript,
            speakerTextPath: artifacts.speakerText,
            summaryPath: artifacts.summary,
            engine: job.engine,
            modelID: job.modelID
        )
    }

    private static func artifactPaths(for job: CallRecordBatchJob) -> (transcript: String, speakerMap: String, speakerText: String, summary: String) {
        let outputDir = job.outputDirectoryURL
        let base = job.sourceURL.deletingPathExtension().lastPathComponent
        return (
            transcript: existingPath(outputDir.appendingPathComponent("\(base)_通话记录.md")),
            speakerMap: existingPath(outputDir.appendingPathComponent("\(base)_speaker_map.json")),
            speakerText: existingPath(outputDir.appendingPathComponent("\(base)_整理版.md")),
            summary: existingPath(outputDir.appendingPathComponent("\(base)_摘要.md"))
        )
    }

    private static func existingPath(_ url: URL) -> String {
        FileManager.default.fileExists(atPath: url.path) ? url.path : ""
    }

    private static func buildIndexMarkdown(entries: [CallRecordIndexEntry]) -> String {
        var lines = ["# 通话记录索引", ""]
        if entries.isEmpty {
            lines.append("暂无已完成通话记录。")
            return lines.joined(separator: "\n")
        }
        for entry in entries {
            lines.append("- \(entry.callDateText) | \(entry.displayName) | \(entry.rawPhone)")
            if !entry.speakerTextPath.isEmpty {
                lines.append("  - 整理版: \(entry.speakerTextPath)")
            } else if !entry.transcriptPath.isEmpty {
                lines.append("  - 通话记录: \(entry.transcriptPath)")
            }
            if !entry.summaryPath.isEmpty {
                lines.append("  - 摘要: \(entry.summaryPath)")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func writeContactPages(entries: [CallRecordIndexEntry], archiveRoot: URL) throws {
        let contactsDir = archiveRoot.appendingPathComponent("Contacts", isDirectory: true)
        try FileManager.default.createDirectory(at: contactsDir, withIntermediateDirectories: true)

        let grouped = Dictionary(grouping: entries, by: \.normalizedPhone)
        for (phone, phoneEntries) in grouped {
            guard let first = phoneEntries.sorted(by: { $0.callDate > $1.callDate }).first else { continue }
            let namePart = first.contactName.map { "_\(sanitizePathComponent($0))" } ?? ""
            let pageURL = contactsDir.appendingPathComponent("\(phone)\(namePart).md")
            var lines = ["# \(first.displayName)", "", "- 号码: \(first.rawPhone)", ""]
            for entry in phoneEntries.sorted(by: { $0.callDate > $1.callDate }) {
                lines.append("## \(entry.callDateText)")
                if !entry.speakerTextPath.isEmpty {
                    lines.append("- 整理版: \(entry.speakerTextPath)")
                } else if !entry.transcriptPath.isEmpty {
                    lines.append("- 通话记录: \(entry.transcriptPath)")
                }
                if !entry.summaryPath.isEmpty {
                    lines.append("- 摘要: \(entry.summaryPath)")
                }
                lines.append("- 输出目录: \(entry.outputDirectoryPath)")
                lines.append("")
            }
            try lines.joined(separator: "\n").write(to: pageURL, atomically: true, encoding: .utf8)
        }
    }

    private static func sanitizePathComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        return value
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension Notification.Name {
    static let callRecordArchiveWriterDidWrite = Notification.Name("CallRecordArchiveWriter.didWrite")
}
