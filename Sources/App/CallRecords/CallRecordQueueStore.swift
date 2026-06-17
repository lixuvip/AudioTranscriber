import AVFoundation
import Combine
import Foundation

@MainActor
final class CallRecordQueueStore: ObservableObject {
    static let minimumDurationSeconds: Double = 10

    @Published private(set) var jobs: [CallRecordBatchJob] = []
    @Published private(set) var isActive = false
    @Published private(set) var isPaused = false

    private let storageURL: URL
    private let legacyDefaultsKey: String?

    init(
        storageURL: URL? = nil,
        legacyDefaultsKey: String? = "callRecordBatchJobs"
    ) {
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        self.legacyDefaultsKey = legacyDefaultsKey
        load()
    }

    private static func defaultStorageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("VoiceScribe", isDirectory: true)
            .appendingPathComponent("call_record_queue.json")
    }

    func importFiles(
        _ urls: [URL],
        outputRoot: URL?,
        engine: String,
        modelID: String
    ) async {
        let supported = urls
            .filter { Self.isSupportedMedia($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for url in supported {
            let metadata = CallRecordFilenameParser.parse(fileURL: url)
            let duration = await Self.mediaDurationSeconds(for: url)
            let resolvedOutputRoot = outputRoot ?? defaultArchiveRoot(for: url)
            let outputDirectory = Self.outputDirectory(
                for: metadata,
                sourceURL: url,
                outputRoot: resolvedOutputRoot
            )

            var status: CallRecordJobStatus = .pending
            var message: String?
            if metadata == nil {
                status = .ignored
                message = "文件名不符合通话记录格式，已忽略"
            } else if let duration, duration < Self.minimumDurationSeconds {
                status = .ignored
                message = "录音少于 10 秒，已忽略"
            }

            let job = CallRecordBatchJob(
                id: Self.stableJobID(sourceURL: url, metadata: metadata),
                sourcePath: url.path,
                outputDirectoryPath: outputDirectory.path,
                metadata: metadata,
                status: status,
                durationSeconds: duration,
                progress: status == .ignored ? 0 : 0,
                errorMessage: message,
                engine: engine,
                modelID: modelID,
                createdAt: Date(),
                startedAt: nil,
                finishedAt: status == .ignored ? Date() : nil
            )
            upsert(job)
        }
        save()
    }

    func importFolder(
        _ folderURL: URL,
        outputRoot: URL?,
        engine: String,
        modelID: String
    ) async {
        let files = Self.mediaFiles(in: folderURL)
        await importFiles(files, outputRoot: outputRoot, engine: engine, modelID: modelID)
    }

    func start() {
        isActive = true
        isPaused = false
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isActive = true
        isPaused = false
    }

    func stop() {
        isActive = false
        isPaused = false
    }

    func clearCompletedAndIgnored() {
        jobs.removeAll { $0.status == .completed || $0.status == .ignored }
        save()
    }

    func clearAll() {
        jobs.removeAll()
        isActive = false
        isPaused = false
        save()
    }

    func retry(_ job: CallRecordBatchJob) {
        updateJob(id: job.id) { item in
            item.status = .pending
            item.progress = 0
            item.errorMessage = nil
            item.startedAt = nil
            item.finishedAt = nil
            item.engine = job.engine
            item.modelID = job.modelID
        }
    }

    func nextPendingJob() -> CallRecordBatchJob? {
        guard isActive, !isPaused else { return nil }
        return jobs
            .filter { $0.status == .pending }
            .sorted { lhs, rhs in
                let leftDate = lhs.metadata?.callDate ?? lhs.createdAt
                let rightDate = rhs.metadata?.callDate ?? rhs.createdAt
                return leftDate < rightDate
            }
            .first
    }

    func markRunning(_ job: CallRecordBatchJob, engine: String, modelID: String) {
        updateJob(id: job.id) { item in
            item.status = .running
            item.progress = 0
            item.errorMessage = nil
            item.engine = engine
            item.modelID = modelID
            item.startedAt = Date()
            item.finishedAt = nil
        }
    }

    func markCompleted(id: String) {
        updateJob(id: id) { item in
            item.status = .completed
            item.progress = 1
            item.errorMessage = nil
            item.finishedAt = Date()
        }
    }

    func markSummarizing(id: String) {
        updateJob(id: id) { item in
            item.status = .summarizing
            item.progress = 0
            item.errorMessage = nil
        }
    }

    func markFailed(id: String, message: String) {
        updateJob(id: id) { item in
            item.status = .failed
            item.progress = 0
            item.errorMessage = message
            item.finishedAt = Date()
        }
    }

    func markCancelled(id: String) {
        updateJob(id: id) { item in
            item.status = .cancelled
            item.progress = 0
            item.errorMessage = "用户取消"
            item.finishedAt = Date()
        }
    }

    func activeJob(for sourcePath: String) -> CallRecordBatchJob? {
        jobs.first {
            $0.sourcePath == sourcePath
                && ($0.status == .running || $0.status == .summarizing)
        }
    }

    private func upsert(_ job: CallRecordBatchJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
    }

    private func updateJob(id: String, mutate: (inout CallRecordBatchJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
        save()
    }

    private var backupURL: URL {
        storageURL.appendingPathExtension("backup")
    }

    private func load() {
        // 一次性迁移：旧版本把队列存在 UserDefaults，迁到原子文件存储（带备份）。
        migrateFromUserDefaultsIfNeeded()

        // 主文件损坏时回退到 .backup。
        let decoded = decodeJobs(from: storageURL) ?? decodeJobs(from: backupURL) ?? []
        jobs = decoded.map { job in
            var item = job
            if item.status == .running || item.status == .summarizing {
                item.status = .pending
                item.progress = 0
                item.errorMessage = "上次退出时任务未完成，已恢复为等待中"
            }
            return item
        }
    }

    private func decodeJobs(from url: URL) -> [CallRecordBatchJob]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([CallRecordBatchJob].self, from: data)
    }

    private func migrateFromUserDefaultsIfNeeded() {
        // 旧数据格式与新文件一致（默认 JSONEncoder），直接落盘即可，无需重编码。
        guard let key = legacyDefaultsKey,
              !FileManager.default.fileExists(atPath: storageURL.path),
              let data = UserDefaults.standard.data(forKey: key),
              (try? JSONDecoder().decode([CallRecordBatchJob].self, from: data)) != nil else {
            return
        }
        do {
            try writeAtomically(data)
            UserDefaults.standard.removeObject(forKey: key)
        } catch {
            // 迁移失败保留旧数据，下次启动再试，不影响本次运行。
            print("[CallRecordQueueStore] 迁移旧队列数据失败: \(error)")
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        do {
            try writeAtomically(data)
        } catch {
            // 持久化失败不应中断内存中的队列状态。
            print("[CallRecordQueueStore] 保存队列失败: \(error)")
        }
    }

    /// 原子写入：先备份现有有效文件，再写临时文件并原子替换，避免写一半导致损坏。
    private func writeAtomically(_ data: Data) throws {
        let fileManager = FileManager.default
        let directoryURL = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: storageURL.path) {
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.removeItem(at: backupURL)
            }
            try? fileManager.copyItem(at: storageURL, to: backupURL)
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(storageURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporaryURL)
            if fileManager.fileExists(atPath: storageURL.path) {
                _ = try fileManager.replaceItemAt(storageURL, withItemAt: temporaryURL)
            } else {
                try fileManager.moveItem(at: temporaryURL, to: storageURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func stableJobID(sourceURL: URL, metadata: CallRecordMetadata?) -> String {
        if let metadata {
            return "\(metadata.normalizedPhone)_\(metadata.timestampDigits)"
        }
        return sourceURL.path
    }

    private static func outputDirectory(
        for metadata: CallRecordMetadata?,
        sourceURL: URL,
        outputRoot: URL
    ) -> URL {
        if let metadata {
            return outputRoot
                .appendingPathComponent("Calls", isDirectory: true)
                .appendingPathComponent(metadata.yearPathComponent, isDirectory: true)
                .appendingPathComponent(metadata.monthPathComponent, isDirectory: true)
                .appendingPathComponent(metadata.directorySlug, isDirectory: true)
        }
        return outputRoot
            .appendingPathComponent("Ignored", isDirectory: true)
            .appendingPathComponent(sourceURL.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    private func defaultArchiveRoot(for sourceURL: URL) -> URL {
        sourceURL.deletingLastPathComponent()
            .appendingPathComponent("VoiceScribe_CallRecords", isDirectory: true)
    }

    private static func mediaFiles(in folderURL: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return isSupportedMedia(url) ? url : nil
        }
    }

    private static func isSupportedMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["m4a", "mp3", "wav", "mp4", "mov", "aac", "flac"].contains(ext)
    }

    private static func mediaDurationSeconds(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        do {
            if #available(macOS 13.0, *) {
                let duration = try await asset.load(.duration)
                let seconds = CMTimeGetSeconds(duration)
                return seconds.isFinite ? seconds : nil
            } else {
                let seconds = CMTimeGetSeconds(asset.duration)
                return seconds.isFinite ? seconds : nil
            }
        } catch {
            return nil
        }
    }
}
