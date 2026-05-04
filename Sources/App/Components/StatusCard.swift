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

            VStack(alignment: .leading, spacing: 6) {
                Text(envChecker.checkProgress)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .lineLimit(3)

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
                    HStack(spacing: 10) {
                        Text("检测到缺失项，可直接安装。")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "A0A0B0"))
                        Spacer()
                        if isMissingFFmpeg {
                            Button("安装 ffmpeg") {
                                envChecker.installFFmpeg()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        if isMissingPythonDeps {
                            Button("安装 FunASR 依赖") {
                                envChecker.installPythonDependencies()
                            }
                            .buttonStyle(.bordered)
                        }
                        if isMissingModels {
                            Button("下载模型") {
                                envChecker.installModels()
                            }
                            .buttonStyle(.bordered)
                        }
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
        envChecker.deps.contains { !$0.isReady && ["ffmpeg", "python3", "funasr", "models"].contains($0.name) }
    }

    private var isMissingFFmpeg: Bool {
        envChecker.deps.contains { $0.name == "ffmpeg" && !$0.isReady }
    }

    private var isMissingPythonDeps: Bool {
        envChecker.deps.contains { ($0.name == "python3" || $0.name == "funasr") && !$0.isReady }
    }

    private var isMissingModels: Bool {
        envChecker.deps.contains { $0.name == "models" && !$0.isReady }
    }
}

struct PerformanceProfileRow: View {
    let profile: PerformanceProfile

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "speedometer")
                .foregroundColor(Color(hex: "4EC9B0"))
            Text(profile.summary)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "A0A0B0"))
                .lineLimit(2)
            Spacer()
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
