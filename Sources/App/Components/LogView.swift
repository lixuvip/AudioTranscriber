import SwiftUI
import AppKit

struct LogView: View {
    let logs: [String]
    var currentProgress: String = ""
    var progress: Double = 0
    var isRunning: Bool = false
    var outputDir: URL?
    var onClear: (() -> Void)?

    @State private var scrollViewHeight: CGFloat = 0
    @State private var autoScroll: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            terminalHeader

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if logs.isEmpty {
                            Text("$ 等待任务启动，转写进度会实时显示在这里")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Color(hex: "A0A0B0"))
                                .padding(.top, 2)
                        } else {
                            ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(String(format: "%04d", index + 1))
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(Color(hex: "5A5A6C"))
                                        .frame(width: 38, alignment: .trailing)
                                    Text(line)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(lineColor(for: line))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(index)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .background(
                                GeometryReader { geo in
                                    Color.clear
                                        .preference(
                                            key: ScrollOffsetPreferenceKey.self,
                                            value: geo.frame(in: .named("scroll")).minY
                                        )
                                }
                            )
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: "scroll")
                .background(
                    GeometryReader { outerGeo in
                        Color.clear
                            .onAppear {
                                self.scrollViewHeight = outerGeo.size.height
                            }
                            .onChange(of: outerGeo.size.height) { newHeight in
                                self.scrollViewHeight = newHeight
                            }
                    }
                )
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { minY in
                    let isAtBottom = minY <= scrollViewHeight + 40
                    if isAtBottom != autoScroll {
                        autoScroll = isAtBottom
                    }
                }
                .onChange(of: logs.count) { _ in
                    if autoScroll && !logs.isEmpty {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
                .overlay(
                    Group {
                        if !autoScroll && !logs.isEmpty {
                            VStack {
                                Spacer()
                                Button(action: {
                                    autoScroll = true
                                    withAnimation(.easeOut(duration: 0.18)) {
                                        proxy.scrollTo("bottom", anchor: .bottom)
                                    }
                                }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "arrow.down.circle.fill")
                                            .font(.system(size: 10))
                                        Text("滚回底部")
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color(hex: "8E81F6"))
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                                    .shadow(color: Color.black.opacity(0.3), radius: 3, x: 0, y: 1)
                                }
                                .buttonStyle(.plain)
                                .padding(.bottom, 8)
                            }
                            .transition(.opacity.combined(with: .scale))
                        }
                    },
                    alignment: .bottom
                )
            }
        }
        .background(Color(hex: "0D0D15"))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .cornerRadius(8)
        .padding(.horizontal, 24)
    }

    private var terminalHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Circle().fill(Color(hex: "FF5C5C")).frame(width: 8, height: 8)
                Circle().fill(Color(hex: "F5A623")).frame(width: 8, height: 8)
                Circle().fill(Color(hex: "4EC9B0")).frame(width: 8, height: 8)
            }

            Label(statusTitle, systemImage: isRunning ? "dot.radiowaves.left.and.right" : "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isRunning ? Color(hex: "4EC9B0") : Color(hex: "A0A0B0"))

            if isRunning {
                ProgressView(value: max(0, min(progress, 1)))
                    .progressViewStyle(LinearProgressViewStyle(tint: Color(hex: "4EC9B0")))
                    .frame(width: 120)
            }

            Spacer()

            Button(action: copyLogs) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.plain)
            .help("复制全部日志")
            .disabled(logs.isEmpty)

            if let outputDir {
                Button(action: { NSWorkspace.shared.open(outputDir) }) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.plain)
                .help("打开输出目录")
            }

            Button(action: { onClear?() }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("清空日志")
            .disabled(logs.isEmpty || onClear == nil)
        }
        .font(.system(size: 11))
        .foregroundColor(Color(hex: "A0A0B0"))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color(hex: "16161E"))
    }

    private var statusTitle: String {
        if isRunning {
            return currentProgress.isEmpty ? "任务运行中" : currentProgress
        }
        return logs.isEmpty ? "实时日志" : "任务已结束"
    }

    private func copyLogs() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logs.joined(separator: "\n"), forType: .string)
    }

    private func lineColor(for line: String) -> Color {
        if line.contains("✓") { return Color(hex: "4EC9B0") }
        if line.contains("✗") || line.contains("❌") || line.contains("error") || line.contains("Error") { return Color(hex: "F14C4C") }
        if line.contains("warning") || line.contains("Warning") || line.contains("⚠️") { return Color(hex: "CCA700") }
        if line.contains("Qwen3") || line.contains("pyannote") || line.contains("Voiceprint") { return Color(hex: "4EC9B0") }
        if line.contains("[进度]") || line.contains("[INFO]") { return Color(hex: "7C6FE3") }
        return Color(hex: "C0C0D0")
    }
}

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
