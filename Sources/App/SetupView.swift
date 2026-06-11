import SwiftUI
import AppKit

struct SetupView: View {
    @ObservedObject var envChecker: EnvironmentChecker
    @ObservedObject var settingsManager: SettingsManager
    var onComplete: () -> Void
    var onSkip: () -> Void

    @State private var showingPythonPicker = false
    @State private var autoWarmedUp = false

    private func triggerAutoWarmup() {
        guard !autoWarmedUp, !envChecker.isChecking else { return }
        autoWarmedUp = true
        envChecker.updateRuntimeSelection(
            environment: settingsManager.runtimeEnvironment,
            engine: settingsManager.transcriptionEngine,
            modelID: settingsManager.transcriptionModelID
        )
        envChecker.customPythonPath = settingsManager.pythonPath
        envChecker.warmUp()
    }


    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 40)

                // 标题区
                VStack(spacing: 8) {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 48))
                        .foregroundColor(Color(hex: "7C6FE3"))
                        .padding(.bottom, 4)
                    Text("VoiceScribe")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                    Text("本地离线音频转写 · 支持说话人识别")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "A0A0B0"))
                }
                .padding(.bottom, 28)

                // 设备信息卡片
                DeviceInfoCard()
                    .padding(.horizontal, 40)
                    .padding(.bottom, 12)

                // 主设置卡片
                VStack(spacing: 16) {
                    // 引擎选择
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(icon: "cpu", title: "转写引擎")

                        HStack(spacing: 10) {
                            ForEach(TranscriptionEngine.available(for: settingsManager.runtimeEnvironment)) { engine in
                                engineCard(engine: engine)
                            }
                        }

                        engineRecommendation
                    }

                    Divider().background(Color(hex: "3A3A4C"))

                    // 预热区
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            sectionHeader(icon: "flame.fill", title: "环境预热")
                            Spacer()
                            warmUpButton
                        }

                        // 依赖状态
                        if !envChecker.deps.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(envChecker.deps) { dep in
                                    depBadge(dep: dep)
                                }
                            }
                        }

                        if !envChecker.checkProgress.isEmpty {
                            Text(envChecker.checkProgress)
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "A0A0B0"))
                                .lineLimit(2)
                        }

                        // 性能档位
                        if envChecker.hasChecked {
                            PerformanceTierPicker(
                                recommendedTier: envChecker.recommendedPerformanceTier,
                                selectedTier: envChecker.selectedPerformanceTier,
                                onSelect: { envChecker.applyPerformanceTier($0) }
                            )
                        }

                        // 安装提示
                        if envChecker.hasChecked && hasMissingDeps {
                            missingDepsSection
                        }
                    }
                }
                .padding(20)
                .background(Color(hex: "2A2A3C"))
                .cornerRadius(14)
                .padding(.horizontal, 40)

                // 底部按钮
                HStack(spacing: 14) {
                    if !envChecker.hasChecked {
                        Button(action: onSkip) {
                            Text("跳过检测，直接使用")
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "A0A0B0"))
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    if envChecker.isChecking {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.7)
                                .frame(width: 16, height: 16)
                            Text("正在自动检测环境...")
                                .font(.system(size: 13))
                                .foregroundColor(Color(hex: "A0A0B0"))
                        }
                    } else if envChecker.hasChecked && envChecker.allReady {
                        Button(action: onComplete) {
                            HStack(spacing: 6) {
                                Image(systemName: "play.circle.fill")
                                Text("开启 VoiceScribe")
                            }
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color(hex: "8E81F6"))
                            .cornerRadius(10)
                            .shadow(color: Color(hex: "8E81F6").opacity(0.3), radius: 6)
                        }
                        .buttonStyle(.plain)
                    } else if envChecker.hasChecked {
                        Button(action: onComplete) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.right.circle.fill")
                                Text("忽略警告，开始使用")
                            }
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color(hex: "7C6FE3"))
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 20)

                Spacer().frame(height: 40)
            }
        }
        .frame(minWidth: 520, minHeight: 500)
        .background(Color(hex: "1E1E2E"))
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
        .onChange(of: envChecker.pythonPath) { newPath in
            if envChecker.hasChecked, !newPath.isEmpty, settingsManager.pythonPath != newPath {
                settingsManager.pythonPath = newPath
            }
        }
        .onChange(of: envChecker.selectedPerformanceTier) { tier in
            settingsManager.performanceTier = tier.rawValue
        }

        .onAppear {
            triggerAutoWarmup()
        }
    }

    // MARK: - 子视图

    private var engineRecommendation: some View {
        Group {
            if settingsManager.runtimeEnvironment == .macAppleSilicon {
                HStack(spacing: 6) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "F5A623"))
                    Text("Apple Silicon Mac 推荐使用 Qwen3-ASR 或 VibeVoice MLX 引擎，MLX 原生加速")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "A0A0B0"))
                }
                .padding(8)
                .background(Color(hex: "1E1E2E"))
                .cornerRadius(6)
            }
        }
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "7C6FE3"))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
        }
    }

    private func engineCard(engine: TranscriptionEngine) -> some View {
        let isSelected = settingsManager.transcriptionEngine == engine
        return Button(action: {
            settingsManager.updateTranscriptionEngine(engine)
            envChecker.updateRuntimeSelection(
                environment: settingsManager.runtimeEnvironment,
                engine: engine,
                modelID: settingsManager.transcriptionModelID
            )
            envChecker.initialize(cachedPythonPath: settingsManager.pythonPath)
        }) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 14))
                        .foregroundColor(isSelected ? Color(hex: "7C6FE3") : Color(hex: "5A5A6C"))
                    Text(engine.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                }
                Text(engine.description)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(isSelected ? Color(hex: "33334D") : Color(hex: "1E1E2E"))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color(hex: "7C6FE3") : Color(hex: "3A3A4C"), lineWidth: 1)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private var warmUpButton: some View {
        Button(action: {
            envChecker.updateRuntimeSelection(
                environment: settingsManager.runtimeEnvironment,
                engine: settingsManager.transcriptionEngine,
                modelID: settingsManager.transcriptionModelID
            )
            envChecker.customPythonPath = settingsManager.pythonPath
            envChecker.warmUp()
        }) {
            HStack(spacing: 5) {
                if envChecker.isChecking {
                    ProgressView()
                        .scaleEffect(0.55)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: envChecker.hasChecked ? "arrow.clockwise" : "bolt.fill")
                        .font(.system(size: 11))
                }
                Text(envChecker.isChecking ? "检测中..." : (envChecker.hasChecked ? "重新检测" : "检测"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(hex: "7C6FE3"))
            .cornerRadius(7)
        }
        .buttonStyle(.plain)
        .disabled(envChecker.isChecking)
    }

    private func depBadge(dep: DependencyStatus) -> some View {
        HStack(spacing: 4) {
            Image(systemName: dep.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(dep.isReady ? Color(hex: "4EC9B0") : Color(hex: "F5A623"))
            Text(dep.name)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(dep.isReady ? Color(hex: "4EC9B0") : Color(hex: "F5A623"))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(hex: "1E1E2E"))
        .cornerRadius(6)
    }

    private var hasMissingDeps: Bool {
        envChecker.deps.contains { !$0.isReady }
    }

    private var missingDepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("缺少以下依赖，可按步骤安装：")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "A0A0B0"))

            if envChecker.isInstallingDependency {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                    Text(envChecker.installMessage)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "A0A0B0"))
                }
            }

            // Keep log visible after install completes so user can review
            if !envChecker.installLog.isEmpty {
                ScrollView {
                    Text(envChecker.installLog)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "4EC9B0"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .padding(8)
                .background(Color(hex: "0D0D15"))
                .cornerRadius(6)
                HStack {
                    Spacer()
                    Button("清除日志") {
                        envChecker.installLog = ""
                        envChecker.installMessage = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if !envChecker.isInstallingDependency {
                HStack(spacing: 8) {
                    if isMissingFFmpeg {
                        Button("安装 ffmpeg") { envChecker.installFFmpeg() }
                            .buttonStyle(.borderedProminent)
                    }
                    if isMissingPythonDeps {
                        Button("安装依赖") { envChecker.installPythonDependencies() }
                            .buttonStyle(.borderedProminent)
                    }
                    if isMissingModels {
                        Button("下载模型") { envChecker.installModels() }
                            .buttonStyle(.bordered)
                            .disabled(!canDownloadModelYet)
                    }
                    Button("重新检测") {
                        envChecker.installLog = ""
                        envChecker.installMessage = ""
                        envChecker.refreshAfterExternalInstall()
                    }
                    .buttonStyle(.bordered)
                    .disabled(envChecker.isChecking)
                }
            }

            if !envChecker.installMessage.isEmpty && envChecker.installLog.isEmpty {
                Text(envChecker.installMessage)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(Color(hex: "1E1E2E"))
        .cornerRadius(8)
    }

    private var isMissingFFmpeg: Bool {
        envChecker.deps.contains { $0.name == "ffmpeg" && !$0.isReady }
    }

    private var isMissingPythonDeps: Bool {
        envChecker.deps.contains { dep in !dep.isReady && ["funasr", "mlx-audio", "mlx-qwen3-asr"].contains(dep.name) }
    }

    private var isMissingModels: Bool {
        envChecker.deps.contains { dep in !dep.isReady && ["models", "mlx-model", "qwen3-model"].contains(dep.name) }
    }

    private var canDownloadModelYet: Bool {
        let engine = envChecker.runtimeSelection.engine
        if engine == .funASR { return true }
        return !isMissingPythonDeps
    }
}

// MARK: - 设备信息卡片

private struct DeviceInfoCard: View {
    @State private var chipName: String = ""
    @State private var memoryGB: Int = 0
    @State private var coreCount: Int = 0

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 20))
                .foregroundColor(Color(hex: "7C6FE3"))

            VStack(alignment: .leading, spacing: 3) {
                Text("当前设备")
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "5A5A6C"))
                Text(chipName.isEmpty ? "检测中..." : chipName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text("\(memoryGB)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("GB 内存")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "A0A0B0"))
                }
                VStack(spacing: 2) {
                    Text("\(coreCount)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                    Text("核心")
                        .font(.system(size: 9))
                        .foregroundColor(Color(hex: "A0A0B0"))
                }
            }
        }
        .padding(14)
        .background(Color(hex: "2A2A3C"))
        .cornerRadius(10)
        .onAppear { detectHardware() }
    }

    private func detectHardware() {
        Task.detached {
            let chip = Self.shellOutput("sysctl -n machdep.cpu.brand_string 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let memBytes = Int64(Self.shellOutput("sysctl -n hw.memsize 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? Int64(ProcessInfo.processInfo.physicalMemory)
            let cores = Int(Self.shellOutput("sysctl -n hw.ncpu 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ProcessInfo.processInfo.processorCount

            await MainActor.run {
                chipName = chip.isEmpty ? "Unknown" : chip
                memoryGB = max(1, Int(memBytes / 1_073_741_824))
                coreCount = cores
            }
        }
    }

    private static func shellOutput(_ command: String) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", command]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}
