import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var envChecker = EnvironmentChecker()
    @StateObject private var transcriber = Transcriber()
    @StateObject private var settingsManager = SettingsManager()

    @State private var selectedFileURL: URL?
    @State private var customOutputDir: String = ""
    @State private var isDragging = false
    @State private var showingFilePicker = false
    @State private var showingFolderPicker = false
    @State private var showingPythonPicker = false

    private var outputDir: URL? {
        customOutputDir.isEmpty ? nil : URL(fileURLWithPath: customOutputDir)
    }

    private var effectiveOutputDir: URL? {
        outputDir ?? selectedFileURL?.deletingLastPathComponent()
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 26))
                    .foregroundColor(Color(hex: "7C6FE3"))
                Text("AudioTranscriber")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    envChecker.customPythonPath = settingsManager.pythonPath
                    envChecker.check()
                }) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(Color(hex: "A0A0B0"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                VStack(spacing: 14) {
                    // 环境状态
                    StatusCard(envChecker: envChecker)

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
                            envChecker.initialize(cachedPythonPath: "")
                            envChecker.warmUp()
                        },
                        onClearPython: {
                            settingsManager.pythonPath = ""
                            envChecker.customPythonPath = ""
                            envChecker.initialize(cachedPythonPath: "")
                        }
                    )

                    // 按钮行
                    HStack(spacing: 12) {
                        Button(action: {
                            guard envChecker.hasChecked else {
                                envChecker.warmUp()
                                return
                            }
                            transcriber.startTranscription(
                                audioURL: selectedFileURL,
                                outputDir: effectiveOutputDir,
                                pythonPath: envChecker.pythonPath,
                                pythonSitePackages: envChecker.pythonSitePackages,
                                performanceProfile: envChecker.performanceProfile
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
                            transcriber.startSummarization(
                                audioURL: selectedFileURL,
                                outputDir: effectiveOutputDir,
                                model: settingsManager.selectedModel,
                                pythonPath: envChecker.pythonPath
                            )
                        }) {
                            HStack {
                                Image(systemName: "text.badge.plus")
                                Text("生成摘要")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(transcriber.isTranscribing || transcriber.isSummarizing || selectedFileURL == nil || !envChecker.hasChecked)

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
            }
        }
        .background(Color(hex: "1E1E2E"))
        .onAppear {
            envChecker.customPythonPath = settingsManager.pythonPath
            if settingsManager.pythonPath.isEmpty {
                settingsManager.pythonPath = envChecker.pythonPath
            }
            envChecker.initialize(cachedPythonPath: settingsManager.pythonPath)
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
        .onChange(of: envChecker.pythonPath) { newPath in
            if envChecker.hasChecked, !newPath.isEmpty, settingsManager.pythonPath != newPath {
                settingsManager.pythonPath = newPath
            }
        }
        .background(PythonExecutablePicker(isPresented: $showingPythonPicker) { url in
            if let url = url {
                settingsManager.pythonPath = url.path
                envChecker.customPythonPath = url.path
                envChecker.initialize(cachedPythonPath: url.path)
            }
        })
    }
}

private struct PythonExecutablePicker: NSViewRepresentable {
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
