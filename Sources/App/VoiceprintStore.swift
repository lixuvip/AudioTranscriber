import AVFoundation
import AppKit
import Foundation

enum VoiceprintCaptureSourceType: String, CaseIterable, Identifiable, Codable {
    case direct
    case call
    case meeting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct:
            return "近场录制"
        case .call:
            return "电话录音"
        case .meeting:
            return "会议录音"
        }
    }

    var shortTitle: String {
        switch self {
        case .direct:
            return "近场"
        case .call:
            return "电话"
        case .meeting:
            return "会议"
        }
    }

    var iconName: String {
        switch self {
        case .direct:
            return "mic.fill"
        case .call:
            return "phone.fill"
        case .meeting:
            return "person.2.wave.2.fill"
        }
    }
}

struct VoiceprintSample: Codable, Identifiable, Equatable {
    var id: String { path }
    let path: String
    let sha256: String
    let sourceType: String?
    let sourceTitle: String?
    let capturedAt: String?
    let sourceAudio: String?
}

struct VoiceprintSampleGroup: Codable, Identifiable, Equatable {
    var id: String { sourceType }
    let sourceType: String
    let title: String
    let sampleCount: Int
    let matchWeight: Double?
    let lastUpdatedAt: String?
}

struct VoiceprintRequiredModel: Codable, Equatable {
    let id: String
    let purpose: String
}

struct VoiceprintProfile: Codable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let speakerKey: String
    let createdAt: String
    let updatedAt: String
    let sourceAudio: String
    let samples: [VoiceprintSample]
    let sampleGroups: [VoiceprintSampleGroup]?
    let embeddingModel: String?
    let embeddingStatus: String
    let requiredModel: VoiceprintRequiredModel?
    let selectedSegmentCount: Int?

    var sourceSummary: String {
        guard let sampleGroups, !sampleGroups.isEmpty else {
            return "\(samples.count) 个样本"
        }
        return sampleGroups
            .sorted { ($0.matchWeight ?? 0) > ($1.matchWeight ?? 0) }
            .map { "\($0.title) \($0.sampleCount)" }
            .joined(separator: " · ")
    }
}

struct VoiceprintDependencyReport: Codable, Equatable {
    let ready: Bool
    let missing: [String]
    let dependencies: [VoiceprintDependency]

    init(ready: Bool, missing: [String], dependencies: [VoiceprintDependency] = []) {
        self.ready = ready
        self.missing = missing
        self.dependencies = dependencies
    }
}

struct VoiceprintDependency: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let kind: String
    let ready: Bool
    let description: String
    let installCommand: String
    let detectedPath: String?
    let envOverride: String?
}

struct VoiceprintOperationResult: Equatable {
    let success: Bool
    let message: String
}

@MainActor
final class VoiceprintStore: ObservableObject {
    @Published var profiles: [VoiceprintProfile] = []
    @Published var dependencyReport: VoiceprintDependencyReport?
    @Published var isWorking = false
    @Published var isRecording = false
    @Published var message = ""
    @Published var microphonePermissionStatus = "未知"
    @Published var playingSamplePath: String? = nil

    private var samplePlayer: AVAudioPlayer?
    private var playbackTimer: Timer?

    let libraryDir: URL
    private var audioRecorder: AVAudioRecorder?
    private var recordingURL: URL?

    init(libraryDir: URL? = nil) {
        if let libraryDir {
            self.libraryDir = libraryDir
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.libraryDir = appSupport
                .appendingPathComponent("VoiceScribe", isDirectory: true)
                .appendingPathComponent("Voiceprints", isDirectory: true)
        }
        refreshMicrophonePermissionStatus()
        load()
    }

    func refreshMicrophonePermissionStatus() {
        microphonePermissionStatus = Self.microphonePermissionText(
            AVCaptureDevice.authorizationStatus(for: .audio)
        )
    }

    func load() {
        let root = libraryDir
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            profiles = []
            return
        }

        profiles = children.compactMap { dir in
            let profileURL = dir.appendingPathComponent("profile.json")
            guard let data = try? Data(contentsOf: profileURL),
                  let profile = try? JSONDecoder().decode(VoiceprintProfile.self, from: data) else {
                return nil
            }
            return profile
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    func checkDependencies(pythonPath: String, scriptsDir: URL) async {
        let resolvedPython = voiceprintPythonPath(fallback: pythonPath)
        guard !resolvedPython.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dependencyReport = VoiceprintDependencyReport(ready: false, missing: ["pythonPath"])
            message = "请先选择 Python 环境"
            return
        }

        isWorking = true
        defer { isWorking = false }

        let scriptURL = scriptsDir.appendingPathComponent("voiceprint.py")
        do {
            let output = try await runPython(
                pythonPath: resolvedPython,
                arguments: [scriptURL.path, "check", "--json"]
            )
            if let data = output.data(using: .utf8),
               let report = try? JSONDecoder().decode(VoiceprintDependencyReport.self, from: data) {
                dependencyReport = report
                message = report.ready ? "声纹模型依赖已就绪" : "声纹模型依赖未完整安装"
            } else {
                message = "无法解析声纹依赖检查结果"
            }
        } catch {
            message = "声纹依赖检查失败：\(error.localizedDescription)"
        }
    }

    func installDependency(_ dependency: VoiceprintDependency, pythonPath: String) {
        if dependency.ready {
            message = "\(dependency.title) 已安装"
            return
        }

        let command: String
        if dependency.installCommand.contains("${python}") {
            let basePython = pythonPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !basePython.isEmpty, FileManager.default.isExecutableFile(atPath: basePython) else {
                message = "请先选择有效的 Python 环境"
                return
            }
            let installCommand = dependency.installCommand.replacingOccurrences(
                of: "${python}",
                with: Self.shellQuote(Self.appManagedPythonPath)
            )
            command = Self.managedVenvBootstrapCommand(basePython: basePython) + " && " + installCommand
        } else {
            command = dependency.installCommand
        }

        openTerminal(command: command)
        message = "已打开 Terminal 安装 \(dependency.title)，完成后请重新点击检查依赖"
    }

    func requestMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphonePermissionStatus = Self.microphonePermissionText(status)

        switch status {
        case .authorized:
            message = "麦克风权限已授权"
        case .notDetermined:
            message = "正在请求麦克风权限..."
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.refreshMicrophonePermissionStatus()
                    self.message = granted ? "麦克风权限已授权" : "麦克风权限未授权，无法直接录制声纹"
                }
            }
        case .denied, .restricted:
            openMicrophonePrivacySettings()
            message = "已打开系统设置，请允许 VoiceScribe 使用麦克风"
        @unknown default:
            message = "当前系统无法确认麦克风权限，请在系统设置中检查"
        }
    }

    func openMicrophonePrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    func startRecording(speakerName: String) {
        let displayName = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            message = "请先填写人物名称"
            return
        }
        guard !isRecording else { return }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            refreshMicrophonePermissionStatus()
            beginRecording(speakerName: displayName)
        case .notDetermined:
            message = "正在请求麦克风权限..."
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    self.refreshMicrophonePermissionStatus()
                    if granted {
                        self.beginRecording(speakerName: displayName)
                    } else {
                        self.message = "麦克风权限未授权，无法直接录制声纹"
                    }
                }
            }
        default:
            refreshMicrophonePermissionStatus()
            message = "麦克风权限未授权，请在系统设置中允许 VoiceScribe 使用麦克风"
        }
    }

    func stopRecordingAndCollect(
        speakerName: String,
        pythonPath: String,
        scriptsDir: URL
    ) async {
        guard isRecording, let recordingURL else {
            message = "当前没有正在录制的声纹样本"
            return
        }
        audioRecorder?.stop()
        audioRecorder = nil
        self.recordingURL = nil
        isRecording = false

        await collectVoiceprintSample(
            speakerName: speakerName,
            audioURL: recordingURL,
            sourceType: .direct,
            pythonPath: pythonPath,
            scriptsDir: scriptsDir
        )
    }

    func collectVoiceprintSample(
        speakerName: String,
        audioURL: URL,
        sourceType: VoiceprintCaptureSourceType,
        pythonPath: String,
        scriptsDir: URL
    ) async {
        let displayName = speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            message = "请先填写人物名称"
            return
        }
        let resolvedPython = voiceprintPythonPath(fallback: pythonPath)
        guard !resolvedPython.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            message = "请先选择 Python 环境"
            return
        }

        isWorking = true
        defer { isWorking = false }

        let scriptURL = scriptsDir.appendingPathComponent("voiceprint.py")
        do {
            try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
            _ = try await runPython(
                pythonPath: resolvedPython,
                arguments: [
                    scriptURL.path,
                    "collect",
                    "--audio", audioURL.path,
                    "--speaker-name", displayName,
                    "--source-type", sourceType.rawValue,
                    "--library-dir", libraryDir.path,
                ]
            )
            load()
            message = "已保存 \(displayName) 的\(sourceType.title)声纹样本"
        } catch {
            message = "采集声纹失败：\(error.localizedDescription)"
        }
    }

    func enroll(
        role: SpeakerRole,
        audioURL: URL?,
        speakerMapURL: URL?,
        pythonPath: String,
        scriptsDir: URL
    ) async -> VoiceprintOperationResult {
        guard let audioURL, let speakerMapURL else {
            let result = VoiceprintOperationResult(success: false, message: "缺少音频或 speaker_map，无法加入声纹库")
            message = result.message
            return result
        }
        let resolvedPython = voiceprintPythonPath(fallback: pythonPath)
        guard !resolvedPython.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let result = VoiceprintOperationResult(success: false, message: "请先选择 Python 环境")
            message = result.message
            return result
        }

        let displayName = role.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakerName = displayName.isEmpty ? role.placeholder : displayName
        let scriptURL = scriptsDir.appendingPathComponent("voiceprint.py")

        isWorking = true
        defer { isWorking = false }

        do {
            try FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
            _ = try await runPython(
                pythonPath: resolvedPython,
                arguments: [
                    scriptURL.path,
                    "enroll",
                    "--audio", audioURL.path,
                    "--speaker-map", speakerMapURL.path,
                    "--speaker-key", role.key,
                    "--speaker-name", speakerName,
                    "--library-dir", libraryDir.path,
                ]
            )
            load()
            let result = VoiceprintOperationResult(success: true, message: "已将 \(speakerName) 的样本加入声纹库")
            message = result.message
            return result
        } catch {
            let result = VoiceprintOperationResult(success: false, message: "加入声纹库失败：\(error.localizedDescription)")
            message = result.message
            return result
        }
    }

    private func runPython(pythonPath: String, arguments: [String]) async throws -> String {
        let task = Task.detached(priority: .userInitiated) { () throws -> String in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let error = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 || process.terminationStatus == 2 else {
                throw VoiceprintStoreError(error.isEmpty ? output : error)
            }
            return output
        }
        return try await task.value
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static var appManagedVenvPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".voicescribe")
            .appendingPathComponent("venv")
            .path
    }

    private static var appManagedPythonPath: String {
        URL(fileURLWithPath: appManagedVenvPath)
            .appendingPathComponent("bin")
            .appendingPathComponent("python3")
            .path
    }

    private func voiceprintPythonPath(fallback: String) -> String {
        let managedPython = Self.appManagedPythonPath
        if FileManager.default.isExecutableFile(atPath: managedPython) {
            return managedPython
        }
        return fallback.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func managedVenvBootstrapCommand(basePython: String) -> String {
        let quotedBasePython = shellQuote(basePython)
        let quotedVenv = shellQuote(appManagedVenvPath)
        let quotedManagedPython = shellQuote(appManagedPythonPath)
        return "([ -x \(quotedManagedPython) ] || \(quotedBasePython) -m venv \(quotedVenv)) && \(quotedManagedPython) -m pip install -U pip setuptools wheel"
    }

    private func beginRecording(speakerName: String) {
        do {
            let recordingsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let captureDir = recordingsDir
                .appendingPathComponent("VoiceScribe", isDirectory: true)
                .appendingPathComponent("VoiceprintRecordings", isDirectory: true)
            try FileManager.default.createDirectory(at: captureDir, withIntermediateDirectories: true)
            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
                .replacingOccurrences(of: ".", with: "-")
            let fileURL = captureDir.appendingPathComponent("\(Self.fileSafeName(speakerName))-\(timestamp).m4a")
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
            recorder.prepareToRecord()
            recorder.record()
            audioRecorder = recorder
            recordingURL = fileURL
            isRecording = true
            message = "正在录制 \(speakerName) 的近场声纹"
        } catch {
            message = "开始录制失败：\(error.localizedDescription)"
        }
    }

    func playSample(path: String) {
        if playingSamplePath == path {
            stopPlayingSample()
            return
        }

        stopPlayingSample()

        do {
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            player.prepareToPlay()
            player.play()
            self.samplePlayer = player
            self.playingSamplePath = path

            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if let player = self.samplePlayer, !player.isPlaying {
                    self.stopPlayingSample()
                }
            }
        } catch {
            message = "无法播放该声纹样本: \(error.localizedDescription)"
        }
    }

    func stopPlayingSample() {
        samplePlayer?.stop()
        samplePlayer = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        playingSamplePath = nil
    }

    func deleteProfile(_ profile: VoiceprintProfile) {
        stopPlayingSample()
        let profileDir = libraryDir.appendingPathComponent(profile.id)
        try? FileManager.default.removeItem(at: profileDir)
        load()
        message = "已删除声纹：\(profile.displayName)"
    }

    func deleteSample(_ sample: VoiceprintSample, from profile: VoiceprintProfile) {
        stopPlayingSample()
        let sampleURL = URL(fileURLWithPath: sample.path)
        try? FileManager.default.removeItem(at: sampleURL)

        let updatedSamples = profile.samples.filter { $0.path != sample.path }

        if updatedSamples.isEmpty {
            deleteProfile(profile)
            return
        }

        var groupsDict: [String: VoiceprintSampleGroup] = [:]
        for s in updatedSamples {
            let type = s.sourceType ?? "transcript"
            let title = s.sourceTitle ?? "转写片段"
            let currentCount = groupsDict[type]?.sampleCount ?? 0

            let weight: Double
            switch type {
            case "direct": weight = 1.0
            case "call": weight = 0.72
            case "meeting": weight = 0.78
            case "transcript": weight = 0.86
            default: weight = 0.86
            }

            groupsDict[type] = VoiceprintSampleGroup(
                sourceType: type,
                title: title,
                sampleCount: currentCount + 1,
                matchWeight: weight,
                lastUpdatedAt: s.capturedAt ?? ISO8601DateFormatter().string(from: Date())
            )
        }
        let newGroups = Array(groupsDict.values).sorted { $0.sourceType < $1.sourceType }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let nowStr = isoFormatter.string(from: Date())

        let updatedProfile = VoiceprintProfile(
            id: profile.id,
            displayName: profile.displayName,
            speakerKey: profile.speakerKey,
            createdAt: profile.createdAt,
            updatedAt: nowStr,
            sourceAudio: profile.sourceAudio,
            samples: updatedSamples,
            sampleGroups: newGroups,
            embeddingModel: profile.embeddingModel,
            embeddingStatus: profile.embeddingStatus,
            requiredModel: profile.requiredModel,
            selectedSegmentCount: updatedSamples.count
        )

        let profileURL = libraryDir.appendingPathComponent(profile.id).appendingPathComponent("profile.json")
        if let data = try? JSONEncoder().encode(updatedProfile) {
            try? data.write(to: profileURL)
        }

        load()
        message = "已删除声纹样本"
    }

    private func openTerminal(command: String) {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escapedCommand)"
        end tell
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        try? task.run()
    }

    private static func fileSafeName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let parts = value.components(separatedBy: invalid)
        let cleaned = parts.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "voiceprint" : cleaned
    }

    private static func microphonePermissionText(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "已授权"
        case .notDetermined:
            return "未请求"
        case .denied:
            return "已拒绝"
        case .restricted:
            return "受限制"
        @unknown default:
            return "未知"
        }
    }
}

private struct VoiceprintStoreError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "声纹脚本执行失败" : message
    }
}
