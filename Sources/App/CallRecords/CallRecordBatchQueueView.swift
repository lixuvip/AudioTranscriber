import SwiftUI

struct CallRecordBatchQueueView: View {
    @ObservedObject var store: CallRecordQueueStore
    let isProcessing: Bool
    let currentProgress: String
    let progress: Double
    let currentAudioPath: String?
    let summaryModelName: String?
    var onImportFiles: () -> Void
    var onImportFolder: () -> Void
    var onStart: () -> Void
    var onPause: () -> Void
    var onResume: () -> Void
    var onStopCurrent: () -> Void
    var onRetry: (CallRecordBatchJob) -> Void
    var onClearFinished: () -> Void
    var onClearAll: () -> Void

    private var pendingCount: Int {
        store.jobs.filter { $0.status == .pending }.count
    }

    private var completedCount: Int {
        store.jobs.filter { $0.status == .completed }.count
    }

    private var summarizingCount: Int {
        store.jobs.filter { $0.status == .summarizing }.count
    }

    private var failedCount: Int {
        store.jobs.filter { $0.status == .failed }.count
    }

    private var ignoredCount: Int {
        store.jobs.filter { $0.status == .ignored }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 24)
                .padding(.vertical, 16)

            Divider()
                .background(Color.white.opacity(0.08))

            if store.jobs.isEmpty {
                emptyState
            } else {
                VStack(spacing: 12) {
                    workflowBanner
                    statsRow
                    queueList
                }
                .padding(24)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button(action: onImportFiles) {
                Label("导入文件", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)

            Button(action: onImportFolder) {
                Label("导入文件夹", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.bordered)

            Spacer()

            if store.isActive && !store.isPaused {
                Button(action: onPause) {
                    Label("暂停队列", systemImage: "pause.fill")
                }
                .buttonStyle(.bordered)
            } else if store.isPaused {
                Button(action: onResume) {
                    Label("继续队列", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(action: onStart) {
                    Label("开始队列", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(pendingCount == 0 || isProcessing || summaryModelName == nil)
            }

            Button(action: onStopCurrent) {
                Label("停止当前", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!isProcessing)

            Menu {
                Button("清理已完成/已忽略", action: onClearFinished)
                Button("清空全部", role: .destructive, action: onClearAll)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var workflowBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: summaryModelName == nil ? "exclamationmark.triangle.fill" : "sparkles")
                .foregroundColor(
                    summaryModelName == nil
                        ? Color(hex: "F5A623")
                        : Color(hex: "8E81F6")
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("逐条处理：转写 → AI 整理 → 归档")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(
                    summaryModelName.map { "摘要模型：\($0)" }
                        ?? "请先在“环境与设置”中配置 AI 摘要模型"
                )
                .font(.system(size: 11))
                .foregroundColor(
                    summaryModelName == nil
                        ? Color(hex: "F5A623")
                        : Color(hex: "A0A0B0")
                )
            }
            Spacer()
        }
        .padding(12)
        .background(Color(hex: "1E1E2E"))
        .cornerRadius(8)
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            statChip(title: "等待", value: "\(pendingCount)", color: "A0A0B0")
            statChip(title: "AI 整理", value: "\(summarizingCount)", color: "8E81F6")
            statChip(title: "完成", value: "\(completedCount)", color: "4EC9B0")
            statChip(title: "失败", value: "\(failedCount)", color: "F08A8A")
            statChip(title: "忽略", value: "\(ignoredCount)", color: "F5A623")
            Spacer()
            if isProcessing {
                Text("\(currentProgress) \(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "A0A0B0"))
            }
        }
    }

    private func statChip(title: String, value: String, color: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "A0A0B0"))
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(Color(hex: color))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(hex: "1E1E2E"))
        .cornerRadius(6)
    }

    private var queueList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(store.jobs.sorted(by: sortJobs)) { job in
                    CallRecordJobRow(
                        job: job,
                        isCurrent: currentAudioPath == job.sourcePath,
                        progress: currentAudioPath == job.sourcePath ? progress : job.progress,
                        onRetry: { onRetry(job) }
                    )
                }
            }
        }
    }

    private func sortJobs(_ lhs: CallRecordBatchJob, _ rhs: CallRecordBatchJob) -> Bool {
        let leftDate = lhs.metadata?.callDate ?? lhs.createdAt
        let rightDate = rhs.metadata?.callDate ?? rhs.createdAt
        return leftDate < rightDate
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "queue.play.next")
                .font(.system(size: 54))
                .foregroundColor(Color(hex: "7C6FE3"))
            Text("导入通话录音后按队列逐条转写")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
            Text("每条依次完成转写、AI 整理和归档；少于 10 秒的录音会自动忽略。")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "A0A0B0"))
            HStack {
                Button("导入文件", action: onImportFiles)
                    .buttonStyle(.borderedProminent)
                Button("导入文件夹", action: onImportFolder)
                    .buttonStyle(.bordered)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CallRecordJobRow: View {
    let job: CallRecordBatchJob
    let isCurrent: Bool
    let progress: Double
    var onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 14))
                .foregroundColor(statusColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(job.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    if !job.rawPhone.isEmpty {
                        Text(job.rawPhone)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Color(hex: "A0A0B0"))
                    }
                }
                Text("\(job.callTimeText)  ·  \(job.sourceURL.lastPathComponent)")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "6E6E82"))
                    .lineLimit(1)
                if let message = job.errorMessage, !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(statusColor)
                        .lineLimit(2)
                }
                if isCurrent {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Color(hex: "7C6FE3"))
                }
            }

            Spacer()

            Text(job.status.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(statusColor)

            if job.status == .failed || job.status == .cancelled {
                Button("重试", action: onRetry)
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(isCurrent ? Color(hex: "252542") : Color(hex: "1E1E2E"))
        .cornerRadius(8)
    }

    private var statusIcon: String {
        switch job.status {
        case .pending: return "clock"
        case .running: return "waveform"
        case .summarizing: return "sparkles"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "stop.circle"
        case .ignored: return "minus.circle"
        }
    }

    private var statusColor: Color {
        switch job.status {
        case .pending: return Color(hex: "A0A0B0")
        case .running: return Color(hex: "7C6FE3")
        case .summarizing: return Color(hex: "8E81F6")
        case .completed: return Color(hex: "4EC9B0")
        case .failed: return Color(hex: "F08A8A")
        case .cancelled: return Color(hex: "F5A623")
        case .ignored: return Color(hex: "F5A623")
        }
    }
}
