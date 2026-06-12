import Foundation
import Combine
import Darwin
import AVFoundation

@MainActor
class Transcriber: ObservableObject {
    @Published var isAudioPlaying = false
    @Published var currentPlaybackTime: Double = 0
    @Published var audioDuration: Double = 0
    @Published var playbackSpeed: Double = 1.0
    
    private var audioPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    var currentAudioURL: URL?

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
    @Published var memoryWarning: String?
    @Published var showMemoryWarning = false
    @Published var estimatedTimeRemaining: String?
    @Published var completionSummary: TranscriptionCompletionSummary?
    @Published var generatedSummary: String? = nil
    @Published var lastKnownStageIndex: Int = 0
    @Published var isRemoteTranscription = false

    private var currentTask: Process?
    private var didRequestStop = false
    @Published var currentTranscriptSegments: [TranscriptSegment] = []
    @Published var currentTranscriptTitle: String = ""
    private var transcriptionStartTime: Date?
    private var currentEngine: String = ""
    private var currentTranscriptionEngine: TranscriptionEngine = .funASR
    private var currentModelID: String = ""
    private var currentPythonPath: String = ""
    private var currentPythonSitePackages: String = ""
    var currentOutputDir: URL?
    private var audioDurationSeconds: Double?
    private var processedDurationSeconds: Double = 0
    private var memoryMonitorTimer: Timer?
    private var etaTimer: Timer?
    private var remoteTaskID: String?
    private var remoteServiceURL: String?
    private var executionTarget: ExecutionTarget = .local

    var bundleScriptsDir: URL {
        if Bundle.main.resourceURL != nil {
            return Bundle.main.resourceURL!
        }
        return URL(fileURLWithPath: "../../../Scripts") // fallback only for dev, not used in built app
    }

    func startTranscription(
        audioURL: URL?,
        outputDir: URL?,
        pythonPath: String,
        pythonSitePackages: String = "",
        performanceProfile: PerformanceProfile = .automatic,
        engine: TranscriptionEngine = .funASR,
        modelID: String = "",
        executionTarget: ExecutionTarget = .local,
        remoteServiceURL: String = "",
        remoteTailscaleURL: String = "",
        relayServiceURL: String = "",
        speakerDiarizationEnabled: Bool = true
    ) {
        guard let audioURL = audioURL else { return }
        let outDir = outputDir ?? audioURL.deletingLastPathComponent()

        didRequestStop = false
        currentAudioURL = audioURL
        isAudioPlaying = false
        currentPlaybackTime = 0
        audioDuration = 0
        if let player = audioPlayer {
            player.stop()
            audioPlayer = nil
        }
        playbackTimer?.invalidate()
        playbackTimer = nil
        
        speakerRoles = []
        speakerRolesReady = false
        currentTranscriptURL = nil
        currentSpeakerMapURL = nil
        currentSpeakerTextURL = nil
        currentTranscriptSegments = []
        currentTranscriptTitle = audioURL.deletingPathExtension().lastPathComponent
        isTranscribing = true
        lastKnownStageIndex = 0
        self.executionTarget = executionTarget
        isRemoteTranscription = (executionTarget == .remote || executionTarget == .relay)
        isSummarizing = false
        logs = []
        progress = 0
        currentProgress = "准备中..."
        pendingHistoryEntry = nil
        completionSummary = nil
        estimatedTimeRemaining = nil
        transcriptionStartTime = Date()
        currentEngine = engine.rawValue
        currentTranscriptionEngine = engine
        currentModelID = modelID.isEmpty ? engine.defaultModelID : modelID
        currentPythonPath = pythonPath
        currentPythonSitePackages = pythonSitePackages
        currentOutputDir = outDir
        audioDurationSeconds = nil
        processedDurationSeconds = 0

        if executionTarget == .remote || executionTarget == .relay {
            self.remoteServiceURL = executionTarget == .relay ? relayServiceURL : remoteServiceURL
            self.startRemoteTranscription(
                audioURL: audioURL,
                outDir: outDir,
                performanceProfile: performanceProfile,
                engine: engine,
                modelID: modelID,
                remoteServiceURL: remoteServiceURL,
                remoteTailscaleURL: remoteTailscaleURL,
                relayServiceURL: relayServiceURL,
                executionTarget: executionTarget,
                speakerDiarizationEnabled: speakerDiarizationEnabled
            )
            return
        }

        // 内存预检
        let tier: PerformanceTier
        if performanceProfile.summary.contains("高") {
            tier = .high
        } else if performanceProfile.summary.contains("中") {
            tier = .medium
        } else {
            tier = .low
        }
        let memCheck = EnvironmentChecker.checkAvailableMemory(engine: engine, currentTier: tier)
        var effectiveProfile = performanceProfile

        switch memCheck.recommendation {
        case .proceed:
            break
        case .downgrade(let suggestedTier, let reason):
            memoryWarning = reason
            showMemoryWarning = true
            appendLog("[内存预检] \(reason)")
            effectiveProfile = adjustProfileForTier(suggestedTier, base: performanceProfile, engine: engine)
        case .warn(let reason):
            memoryWarning = reason
            showMemoryWarning = true
            appendLog("[内存预检] \(reason)")
            effectiveProfile = adjustProfileForTier(.low, base: performanceProfile, engine: engine)
        }

        let scriptPath = bundleScriptsDir.appendingPathComponent("transcribe.py").path
        var env = ProcessInfo.processInfo.environment
        env["OMP_NUM_THREADS"] = "\(effectiveProfile.threads)"
        env["MKL_NUM_THREADS"] = "\(effectiveProfile.threads)"
        if !pythonSitePackages.isEmpty {
            env["PYTHONPATH"] = pythonSitePackages
        }
        // Pass HF token for gated models (pyannote diarization)
        if let token = UserDefaults.standard.string(forKey: "hfToken"), !token.isEmpty {
            env["HF_TOKEN"] = token
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [
            scriptPath,
            audioURL.path,
            outDir.path,
            "--engine", engine.scriptEngineRawValue,
            "--model-id", modelID.isEmpty ? engine.defaultModelID : modelID,
            "--device", effectiveProfile.device,
            "--threads", "\(effectiveProfile.threads)",
            "--batch-size-s", "\(effectiveProfile.batchSizeSeconds)",
            "--merge-length-s", "\(effectiveProfile.mergeLengthSeconds)",
            "--speaker-diarization", speakerDiarizationEnabled ? "1" : "0"
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

        startMemoryMonitor(engine: engine)
        startETATimer()

        do {
            try process.run()
        } catch {
            appendLog("启动失败: \(error.localizedDescription)")
            isTranscribing = false
            stopMemoryMonitor()
            stopETATimer()
        }
    }

    private func startRemoteTranscription(
        audioURL: URL,
        outDir: URL,
        performanceProfile: PerformanceProfile,
        engine: TranscriptionEngine,
        modelID: String,
        remoteServiceURL: String,
        remoteTailscaleURL: String,
        relayServiceURL: String,
        executionTarget: ExecutionTarget,
        speakerDiarizationEnabled: Bool
    ) {
        Task {
            do {
                self.currentProgress = "检测远程连接..."
                self.updateStageIndex(for: "检测远程")
                self.appendLog("开始检测远程服务器连接...")
                
                let client = RemoteTranscriberClient()
                var activeURL = ""
                let isRelay = (executionTarget == .relay)
                
                if isRelay {
                    let relayClean = relayServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if relayClean.isEmpty {
                        throw VoiceScribeRemoteClientError.invalidServiceURL
                    }
                    self.appendLog("正在连接中转服务器: \(relayClean)...")
                    _ = try await client.health(serviceURL: relayClean, isRelay: true, timeout: 5.0)
                    activeURL = relayClean
                    self.appendLog("✓ 中转服务器连接成功。")
                } else {
                    // 1. 尝试检测局域网连接
                    var primaryConnected = false
                    let primaryClean = remoteServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !primaryClean.isEmpty {
                        do {
                            self.appendLog("正在测试局域网连接: \(primaryClean)...")
                            _ = try await client.health(serviceURL: primaryClean, isRelay: false, timeout: 2.0)
                            primaryConnected = true
                            activeURL = primaryClean
                            self.appendLog("✓ 局域网连接成功，将使用局域网地址。")
                        } catch {
                            self.appendLog("⚠️ 局域网连接失败: \(error.localizedDescription)")
                        }
                    }
                    
                    // 2. 如果局域网失败，且配置了 Tailscale，尝试检测 Tailscale 连接
                    if !primaryConnected {
                        let tsURL = remoteTailscaleURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !tsURL.isEmpty {
                            self.appendLog("正在尝试切换到 Tailscale 地址: \(tsURL)...")
                            do {
                                _ = try await client.health(serviceURL: tsURL, isRelay: false, timeout: 3.0)
                                primaryConnected = true
                                activeURL = tsURL
                                self.appendLog("✓ Tailscale 连接成功，已切换到 Tailscale 地址。")
                            } catch {
                                self.appendLog("❌ Tailscale 连接亦失败: \(error.localizedDescription)")
                                if primaryClean.isEmpty {
                                    throw error
                                }
                                self.appendLog("默认回退至局域网地址进行尝试。")
                            }
                        } else {
                            if primaryClean.isEmpty {
                                throw VoiceScribeRemoteClientError.invalidServiceURL
                            }
                            self.appendLog("未配置 Tailscale 备份地址，默认使用局域网地址进行尝试。")
                        }
                    }
                }
                
                if activeURL.isEmpty {
                    activeURL = isRelay ? relayServiceURL.trimmingCharacters(in: .whitespacesAndNewlines) : remoteServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                
                // 记录当前活跃的 URL，用于停止任务等操作
                self.remoteServiceURL = activeURL
                
                appendLog("开始上传音频到远程服务器: \(audioURL.lastPathComponent)")
                currentProgress = "正在上传音频..."
                self.updateStageIndex(for: "上传")
                let uploadResult = try await client.uploadAudio(at: audioURL, serviceURL: activeURL, isRelay: isRelay)
                appendLog("音频上传成功, ID: \(uploadResult.uploadID)")
                
                if self.didRequestStop {
                    self.markStoppedByUser()
                    return
                }
                
                self.currentProgress = "提交转写任务..."
                self.updateStageIndex(for: "提交")
                self.appendLog("提交转写任务中...")
                
                var arguments: [String: String] = [
                    "engine": engine.scriptEngineRawValue,
                    "model_id": modelID.isEmpty ? engine.defaultModelID : modelID,
                    "device": performanceProfile.device,
                    "threads": "\(performanceProfile.threads)",
                    "batch_size_s": "\(performanceProfile.batchSizeSeconds)",
                    "merge_length_s": "\(performanceProfile.mergeLengthSeconds)",
                    "speaker_diarization": speakerDiarizationEnabled ? "1" : "0"
                ]
                if let token = UserDefaults.standard.string(forKey: "hfToken"), !token.isEmpty {
                    arguments["hf_token"] = token
                }
                
                let taskStatus = try await client.createTask(
                    serviceURL: activeURL,
                    uploadID: uploadResult.uploadID,
                    arguments: arguments,
                    isRelay: isRelay
                )
                let taskID = taskStatus.taskID
                self.remoteTaskID = taskID
                self.appendLog("转写任务已创建, ID: \(taskID)")
                
                self.currentProgress = "正在排队/运行..."
                self.appendLog("开始轮询任务状态...")
                
                self.transcriptionStartTime = Date()
                self.startETATimer()
                
                var isDone = false
                while !isDone {
                    if self.didRequestStop {
                        self.appendLog("正在终止远程任务...")
                        try? await client.deleteTask(taskID: taskID, serviceURL: activeURL, isRelay: isRelay)
                        self.markStoppedByUser()
                        return
                    }
                    
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    
                    if self.didRequestStop {
                        continue
                    }
                    
                    let status = try await client.taskStatus(taskID: taskID, serviceURL: activeURL, isRelay: isRelay)
                    self.progress = min(status.progress, 0.99)
                    let remoteStage = status.currentStage ?? self.statusTitle(for: status.status)
                    self.currentProgress = remoteStage
                    self.updateStageIndex(for: remoteStage)
                    
                    if let eta = status.estimatedTimeRemaining {
                        self.estimatedTimeRemaining = "预计剩余 \(eta)"
                    }
                    
                    if status.status == "completed" {
                        isDone = true
                        self.appendLog("远程转写任务执行成功，开始下载结果文件...")
                        self.currentProgress = "正在下载结果..."
                        self.updateStageIndex(for: "下载")
                        
                        for file in status.results {
                            let (tempURL, _) = try await client.downloadResult(
                                taskID: taskID,
                                index: file.index,
                                serviceURL: activeURL,
                                isRelay: isRelay
                            )
                            let destURL = outDir.appendingPathComponent(file.filename)
                            if FileManager.default.fileExists(atPath: destURL.path) {
                                try? FileManager.default.removeItem(at: destURL)
                            }
                            try FileManager.default.moveItem(at: tempURL, to: destURL)
                            self.appendLog("已下载产物: \(file.filename)")
                        }
                        
                        self.currentProgress = "完成 ✓"
                        self.updateStageIndex(for: "完成 ✓")
                        self.progress = 1.0
                        self.appendLog("✓ 所有产物下载并保存成功。")
                        
                        self.currentTranscriptURL = outDir.appendingPathComponent("\(audioURL.deletingPathExtension().lastPathComponent)_通话记录.md")
                        self.currentSpeakerMapURL = outDir.appendingPathComponent("\(audioURL.deletingPathExtension().lastPathComponent)_speaker_map.json")
                        self.currentSpeakerTextURL = outDir.appendingPathComponent("\(audioURL.deletingPathExtension().lastPathComponent)_整理版.md")

                        if engine.usesVoiceprintLibrary {
                            self.currentProgress = "声纹库匹配..."
                            self.appendLog("[Voiceprint] 开始读取本地声纹库匹配已知人物")
                            await self.runVoiceprintMatchingIfNeeded()
                        }
                        
                        self.loadSpeakerRolesIfNeeded()
                        self.createHistoryEntry()
                        self.buildCompletionSummary()
                        
                        self.isTranscribing = false
                        self.stopETATimer()
                        self.remoteTaskID = nil
                        
                    } else if status.status == "failed" {
                        isDone = true
                        let errorMsg = status.error?.message ?? "未知错误"
                        self.appendLog("❌ 远程转写失败: \(errorMsg)")
                        self.progress = 0
                        self.isTranscribing = false
                        self.stopETATimer()
                        self.remoteTaskID = nil
                    }
                }
            } catch {
                self.appendLog("❌ 远程转写出错: \(error.localizedDescription)")
                self.progress = 0
                self.isTranscribing = false
                self.stopETATimer()
                self.remoteTaskID = nil
            }
        }
    }

    private func statusTitle(for status: String) -> String {
        switch status {
        case "queued": return "排队中..."
        case "preparing": return "准备中..."
        case "running": return "转写中..."
        case "completed": return "完成 ✓"
        case "failed": return "失败 ✗"
        default: return "运行中..."
        }
    }

    func stopTranscription() {
        if let taskID = remoteTaskID, let serviceURL = remoteServiceURL {
            didRequestStop = true
            currentProgress = "正在停止..."
            appendLog("正在通知远程服务器停止任务...")
            Task {
                do {
                    let client = RemoteTranscriberClient()
                    try await client.deleteTask(taskID: taskID, serviceURL: serviceURL, isRelay: self.executionTarget == .relay)
                    self.appendLog("远程任务已取消。")
                } catch {
                    self.appendLog("取消远程任务失败: \(error.localizedDescription)")
                }
                self.markStoppedByUser()
            }
            return
        }

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
        stopETATimer()
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
            if line.hasPrefix("{\"progress\":") || line.hasPrefix("{\"type\":") {
                parseProgressJSON(line)
                continue
            }
            appendLog(line)
            if line.contains("音频时长") || line.contains("duration") {
                if let durationMatch = extractDuration(from: line) {
                    audioDurationSeconds = durationMatch
                }
            }
            if line.contains("STATUS:") && line.contains("转写中") {
                progress = min(progress + 0.05, 0.90)
                currentProgress = "转写中..."
            }
            if line.contains("rtf") {
                progress = min(progress + 0.02, 0.95)
                currentProgress = "转写中..."
            }
            if line.contains("Done in") || line.contains("完成") {
                progress = 0.98
            }
            updateETA()
        }
    }

    private func parseProgressJSON(_ json: String) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let type = dict["type"] as? String {
            switch type {
            case "progress":
                if let pct = dict["percent"] as? Double {
                    progress = min(pct / 100.0, 0.99)
                }
                if let processed = dict["processed_seconds"] as? Double {
                    processedDurationSeconds = processed
                }
                if let total = dict["total_seconds"] as? Double {
                    audioDurationSeconds = total
                }
                if let stage = dict["stage"] as? String {
                    currentProgress = stage
                    updateStageIndex(for: stage)
                }
                updateETA()
            case "duration":
                if let total = dict["total_seconds"] as? Double {
                    audioDurationSeconds = total
                    appendLog(String(format: "[VoiceScribe] 音频时长: %.0f 秒", total))
                }
            case "error":
                let code = dict["code"] as? String ?? "unknown"
                let message = dict["message"] as? String ?? "未知错误"
                let suggestion = dict["suggestion"] as? String ?? ""
                appendLog("✗ [\(code)] \(message)")
                if !suggestion.isEmpty {
                    appendLog("  建议: \(suggestion)")
                }
            default:
                break
            }
        }
    }

    private func updateETA() {
        guard let startTime = transcriptionStartTime else {
            estimatedTimeRemaining = nil
            return
        }
        let elapsed = Date().timeIntervalSince(startTime)

        // Prefer processed/total duration ratio for more accurate ETA
        let effectiveProgress: Double
        if let processed = processedDurationSeconds > 0 ? processedDurationSeconds : nil,
           let total = audioDurationSeconds, total > 0 {
            effectiveProgress = min(processed / total, 0.99)
        } else {
            effectiveProgress = progress
        }

        guard effectiveProgress > 0.05 else {
            estimatedTimeRemaining = nil
            return
        }

        let estimatedTotal = elapsed / effectiveProgress
        let remaining = max(0, estimatedTotal - elapsed)

        if remaining < 60 {
            estimatedTimeRemaining = "预计剩余 \(Int(remaining)) 秒"
        } else {
            let mins = Int(remaining) / 60
            let secs = Int(remaining) % 60
            estimatedTimeRemaining = String(format: "预计剩余 %d:%02d", mins, secs)
        }
    }

    private func extractDuration(from line: String) -> Double? {
        let pattern = #"(\d+\.?\d*)\s*[秒s]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: 1), in: line) else { return nil }
        return Double(line[range])
    }

    private func handleTermination(status: Int32) {
        stopMemoryMonitor()
        stopETATimer()

        if didRequestStop {
            markStoppedByUser()
            return
        }

        if status == 0 {
            if !isSummarizing && currentTranscriptionEngine.usesVoiceprintLibrary {
                currentProgress = "声纹库匹配..."
                progress = 0.99
                appendLog("[Voiceprint] 开始读取本地声纹库匹配已知人物")
                Task {
                    await self.runVoiceprintMatchingIfNeeded()
                    self.finishSuccessfulRun()
                }
                return
            }
            finishSuccessfulRun()
        } else if isTranscribing {
            appendLog("✗ 转写失败 (exit: \(status))")
            appendErrorSuggestion(for: status)
            progress = 0
        } else if isSummarizing {
            appendLog("✗ 总结失败 (exit: \(status))")
            progress = 0
        }
        isTranscribing = false
        isSummarizing = false
        currentTask = nil
        estimatedTimeRemaining = nil
    }

    private func finishSuccessfulRun() {
        progress = 1.0
        currentProgress = "完成 ✓"
        appendLog("✓ 完成")
        if isSummarizing {
            loadSummaryIfExists()
        } else {
            loadSpeakerRolesIfNeeded()
            createHistoryEntry()
            buildCompletionSummary()
        }
        isTranscribing = false
        isSummarizing = false
        currentTask = nil
        estimatedTimeRemaining = nil
    }

    private func runVoiceprintMatchingIfNeeded() async {
        guard currentTranscriptionEngine.usesVoiceprintLibrary else { return }
        guard let audioURL = currentAudioURL, let speakerMapURL = currentSpeakerMapURL else {
            appendLog("[Voiceprint] 缺少音频或 speaker map，跳过声纹匹配")
            return
        }
        let pythonPath = currentPythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pythonPath.isEmpty, FileManager.default.isExecutableFile(atPath: pythonPath) else {
            appendLog("[Voiceprint] Python 环境不可用，跳过声纹匹配")
            return
        }

        let scriptURL = bundleScriptsDir.appendingPathComponent("voiceprint.py")
        let libraryDir = Self.defaultVoiceprintLibraryDir()
        let result = await runVoiceprintProcess(
            pythonPath: pythonPath,
            arguments: [
                scriptURL.path,
                "match",
                "--audio", audioURL.path,
                "--speaker-map", speakerMapURL.path,
                "--library-dir", libraryDir.path,
            ],
            pythonSitePackages: currentPythonSitePackages
        )
        appendVoiceprintMatchLog(status: result.status, output: result.output)
    }

    private func runVoiceprintProcess(
        pythonPath: String,
        arguments: [String],
        pythonSitePackages: String
    ) async -> (status: Int32, output: String) {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = arguments
            var env = ProcessInfo.processInfo.environment
            if !pythonSitePackages.isEmpty {
                env["PYTHONPATH"] = pythonSitePackages
            }
            process.environment = env
            process.standardInput = FileHandle.nullDevice

            let outputPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = outputPipe

            do {
                try process.run()
                process.waitUntilExit()
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                return (process.terminationStatus, output)
            } catch {
                return (1, error.localizedDescription)
            }
        }.value
    }

    private func appendVoiceprintMatchLog(status: Int32, output: String) {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            appendLog(status == 0 ? "[Voiceprint] 声纹匹配完成，但没有返回匹配结果" : "[Voiceprint] 声纹匹配失败 (exit: \(status))")
            return
        }

        for line in trimmed.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
            guard let data = line.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = dict["type"] as? String else {
                appendLog("[Voiceprint] \(line)")
                continue
            }
            switch type {
            case "voiceprint_matched":
                let matches = dict["matches"] as? [[String: Any]] ?? []
                if matches.isEmpty {
                    appendLog("[Voiceprint] 声纹库已读取，但未找到达到阈值的已知人物")
                } else {
                    let names = matches.compactMap { $0["displayName"] as? String }.joined(separator: "、")
                    appendLog("[Voiceprint] 已匹配 \(matches.count) 个已知人物：\(names)")
                }
            case "voiceprint_match_skipped":
                let reason = dict["reason"] as? String ?? "unknown"
                if let report = dict["dependencyReport"] as? [String: Any],
                   let missing = report["missing"] as? [String],
                   !missing.isEmpty {
                    appendLog("[Voiceprint] 声纹匹配未执行：缺少 \(missing.joined(separator: ", "))")
                } else {
                    appendLog("[Voiceprint] 声纹匹配未执行：\(reason)")
                }
            default:
                appendLog("[Voiceprint] \(line)")
            }
        }
    }

    private static func defaultVoiceprintLibraryDir() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("VoiceScribe", isDirectory: true)
            .appendingPathComponent("Voiceprints", isDirectory: true)
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
            speakerCount: speakerRoles.count,
            audioPath: currentAudioURL?.path
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
        initializeAudioPlayer()
        loadSummaryIfExists()
    }

    func loadSummaryIfExists() {
        guard let outDir = currentOutputDir else { return }
        let summaryURL = outDir.appendingPathComponent("\(currentTranscriptTitle)_摘要.md")
        if FileManager.default.fileExists(atPath: summaryURL.path),
           let content = try? String(contentsOf: summaryURL, encoding: .utf8) {
            self.generatedSummary = content
        } else {
            self.generatedSummary = nil
        }
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

    // MARK: - 内存监控

    private func startMemoryMonitor(engine: TranscriptionEngine) {
        memoryMonitorTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.checkMemoryDuringTranscription(engine: engine)
            }
        }
    }

    private func stopMemoryMonitor() {
        memoryMonitorTimer?.invalidate()
        memoryMonitorTimer = nil
    }

    private func checkMemoryDuringTranscription(engine: TranscriptionEngine) {
        let check = EnvironmentChecker.checkAvailableMemory(engine: engine, currentTier: .low)
        if check.availableGB < 1.5 {
            if memoryWarning == nil {
                memoryWarning = String(format: "系统内存紧张（可用 %.1fGB），转写可能变慢或被终止。建议关闭其他应用释放内存。", check.availableGB)
                showMemoryWarning = true
                appendLog("[内存监控] 警告：可用内存低于 1.5GB")
            }
        }
    }

    // MARK: - 性能档位调整

    private func adjustProfileForTier(_ tier: PerformanceTier, base: PerformanceProfile, engine: TranscriptionEngine) -> PerformanceProfile {
        let threads: Int
        let batchSize: Int
        let mergeLength: Int

        switch tier {
        case .low:
            threads = max(1, min(2, base.threads - 1))
            batchSize = 60
            mergeLength = 10
        case .medium:
            threads = max(2, min(base.threads, 4))
            batchSize = 90
            mergeLength = 12
        case .high:
            threads = base.threads
            batchSize = base.batchSizeSeconds
            mergeLength = base.mergeLengthSeconds
        }

        return PerformanceProfile(
            device: base.device,
            threads: threads,
            batchSizeSeconds: batchSize,
            mergeLengthSeconds: mergeLength,
            speakerDiarizationEnabled: base.speakerDiarizationEnabled,
            mpsAvailable: base.mpsAvailable,
            summary: "已降档至\(tier.title)（\(threads)线程, batch \(batchSize)s）"
        )
    }

    // MARK: - ETA 定时刷新

    private func startETATimer() {
        etaTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.updateETA()
            }
        }
    }

    private func stopETATimer() {
        etaTimer?.invalidate()
        etaTimer = nil
        estimatedTimeRemaining = nil
    }

    // MARK: - 完成摘要

    private func buildCompletionSummary() {
        let elapsed = transcriptionStartTime.map { Date().timeIntervalSince($0) } ?? 0
        completionSummary = TranscriptionCompletionSummary(
            elapsedSeconds: elapsed,
            segmentCount: currentTranscriptSegments.count,
            speakerCount: speakerRoles.count,
            engine: currentEngine,
            modelID: currentModelID,
            audioDurationSeconds: audioDurationSeconds
        )
    }

    // MARK: - 错误建议

    private func appendErrorSuggestion(for exitCode: Int32) {
        switch exitCode {
        case 137, 9:
            appendLog("  可能原因：进程因内存不足被系统终止（OOM Kill）")
            appendLog("  建议：降低性能档位，或关闭其他占用内存的应用后重试")
        case 1:
            appendLog("  可能原因：Python 脚本执行出错（依赖缺失或模型加载失败）")
            appendLog("  建议：检查日志中的具体错误信息，确认依赖已正确安装")
        case 2:
            appendLog("  可能原因：命令行参数错误")
            appendLog("  建议：请重新预热环境，确认引擎和模型配置正确")
        default:
            appendLog("  建议：查看上方日志获取详细错误信息")
        }
    }

    func dismissMemoryWarning() {
        showMemoryWarning = false
    }

    private func initializeAudioPlayer() {
        guard let audioURL = currentAudioURL else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: audioURL)
            player.enableRate = true
            player.prepareToPlay()
            self.audioPlayer = player
            self.audioDuration = player.duration
            self.currentPlaybackTime = 0
            self.playbackSpeed = 1.0
            self.isAudioPlaying = false
        } catch {
            appendLog("音频播放器初始化失败: \(error.localizedDescription)")
        }
    }

    func toggleAudioPlayback() {
        if audioPlayer == nil && currentAudioURL != nil {
            initializeAudioPlayer()
        }
        guard let player = audioPlayer else { return }
        
        if player.isPlaying {
            player.pause()
            isAudioPlaying = false
            stopPlaybackTimer()
        } else {
            player.rate = Float(playbackSpeed)
            player.play()
            isAudioPlaying = true
            startPlaybackTimer()
        }
    }

    func seekAudio(to seconds: Double) {
        if audioPlayer == nil && currentAudioURL != nil {
            initializeAudioPlayer()
        }
        guard let player = audioPlayer else { return }
        let targetTime = max(0, min(seconds, player.duration))
        player.currentTime = targetTime
        currentPlaybackTime = targetTime
    }

    func setAudioPlaybackSpeed(_ speed: Double) {
        playbackSpeed = speed
        if let player = audioPlayer {
            player.rate = Float(speed)
        }
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if let player = self.audioPlayer {
                    self.currentPlaybackTime = player.currentTime
                    if !player.isPlaying && self.isAudioPlaying {
                        self.isAudioPlaying = false
                        self.stopPlaybackTimer()
                    }
                }
            }
        }
    }

    private func stopPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    // MARK: - Timeline Stage Processing & Proofreading Support

    func updateStageIndex(for stageStr: String) {
        if stageStr.contains("失败") || stageStr.contains("failed") {
            return
        }
        let isRemote = self.isRemoteTranscription
        if stageStr == "完成 ✓" || stageStr == "完成" {
            lastKnownStageIndex = isRemote ? 6 : 4
            return
        }
        
        let index: Int
        if isRemote {
            if stageStr.contains("检测远程") || stageStr.contains("上传") {
                index = 0
            } else if stageStr.contains("提交") || stageStr.contains("排队") {
                index = 1
            } else if stageStr.contains("准备") || stageStr.contains("预处理") {
                index = 2
            } else if stageStr.contains("加载") || stageStr.contains("Loading") {
                index = 3
            } else if stageStr.contains("转写中") || stageStr.contains("transcribing") {
                index = 4
            } else if stageStr.contains("解析") || stageStr.contains("Parsing") || stageStr.contains("保存") {
                index = 5
            } else if stageStr.contains("下载") {
                index = 6
            } else {
                index = lastKnownStageIndex
            }
        } else {
            if stageStr.contains("准备") || stageStr.contains("预处理") {
                index = 0
            } else if stageStr.contains("加载") || stageStr.contains("Loading") {
                index = 1
            } else if stageStr.contains("转写中") || stageStr.contains("transcribing") {
                index = 2
            } else if stageStr.contains("解析") || stageStr.contains("Parsing") {
                index = 3
            } else if stageStr.contains("保存") {
                index = 4
            } else {
                index = lastKnownStageIndex
            }
        }
        lastKnownStageIndex = index
    }

    var timelineStages: [TimelineStageItem] {
        let isRemote = self.isRemoteTranscription
        let currentIdx = self.lastKnownStageIndex
        let isFailed = self.currentProgress.contains("失败") || self.currentProgress.contains("failed")
        let isCompleted = self.currentProgress.contains("完成") || self.currentProgress.contains("completed") || self.progress >= 1.0
        
        let titles: [String]
        if isRemote {
            titles = [
                "音频上传到服务器",
                "提交并创建转译任务",
                "音频提取与预处理 (Mac mini)",
                "加载转写模型 (Mac mini)",
                "执行语音识别 (Mac mini)",
                "解析与说话人对齐 (Mac mini)",
                "下载并同步转写结果"
            ]
        } else {
            titles = [
                "音频提取与预处理",
                "加载转译模型",
                "执行语音识别 (Transcribing)",
                "解析与说话人对齐",
                "保存转译结果"
            ]
        }
        
        return titles.enumerated().map { (index, title) in
            let status: StageStatus
            if isCompleted {
                status = .completed
            } else if isFailed {
                if index < currentIdx {
                    status = .completed
                } else if index == currentIdx {
                    status = .failed
                } else {
                    status = .pending
                }
            } else {
                if index < currentIdx {
                    status = .completed
                } else if index == currentIdx {
                    status = .inProgress
                } else {
                    status = .pending
                }
            }
            return TimelineStageItem(title: title, status: status)
        }
    }

    func loadHistoryEntry(_ entry: TranscriptionHistoryEntry) {
        // Reset player
        isAudioPlaying = false
        currentPlaybackTime = 0
        audioDuration = 0
        if let player = audioPlayer {
            player.stop()
            audioPlayer = nil
        }
        playbackTimer?.invalidate()
        playbackTimer = nil
        
        let outDir = URL(fileURLWithPath: entry.outputDir)
        let baseName = entry.fileName
        
        currentTranscriptTitle = baseName
        currentOutputDir = outDir
        
        currentTranscriptURL = outDir.appendingPathComponent("\(baseName)_通话记录.md")
        currentSpeakerMapURL = outDir.appendingPathComponent("\(baseName)_speaker_map.json")
        currentSpeakerTextURL = outDir.appendingPathComponent("\(baseName)_整理版.md")
        
        // Try to locate audio file
        var foundAudioURL: URL? = nil
        if let path = entry.audioPath, FileManager.default.fileExists(atPath: path) {
            foundAudioURL = URL(fileURLWithPath: path)
        } else {
            let fm = FileManager.default
            let extensions = ["wav", "mp3", "m4a", "aac", "flac"]
            for ext in extensions {
                let potentialURL = outDir.appendingPathComponent("\(baseName).\(ext)")
                if fm.fileExists(atPath: potentialURL.path) {
                    foundAudioURL = potentialURL
                    break
                }
                let inputWavURL = outDir.appendingPathComponent("input.wav")
                if fm.fileExists(atPath: inputWavURL.path) {
                    foundAudioURL = inputWavURL
                    break
                }
            }
        }
        
        if let audioURL = foundAudioURL {
            currentAudioURL = audioURL
            initializeAudioPlayer()
        } else {
            currentAudioURL = nil
        }
        
        // Load speaker roles and segments
        loadSpeakerRolesIfNeeded()
        loadSummaryIfExists()
    }

    func updateSegmentText(index: Int, newText: String) {
        guard index >= 0 && index < currentTranscriptSegments.count else { return }
        let oldSeg = currentTranscriptSegments[index]
        let newSeg = TranscriptSegment(
            speakerKey: oldSeg.speakerKey,
            placeholder: oldSeg.placeholder,
            start: oldSeg.start,
            end: oldSeg.end,
            text: newText
        )
        currentTranscriptSegments[index] = newSeg
        saveTranscriptionChanges()
    }

    func saveTranscriptionChanges() {
        // 1. Save back to _speaker_map.json
        if let mapURL = currentSpeakerMapURL {
            let payload = SpeakerMapPayload(
                title: currentTranscriptTitle,
                roles: speakerRoles,
                segments: currentTranscriptSegments
            )
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: mapURL)
            }
        }
        
        // 2. Rebuild _整理版.md (uses display names)
        rebuildSpeakerText()
        
        // 3. Rebuild _通话记录.md (uses placeholders)
        rebuildTranscriptText()
    }

    private func rebuildTranscriptText() {
        guard let transcriptURL = currentTranscriptURL else { return }
        var lines: [String] = ["# \(currentTranscriptTitle) 通话记录\n"]
        for segment in currentTranscriptSegments {
            let start = timestamp(from: segment.start)
            lines.append("[\(start)] 【\(segment.placeholder)】 \(segment.text)")
        }
        try? lines.joined(separator: "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
    }
}

struct TranscriptionCompletionSummary {
    let elapsedSeconds: Double
    let segmentCount: Int
    let speakerCount: Int
    let engine: String
    let modelID: String
    let audioDurationSeconds: Double?

    var elapsedFormatted: String {
        let total = Int(elapsedSeconds)
        if total < 60 { return "\(total) 秒" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var audioDurationFormatted: String? {
        guard let dur = audioDurationSeconds else { return nil }
        let total = Int(dur)
        if total < 60 { return "\(total) 秒" }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var speedRatio: String? {
        guard let dur = audioDurationSeconds, dur > 0 else { return nil }
        let ratio = dur / elapsedSeconds
        return String(format: "%.1fx", ratio)
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

enum StageStatus: String, Codable {
    case pending
    case inProgress
    case completed
    case failed
}

struct TimelineStageItem: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let status: StageStatus
}
