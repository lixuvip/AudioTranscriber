import AppKit
import SwiftUI

struct PersonOrganizationPane: View {
    @ObservedObject var store: PersonTimelineStore
    @ObservedObject var runner: PersonOrganizationRunner
    @ObservedObject var settingsManager: SettingsManager
    let pythonPath: String
    let summarizeScriptPath: String

    @State private var selectedModelID = ""
    @State private var selectedTemplateID = "relationship-progress"
    @State private var customPrompt = ""
    @State private var showUnavailableConfirmation = false
    @State private var pendingRun: PendingRun?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    selectionSummary
                    modelAndTemplateControls
                    runControls
                    repairSection
                    versionsSection
                }
                .padding(14)
            }
        }
        .onAppear(perform: resolveSelectedModelIfNeeded)
        .onReceive(settingsManager.$customModels) { _ in
            resolveSelectedModelIfNeeded()
        }
        .onReceive(settingsManager.$lastSummaryModelID) { _ in
            resolveSelectedModelIfNeeded()
        }
        .alert(
            "部分通话不可读取",
            isPresented: $showUnavailableConfirmation
        ) {
            Button("继续整理") {
                if let pendingRun {
                    startRunner(with: pendingRun)
                }
                pendingRun = nil
            }
            Button("取消", role: .cancel) {
                pendingRun = nil
            }
        } message: {
            Text(unavailableConfirmationMessage)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
            Text("人物整理")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if runner.isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var selectionSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("输入范围")
                .font(.system(size: 12, weight: .semibold))

            HStack(spacing: 8) {
                metric("已选", "\(selectedCalls.count)")
                metric("可读", "\(selectedCalls.filter(\.isAvailable).count)")
            }

            Text(dateCoverageText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var modelAndTemplateControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("生成设置")
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 6) {
                Text("模型")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("模型", selection: $selectedModelID) {
                    if settingsManager.customModels.isEmpty {
                        Text("未配置模型").tag("")
                    }
                    ForEach(settingsManager.customModels) { model in
                        Text(model.name.isEmpty ? model.id : model.name)
                            .tag(model.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(settingsManager.customModels.isEmpty || runner.isRunning)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("模板")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Picker("模板", selection: $selectedTemplateID) {
                    ForEach(Self.templates) { template in
                        Text(template.title).tag(template.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(runner.isRunning)
            }

            if selectedTemplateID == "custom" {
                VStack(alignment: .leading, spacing: 6) {
                    Text("自定义要求")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $customPrompt)
                        .font(.system(size: 12))
                        .frame(minHeight: 100)
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary, lineWidth: 1)
                        }
                }
            } else {
                Text(selectedTemplate.prompt)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
    }

    private var runControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    prepareAndStart()
                } label: {
                    Label("开始整理", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(startDisabled)

                if runner.isRunning {
                    Button {
                        runner.cancel()
                    } label: {
                        Label("取消", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !runner.progressText.isEmpty {
                Text(runner.progressText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if let message = runner.errorMessage, !message.isEmpty {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
            }

            if settingsManager.customModels.isEmpty {
                Label("请先在设置中配置摘要模型", systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var repairSection: some View {
        if store.pendingVersionRepair != nil {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                Text("版本索引待修复")
                    .font(.system(size: 12, weight: .semibold))
                Text("上次结果文件已生成，但版本索引写入未完成。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    do {
                        try store.repairVersionIndex()
                    } catch {
                        store.present(error)
                    }
                } label: {
                    Label("修复版本索引", systemImage: "wrench.and.screwdriver")
                }
                .disabled(isReadOnly || runner.isRunning)
            }
        }
    }

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack {
                Text("版本历史")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(store.versions.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if store.versions.isEmpty {
                Text("暂无整理版本")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(store.versions.sorted { $0.createdAt > $1.createdAt }) { version in
                        versionRow(version)
                    }
                }
            }
        }
    }

    private func versionRow(_ version: PersonOrganizationVersion) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(templateTitle(for: version.templateID))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(modelTitle(for: version.modelID)) · \(version.callIDs.count) 通")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(Self.dateTimeFormatter.string(from: version.createdAt))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 0)

            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: version.resultPath))
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("打开整理结果")
            .disabled(!FileManager.default.fileExists(atPath: version.resultPath))
        }
        .padding(9)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var selectedCalls: [PersonTimelineCall] {
        store.calls.filter { store.selectedCallIDs.contains($0.id) }
    }

    private var dateCoverageText: String {
        let dates = selectedCalls.map(\.entry.callDate)
        guard let start = dates.min(), let end = dates.max() else {
            return "尚未选择通话"
        }
        if Calendar.current.isDate(start, inSameDayAs: end) {
            return "日期覆盖：\(Self.dateFormatter.string(from: start))"
        }
        return "日期覆盖：\(Self.dateFormatter.string(from: start)) - \(Self.dateFormatter.string(from: end))"
    }

    private var selectedModel: LLMModel? {
        settingsManager.customModels.first { $0.id == selectedModelID }
    }

    private var selectedTemplate: OrganizationTemplate {
        Self.templates.first { $0.id == selectedTemplateID } ?? Self.templates[0]
    }

    private var effectivePrompt: String {
        if selectedTemplateID == "custom" {
            return customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return selectedTemplate.prompt
    }

    private var startDisabled: Bool {
        selectedCalls.isEmpty || selectedModel == nil || isReadOnly || runner.isRunning
    }

    private var isReadOnly: Bool {
        if case .readOnly = store.access {
            return true
        }
        return false
    }

    private var unavailableConfirmationMessage: String {
        guard let pendingRun else {
            return "部分通话缺少可读取的整理版或通话记录。"
        }
        return "\(pendingRun.preparation.unavailableCallIDs.count) 条已选通话不可读取，将跳过这些通话继续整理。"
    }

    private func resolveSelectedModelIfNeeded() {
        let ids = Set(settingsManager.customModels.map(\.id))
        guard !ids.isEmpty else {
            selectedModelID = ""
            return
        }
        if ids.contains(selectedModelID) {
            return
        }
        if ids.contains(settingsManager.lastSummaryModelID) {
            selectedModelID = settingsManager.lastSummaryModelID
        } else if ids.contains(settingsManager.selectedModel) {
            selectedModelID = settingsManager.selectedModel
        } else {
            selectedModelID = settingsManager.customModels.first?.id ?? ""
        }
    }

    private func prepareAndStart() {
        guard let archiveRoot = store.archiveRoot,
              let personID = store.selectedPersonID,
              let model = selectedModel else {
            return
        }

        do {
            let preparation = try store.prepareOrganization()
            let pendingRun = PendingRun(
                personID: personID,
                preparation: preparation,
                model: model,
                templateID: selectedTemplateID,
                prompt: effectivePrompt,
                archiveRoot: archiveRoot
            )

            if preparation.unavailableCallIDs.isEmpty {
                startRunner(with: pendingRun)
            } else {
                self.pendingRun = pendingRun
                showUnavailableConfirmation = true
            }
        } catch {
            store.present(error)
        }
    }

    private func startRunner(with pendingRun: PendingRun) {
        settingsManager.lastSummaryModelID = pendingRun.model.id
        let request = PersonOrganizationRequest(
            personID: pendingRun.personID,
            preparation: pendingRun.preparation,
            model: pendingRun.model,
            templateID: pendingRun.templateID,
            prompt: pendingRun.prompt,
            archiveRoot: pendingRun.archiveRoot,
            pythonPath: pythonPath,
            scriptPath: summarizeScriptPath
        )

        runner.start(request: request) { result in
            if let version = result.version {
                do {
                    try store.commitOrganizationVersion(version)
                } catch {
                    store.preserveDraftAfterFailedRun()
                    store.present(error)
                }
            } else {
                store.preserveDraftAfterFailedRun()
                if result.cancelled {
                    store.present("人物整理已取消")
                } else {
                    store.present(result.errorMessage ?? "人物整理失败")
                }
            }
        }
    }

    private func modelTitle(for modelID: String) -> String {
        settingsManager.customModels.first { $0.id == modelID }?.name.nonEmpty ?? modelID
    }

    private func templateTitle(for templateID: String) -> String {
        Self.templates.first { $0.id == templateID }?.title ?? templateID
    }

    private struct PendingRun {
        let personID: String
        let preparation: PersonOrganizationPreparation
        let model: LLMModel
        let templateID: String
        let prompt: String
        let archiveRoot: URL
    }

    private struct OrganizationTemplate: Identifiable {
        let id: String
        let title: String
        let prompt: String
    }

    private static let templates: [OrganizationTemplate] = [
        OrganizationTemplate(
            id: "relationship-progress",
            title: "关系进展",
            prompt: "请按时间线总结我与这个人的关系进展、关键共识、重要上下文和后续需要保持关注的事项。"
        ),
        OrganizationTemplate(
            id: "action-items",
            title: "行动项",
            prompt: "请从这些通话中提取明确行动项，按负责人、截止时间、依赖条件和风险整理。"
        ),
        OrganizationTemplate(
            id: "requirements-changes",
            title: "需求变化",
            prompt: "请识别这些通话中需求、范围、优先级和验收口径的变化，按时间顺序说明变化原因。"
        ),
        OrganizationTemplate(
            id: "custom",
            title: "自定义",
            prompt: ""
        )
    ]

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
