import SwiftUI
import AppKit

struct SetupView: View {
    @ObservedObject var envChecker: EnvironmentChecker
    @ObservedObject var settingsManager: SettingsManager
    var onComplete: () -> Void
    var onSkip: () -> Void

    @State private var showingPythonPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

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
                Button(action: onSkip) {
                    Text("跳过，直接使用")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "A0A0B0"))
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: {
                    if envChecker.hasChecked {
                        onComplete()
                    } else {
                        envChecker.warmUp()
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: envChecker.hasChecked ? "arrow.right.circle.fill" : "flame.fill")
                        Text(envChecker.hasChecked ? "开始使用" : "开始预热")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color(hex: "7C6FE3"))
                    .cornerRadius(10)
                }
                .buttonStyle(.plain)
                .disabled(envChecker.isChecking)
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)

            Spacer()
            Spacer()
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
    }

    // MARK: - 子视图

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
                Text(envChecker.isChecking ? "预热中..." : (envChecker.hasChecked ? "重新预热" : "预热"))
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

            HStack(spacing: 8) {
                if envChecker.deps.contains(where: { $0.name == "ffmpeg" && !$0.isReady }) {
                    Button("安装 ffmpeg") { envChecker.installFFmpeg() }
                        .buttonStyle(.borderedProminent)
                }
                if envChecker.deps.contains(where: { ($0.name == "funasr" || $0.name == "mlx-audio") && !$0.isReady }) {
                    Button("安装依赖") { envChecker.installPythonDependencies() }
                        .buttonStyle(.borderedProminent)
                }
                if envChecker.deps.contains(where: { ($0.name == "models" || $0.name == "mlx-model") && !$0.isReady }) {
                    Button("下载模型") { envChecker.installModels() }
                        .buttonStyle(.bordered)
                }
                Button("完成后重新预热") { envChecker.refreshAfterExternalInstall() }
                    .buttonStyle(.bordered)
                    .disabled(envChecker.isChecking)
            }

            if !envChecker.installMessage.isEmpty {
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
}
