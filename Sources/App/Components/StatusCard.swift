import SwiftUI

struct StatusCard: View {
    @ObservedObject var envChecker: EnvironmentChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(envChecker.hasChecked ? Color(hex: "4EC9B0") : Color(hex: "F5A623"))
                Text(envChecker.hasChecked ? "环境已预热" : "环境预热")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: { envChecker.warmUp() }) {
                    HStack(spacing: 6) {
                        if envChecker.isChecking {
                            ProgressView()
                                .scaleEffect(0.55)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: envChecker.hasChecked ? "arrow.clockwise" : "flame.fill")
                                .font(.system(size: 12))
                        }
                        Text(envChecker.isChecking ? "预热中" : (envChecker.hasChecked ? "重新预热" : "预热环境"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(hex: "7C6FE3"))
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
                .disabled(envChecker.isChecking)
            }

            PerformanceTierPicker(
                recommendedTier: envChecker.recommendedPerformanceTier,
                selectedTier: envChecker.selectedPerformanceTier,
                onSelect: { envChecker.applyPerformanceTier($0) }
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(envChecker.checkProgress)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .lineLimit(3)
                Text(envChecker.recommendationDetail)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .lineLimit(2)

                if envChecker.isChecking {
                    ProgressView()
                        .progressViewStyle(LinearProgressViewStyle(tint: Color(hex: "7C6FE3")))
                }
            }

            if !envChecker.deps.isEmpty {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 10) {
                    ForEach(envChecker.deps) { dep in
                        DependencyItem(dep: dep)
                    }
                }
            }

            PerformanceProfileRow(profile: envChecker.performanceProfile)

            if hasMissingRequirements {
                VStack(alignment: .leading, spacing: 8) {
                    Text(missingRequirementsTitle)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "A0A0B0"))

                    HStack(spacing: 10) {
                        if isMissingFFmpeg {
                            Button("第 1 步：安装 ffmpeg") {
                                envChecker.installFFmpeg()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if isMissingPythonDeps {
                            Button(installDependenciesStepTitle) {
                                envChecker.installPythonDependencies()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if isMissingModels {
                            Button(downloadModelStepTitle) {
                                envChecker.installModels()
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canDownloadModelYet)
                        }
                        Button("完成后重新预热") {
                            envChecker.refreshAfterExternalInstall()
                        }
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
            }
        }
        .padding(16)
        .background(Color(hex: "2A2A3C"))
        .cornerRadius(12)
        .padding(.horizontal, 24)
    }

    private var hasMissingRequirements: Bool {
        envChecker.deps.contains { !$0.isReady && requiredDependencyNames.contains($0.name) }
    }

    private var isMissingFFmpeg: Bool {
        envChecker.deps.contains { $0.name == "ffmpeg" && !$0.isReady }
    }

    private var isMissingPythonDeps: Bool {
        envChecker.deps.contains { pythonDependencyNames.contains($0.name) && !$0.isReady }
    }

    private var isMissingModels: Bool {
        envChecker.deps.contains { modelDependencyNames.contains($0.name) && !$0.isReady }
    }

    private var requiredDependencyNames: [String] {
        switch envChecker.runtimeSelection.engine {
        case .funASR:
            return ["ffmpeg", "python3", "funasr", "models"]
        case .vibeVoiceMLX:
            return ["ffmpeg", "python3", "mlx-audio", "mlx-model"]
        }
    }

    private var pythonDependencyNames: [String] {
        switch envChecker.runtimeSelection.engine {
        case .funASR:
            return ["python3", "funasr"]
        case .vibeVoiceMLX:
            return ["python3", "mlx-audio"]
        }
    }

    private var modelDependencyNames: [String] {
        switch envChecker.runtimeSelection.engine {
        case .funASR:
            return ["models"]
        case .vibeVoiceMLX:
            return ["mlx-model"]
        }
    }

    private var installDependenciesTitle: String {
        switch envChecker.runtimeSelection.engine {
        case .funASR:
            return "安装 FunASR 依赖"
        case .vibeVoiceMLX:
            return "安装 MLX 依赖"
        }
    }

    private var downloadModelTitle: String {
        switch envChecker.runtimeSelection.engine {
        case .funASR:
            return "下载模型"
        case .vibeVoiceMLX:
            return "下载 MLX 模型"
        }
    }

    private var installDependenciesStepTitle: String {
        switch envChecker.runtimeSelection.engine {
        case .funASR:
            return "第 1 步：安装 FunASR 依赖"
        case .vibeVoiceMLX:
            return "第 1 步：安装 MLX 依赖"
        }
    }

    private var downloadModelStepTitle: String {
        switch envChecker.runtimeSelection.engine {
        case .funASR:
            return "第 2 步：下载模型"
        case .vibeVoiceMLX:
            return "第 2 步：下载 MLX 模型"
        }
    }

    private var canDownloadModelYet: Bool {
        switch envChecker.runtimeSelection.engine {
        case .funASR:
            return true
        case .vibeVoiceMLX:
            return !isMissingPythonDeps
        }
    }

    private var missingRequirementsTitle: String {
        if envChecker.runtimeSelection.engine == .vibeVoiceMLX && isMissingPythonDeps {
            return "请按顺序完成：先安装 MLX 依赖，再下载 MLX 模型。"
        }
        return "检测到 \(envChecker.runtimeSelection.engine.title) 缺失项，可直接安装。"
    }
}

struct PerformanceProfileRow: View {
    let profile: PerformanceProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .foregroundColor(Color(hex: "4EC9B0"))
                Text(profile.summary)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .lineLimit(2)
                Spacer()
            }
            HStack(spacing: 10) {
                infoChip(title: "设备", value: profile.device.uppercased())
                infoChip(title: "线程", value: "\(profile.threads)")
                infoChip(title: "batch", value: "\(profile.batchSizeSeconds)s")
                infoChip(title: "merge", value: "\(profile.mergeLengthSeconds)s")
                infoChip(title: "说话人", value: profile.speakerDiarizationEnabled ? "开" : "关")
            }
        }
        .padding(10)
        .background(Color(hex: "1E1E2E"))
        .cornerRadius(8)
    }

    private func infoChip(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "A0A0B0"))
            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(hex: "2A2A3C"))
        .cornerRadius(6)
    }
}

struct PerformanceTierPicker: View {
    let recommendedTier: PerformanceTier
    let selectedTier: PerformanceTier
    var onSelect: (PerformanceTier) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(Color(hex: "7C6FE3"))
                Text("性能档位")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Text("推荐 \(recommendedTier.title) 档")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
            }

            HStack(spacing: 8) {
                ForEach(PerformanceTier.allCases) { tier in
                    Button(action: { onSelect(tier) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(tier.title)
                                    .font(.system(size: 12, weight: .semibold))
                                if tier == recommendedTier {
                                    Text("推荐")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Color(hex: "7C6FE3"))
                                        .cornerRadius(4)
                                }
                            }
                            Text(tier.description)
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "A0A0B0"))
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(selectedTier == tier ? Color(hex: "3A3557") : Color(hex: "1E1E2E"))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(tier == selectedTier ? Color(hex: "7C6FE3") : Color.clear, lineWidth: 1)
                        )
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(Color(hex: "1E1E2E"))
        .cornerRadius(8)
    }
}

struct DependencyItem: View {
    let dep: DependencyStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: dep.icon)
                    .font(.system(size: 14))
                    .foregroundColor(dep.isReady ? Color(hex: "4EC9B0") : Color(hex: "F5A623"))
                Text(dep.name.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(Color(hex: "A0A0B0"))
            }
            Text(dep.message)
                .font(.system(size: 11))
                .foregroundColor(dep.isReady ? Color(hex: "4EC9B0") : Color(hex: "F5A623"))
                .lineLimit(2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: "1E1E2E"))
        .cornerRadius(8)
    }
}
