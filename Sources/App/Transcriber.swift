import Foundation
import Combine
import Darwin

@MainActor
class Transcriber: ObservableObject {
    @Published var isTranscribing = false
    @Published var isSummarizing = false
    @Published var logs: [String] = []
    @Published var progress: Double = 0
    @Published var currentProgress: String = ""
    @Published var speakerRoles: [SpeakerRole] = []
    @Published var speakerRolesReady = false
    @Published var currentTranscriptURL: URL?
    @Published var currentSpeakerMapURL: URL?
    @Published var currentSpeakerTextURL: URL?
    @Published var pendingHistoryEntry: TranscriptionHistoryEntry?

    private var currentTask: Process?
    private var didRequestStop = false
    private var currentTranscriptSegments: [TranscriptSegment] = []
    private var currentTranscriptTitle: String = ""
    private var transcriptionStartTime: Date?
    private var currentEngine: String = ""
    private var currentModelID: String = ""
    private var currentOutputDir: URL?

    var bundleScriptsDir: URL {
        if Bundle.main.resourceURL != nil {
            return Bundle.main.resourceURL!
        }
        return URL(fileURLWithPath: "../../../Scripts") // fallback only for dev, not used in built app
    }

    func startTranscription(audioURL: URL?, outputDir: URL?, pythonPath: String, pythonSitePackages: String = "", performanceProfile: PerformanceProfile = .automatic, engine: TranscriptionEngine = .funASR, modelID: String = "") {
        guard let audioURL = audioURL else { return }
        let outDir = outputDir ?? audioURL.deletingLastPathComponent()

        didRequestStop = false
        speakerRoles = []
        speakerRolesReady = false
        currentTranscriptURL = nil
        currentSpeakerMapURL = nil
        currentSpeakerTextURL = nil
        currentTranscriptSegments = []
        currentTranscriptTitle = audioURL.deletingPathExtension().lastPathComponent
        isTranscribing = true
        isSummarizing = false
        logs = []
        progress = 0
        currentProgress = "准备中..."
        pendingHistoryEntry = nil
        transcriptionStartTime = Date()
        currentEngine = engine.rawValue
        currentModelID = modelID.isEmpty ? engine.defaultModelID : modelID
        currentOutputDir = outDir

        let scriptPath = bundleScriptsDir.appendingPathComponent("transcribe.py").path
        var env = ProcessInfo.processInfo.environment
        env["OMP_NUM_THREADS"] = "\(performanceProfile.threads)"
        env["MKL_NUM_THREADS"] = "\(performanceProfile.threads)"
        if !pythonSitePackages.isEmpty {
            env["PYTHONPATH"] = pythonSitePackages
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            scriptPath,
            audioURL.path,
            outDir.path,
            "--engine", engine.rawValue,
            "--model-id", modelID.isEmpty ? engine.defaultModelID : modelID,
            "--device", performanceProfile.device,
            "--threads", "\(performanceProfile.threads)",
            "--batch-size-s", "\(performanceProfile.batchSizeSeconds)",
            "--merge-length-s", "\(performanceProfile.mergeLengthSeconds)",
            "--speaker-diarization", performanceProfile.speakerDiarizationEnabled ? "1" : "0"
        ]
        process.environment = env

        currentTranscriptURL = outDir.appendingPathComponent("\(audioURL.deletingPathExtension().lastPathComponent)_通话记录.md")
        currentSpeakerMapURL = outDir.appendingPathComponent("\(audioURL.deletingPathExtension().lastPathComponent)_speaker_map.json")
        currentSpeakerTextURL = outDir.appendingPathComponent("\(audioURL.deletingPathExtension().lastPathComponent)_整理版.md")

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = FileHandle.nullDevice
        currentTask = process

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.handleOutput(text) }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.handleTermination(status: proc.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            appendLog("启动失败: \(error.localizedDescription)")
            isTranscribing = false
        }
    }

    func stopTranscription() {
        guard let task = currentTask, task.isRunning else {
            isTranscribing = false
            currentTask = nil
            return
        }

        didRequestStop = true
        currentProgress = "正在停止..."
        appendLog("正在停止转写进程...")
        task.terminate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak task] in
            guard let self, let task, self.didRequestStop, task.isRunning else { return }
            kill(task.processIdentifier, SIGKILL)
            self.appendLog("转写进程未及时退出，已强制结束。")
        }
    }

    func stopCurrentTask() {
        if isTranscribing {
            stopTranscription()
            return
        }

        guard let task = currentTask, task.isRunning else {
            isSummarizing = false
            currentTask = nil
            return
        }

        didRequestStop = true
        currentProgress = "正在停止..."
        appendLog("正在停止当前进程...")
        task.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak task] in
            guard let self, let task, self.didRequestStop, task.isRunning else { return }
            kill(task.processIdentifier, SIGKILL)
            self.appendLog("当前进程未及时退出，已强制结束。")
        }
    }

    private func markStoppedByUser() {
        progress = 0
        currentProgress = "已停止"
        isTranscribing = false
        isSummarizing = false
        currentTask = nil
        didRequestStop = false
        appendLog("已停止")
    }

    func startSummarization(audioURL: URL?, outputDir: URL?, model: LLMModel, pythonPath: String, summaryPrompt: String = "") {
        guard let audioURL = audioURL else { return }
        let outDir = outputDir ?? audioURL.deletingLastPathComponent()
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        let speakerTextPath = outDir.appendingPathComponent("\(baseName)_整理版.md")
        let fallbackPath = outDir.appendingPathComponent("\(baseName)_通话记录.md")
        let inputPath = FileManager.default.fileExists(atPath: speakerTextPath.path) ? speakerTextPath : fallbackPath

        didRequestStop = false
        isSummarizing = true
        isTranscribing = false
        logs = []
        progress = 0
        currentProgress = "生成摘要..."

        let scriptPath = bundleScriptsDir.appendingPathComponent("summarize.py").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            scriptPath,
            inputPath.path,
            model.id,
            "--api-base", model.apiBase,
            "--api-key", model.apiKey,
            "--provider-type", model.providerType.rawValue,
        ]
        if !summaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            process.arguments?.append(contentsOf: ["--summary-prompt", summaryPrompt])
            appendLog("已应用摘要提示词")
        }
        currentTask = process

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.standardInput = FileHandle.nullDevice

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.handleOutput(text) }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.handleTermination(status: proc.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            appendLog("启动失败: \(error.localizedDescription)")
            isSummarizing = false
        }
    }

    private func handleOutput(_ text: String) {
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        for line in lines {
            appendLog(line)
            if line.contains("rtf") {
                progress = min(progress + 0.02, 0.95)
                currentProgress = "转写中..."
            }
            if line.contains("Done in") || line.contains("完成") {
                progress = 0.98
            }
        }
    }

    private func handleTermination(status: Int32) {
        if didRequestStop {
            markStoppedByUser()
            return
        }

        if status == 0 {
            progress = 1.0
            currentProgress = "完成 ✓"
            appendLog("✓ 完成")
            loadSpeakerRolesIfNeeded()
            createHistoryEntry()
        } else if isTranscribing {
            appendLog("✗ 转写失败 (exit: \(status))")
            progress = 0
        } else if isSummarizing {
            appendLog("✗ 总结失败 (exit: \(status))")
            progress = 0
        }
        isTranscribing = false
        isSummarizing = false
        currentTask = nil
    }

    private func appendLog(_ line: String) {
        if logs.count > 500 { logs.removeFirst() }
        logs.append(line)
    }

    private func createHistoryEntry() {
        let duration = transcriptionStartTime.map { Date().timeIntervalSince($0) }
        let entry = TranscriptionHistoryEntry(
            fileName: currentTranscriptTitle,
            filePath: currentTranscriptURL?.path ?? "",
            outputDir: currentOutputDir?.path ?? "",
            engine: currentEngine,
            modelID: currentModelID,
            date: Date(),
            duration: duration,
            segmentCount: currentTranscriptSegments.count,
            speakerCount: speakerRoles.count
        )
        pendingHistoryEntry = entry
    }

    private func loadSpeakerRolesIfNeeded() {
        guard let mapURL = currentSpeakerMapURL,
              let data = try? Data(contentsOf: mapURL),
              let payload = try? JSONDecoder().decode(SpeakerMapPayload.self, from: data) else {
            speakerRolesReady = false
            return
        }
        currentTranscriptSegments = payload.segments
        currentTranscriptTitle = payload.title
        speakerRoles = payload.roles.map {
            SpeakerRole(key: $0.key, placeholder: $0.placeholder, displayName: $0.displayName)
        }
        speakerRolesReady = !speakerRoles.isEmpty
        rebuildSpeakerText()
    }

    func updateSpeakerRole(id: String, displayName: String) {
        guard let index = speakerRoles.firstIndex(where: { $0.id == id }) else { return }
        speakerRoles[index].displayName = displayName
        rebuildSpeakerText()
    }

    func applySpeakerNames() {
        rebuildSpeakerText()
        appendLog("已更新角色名称并重写正文")
    }

    private func rebuildSpeakerText() {
        guard let speakerTextURL = currentSpeakerTextURL else { return }
        let nameMap = Dictionary(uniqueKeysWithValues: speakerRoles.map {
            ($0.placeholder, $0.displayName.isEmpty ? $0.placeholder : $0.displayName)
        })

        var lines: [String] = ["# \(currentTranscriptTitle) 整理版\n"]
        for segment in currentTranscriptSegments {
            let start = timestamp(from: segment.start)
            let speakerName = nameMap[segment.placeholder] ?? segment.placeholder
            lines.append("[\(start)] 【\(speakerName)】 \(segment.text)")
        }

        try? lines.joined(separator: "\n").write(to: speakerTextURL, atomically: true, encoding: .utf8)
    }

    private func timestamp(from seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct SpeakerRole: Identifiable, Codable {
    var id: String { key }
    let key: String
    let placeholder: String
    var displayName: String
}

struct TranscriptSegment: Codable {
    let speakerKey: String
    let placeholder: String
    let start: Double
    let end: Double
    let text: String
}

struct SpeakerMapPayload: Codable {
    let title: String
    let roles: [SpeakerRole]
    let segments: [TranscriptSegment]
}
