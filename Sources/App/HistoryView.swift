import SwiftUI
import AppKit

struct HistoryView: View {
    @ObservedObject var historyManager: HistoryManager
    @ObservedObject var transcriber: Transcriber
    @Binding var activeTab: ContentView.MainTab
    @State private var searchText = ""
    @State private var expandedID: String?

    private var filteredEntries: [TranscriptionHistoryEntry] {
        if searchText.isEmpty { return historyManager.entries }
        return historyManager.entries.filter {
            $0.fileName.localizedCaseInsensitiveContains(searchText) ||
            $0.engine.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 搜索栏
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "5A5A6C"))
                TextField("搜索文件名...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "5A5A6C"))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Color(hex: "1E1E2E"))
            .cornerRadius(8)

            // 列表
            if filteredEntries.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 36))
                        .foregroundColor(Color(hex: "3A3A4C"))
                    Text(searchText.isEmpty ? "暂无转写记录" : "未找到匹配记录")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "5A5A6C"))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(filteredEntries) { entry in
                            HistoryRow(
                                entry: entry,
                                isExpanded: expandedID == entry.id,
                                onToggle: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        expandedID = expandedID == entry.id ? nil : entry.id
                                    }
                                },
                                onOpenDir: { openOutputDir(entry) },
                                onDelete: { historyManager.remove(id: entry.id) },
                                onLoadProofread: {
                                    transcriber.loadHistoryEntry(entry)
                                    activeTab = .editor
                                }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            // 底部
            if !historyManager.entries.isEmpty {
                HStack {
                    Text("共 \(historyManager.entries.count) 条记录")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "5A5A6C"))
                    Spacer()
                    Button("清空历史") {
                        historyManager.clear()
                    }
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "F08A8A"))
                    .buttonStyle(.plain)
                }
                .padding(.top, 8)
            }
        }
    }

    private func openOutputDir(_ entry: TranscriptionHistoryEntry) {
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.outputDir))
    }
}

private struct HistoryRow: View {
    let entry: TranscriptionHistoryEntry
    let isExpanded: Bool
    var onToggle: () -> Void
    var onOpenDir: () -> Void
    var onDelete: () -> Void
    var onLoadProofread: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 主行
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    // 引擎图标
                    Image(systemName: entry.engine == "vibeVoiceMLX" ? "cpu" : "waveform")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "7C6FE3"))
                        .frame(width: 28)

                    // 文件名 + 日期
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.fileName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(entry.dateString)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "5A5A6C"))
                    }

                    Spacer()

                    // 标签
                    HStack(spacing: 6) {
                        tag(text: entry.engine, color: "7C6FE3")
                        if entry.segmentCount > 0 {
                            tag(text: "\(entry.segmentCount)段", color: "4EC9B0")
                        }
                        if entry.speakerCount > 0 {
                            tag(text: "\(entry.speakerCount)人", color: "F5A623")
                        }
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "5A5A6C"))
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
            }
            .buttonStyle(.plain)
            .background(Color(hex: "2A2A3C"))
            .cornerRadius(10)

            // 展开详情
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Divider().background(Color(hex: "3A3A4C"))

                    // 输出文件列表
                    if !entry.outputFiles.isEmpty {
                        Text("输出文件")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(Color(hex: "5A5A6C"))
                        ForEach(entry.outputFiles, id: \.self) { url in
                            HStack(spacing: 6) {
                                Image(systemName: fileIcon(url))
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "7C6FE3"))
                                Text(url.lastPathComponent)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Color(hex: "A0A0B0"))
                                    .lineLimit(1)
                                Spacer()
                                Button(action: { NSWorkspace.shared.open(url) }) {
                                    Image(systemName: "arrow.up.forward.app")
                                        .font(.system(size: 10))
                                        .foregroundColor(Color(hex: "7C6FE3"))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    // 操作按钮
                    HStack(spacing: 8) {
                        Button(action: onLoadProofread) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text.magnifyingglass")
                                    .font(.system(size: 10))
                                Text("加载校对")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(Color(hex: "4EC9B0"))
                        }
                        .buttonStyle(.plain)

                        Button(action: onOpenDir) {
                            HStack(spacing: 4) {
                                Image(systemName: "folder")
                                    .font(.system(size: 10))
                                Text("打开目录")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(Color(hex: "7C6FE3"))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button(action: onDelete) {
                            HStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                Text("删除记录")
                                    .font(.system(size: 11))
                            }
                            .foregroundColor(Color(hex: "F08A8A"))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .background(Color(hex: "2A2A3C"))
                .cornerRadius(10)
                .padding(.top, -6)
            }
        }
        .padding(.horizontal, 2)
    }

    private func tag(text: String, color: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundColor(Color(hex: color))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(hex: color).opacity(0.15))
            .cornerRadius(4)
    }

    private func fileIcon(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md": return "doc.text"
        case "json": return "curlybraces"
        default: return "doc"
        }
    }
}
