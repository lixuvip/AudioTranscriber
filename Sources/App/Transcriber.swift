import Foundation
import Combine

@MainActor
class Transcriber: ObservableObject {
    @Published var isTranscribing = false
    @Published var isSummarizing = false
    @Published var logs: [String] = []
    @Published var progress: Double = 0
    @Published var currentProgress: String = ""

    private var currentTask: Process?

    var bundleScriptsDir: URL {
        if Bundle.main.resourceURL != nil {
            return Bundle.main.resourceURL!
        }
        return URL(fileURLWithPath: "../../../Scripts") // fallback only for dev, not used in built app
    }

    func startTranscription(audioURL: URL?, outputDir: URL?, pythonPath: String, pythonSitePackages: String = "", performanceProfile: PerformanceProfile = .automatic) {
        guard let audioURL = audioURL else { return }
        let outDir = outputDir ?? audioURL.deletingLastPathComponent()

        isTranscribing = true
        isSummarizing = false
        logs = []
        progress = 0
        currentProgress = "准备中..."

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
            "--device", performanceProfile.device,
            "--threads", "\(performanceProfile.threads)",
            "--batch-size-s", "\(performanceProfile.batchSizeSeconds)",
            "--merge-length-s", "\(performanceProfile.mergeLengthSeconds)",
            "--speaker-diarization", performanceProfile.speakerDiarizationEnabled ? "1" : "0"
        ]
        process.environment = env

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
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
            try process.launch()
        } catch {
            appendLog("启动失败: \(error.localizedDescription)")
            isTranscribing = false
        }
    }

    func stopTranscription() {
        currentTask?.terminate()
        currentTask = nil
        isTranscribing = false
        appendLog("已停止转写")
    }

    func startSummarization(audioURL: URL?, outputDir: URL?, model: String, pythonPath: String) {
        guard let audioURL = audioURL else { return }
        let outDir = outputDir ?? audioURL.deletingLastPathComponent()
        let baseName = audioURL.deletingPathExtension().lastPathComponent
        let mdPath = outDir.appendingPathComponent("\(baseName)_通话记录.md")

        isSummarizing = true
        isTranscribing = false
        logs = []
        progress = 0
        currentProgress = "生成摘要..."

        let scriptPath = bundleScriptsDir.appendingPathComponent("summarize.py").path

        let cmd = """
        export OPENAI_API_KEY="${OPENAI_API_KEY:-}"
        export OPENAI_API_BASE="${OPENAI_API_BASE:-https://api.openai.com/v1}"
        \(pythonPath) \(scriptPath) "\(mdPath.path)" "\(model)" 2>&1
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", cmd]
        currentTask = process

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.handleOutput(text) }
        }

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.handleTermination(status: proc.terminationStatus) }
        }

        do {
            try process.launch()
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
        if status == 0 {
            progress = 1.0
            currentProgress = "完成 ✓"
            appendLog("✓ 完成")
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
}
