import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AVFoundation

// 从 ContentView.swift 抽出的自包含 UI 组件（纯参数/绑定，无 ContentView 私有状态依赖）。

// MARK: - Core components definitions copies for completeness

enum SpeakerRoleActionFeedbackKind {
    case info
    case success
    case error
}

struct SpeakerRoleActionFeedback {
    let message: String
    let kind: SpeakerRoleActionFeedbackKind
}

struct SpeakerRolesCard: View {
    let roles: [SpeakerRole]
    let feedback: SpeakerRoleActionFeedback?
    let isApplying: Bool
    let enrollingRoleID: String?
    let enrolledRoleIDs: Set<String>
    var onChange: (String, String) -> Void
    var onApply: () -> Void
    var onEnroll: (SpeakerRole) -> Void
    var onAddRole: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundColor(Color(hex: "8E81F6"))
                Text("角色命名优化")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    onApply()
                }) {
                    HStack(spacing: 6) {
                        if isApplying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11))
                        }
                        Text(isApplying ? "应用中" : "应用到整理版")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplying)
            }

            Text("转写后会先生成角色A、角色B、角色C。你可以在这里改成真实姓名或身份，整理版文本和后续摘要都会优先使用这些名称。")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "A0A0B0"))

            ForEach(roles) { role in
                let isEnrolling = enrollingRoleID == role.id
                let isEnrolled = enrolledRoleIDs.contains(role.id)
                HStack(spacing: 10) {
                    Text(role.placeholder)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: "A0A0B0"))
                        .frame(width: 70, alignment: .leading)

                    TextField(role.placeholder, text: Binding(
                        get: { role.displayName },
                        set: { onChange(role.id, $0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color(hex: "12121A"))
                    .cornerRadius(6)

                    Button(action: { onEnroll(role) }) {
                        HStack(spacing: 4) {
                            if isEnrolling {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: isEnrolled ? "checkmark.circle.fill" : "waveform.badge.plus")
                                    .font(.system(size: 11))
                            }
                            Text(isEnrolling ? "加入中" : (isEnrolled ? "已加入" : "加入声纹库"))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(isEnrolled ? Color(hex: "8E81F6") : Color(hex: "4EC9B0"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background((isEnrolled ? Color(hex: "8E81F6") : Color(hex: "4EC9B0")).opacity(0.12))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(isEnrolling || enrollingRoleID != nil)
                }
            }

            if let onAddRole = onAddRole {
                Button(action: onAddRole) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11))
                        Text("添加新角色")
                    }
                    .foregroundColor(Color(hex: "8E81F6"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(hex: "8E81F6").opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            if let feedback {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: feedbackIcon(for: feedback.kind))
                        .font(.system(size: 11, weight: .semibold))
                    Text(feedback.message)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(feedbackColor(for: feedback.kind))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(feedbackColor(for: feedback.kind).opacity(0.12))
                .cornerRadius(8)
            }
        }
        .padding(16)
        .background(Color(hex: "1E1E2E"))
        .cornerRadius(12)
        .padding(.horizontal, 24)
    }

    private func feedbackIcon(for kind: SpeakerRoleActionFeedbackKind) -> String {
        switch kind {
        case .info: return "clock.arrow.circlepath"
        case .success: return "checkmark.seal.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func feedbackColor(for kind: SpeakerRoleActionFeedbackKind) -> Color {
        switch kind {
        case .info: return Color(hex: "8E81F6")
        case .success: return Color(hex: "4EC9B0")
        case .error: return Color(hex: "F14C4C")
        }
    }
}

struct VoiceprintLibraryPanel: View {
    @ObservedObject var store: VoiceprintStore
    let pythonPath: String
    let scriptsDir: URL
    @State private var captureSpeakerName = ""
    @State private var importSourceType: VoiceprintCaptureSourceType = .meeting
    @State private var selectedProfile: VoiceprintProfile? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .foregroundColor(Color(hex: "4EC9B0"))
                Text("本地声纹库")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    Task {
                        await store.checkDependencies(pythonPath: pythonPath, scriptsDir: scriptsDir)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checklist")
                        Text(store.isWorking ? "检查中" : "检查依赖")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(hex: "4EC9B0").opacity(0.18))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(store.isWorking)

                Button(action: {
                    NSWorkspace.shared.open(store.libraryDir)
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "A0A0B0"))
                        .padding(7)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            Text("声纹库会保存用户确认过的角色样本。依赖会安装到 VoiceScribe 独立 Python 环境，不写入系统 Python；模型缺失时只有点击安装才会下载。")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "A0A0B0"))

            Text(store.libraryDir.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(hex: "A0A0B0"))
                .lineLimit(1)
                .truncationMode(.middle)

            VoiceprintCaptureCard(
                speakerName: $captureSpeakerName,
                importSourceType: $importSourceType,
                isRecording: store.isRecording,
                isWorking: store.isWorking,
                microphonePermissionStatus: store.microphonePermissionStatus,
                requestMicrophonePermission: {
                    store.requestMicrophonePermission()
                },
                startRecording: {
                    store.startRecording(speakerName: captureSpeakerName)
                },
                stopRecording: {
                    Task {
                        await store.stopRecordingAndCollect(
                            speakerName: captureSpeakerName,
                            pythonPath: pythonPath,
                            scriptsDir: scriptsDir
                        )
                    }
                },
                importAudio: {
                    openVoiceprintImportPanel()
                }
            )

            if let report = store.dependencyReport {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: report.ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(report.ready ? Color(hex: "4EC9B0") : Color(hex: "F5A623"))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.ready ? "声纹模型依赖已就绪" : "声纹模型依赖缺失")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                            if !report.missing.isEmpty {
                                Text(report.missing.joined(separator: ", "))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Color(hex: "A0A0B0"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if !report.dependencies.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(report.dependencies) { dependency in
                                VoiceprintDependencyRow(
                                    dependency: dependency,
                                    isWorking: store.isWorking,
                                    installAction: {
                                        store.installDependency(dependency, pythonPath: pythonPath)
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color(hex: "12121A"))
                .cornerRadius(8)
            }

            if !store.message.isEmpty {
                Text(store.message)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
            }

            if store.profiles.isEmpty {
                Text("暂无声纹 profile。完成转写后，在角色命名卡中点击“加入声纹库”。")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "12121A"))
                    .cornerRadius(8)
            } else {
                ForEach(store.profiles) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: "person.wave.2.fill")
                            .foregroundColor(Color(hex: "4EC9B0"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                            Text("\(profile.sourceSummary) · \(profile.embeddingStatus == "ready" ? "特征已生成" : "等待特征提取")")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "A0A0B0"))
                        }
                        Spacer()
                        Text("\(profile.samples.count) 段")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(hex: "4EC9B0"))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: "4EC9B0").opacity(0.12))
                            .cornerRadius(4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(hex: "A0A0B0"))
                    }
                    .padding(10)
                    .background(Color(hex: "12121A"))
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedProfile = profile
                    }
                }
            }
        }
        .padding(18)
        .background(Color(hex: "1E1E2E").opacity(0.6))
        .cornerRadius(12)
        .sheet(item: $selectedProfile) { profile in
            VoiceprintProfileDetailView(profile: profile, store: store)
        }
    }

    private func openVoiceprintImportPanel() {
        let name = captureSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            store.message = "请先填写人物名称"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择要加入声纹库的录音"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie]
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await store.collectVoiceprintSample(
                    speakerName: name,
                    audioURL: url,
                    sourceType: importSourceType,
                    pythonPath: pythonPath,
                    scriptsDir: scriptsDir
                )
            }
        }
    }
}

struct VoiceprintCaptureCard: View {
    @Binding var speakerName: String
    @Binding var importSourceType: VoiceprintCaptureSourceType
    let isRecording: Bool
    let isWorking: Bool
    let microphonePermissionStatus: String
    let requestMicrophonePermission: () -> Void
    let startRecording: () -> Void
    let stopRecording: () -> Void
    let importAudio: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform.badge.plus")
                    .foregroundColor(Color(hex: "4EC9B0"))
                Text("声纹采集")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                if isRecording {
                    Label("录制中", systemImage: "record.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "FF5C5C"))
                }
            }

            TextField("人物名称，例如：张三", text: $speakerName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .padding(9)
                .background(Color(hex: "12121A"))
                .cornerRadius(7)

            HStack(spacing: 8) {
                Label("麦克风：\(microphonePermissionStatus)", systemImage: microphoneIconName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(microphoneStatusColor)
                Spacer()
                Button(action: requestMicrophonePermission) {
                    HStack(spacing: 4) {
                        Image(systemName: microphonePermissionStatus == "已授权" ? "checkmark.circle" : "lock.open")
                        Text(microphoneButtonTitle)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(microphoneButtonColor.opacity(0.18))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isWorking || isRecording || microphonePermissionStatus == "已授权")
            }
            .padding(8)
            .background(Color.white.opacity(0.04))
            .cornerRadius(7)

            HStack(spacing: 6) {
                ForEach(VoiceprintCaptureSourceType.allCases) { sourceType in
                    Button(action: { importSourceType = sourceType }) {
                        HStack(spacing: 4) {
                            Image(systemName: sourceType.iconName)
                            Text(sourceType.shortTitle)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(importSourceType == sourceType ? Color(hex: "4EC9B0") : Color(hex: "A0A0B0"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(importSourceType == sourceType ? Color(hex: "4EC9B0").opacity(0.12) : Color.white.opacity(0.04))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Button(action: isRecording ? stopRecording : startRecording) {
                    HStack(spacing: 5) {
                        Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        Text(isRecording ? "停止并保存" : "直接录制")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(isRecording ? Color(hex: "FF5C5C").opacity(0.25) : Color(hex: "4EC9B0").opacity(0.18))
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)

                Button(action: importAudio) {
                    HStack(spacing: 5) {
                        Image(systemName: "tray.and.arrow.down")
                        Text("导入录音")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(hex: "8E81F6").opacity(0.16))
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
                .disabled(isWorking || isRecording)
            }

            Text("直接录制会保存为近场样本；导入录音会按上面的来源标签保存到同一个人名下。")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "A0A0B0"))
        }
        .padding(10)
        .background(Color(hex: "12121A"))
        .cornerRadius(8)
    }

    private var microphoneButtonTitle: String {
        switch microphonePermissionStatus {
        case "已授权":
            return "已授权"
        case "已拒绝", "受限制":
            return "打开设置"
        default:
            return "授权麦克风"
        }
    }

    private var microphoneIconName: String {
        switch microphonePermissionStatus {
        case "已授权":
            return "mic.fill"
        case "已拒绝", "受限制":
            return "mic.slash.fill"
        default:
            return "mic"
        }
    }

    private var microphoneStatusColor: Color {
        switch microphonePermissionStatus {
        case "已授权":
            return Color(hex: "4EC9B0")
        case "已拒绝", "受限制":
            return Color(hex: "FF5C5C")
        default:
            return Color(hex: "F5A623")
        }
    }

    private var microphoneButtonColor: Color {
        microphonePermissionStatus == "已授权" ? Color(hex: "4EC9B0") : Color(hex: "8E81F6")
    }
}

struct VoiceprintDependencyRow: View {
    let dependency: VoiceprintDependency
    let isWorking: Bool
    let installAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: dependency.ready ? "checkmark.circle.fill" : iconName)
                .font(.system(size: 12))
                .foregroundColor(dependency.ready ? Color(hex: "4EC9B0") : Color(hex: "F5A623"))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(dependency.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if dependency.ready {
                Text("已安装")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "4EC9B0"))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color(hex: "4EC9B0").opacity(0.12))
                    .cornerRadius(5)
            } else {
                Button(action: installAction) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                        Text("安装")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(hex: "4EC9B0").opacity(0.18))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .help(dependency.installCommand)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .cornerRadius(7)
    }

    private var iconName: String {
        switch dependency.kind {
        case "model":
            return "cube.box"
        case "system_binary":
            return "terminal"
        default:
            return "shippingbox"
        }
    }

    private var statusText: String {
        if dependency.ready, let detectedPath = dependency.detectedPath, !detectedPath.isEmpty {
            return detectedPath
        }
        return dependency.ready ? "可用" : dependency.description
    }
}

struct CompletionSummaryCard: View {
    let summary: TranscriptionCompletionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(Color(hex: "4EC9B0"))
                Text("转写完成")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                if let speed = summary.speedRatio {
                    Text(speed)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "8E81F6"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: "8E81F6").opacity(0.15))
                        .cornerRadius(6)
                }
            }

            HStack(spacing: 16) {
                summaryChip(icon: "clock", label: "耗时", value: summary.elapsedFormatted)
                if let dur = summary.audioDurationFormatted {
                    summaryChip(icon: "waveform", label: "音频", value: dur)
                }
                if summary.segmentCount > 0 {
                    summaryChip(icon: "text.alignleft", label: "片段", value: "\(summary.segmentCount)")
                }
                if summary.speakerCount > 0 {
                    summaryChip(icon: "person.2", label: "说话人", value: "\(summary.speakerCount)")
                }
            }

            HStack(spacing: 6) {
                Text(summary.engine)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "8E81F6"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(hex: "8E81F6").opacity(0.12))
                    .cornerRadius(4)
                Text(summary.modelID)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "A0A0B0"))
            }
        }
        .padding(14)
        .background(Color(hex: "1E1E2E"))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "4EC9B0").opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
        .padding(.horizontal, 24)
    }

    private func summaryChip(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "8E81F6"))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(Color(hex: "A0A0B0"))
        }
        .frame(minWidth: 50)
        .padding(8)
        .background(Color(hex: "12121A"))
        .cornerRadius(8)
    }
}

struct PythonExecutablePicker: NSViewRepresentable {
    @Binding var isPresented: Bool
    var onSelect: (URL?) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard isPresented, !context.coordinator.isShowing else { return }
        context.coordinator.isShowing = true
        NSOpenPanel.openPythonExecutable { url in
            DispatchQueue.main.async {
                isPresented = false
                context.coordinator.isShowing = false
                onSelect(url)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var isShowing = false
    }
}

struct VoiceprintProfileDetailView: View {
    let profile: VoiceprintProfile
    @ObservedObject var store: VoiceprintStore
    @Environment(\.presentationMode) var presentationMode

    enum DeletionTarget: Identifiable {
        case profile
        case sample(VoiceprintSample)

        var id: String {
            switch self {
            case .profile:
                return "profile"
            case .sample(let sample):
                return "sample-\(sample.path)"
            }
        }
    }

    @State private var deletionTarget: DeletionTarget? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "person.crop.circle.badge.questionmark.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Color(hex: "4EC9B0"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text("声纹 ID: \(profile.id) · \(profile.embeddingStatus == "ready" ? "特征已生成" : "等待特征提取")")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "A0A0B0"))
                }
                Spacer()
                Button(action: {
                    store.stopPlayingSample()
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Color(hex: "A0A0B0"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(hex: "1E1E2E"))

            Divider()
                .background(Color.white.opacity(0.08))

            // Body ScrollView
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Profile Info Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("基本信息")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "8E81F6"))

                        VStack(alignment: .leading, spacing: 6) {
                            infoRow(label: "创建时间", value: formatDate(profile.createdAt))
                            infoRow(label: "更新时间", value: formatDate(profile.updatedAt))
                            if let model = profile.embeddingModel {
                                infoRow(label: "声纹模型", value: model)
                            }
                            if !profile.sourceAudio.isEmpty {
                                HStack(alignment: .top) {
                                    Text("来源音频")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "A0A0B0"))
                                        .frame(width: 70, alignment: .leading)
                                    Text(profile.sourceAudio)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.white)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    if FileManager.default.fileExists(atPath: profile.sourceAudio) {
                                        Button(action: {
                                            NSWorkspace.shared.selectFile(profile.sourceAudio, inFileViewerRootedAtPath: "")
                                        }) {
                                            Image(systemName: "arrow.right.circle.fill")
                                                .foregroundColor(Color(hex: "4EC9B0"))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(hex: "12121A"))
                        .cornerRadius(8)
                    }

                    // Samples List
                    VStack(alignment: .leading, spacing: 8) {
                        Text("声纹样本 (\(profile.samples.count)个)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "8E81F6"))

                        ForEach(Array(profile.samples.enumerated()), id: \.offset) { index, sample in
                            HStack(spacing: 12) {
                                // Play Button
                                Button(action: {
                                    store.playSample(path: sample.path)
                                }) {
                                    Image(systemName: store.playingSamplePath == sample.path ? "stop.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(store.playingSamplePath == sample.path ? Color(hex: "FF5C5C") : Color(hex: "4EC9B0"))
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(sample.sourceTitle ?? "转写片段")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(sourceBadgeColor(sample.sourceType).opacity(0.15))
                                            .cornerRadius(3)

                                        if let durationText = getSampleDurationText(path: sample.path) {
                                            Text(durationText)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(Color(hex: "4EC9B0"))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color(hex: "4EC9B0").opacity(0.12))
                                                .cornerRadius(3)
                                        }

                                        if let capturedAt = sample.capturedAt {
                                            Text(formatDate(capturedAt))
                                                .font(.system(size: 10))
                                                .foregroundColor(Color(hex: "A0A0B0"))
                                        }
                                    }

                                    Text(sample.path)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(Color(hex: "A0A0B0"))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                // Finder Button
                                if FileManager.default.fileExists(atPath: sample.path) {
                                    Button(action: {
                                        NSWorkspace.shared.selectFile(sample.path, inFileViewerRootedAtPath: "")
                                    }) {
                                        Image(systemName: "folder")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(hex: "A0A0B0"))
                                            .padding(5)
                                            .background(Color.white.opacity(0.05))
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                    .help("在 Finder 中显示样本")
                                }

                                // Delete Sample Button
                                Button(action: {
                                    deletionTarget = .sample(sample)
                                }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "FF5C5C").opacity(0.8))
                                        .padding(5)
                                        .background(Color(hex: "FF5C5C").opacity(0.1))
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                                .help("删除此样本")
                            }
                            .padding(8)
                            .background(Color(hex: "12121A"))
                            .cornerRadius(8)
                        }
                    }
                }
                .padding(20)
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Footer / Deletion Area
            HStack {
                Button(action: {
                    deletionTarget = .profile
                }) {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("删除声纹")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(hex: "FF5C5C").opacity(0.2))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(hex: "FF5C5C").opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                Button("关闭") {
                    store.stopPlayingSample()
                    presentationMode.wrappedValue.dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(hex: "1E1E2E"))
        }
        .frame(width: 550, height: 460)
        .background(Color(hex: "2A2A3C"))
        .alert(item: $deletionTarget) { target in
            switch target {
            case .profile:
                return Alert(
                    title: Text("确认删除整个人物声纹？"),
                    message: Text("此操作将永久删除人物「\(profile.displayName)」的声纹信息及所有关联的样本文件。"),
                    primaryButton: .destructive(Text("彻底删除")) {
                        store.deleteProfile(profile)
                        presentationMode.wrappedValue.dismiss()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .sample(let sample):
                return Alert(
                    title: Text("确认删除样本？"),
                    message: Text("此操作将永久从磁盘删除该声纹样本音频，且不可撤销。"),
                    primaryButton: .destructive(Text("删除")) {
                        store.deleteSample(sample, from: profile)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "A0A0B0"))
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.white)
        }
    }

    private func sourceBadgeColor(_ type: String?) -> Color {
        switch type {
        case "direct": return Color(hex: "4EC9B0")
        case "call": return Color(hex: "FFD35C")
        case "meeting": return Color(hex: "8E81F6")
        case "transcript": return Color(hex: "5CB3FF")
        default: return Color(hex: "A0A0B0")
        }
    }

    private func formatDate(_ isoString: String) -> String {
        let cleaner = isoString.replacingOccurrences(of: "Z", with: "")
        let parts = cleaner.components(separatedBy: "T")
        if parts.count == 2 {
            let datePart = parts[0]
            let timePart = parts[1].prefix(8)
            return "\(datePart) \(timePart)"
        }
        return isoString
    }

    private func getSampleDurationText(path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            return nil
        }
        return String(format: "%.1f秒", player.duration)
    }
}
