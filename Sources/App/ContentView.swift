import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var envChecker = EnvironmentChecker()
    @StateObject private var transcriber = Transcriber()
    @StateObject private var settingsManager = SettingsManager()
    @StateObject private var historyManager = HistoryManager()

    @State private var selectedFileURL: URL?
    @State private var customOutputDir: String = ""
    @State private var isDragging = false
    @State private var showingFilePicker = false
    @State private var showingFolderPicker = false
    @State private var showingPythonPicker = false
    @State private var showSetup = true
    @State private var activeTab: MainTab = .transcribe

    private var outputDir: URL? {
        customOutputDir.isEmpty ? nil : URL(fileURLWithPath: customOutputDir)
    }

    private var effectiveOutputDir: URL? {
        outputDir ?? selectedFileURL?.deletingLastPathComponent()
    }

    enum MainTab {
        case transcribe
        case history
    }

    var body: some View {
        Group {
            if showSetup {
                SetupView(
                    envChecker: envChecker,
                    settingsManager: settingsManager,
                    onComplete: { showSetup = false },
                    onSkip: { showSetup = false }
                )
                .transition(.opacity)
            } else {
                mainContent
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showSetup)
        .background(Color(hex: "1E1E2E"))
        .onAppear {
            envChecker.customPythonPath = settingsManager.pythonPath
            envChecker.updateRuntimeSelection(
                environment: settingsManager.runtimeEnvironment,
                engine: settingsManager.transcriptionEngine,
                modelID: settingsManager.transcriptionModelID
            )
            envChecker.initialize(cachedPythonPath: settingsManager.pythonPath)
            if let savedTier = PerformanceTier.allCases.first(where: { $0.rawValue == settingsManager.performanceTier }) {
                envChecker.savedPerformanceTier = savedTier
            }
        }
    }

    // MARK: - 主页面

    private var mainContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(Color(hex: "7C6FE3"))
                Text("VoiceScribe")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)

                // 环境状态小图标
                if envChecker.hasChecked {
                    Image(systemName: envChecker.allReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(envChecker.allReady ? Color(hex: "4EC9B0") : Color(hex: "F5A623"))
                }

                Spacer()

                // 回到设置
                Button(action: { showSetup = true }) {
                    HStack(spacing: 4) {
                        Image(systemName: "gear")
                            .font(.system(size: 12))
                        Text("设置")
                            .font(.system(size: 12))
                    }
                    .foregroundColor(Color(hex: "A0A0B0"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 10)

            // 标签栏
            HStack(spacing: 0) {
                tabButton(title: "转写", icon: "waveform", tab: .transcribe)
                tabButton(title: "历史", icon: "clock.arrow.circlepath", tab: .history)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)

            ScrollView {
                if activeTab == .history {
                    HistoryView(historyManager: historyManager)
                        .padding(.horizontal, 24)
                        .padding(.top, 4)
                } else {
                VStack(spacing: 14) {
                    // 文件拖拽
                    FileDropZone(
                        selectedFileURL: $selectedFileURL,
                        isDragging: $isDragging,
                        onSelect: { showingFilePicker = true }
                    )

                    // 设置面板
                    SettingsPanel(
                        outputDir: $customOutputDir,
                        settingsManager: settingsManager,
                        onBrowseOutput: { showingFolderPicker = true },
                        onPickPython: { showingPythonPicker = true },
                        onAutoDetectPython: {
                            settingsManager.pythonPath = ""
                            envChecker.customPythonPath = ""
                            envChecker.updateRuntimeSelection(
                                environment: settingsManager.runtimeEnvironment,
                                engine: settingsManager.transcriptionEngine,
                                modelID: settingsManager.transcriptionModelID
                            )
                            envChecker.initialize(cachedPythonPath: "")
                            envChecker.warmUp()
                        },
                        onClearPython: {
                            settingsManager.pythonPath = ""
                            envChecker.customPythonPath = ""
                            envChecker.updateRuntimeSelection(
                                environment: settingsManager.runtimeEnvironment,
                                engine: settingsManager.transcriptionEngine,
                                modelID: settingsManager.transcriptionModelID
                            )
                            envChecker.initialize(cachedPythonPath: "")
                        }
                    )

                    // 按钮行
                    HStack(spacing: 12) {
                        Button(action: {
                            guard envChecker.hasChecked else {
                                showSetup = true
                                return
                            }
                            transcriber.startTranscription(
                                audioURL: selectedFileURL,
                                outputDir: effectiveOutputDir,
                                pythonPath: envChecker.pythonPath,
                                pythonSitePackages: envChecker.pythonSitePackages,
                                performanceProfile: envChecker.performanceProfile,
                                engine: settingsManager.transcriptionEngine,
                                modelID: settingsManager.transcriptionModelID
                            )
                        }) {
                            HStack {
                                Image(systemName: "play.fill")
                                Text(envChecker.hasChecked ? "开始转写" : "先预热环境")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(transcriber.isTranscribing || transcriber.isSummarizing || selectedFileURL == nil || envChecker.isChecking || (envChecker.hasChecked && !envChecker.allReady))

                        Button(action: {
                            guard let model = settingsManager.customModels.first(where: { $0.id == settingsManager.selectedModel }) else { return }
                            transcriber.startSummarization(
                                audioURL: selectedFileURL,
                                outputDir: effectiveOutputDir,
                                model: model,
                                pythonPath: envChecker.pythonPath,
                                summaryPrompt: settingsManager.summaryPrompt
                            )
                        }) {
                            HStack {
                                Image(systemName: "text.badge.plus")
                                Text("生成摘要")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(transcriber.isTranscribing || transcriber.isSummarizing || selectedFileURL == nil || !envChecker.hasChecked || settingsManager.selectedModel.isEmpty)

                        Button(action: {
                            transcriber.stopCurrentTask()
                        }) {
                            HStack {
                                Image(systemName: "stop.fill")
                                Text("停止转写")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(DangerButtonStyle())
                        .disabled(!transcriber.isTranscribing)
                    }
                    .padding(.horizontal, 24)

                    // 进度
                    if transcriber.isTranscribing || transcriber.isSummarizing {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(transcriber.isTranscribing ? "转写中..." : "生成摘要...")
                                    .font(.system(size: 12))
                                    .foregroundColor(Color(hex: "A0A0B0"))
                                Spacer()
                                Text(transcriber.currentProgress)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(Color(hex: "4EC9B0"))
                            }
                            ProgressView(value: transcriber.progress)
                                .progressViewStyle(LinearProgressViewStyle(tint: Color(hex: "7C6FE3")))
                        }
                        .padding(.horizontal, 24)
                    }

                    if transcriber.speakerRolesReady {
                        SpeakerRolesCard(
                            roles: transcriber.speakerRoles,
                            onChange: { roleID, newName in
                                transcriber.updateSpeakerRole(id: roleID, displayName: newName)
                            },
                            onApply: {
                                transcriber.applySpeakerNames()
                            }
                        )
                    }

                    // 日志
                    LogView(logs: transcriber.logs)
                        .frame(minHeight: 150)

                    // 打开目录
                    HStack {
                        Spacer()
                        Button(action: {
                            if let url = effectiveOutputDir {
                                NSWorkspace.shared.open(url)
                            }
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                Text("打开输出目录")
                            }
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "A0A0B0"))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 24)
                    }
                }
                .padding(.bottom, 16)
                } // else (transcribe tab)
            }
        }
        .onChange(of: transcriber.pendingHistoryEntry) { entry in
            if let entry = entry {
                historyManager.add(entry)
                transcriber.pendingHistoryEntry = nil
            }
        }
        .onChange(of: envChecker.selectedPerformanceTier) { tier in
            settingsManager.performanceTier = tier.rawValue
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.audio, .movie, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result {
                selectedFileURL = urls.first
            }
        }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPickerSheet(isPresented: $showingFolderPicker) { url in
                if let url = url {
                    customOutputDir = url.path
                }
            }
        }
        .onChange(of: settingsManager.pythonPath) { newPath in
            envChecker.customPythonPath = newPath
        }
        .onChange(of: settingsManager.runtimeEnvironment) { _ in
            envChecker.updateRuntimeSelection(
                environment: settingsManager.runtimeEnvironment,
                engine: settingsManager.transcriptionEngine,
                modelID: settingsManager.transcriptionModelID
            )
            envChecker.initialize(cachedPythonPath: settingsManager.pythonPath)
        }
        .onChange(of: settingsManager.transcriptionEngine) { _ in
            envChecker.updateRuntimeSelection(
                environment: settingsManager.runtimeEnvironment,
                engine: settingsManager.transcriptionEngine,
                modelID: settingsManager.transcriptionModelID
            )
            envChecker.initialize(cachedPythonPath: settingsManager.pythonPath)
        }
        .onChange(of: settingsManager.transcriptionModelID) { _ in
            envChecker.updateRuntimeSelection(
                environment: settingsManager.runtimeEnvironment,
                engine: settingsManager.transcriptionEngine,
                modelID: settingsManager.transcriptionModelID
            )
        }
        .onChange(of: envChecker.pythonPath) { newPath in
            if envChecker.hasChecked, !newPath.isEmpty, settingsManager.pythonPath != newPath {
                settingsManager.pythonPath = newPath
            }
        }
        .background(PythonExecutablePicker(isPresented: $showingPythonPicker) { url in
            if let url = url {
                settingsManager.pythonPath = url.path
                envChecker.customPythonPath = url.path
                envChecker.updateRuntimeSelection(
                    environment: settingsManager.runtimeEnvironment,
                    engine: settingsManager.transcriptionEngine,
                    modelID: settingsManager.transcriptionModelID
                )
                envChecker.initialize(cachedPythonPath: url.path)
            }
        })
    }

    // MARK: - 标签按钮

    private func tabButton(title: String, icon: String, tab: MainTab) -> some View {
        let isActive = activeTab == tab
        return Button(action: { activeTab = tab }) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(title)
                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
            }
            .foregroundColor(isActive ? Color(hex: "7C6FE3") : Color(hex: "5A5A6C"))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(isActive ? Color(hex: "7C6FE3").opacity(0.12) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
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

private struct SpeakerRolesCard: View {
    let roles: [SpeakerRole]
    var onChange: (String, String) -> Void
    var onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundColor(Color(hex: "7C6FE3"))
                Text("角色命名优化")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button("应用到整理版") {
                    onApply()
                }
                .buttonStyle(.borderedProminent)
            }

            Text("转写后会先生成角色A、角色B、角色C。你可以在这里改成真实姓名或身份，整理版文本和后续摘要都会优先使用这些名称。")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "A0A0B0"))

            ForEach(roles) { role in
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
                    .background(Color(hex: "1E1E2E"))
                    .cornerRadius(6)
                }
            }
        }
        .padding(16)
        .background(Color(hex: "2A2A3C"))
        .cornerRadius(12)
        .padding(.horizontal, 24)
    }
}
