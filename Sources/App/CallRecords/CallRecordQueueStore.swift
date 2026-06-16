import AVFoundation
import Combine
import Foundation

@MainActor
final class CallRecordQueueStore: ObservableObject {
    static let minimumDurationSeconds: Double = 10

    @Published private(set) var jobs: [CallRecordBatchJob] = []
    @Published private(set) var isActive = false
    @Published private(set) var isPaused = false

    private let storageKey: String

    init(storageKey: String = "callRecordBatchJobs") {
        self.storageKey = storageKey
        load()
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

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([CallRecordBatchJob].self, from: data) else {
            jobs = []
            return
        }
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

    private func save() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
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
