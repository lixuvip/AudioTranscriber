import SwiftUI

struct PersonCallsPane: View {
    @ObservedObject var store: PersonTimelineStore
    @State private var expandedCallIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()

            if store.selectedPersonID == nil {
                emptyState(
                    icon: "person.crop.circle.badge.exclamationmark",
                    title: "选择一个人物",
                    detail: "左侧选中人物后，这里会显示该人物关联的通话。"
                )
            } else if store.calls.isEmpty {
                emptyState(
                    icon: "phone.down",
                    title: "暂无通话",
                    detail: "当前人物的号码没有匹配到通话记录。"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.calls) { call in
                            callRow(call)
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("通话")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(store.selectedCallIDs.count) / \(store.calls.count) 已选")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("全选") {
                performStoreAction {
                    try store.selectAll()
                }
            }
            .disabled(toolbarActionsDisabled)

            Button("清空") {
                performStoreAction {
                    try store.clearSelection()
                }
            }
            .disabled(toolbarActionsDisabled || store.selectedCallIDs.isEmpty)

            Button("最近 30 天") {
                performStoreAction {
                    try store.selectRecent30Days()
                }
            }
            .disabled(toolbarActionsDisabled)
        }
        .font(.system(size: 12))
    }

    private func callRow(_ call: PersonTimelineCall) -> some View {
        let isSelected = store.selectedCallIDs.contains(call.id)
        let isExpanded = expandedCallIDs.contains(call.id)
        let source = call.sourceStatus
        return HStack(alignment: .top, spacing: 10) {
            Button {
                performStoreAction {
                    try store.toggleCall(call.id)
                }
            } label: {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)
            .disabled((!call.isAvailable && !isSelected) || isReadOnly)
            .help(call.isAvailable || isSelected ? "选择整段通话" : source.reason)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(call.entry.callDateText)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)

                    Text(call.entry.rawPhone)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(source.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(source.isAvailable ? Color.secondary : Color.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: 4))

                    if source.isAvailable {
                        Button {
                            toggleExpanded(call.id)
                        } label: {
                            Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help(isExpanded ? "收起摘要" : "展开摘要")
                    }
                }

                HStack(spacing: 8) {
                    Label(Self.durationText(call.entry.durationSeconds), systemImage: "timer")
                    Label(call.entry.engine.isEmpty ? "未知引擎" : call.entry.engine, systemImage: "cpu")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if isExpanded {
                    expandedPreview(
                        previewText(for: call, source: source, expanded: true),
                        isAvailable: call.isAvailable
                    )
                } else {
                    Text(previewText(for: call, source: source, expanded: false))
                        .font(.system(size: 11))
                        .foregroundStyle(call.isAvailable ? Color.secondary : Color.secondary.opacity(0.7))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 10)
            .padding(.trailing, 12)
        }
        .padding(.leading, 12)
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private func expandedPreview(_ text: String, isAvailable: Bool) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(isAvailable ? Color.secondary : Color.secondary.opacity(0.7))
            .textSelection(.enabled)
            .lineLimit(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            }
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var toolbarActionsDisabled: Bool {
        store.selectedPersonID == nil || store.calls.isEmpty || isReadOnly
    }

    private var isReadOnly: Bool {
        if case .readOnly = store.access {
            return true
        }
        return false
    }

    private func performStoreAction(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            store.present(error)
        }
    }

    private func toggleExpanded(_ callID: String) {
        if expandedCallIDs.contains(callID) {
            expandedCallIDs.remove(callID)
        } else {
            expandedCallIDs.insert(callID)
        }
    }

    private func previewText(
        for call: PersonTimelineCall,
        source: PersonTimelineCall.SourceStatus,
        expanded: Bool
    ) -> String {
        if !source.isAvailable {
            return source.reason
        }
        guard !call.entry.summaryPath.isEmpty else {
            return "摘要缺失：未生成摘要文件"
        }
        guard FileManager.default.fileExists(atPath: call.entry.summaryPath) else {
            return "摘要缺失：文件不存在"
        }
        return Self.readPreview(
            from: call.entry.summaryPath,
            byteLimit: expanded ? 65_536 : 8_192,
            characterLimit: expanded ? 3_000 : 140,
            preserveLineBreaks: expanded
        )
            ?? "摘要缺失：文件为空"
    }

    private static func durationText(_ duration: Double?) -> String {
        guard let duration, duration.isFinite, duration > 0 else {
            return "时长未知"
        }
        let totalSeconds = Int(duration.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func readPreview(
        from path: String,
        byteLimit: Int,
        characterLimit: Int,
        preserveLineBreaks: Bool
    ) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return nil
        }
        defer {
            try? handle.close()
        }

        let data = handle.readData(ofLength: byteLimit)
        guard let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        let lines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalized = lines.joined(separator: preserveLineBreaks ? "\n" : " ")
        guard !normalized.isEmpty else { return nil }
        if normalized.count > characterLimit {
            return String(normalized.prefix(characterLimit)) + "..."
        }
        return normalized
    }
}

private extension PersonTimelineCall {
    struct SourceStatus {
        let title: String
        let isAvailable: Bool
        let reason: String
    }

    var sourceStatus: SourceStatus {
        if let kind = preferredSourceKind {
            switch kind {
            case .proofread:
                return SourceStatus(title: "整理版", isAvailable: true, reason: "")
            case .transcript:
                return SourceStatus(title: "通话记录", isAvailable: true, reason: "")
            }
        }

        return SourceStatus(
            title: "缺失",
            isAvailable: false,
            reason: unavailableReason
        )
    }
}
