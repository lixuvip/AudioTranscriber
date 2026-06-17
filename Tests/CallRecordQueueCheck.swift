import Foundation

@main
struct CallRecordQueueCheck {
    static func main() async throws {
        if CommandLine.arguments.count > 1 {
            try await checkFixtureDirectory(
                URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            )
            return
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CallRecordQueueCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let short = root.appendingPathComponent("短录音@153 9711 1188_20240826172812.wav")
        let long = root.appendingPathComponent("章文@153 9711 1188_20240826172813.wav")
        try writeSilentWav(to: short, durationSeconds: 5)
        try writeSilentWav(to: long, durationSeconds: 12)

        let outputRoot = root.appendingPathComponent("Archive", isDirectory: true)
        let store = await MainActor.run {
            CallRecordQueueStore(
                storageURL: root.appendingPathComponent("queue-\(UUID().uuidString).json"),
                legacyDefaultsKey: nil
            )
        }
        await store.importFiles(
            [short, long],
            outputRoot: outputRoot,
            engine: "whisperMLX",
            modelID: "mlx-community/whisper-large-v3-turbo"
        )

        let jobs = await MainActor.run { store.jobs.sorted { $0.sourcePath < $1.sourcePath } }
        assertEqual(jobs.count, 2, "job count")

        let ignored = try require(jobs.first { $0.sourcePath == short.path }, "short job")
        assertEqual(ignored.status, .ignored, "short status")
        assertEqual(ignored.errorMessage, "录音少于 10 秒，已忽略", "short reason")

        let queued = try require(jobs.first { $0.sourcePath == long.path }, "long job")
        assertEqual(queued.status, .pending, "long status")
        assertEqual(queued.metadata?.contactName, "章文", "long contact")
        assertEqual(queued.outputDirectoryPath.hasSuffix("Calls/2024/2024-08/20240826_172813_章文_15397111188"), true, "output path")

        await MainActor.run { store.start() }
        let next = await MainActor.run { store.nextPendingJob() }
        assertEqual(next?.id, queued.id, "next pending job")

        await MainActor.run {
            store.markRunning(queued, engine: queued.engine, modelID: queued.modelID)
        }
        assertEqual(
            await MainActor.run { store.activeJob(for: queued.sourcePath)?.status },
            .running,
            "running job lookup"
        )

        await MainActor.run { store.markSummarizing(id: queued.id) }
        assertEqual(
            await MainActor.run { store.activeJob(for: queued.sourcePath)?.status },
            .summarizing,
            "summary status"
        )

        await MainActor.run { store.markCompleted(id: queued.id) }
        assertEqual(
            await MainActor.run { store.jobs.first(where: { $0.id == queued.id })?.status },
            .completed,
            "completed after summary"
        )
    }

    private static func checkFixtureDirectory(_ directory: URL) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw CheckError("fixture directory does not exist: \(directory.path)")
        }

        let sourceFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { ["m4a", "mp3", "wav", "mp4", "mov", "aac", "flac"].contains($0.pathExtension.lowercased()) }

        guard !sourceFiles.isEmpty else {
            throw CheckError("fixture directory contains no supported media")
        }

        let outputRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CallRecordRealFilesCheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputRoot) }

        let store = await MainActor.run {
            CallRecordQueueStore(
                storageURL: outputRoot.appendingPathComponent("queue-\(UUID().uuidString).json"),
                legacyDefaultsKey: nil
            )
        }
        await store.importFolder(
            directory,
            outputRoot: outputRoot,
            engine: "whisperMLX",
            modelID: "mlx-community/whisper-large-v3-turbo"
        )

        let jobs = await MainActor.run { store.jobs.sorted { $0.sourcePath < $1.sourcePath } }
        assertEqual(jobs.count, sourceFiles.count, "fixture job count")
        let minimumDuration = await MainActor.run { CallRecordQueueStore.minimumDurationSeconds }

        for job in jobs {
            guard let metadata = job.metadata else {
                throw CheckError("filename did not parse: \(job.sourceURL.lastPathComponent)")
            }
            guard let duration = job.durationSeconds else {
                throw CheckError("duration unavailable: \(job.sourceURL.lastPathComponent)")
            }

            let expectedStatus: CallRecordJobStatus = duration < minimumDuration
                ? .ignored
                : .pending
            assertEqual(job.status, expectedStatus, "fixture status for \(job.sourceURL.lastPathComponent)")

            print(
                String(
                    format: "%.3fs\t%@\t%@\t%@",
                    duration,
                    job.status.rawValue,
                    metadata.displayName,
                    metadata.normalizedPhone
                )
            )
        }

        let ignoredCount = jobs.filter { $0.status == .ignored }.count
        let pendingCount = jobs.filter { $0.status == .pending }.count
        print("checked=\(jobs.count) ignored=\(ignoredCount) pending=\(pendingCount)")
    }

    private static func writeSilentWav(to url: URL, durationSeconds: Int) throws {
        let sampleRate = 16_000
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = durationSeconds * byteRate
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(UInt32(36 + dataSize).littleEndianData)
        data.append("WAVEfmt ".data(using: .ascii)!)
        data.append(UInt32(16).littleEndianData)
        data.append(UInt16(1).littleEndianData)
        data.append(UInt16(channels).littleEndianData)
        data.append(UInt32(sampleRate).littleEndianData)
        data.append(UInt32(byteRate).littleEndianData)
        data.append(UInt16(blockAlign).littleEndianData)
        data.append(UInt16(bitsPerSample).littleEndianData)
        data.append("data".data(using: .ascii)!)
        data.append(UInt32(dataSize).littleEndianData)
        data.append(Data(repeating: 0, count: dataSize))
        try data.write(to: url)
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

private extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = littleEndian
        return Data(bytes: &value, count: MemoryLayout<Self>.size)
    }
}
