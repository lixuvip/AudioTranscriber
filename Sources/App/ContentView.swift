import SwiftUI
import UniformTypeIdentifiers
import AppKit
import AVFoundation

struct ContentView: View {
    @StateObject private var envChecker = EnvironmentChecker()
    @StateObject private var transcriber = Transcriber()
    @StateObject private var settingsManager = SettingsManager()
    @StateObject private var historyManager = HistoryManager()
    @StateObject private var voiceprintStore = VoiceprintStore()
    @StateObject private var callRecordQueue = CallRecordQueueStore()
    @StateObject private var personTimelineStore = PersonTimelineStore()
    @StateObject private var personOrganizationRunner = PersonOrganizationRunner()

    @State private var selectedFileURL: URL?
    @State private var customOutputDir: String = ""
    @State private var isDragging = false
    @State private var showingFilePicker = false
    @State private var showingFolderPicker = false
    @State private var showingPythonPicker = false
    @State private var showSetup = true
    @State private var activeTab: MainTab = .workspace
    @State private var summaryModelID: String = ""
    @State private var editingIndex: Int? = nil
    @State private var editingText: String = ""
    @State private var speakerRoleFeedback: SpeakerRoleActionFeedback?
    @State private var isApplyingSpeakerNames = false
    @State private var enrollingVoiceprintRoleID: String?
    @State private var enrolledVoiceprintRoleIDs: Set<String> = []

    private var outputDir: URL? {
        customOutputDir.isEmpty ? nil : URL(fileURLWithPath: customOutputDir)
    }

    private var effectiveOutputDir: URL? {
        outputDir ?? selectedFileURL?.deletingLastPathComponent()
    }

    enum MainTab {
        case workspace
        case batchQueue
        case people
        case editor
        case voiceprints
        case logs
        case history
        case settings
    }

    var body: some View {
        Group {
            if showSetup {
                SetupView(
                    envChecker: envChecker,
                    settingsManager: settingsManager,
                    onComplete: { showSetup = false },
                    onSkip: { showSetup = false }
                )
                .transition(.opacity)
            } else {
                // New Premium Three-Column Layout
                HStack(spacing: 0) {
                    SidebarView(activeTab: $activeTab, envChecker: envChecker, transcriber: transcriber, settingsManager: settingsManager)

                    Divider()
                        .background(Color.white.opacity(0.08))

                    // Main Workspace
                    VStack(spacing: 0) {
                        HeaderView()

                        ZStack(alignment: .top) {
                            switch activeTab {
                            case .workspace:
                                workspaceTab
                                    .transition(.opacity)
                            case .batchQueue:
                                batchQueueTab
                                    .transition(.opacity)
                            case .people:
                                peopleTab
                                    .transition(.opacity)
                            case .editor:
                                editorTab
                                    .transition(.opacity)
                            case .voiceprints:
                                voiceprintTab
                                    .transition(.opacity)
                            case .logs:
                                logTab
                                    .transition(.opacity)
                            case .history:
                                HistoryView(historyManager: historyManager, transcriber: transcriber, activeTab: $activeTab)
                                    .padding(.horizontal, 24)
                                    .padding(.top, 16)
                                    .transition(.opacity)
                            case .settings:
                                settingsTab
                                    .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Color(hex: "12121A"))
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: showSetup)
        .animation(.easeInOut(duration: 0.25), value: activeTab)
        .background(Color(hex: "12121A"))
        .onAppear {
            voiceprintStore.load()
            envChecker.customPythonPath = settingsManager.pythonPath
            envChecker.updateRuntimeSelection(
                environment: settingsManager.runtimeEnvironment,
                engine: settingsManager.transcriptionEngine,
                modelID: settingsManager.transcriptionModelID
            )
            envChecker.initialize(cachedPythonPath: settingsManager.pythonPath)
            if let savedTier = PerformanceTier.allCases.first(where: { $0.rawValue == settingsManager.performanceTier }) {
                envChecker.savedPerformanceTier = savedTier
            }
            // Always show setup first; it auto-transitions if all ready
            showSetup = true
            // init summaryModelID
            let preferred = !settingsManager.lastSummaryModelID.isEmpty
                && settingsManager.customModels.contains(where: { $0.id == settingsManager.lastSummaryModelID })
                ? settingsManager.lastSummaryModelID
                : settingsManager.selectedModel
            summaryModelID = preferred
            if summaryModelID.isEmpty, let first = settingsManager.customModels.first {
                summaryModelID = first.id
            }
            openLastPersonArchiveRootIfAvailable()
        }
        .onChange(of: transcriber.pendingHistoryEntry) { entry in
            if let entry = entry {
                historyManager.add(entry)
                transcriber.pendingHistoryEntry = nil
            }
        }
        .onChange(of: transcriber.lastRunResult) { result in
            guard let result else { return }
            handleCallRecordRunResult(result)
        }
        .onChange(of: transcriber.lastSummaryRunResult) { result in
            guard let result else { return }
            handleCallRecordSummaryResult(result)
        }
        .onReceive(NotificationCenter.default.publisher(for: .callRecordArchiveWriterDidWrite)) { notification in
            guard let archiveRoot = notification.object as? URL else {
                return
            }
            Task { @MainActor in
                reloadPersonArchiveIfNeeded(writtenArchiveRoot: archiveRoot)
            }
        }
        .onChange(of: envChecker.selectedPerformanceTier) { tier in
            settingsManager.performanceTier = tier.rawValue
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
        .onChange(of: settingsManager.runtimeEnvironment) { _ in
            envChecker.updateRuntimeSelection(
                environment: settingsManager.runtimeEnvironment,
                engine: settingsManager.transcriptionEngine,
                modelID: settingsManager.transcriptionModelID
            )
            envChecker.initialize(cachedPythonPath: settingsManager.pythonPath)
        }
        .onChange(of: settingsManager.transcriptionEngine) { _ in
            envChecker.updateRuntimeSelection(
                environment: settingsManager.runtimeEnvironment,
                engine: settingsManager.transcriptionEngine,
                modelID: settingsManager.transcriptionModelID
            )
            envChecker.initialize(cachedPythonPath: settingsManager.pythonPath)
        }
        .onChange(of: settingsManager.transcriptionModelID) { _ in
            envChecker.updateRuntimeSelection(
                environment: settingsManager.runtimeEnvironment,
                engine: settingsManager.transcriptionEngine,
                modelID: settingsManager.transcriptionModelID
            )
        }
        .onChange(of: envChecker.pythonPath) { newPath in
            if envChecker.hasChecked, !newPath.isEmpty, settingsManager.pythonPath != newPath {
                settingsManager.pythonPath = newPath
            }
        }
        .onChange(of: transcriber.speakerRolesReady) { ready in
            if ready {
                speakerRoleFeedback = nil
                isApplyingSpeakerNames = false
                enrollingVoiceprintRoleID = nil
                enrolledVoiceprintRoleIDs = []
            }
            if CallRecordBatchWorkflow.shouldOpenEditor(
                context: transcriber.currentRunContext,
                speakerRolesReady: ready
            ) && activeTab != .logs {
                activeTab = .editor
            }
        }
        .onChange(of: settingsManager.customModels.count) { _ in
            if !settingsManager.customModels.contains(where: { $0.id == summaryModelID }) {
                summaryModelID = settingsManager.lastSummaryModelID
                if !settingsManager.customModels.contains(where: { $0.id == summaryModelID }) {
                    summaryModelID = settingsManager.selectedModel
                }
                if summaryModelID.isEmpty, let first = settingsManager.customModels.first {
                    summaryModelID = first.id
                }
            }
        }
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
    }

    // MARK: - Header

    private func HeaderView() -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(tabTitle(for: activeTab))
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(Color(hex: "8E81F6"))

                if let file = selectedFileURL {
                    Text(file.lastPathComponent)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Color(hex: "A0A0B0"))
                }
            }

            Spacer()

            // Setup Quick Launch
            Button(action: { showSetup = true }) {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                    Text("向导")
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(hex: "A0A0B0"))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.04))
                .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .background(Color(hex: "12121A").opacity(0.8))
    }

    private func tabTitle(for tab: MainTab) -> String {
        switch tab {
        case .workspace: return "工作台"
        case .batchQueue: return "批量处理队列"
        case .people: return "人物归档"
        case .editor: return "交互校对编辑器"
        case .voiceprints: return "声纹库"
        case .logs: return "实时日志"
        case .history: return "转写历史库"
        case .settings: return "系统环境设置"
        }
    }

    // MARK: - Workspace Tab (工作台)

    private var workspaceTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Dropzone
                FileDropZone(
                    selectedFileURL: $selectedFileURL,
                    isDragging: $isDragging,
                    onSelect: { showingFilePicker = true }
                )

                // Action Buttons
                HStack(spacing: 12) {
                    if transcriber.isTranscribing {
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
                    } else if settingsManager.executionTarget == .local && envChecker.isSilentInstalling {
                        SilentInstallProgressCapsule(
                            status: envChecker.silentInstallStatus,
                            progress: envChecker.silentInstallProgress
                        )
                    } else if settingsManager.executionTarget == .local && envChecker.hasChecked && !envChecker.allReady {
                        VStack(spacing: 8) {
                            Button(action: {
                                envChecker.startSilentDependencyInstall()
                            }) {
                                HStack {
                                    Image(systemName: "sparkles")
                                    Text("一键准备本地加速库及模型")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(PrimaryButtonStyle())

                            Text("检测到本地运行环境缺失必要组件。点击按钮将在后台自动构建虚拟环境、安装依赖并下载所需模型。")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "A0A0B0"))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                        }
                    } else {
                        Button(action: {
                            guard settingsManager.executionTarget == .remote || envChecker.hasChecked else {
                                showSetup = true
                                return
                            }
                            transcriber.startTranscription(
                                audioURL: selectedFileURL,
                                outputDir: effectiveOutputDir,
                                pythonPath: envChecker.pythonPath,
                                pythonSitePackages: envChecker.pythonSitePackages,
                                performanceProfile: envChecker.performanceProfile,
                                engine: settingsManager.transcriptionEngine,
                                modelID: settingsManager.transcriptionModelID,
                                executionTarget: settingsManager.executionTarget,
                                remoteServiceURL: settingsManager.remoteServiceURL,
                                remoteTailscaleURL: settingsManager.remoteTailscaleURL,
                                relayServiceURL: settingsManager.relayServiceURL,
                                speakerDiarizationEnabled: settingsManager.speakerDiarizationEnabled
                            )
                        }) {
                            HStack {
                                Image(systemName: "play.fill")
                                Text(settingsManager.executionTarget == .remote ? "开始转写" : (envChecker.hasChecked ? "开始转写" : "先预热环境"))
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(transcriber.isSummarizing || selectedFileURL == nil || (settingsManager.executionTarget == .local && (envChecker.isChecking || (envChecker.hasChecked && !envChecker.allReady))))
                    }
                }
                .padding(.horizontal, 24)

                // Progress
                if transcriber.isTranscribing || transcriber.isSummarizing {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(transcriber.currentProgress)
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "A0A0B0"))
                            Spacer()
                            if let eta = transcriber.estimatedTimeRemaining {
                                Text(eta)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Color(hex: "4EC9B0"))
                            }
                        }
                        ProgressView(value: transcriber.progress)
                            .progressViewStyle(LinearProgressViewStyle(tint: Color(hex: "8E81F6")))

                        if transcriber.isTranscribing && !transcriber.isSummarizing {
                            TranscriptionTimelineView(transcriber: transcriber)
                                .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 24)
                }

                // Completion Summary
                if let summary = transcriber.completionSummary {
                    CompletionSummaryCard(summary: summary)

                    // Display Speaker Roles mapping card if diarization was enabled and we have roles
                    if !transcriber.speakerRoles.isEmpty {
                        SpeakerRolesCard(
                            roles: transcriber.speakerRoles,
                            feedback: speakerRoleFeedback,
                            isApplying: isApplyingSpeakerNames,
                            enrollingRoleID: enrollingVoiceprintRoleID,
                            enrolledRoleIDs: enrolledVoiceprintRoleIDs,
                            onChange: { id, newName in
                                transcriber.updateSpeakerRole(id: id, displayName: newName)
                            },
                            onApply: {
                                applySpeakerNamesToOutput()
                            },
                            onEnroll: { role in
                                enrollVoiceprint(role)
                            },
                            onAddRole: {
                                transcriber.addNewSpeakerRole()
                            }
                        )
                        .padding(.top, 8)
                    }

                    // Quick jump to editor button
                    Button(action: { activeTab = .editor }) {
                        HStack {
                            Image(systemName: "doc.text.magnifyingglass")
                            Text("进入交互编辑器进行校对")
                        }
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(Color(hex: "8E81F6").opacity(0.15))
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)

                    // AI Summary generation button
                    if !transcriber.isSummarizing {
                        if !settingsManager.customModels.isEmpty {
                            VStack(spacing: 8) {
                                if settingsManager.customModels.count > 1 {
                                    HStack {
                                        Text("模型选择")
                                            .font(.system(size: 10))
                                            .foregroundColor(Color(hex: "A0A0B0"))
                                        Picker("", selection: $summaryModelID) {
                                            ForEach(settingsManager.customModels) { m in
                                                Text(m.name).tag(m.id)
                                            }
                                        }
                                        .pickerStyle(.menu)
                                        Spacer()
                                    }
                                }
                                Button(action: {
                                    if let model = settingsManager.customModels.first(where: { $0.id == summaryModelID }) {
                                        settingsManager.lastSummaryModelID = summaryModelID
                                        transcriber.startSummarization(
                                            audioURL: transcriber.currentAudioURL,
                                            outputDir: transcriber.currentOutputDir,
                                            model: model,
                                            pythonPath: envChecker.pythonPath,
                                            summaryPrompt: settingsManager.summaryPrompt
                                        )
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "sparkles")
                                        Text(transcriber.generatedSummary == nil ? "生成 AI 智能摘要" : "重新生成 AI 摘要")
                                    }
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(Color(hex: "8E81F6").opacity(0.25))
                                    .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                                .disabled(summaryModelID.isEmpty)
                            }
                            .padding(.horizontal, 24)
                        } else {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "F39C12"))
                                Text("需先在设置中配置 LLM 模型才能生成摘要")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "A0A0B0"))
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                }

                // Log Window
                LogView(
                    logs: transcriber.logs,
                    currentProgress: transcriber.currentProgress,
                    progress: transcriber.progress,
                    isRunning: transcriber.isTranscribing || transcriber.isSummarizing,
                    outputDir: transcriber.currentOutputDir,
                    onClear: { transcriber.clearLogs() }
                )
                    .frame(height: 300)

                // Settings Panel inside Workspace for fast path tuning
                SettingsPanel(
                    outputDir: $customOutputDir,
                    settingsManager: settingsManager,
                    onBrowseOutput: { showingFolderPicker = true },
                    onPickPython: { showingPythonPicker = true },
                    onAutoDetectPython: {
                        settingsManager.pythonPath = ""
                        envChecker.customPythonPath = ""
                        envChecker.updateRuntimeSelection(
                            environment: settingsManager.runtimeEnvironment,
                            engine: settingsManager.transcriptionEngine,
                            modelID: settingsManager.transcriptionModelID
                        )
                        envChecker.initialize(cachedPythonPath: "")
                        envChecker.warmUp()
                    },
                    onClearPython: {
                        settingsManager.pythonPath = ""
                        envChecker.customPythonPath = ""
                        envChecker.updateRuntimeSelection(
                            environment: settingsManager.runtimeEnvironment,
                            engine: settingsManager.transcriptionEngine,
                            modelID: settingsManager.transcriptionModelID
                        )
                        envChecker.initialize(cachedPythonPath: "")
                    }
                )
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Batch Queue Tab

    private var batchQueueTab: some View {
        CallRecordBatchQueueView(
            store: callRecordQueue,
            isProcessing: transcriber.isTranscribing || transcriber.isSummarizing,
            currentProgress: transcriber.currentProgress,
            progress: transcriber.progress,
            currentAudioPath: transcriber.currentAudioURL?.path,
            summaryModelName: callRecordSummaryModel?.name,
            onImportFiles: importCallRecordFiles,
            onImportFolder: importCallRecordFolder,
            onStart: startCallRecordQueue,
            onPause: pauseCallRecordQueue,
            onResume: resumeCallRecordQueue,
            onStopCurrent: stopCurrentCallRecordJob,
            onRetry: retryCallRecordJob,
            onClearFinished: { callRecordQueue.clearCompletedAndIgnored() },
            onClearAll: { callRecordQueue.clearAll() }
        )
    }

    private func importCallRecordFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .quickTimeMovie]
        if panel.runModal() == .OK {
            Task {
                await callRecordQueue.importFiles(
                    panel.urls,
                    outputRoot: callRecordArchiveRoot(),
                    engine: settingsManager.transcriptionEngine.scriptEngineRawValue,
                    modelID: settingsManager.transcriptionModelID
                )
            }
        }
    }

    private func importCallRecordFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await callRecordQueue.importFolder(
                    url,
                    outputRoot: callRecordArchiveRoot(),
                    engine: settingsManager.transcriptionEngine.scriptEngineRawValue,
                    modelID: settingsManager.transcriptionModelID
                )
            }
        }
    }

    private func startCallRecordQueue() {
        guard callRecordSummaryModel != nil else { return }
        callRecordQueue.start()
        runNextCallRecordJobIfNeeded()
    }

    private func pauseCallRecordQueue() {
        callRecordQueue.pause()
    }

    private func resumeCallRecordQueue() {
        callRecordQueue.resume()
        runNextCallRecordJobIfNeeded()
    }

    private func stopCurrentCallRecordJob() {
        callRecordQueue.pause()
        transcriber.stopCurrentTask()
    }

    private func retryCallRecordJob(_ job: CallRecordBatchJob) {
        callRecordQueue.retry(job)
        runNextCallRecordJobIfNeeded()
    }

    private func runNextCallRecordJobIfNeeded() {
        guard !transcriber.isTranscribing, !transcriber.isSummarizing else { return }
        guard let job = callRecordQueue.nextPendingJob() else {
            callRecordQueue.stop()
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: job.outputDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            callRecordQueue.markFailed(id: job.id, message: "创建输出目录失败: \(error.localizedDescription)")
            DispatchQueue.main.async { runNextCallRecordJobIfNeeded() }
            return
        }

        let engine = settingsManager.transcriptionEngine
        let modelID = settingsManager.transcriptionModelID.isEmpty ? engine.defaultModelID : settingsManager.transcriptionModelID
        callRecordQueue.markRunning(job, engine: engine.scriptEngineRawValue, modelID: modelID)
        transcriber.startTranscription(
            audioURL: job.sourceURL,
            outputDir: job.outputDirectoryURL,
            pythonPath: settingsManager.pythonPath,
            pythonSitePackages: envChecker.pythonSitePackages,
            performanceProfile: envChecker.performanceProfile,
            engine: engine,
            modelID: modelID,
            executionTarget: settingsManager.executionTarget,
            remoteServiceURL: settingsManager.remoteServiceURL,
            remoteTailscaleURL: settingsManager.remoteTailscaleURL,
            relayServiceURL: settingsManager.relayServiceURL,
            speakerDiarizationEnabled: settingsManager.speakerDiarizationEnabled,
            runContext: .callRecordBatch
        )
    }

    private func handleCallRecordRunResult(_ result: TranscriptionRunResult) {
        guard let job = callRecordQueue.activeJob(for: result.audioPath),
              job.status == .running else {
            return
        }

        let action = CallRecordBatchWorkflow.postTranscriptionAction(
            success: result.success,
            cancelled: result.cancelled,
            errorMessage: result.errorMessage,
            hasSummaryModel: callRecordSummaryModel != nil
        )
        switch action {
        case .summarize:
            guard let model = callRecordSummaryModel else {
                callRecordQueue.markFailed(id: job.id, message: "未配置 AI 摘要模型")
                scheduleNextCallRecordJob()
                return
            }
            callRecordQueue.markSummarizing(id: job.id)
            settingsManager.lastSummaryModelID = model.id
            transcriber.startSummarization(
                audioURL: job.sourceURL,
                outputDir: job.outputDirectoryURL,
                model: model,
                pythonPath: envChecker.pythonPath,
                summaryPrompt: settingsManager.summaryPrompt
            )
        case .cancel:
            callRecordQueue.markCancelled(id: job.id)
            callRecordQueue.pause()
        case .fail(let message):
            callRecordQueue.markFailed(id: job.id, message: message)
            scheduleNextCallRecordJob()
        }
    }

    private func handleCallRecordSummaryResult(_ result: SummarizationRunResult) {
        guard let job = callRecordQueue.activeJob(for: result.audioPath),
              job.status == .summarizing else {
            return
        }

        if result.success {
            callRecordQueue.markCompleted(id: job.id)
            if let completedJob = callRecordQueue.jobs.first(where: { $0.id == job.id }) {
                do {
                    try CallRecordArchiveWriter.write(
                        job: completedJob,
                        allJobs: callRecordQueue.jobs
                    )
                } catch {
                    callRecordQueue.markFailed(
                        id: job.id,
                        message: "写入通话索引失败: \(error.localizedDescription)"
                    )
                }
            }
        } else if result.cancelled {
            callRecordQueue.markCancelled(id: job.id)
            callRecordQueue.pause()
            return
        } else {
            callRecordQueue.markFailed(
                id: job.id,
                message: result.errorMessage ?? "AI 整理失败"
            )
        }
        scheduleNextCallRecordJob()
    }

    private func scheduleNextCallRecordJob() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            runNextCallRecordJobIfNeeded()
        }
    }

    private var callRecordSummaryModel: LLMModel? {
        let preferredIDs = [
            settingsManager.lastSummaryModelID,
            settingsManager.selectedModel,
            summaryModelID,
        ].filter { !$0.isEmpty }
        for id in preferredIDs {
            if let model = settingsManager.customModels.first(where: { $0.id == id }) {
                return model
            }
        }
        return settingsManager.customModels.first
    }

    private func callRecordArchiveRoot() -> URL? {
        guard !customOutputDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: customOutputDir, isDirectory: true)
    }

    // MARK: - People Archive Tab

    private var peopleTab: some View {
        PersonTimelineView(
            store: personTimelineStore,
            runner: personOrganizationRunner,
            settingsManager: settingsManager,
            pythonPath: envChecker.pythonPath,
            summarizeScriptPath: Bundle.main.url(forResource: "summarize", withExtension: "py")?.path ?? "",
            onChooseArchive: choosePersonArchiveRoot
        )
    }

    private func choosePersonArchiveRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try personTimelineStore.openArchive(url)
                UserDefaults.standard.set(url.path, forKey: "lastPersonArchiveRoot")
            } catch {
                personTimelineStore.present(error)
            }
        }
    }

    private func openLastPersonArchiveRootIfAvailable() {
        guard let path = UserDefaults.standard.string(forKey: "lastPersonArchiveRoot"),
              !path.isEmpty else {
            return
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("call_index.json").path) else {
            return
        }

        do {
            try personTimelineStore.openArchive(root)
        } catch {
            personTimelineStore.present(error)
        }
    }

    @MainActor
    private func reloadPersonArchiveIfNeeded(writtenArchiveRoot: URL) {
        guard let currentArchiveRoot = personTimelineStore.archiveRoot,
              canonicalArchiveRoot(writtenArchiveRoot) == canonicalArchiveRoot(currentArchiveRoot) else {
            return
        }

        do {
            try personTimelineStore.reload()
        } catch {
            personTimelineStore.present(error)
        }
    }

    private func canonicalArchiveRoot(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: - Logs Tab

    private var logTab: some View {
        VStack(spacing: 14) {
            LogView(
                logs: transcriber.logs,
                currentProgress: transcriber.currentProgress,
                progress: transcriber.progress,
                isRunning: transcriber.isTranscribing || transcriber.isSummarizing,
                outputDir: transcriber.currentOutputDir,
                onClear: { transcriber.clearLogs() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 10) {
                statusPill(
                    icon: "waveform.path.ecg",
                    title: "阶段",
                    value: transcriber.currentProgress.isEmpty ? "等待任务" : transcriber.currentProgress,
                    color: "8E81F6"
                )
                statusPill(
                    icon: "text.line.first.and.arrowtriangle.forward",
                    title: "日志行",
                    value: "\(transcriber.logs.count)",
                    color: "4EC9B0"
                )
                if let eta = transcriber.estimatedTimeRemaining {
                    statusPill(icon: "timer", title: "预计", value: eta, color: "F5A623")
                }
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
        }
        .padding(.top, 8)
    }

    private func statusPill(icon: String, title: String, value: String, color: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: color))
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "A0A0B0"))
            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.05))
        .cornerRadius(7)
    }

    // MARK: - Editor Tab (交互校对编辑器)

    @ViewBuilder
    private var editorTab: some View {
        if !transcriber.speakerRolesReady {
            VStack(spacing: 16) {
                Spacer()
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundColor(Color(hex: "A0A0B0").opacity(0.5))
                Text("暂无正在校对的逐字稿")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Text("请到工作台上传音频文件并开始转写。转写完成后，编辑器将自动解锁字音联动校对功能。")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                // Split pane layout: Left bubbles | Right insights (Resizable using HSplitView)
                HSplitView {
                    // Left Conversational script editor
                    VStack(alignment: .leading, spacing: 0) {
                        ScrollView {
                            LazyVStack(spacing: 14) {
                                // Add SpeakerRolesCard at the very top of the list if we have roles!
                                if !transcriber.speakerRoles.isEmpty {
                                    SpeakerRolesCard(
                                        roles: transcriber.speakerRoles,
                                        feedback: speakerRoleFeedback,
                                        isApplying: isApplyingSpeakerNames,
                                        enrollingRoleID: enrollingVoiceprintRoleID,
                                        enrolledRoleIDs: enrolledVoiceprintRoleIDs,
                                        onChange: { id, newName in
                                            transcriber.updateSpeakerRole(id: id, displayName: newName)
                                        },
                                        onApply: {
                                            applySpeakerNamesToOutput()
                                        },
                                        onEnroll: { role in
                                            enrollVoiceprint(role)
                                        },
                                        onAddRole: {
                                            transcriber.addNewSpeakerRole()
                                        }
                                    )
                                    .padding(.bottom, 8)
                                }

                                ForEach(transcriber.currentTranscriptSegments.indices, id: \.self) { index in
                                    let segment = transcriber.currentTranscriptSegments[index]
                                    segmentRow(index: index, segment: segment)
                                }
                            }
                            .padding(.vertical, 16)
                        }
                    }
                    .frame(minWidth: 400, maxWidth: .infinity)

                    // Right AI insights panel
                    AIInsightsPanel(transcriber: transcriber, settingsManager: settingsManager, envChecker: envChecker)
                        .frame(minWidth: 300, maxWidth: .infinity)
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity)

                // Bottom Audio Controller Panel (translucent bar)
                BottomPlaybackControlBar()
            }
        }
    }

    private func segmentRow(index: Int, segment: TranscriptSegment) -> some View {
        let isSpeakerA = segment.placeholder.contains("A")
        return HStack(alignment: .top, spacing: 14) {
            // Timecode clickable badge
            Button(action: {
                transcriber.seekAudio(to: segment.start)
            }) {
                VStack(spacing: 2) {
                    Text(formatTimecode(segment.start))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(Color(hex: "8E81F6"))
                    Text(String(format: "%.1f秒", max(0.1, segment.end - segment.start)))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(Color(hex: "A0A0B0"))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(Color(hex: "8E81F6").opacity(0.12))
                .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                // Speaker badge + Edit controls
                HStack(alignment: .center) {
                    Menu {
                        ForEach(transcriber.speakerRoles) { role in
                            Button(action: {
                                transcriber.updateSegmentSpeaker(index: index, role: role)
                            }) {
                                Text(role.displayName.isEmpty ? role.placeholder : role.displayName)
                            }
                        }
                    } label: {
                        let speakerName = getSpeakerName(placeholder: segment.placeholder)
                        Text(speakerName)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(isSpeakerA ? Color(hex: "d4bbff") : Color(hex: "80f7dc"))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(isSpeakerA ? Color(hex: "552f97").opacity(0.4) : Color(hex: "005144").opacity(0.4))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isSpeakerA ? Color(hex: "d4bbff").opacity(0.2) : Color(hex: "80f7dc").opacity(0.2), lineWidth: 1)
                            )
                    }
                    .menuStyle(.borderlessButton)

                    Spacer()

                    if editingIndex == index {
                        HStack(spacing: 8) {
                            Button(action: {
                                transcriber.updateSegmentText(index: index, newText: editingText)
                                editingIndex = nil
                            }) {
                                Text("保存")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color(hex: "4EC9B0"))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(hex: "4EC9B0").opacity(0.15))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)

                            Button(action: {
                                editingIndex = nil
                            }) {
                                Text("取消")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(Color(hex: "F08A8A"))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color(hex: "F08A8A").opacity(0.15))
                                    .cornerRadius(4)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        HStack(spacing: 8) {
                            Button(action: {
                                transcriber.playAudio(from: segment.start)
                            }) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(Color(hex: "8E81F6"))
                                    .frame(width: 20, height: 20)
                                    .background(Color(hex: "8E81F6").opacity(0.14))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .help("从此段开始播放")

                            Button(action: {
                                editingIndex = index
                                editingText = segment.text
                            }) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10))
                                    .foregroundColor(Color(hex: "A0A0B0"))
                                    .padding(4)
                                    .background(Color.white.opacity(0.05))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity)

                // Segment Text content
                if editingIndex == index {
                    TextField("", text: $editingText, axis: .vertical)
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .padding(8)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(6)
                        .textFieldStyle(.plain)
                } else {
                    Text(segment.text)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.95))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .onTapGesture(count: 2) {
                            editingIndex = index
                            editingText = segment.text
                        }
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.02))
        .cornerRadius(10)
    }

    private func getSpeakerName(placeholder: String) -> String {
        if let role = transcriber.speakerRoles.first(where: { $0.placeholder == placeholder }) {
            return role.displayName.isEmpty ? role.placeholder : role.displayName
        }
        return placeholder
    }

    private func formatTimecode(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "[%02d:%02d]", total / 60, total % 60)
    }

    // MARK: - Bottom Playback Control Bar

    private func BottomPlaybackControlBar() -> some View {
        let duration = max(transcriber.audioDuration, 0)
        let sliderRange = 0...max(duration, 1)
        let playbackPosition = Binding<Double>(
            get: {
                min(max(transcriber.currentPlaybackTime, 0), max(duration, 1))
            },
            set: { newValue in
                transcriber.seekAudio(to: newValue)
            }
        )

        return VStack(spacing: 8) {
            // Waveform
            WaveformVisualizer(isAnimating: transcriber.isAudioPlaying)
                .padding(.horizontal, 8)

            // Audio Controls
            HStack(spacing: 14) {
                HStack(spacing: 16) {
                    // Playback toggles
                    Button(action: {
                        transcriber.toggleAudioPlayback()
                    }) {
                        Image(systemName: transcriber.isAudioPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(Color(hex: "8E81F6"))
                            .shadow(color: Color(hex: "8E81F6").opacity(0.4), radius: 6)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(formatDuration(transcriber.currentPlaybackTime)) / \(formatDuration(transcriber.audioDuration))")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(Color(hex: "8E81F6"))
                        Text("字音同步连结中")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Color(hex: "A0A0B0"))
                    }
                }

                HStack(spacing: 8) {
                    Text(formatDuration(transcriber.currentPlaybackTime))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(hex: "A0A0B0"))
                        .frame(width: 42, alignment: .trailing)

                    Slider(value: playbackPosition, in: sliderRange)
                        .tint(Color(hex: "8E81F6"))
                        .disabled(duration <= 0)
                        .help("拖动跳转播放位置")
                        .frame(minWidth: 180)

                    Text(formatDuration(duration))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(Color(hex: "A0A0B0"))
                        .frame(width: 42, alignment: .leading)
                }
                .frame(maxWidth: .infinity)

                // Speed selection
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "A0A0B0"))

                    ForEach([0.8, 1.0, 1.5, 2.0], id: \.self) { rate in
                        let isActive = abs(transcriber.playbackSpeed - rate) < 0.05
                        Button(action: {
                            transcriber.setAudioPlaybackSpeed(rate)
                        }) {
                            Text(String(format: "%.1fx", rate))
                                .font(.system(size: 10, weight: isActive ? .bold : .regular))
                                .foregroundColor(isActive ? Color(hex: "8E81F6") : Color(hex: "A0A0B0"))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(isActive ? Color(hex: "8E81F6").opacity(0.12) : Color.clear)
                                .cornerRadius(4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
        .background(Color(hex: "1E1E2E").opacity(0.8))
        .overlay(
            VStack {
                Divider().background(Color.white.opacity(0.08))
                Spacer()
            }
        )
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - Settings Tab (设置面板)

    private var settingsTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Models configurations card
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Image(systemName: "sparkles")
                            .foregroundColor(Color(hex: "8E81F6"))
                        Text("自定义摘要大模型 (LLM)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    }

                    Text("可以接入支持 OpenAI/Anthropic 协议的各种本地与云端模型。配置保存后，摘要生成器将自动调用此处的模型配置。")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "A0A0B0"))

                    // Simple custom models additions UI placeholder
                    // Linked directly to settingsManager
                    SettingsPanel(
                        outputDir: $customOutputDir,
                        settingsManager: settingsManager,
                        onBrowseOutput: { showingFolderPicker = true },
                        onPickPython: { showingPythonPicker = true },
                        onAutoDetectPython: {},
                        onClearPython: {}
                    )
                }
                .padding(18)
                .background(Color(hex: "1E1E2E").opacity(0.6))
                .cornerRadius(12)
            }
            .padding(24)
        }
    }

    private var voiceprintTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VoiceprintLibraryPanel(
                    store: voiceprintStore,
                    pythonPath: settingsManager.pythonPath,
                    scriptsDir: transcriber.bundleScriptsDir
                )
            }
            .padding(24)
        }
    }

    private func enrollVoiceprint(_ role: SpeakerRole) {
        guard enrollingVoiceprintRoleID == nil else { return }
        let displayName = role.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakerName = displayName.isEmpty ? role.placeholder : displayName
        enrollingVoiceprintRoleID = role.id
        speakerRoleFeedback = SpeakerRoleActionFeedback(
            message: "正在将 \(speakerName) 加入声纹库...",
            kind: .info
        )

        transcriber.saveTranscriptionChanges()

        Task { @MainActor in
            let result = await voiceprintStore.enroll(
                role: role,
                audioURL: transcriber.currentAudioURL,
                speakerMapURL: transcriber.currentSpeakerMapURL,
                pythonPath: settingsManager.pythonPath,
                scriptsDir: transcriber.bundleScriptsDir
            )
            enrollingVoiceprintRoleID = nil
            if result.success {
                enrolledVoiceprintRoleIDs.insert(role.id)
            }
            speakerRoleFeedback = SpeakerRoleActionFeedback(
                message: result.message,
                kind: result.success ? .success : .error
            )
        }
    }

    private func applySpeakerNamesToOutput() {
        guard !isApplyingSpeakerNames else { return }
        isApplyingSpeakerNames = true
        speakerRoleFeedback = SpeakerRoleActionFeedback(
            message: "正在重写整理版文本...",
            kind: .info
        )

        let result = transcriber.applySpeakerNames()
        isApplyingSpeakerNames = false
        speakerRoleFeedback = SpeakerRoleActionFeedback(
            message: result.message,
            kind: result.success ? .success : .error
        )
    }
}

// MARK: - Core components definitions copies for completeness

private enum SpeakerRoleActionFeedbackKind {
    case info
    case success
    case error
}

private struct SpeakerRoleActionFeedback {
    let message: String
    let kind: SpeakerRoleActionFeedbackKind
}

private struct SpeakerRolesCard: View {
    let roles: [SpeakerRole]
    let feedback: SpeakerRoleActionFeedback?
    let isApplying: Bool
    let enrollingRoleID: String?
    let enrolledRoleIDs: Set<String>
    var onChange: (String, String) -> Void
    var onApply: () -> Void
    var onEnroll: (SpeakerRole) -> Void
    var onAddRole: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundColor(Color(hex: "8E81F6"))
                Text("角色命名优化")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    onApply()
                }) {
                    HStack(spacing: 6) {
                        if isApplying {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11))
                        }
                        Text(isApplying ? "应用中" : "应用到整理版")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isApplying)
            }

            Text("转写后会先生成角色A、角色B、角色C。你可以在这里改成真实姓名或身份，整理版文本和后续摘要都会优先使用这些名称。")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "A0A0B0"))

            ForEach(roles) { role in
                let isEnrolling = enrollingRoleID == role.id
                let isEnrolled = enrolledRoleIDs.contains(role.id)
                HStack(spacing: 10) {
                    Text(role.placeholder)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: "A0A0B0"))
                        .frame(width: 70, alignment: .leading)

                    TextField(role.placeholder, text: Binding(
                        get: { role.displayName },
                        set: { onChange(role.id, $0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color(hex: "12121A"))
                    .cornerRadius(6)

                    Button(action: { onEnroll(role) }) {
                        HStack(spacing: 4) {
                            if isEnrolling {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: isEnrolled ? "checkmark.circle.fill" : "waveform.badge.plus")
                                    .font(.system(size: 11))
                            }
                            Text(isEnrolling ? "加入中" : (isEnrolled ? "已加入" : "加入声纹库"))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(isEnrolled ? Color(hex: "8E81F6") : Color(hex: "4EC9B0"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background((isEnrolled ? Color(hex: "8E81F6") : Color(hex: "4EC9B0")).opacity(0.12))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .disabled(isEnrolling || enrollingRoleID != nil)
                }
            }

            if let onAddRole = onAddRole {
                Button(action: onAddRole) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11))
                        Text("添加新角色")
                    }
                    .foregroundColor(Color(hex: "8E81F6"))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(hex: "8E81F6").opacity(0.12))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }

            if let feedback {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: feedbackIcon(for: feedback.kind))
                        .font(.system(size: 11, weight: .semibold))
                    Text(feedback.message)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundColor(feedbackColor(for: feedback.kind))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(feedbackColor(for: feedback.kind).opacity(0.12))
                .cornerRadius(8)
            }
        }
        .padding(16)
        .background(Color(hex: "1E1E2E"))
        .cornerRadius(12)
        .padding(.horizontal, 24)
    }

    private func feedbackIcon(for kind: SpeakerRoleActionFeedbackKind) -> String {
        switch kind {
        case .info: return "clock.arrow.circlepath"
        case .success: return "checkmark.seal.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func feedbackColor(for kind: SpeakerRoleActionFeedbackKind) -> Color {
        switch kind {
        case .info: return Color(hex: "8E81F6")
        case .success: return Color(hex: "4EC9B0")
        case .error: return Color(hex: "F14C4C")
        }
    }
}

private struct VoiceprintLibraryPanel: View {
    @ObservedObject var store: VoiceprintStore
    let pythonPath: String
    let scriptsDir: URL
    @State private var captureSpeakerName = ""
    @State private var importSourceType: VoiceprintCaptureSourceType = .meeting
    @State private var selectedProfile: VoiceprintProfile? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "waveform.circle.fill")
                    .foregroundColor(Color(hex: "4EC9B0"))
                Text("本地声纹库")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Button(action: {
                    Task {
                        await store.checkDependencies(pythonPath: pythonPath, scriptsDir: scriptsDir)
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checklist")
                        Text(store.isWorking ? "检查中" : "检查依赖")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(hex: "4EC9B0").opacity(0.18))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(store.isWorking)

                Button(action: {
                    NSWorkspace.shared.open(store.libraryDir)
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "A0A0B0"))
                        .padding(7)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            Text("声纹库会保存用户确认过的角色样本。依赖会安装到 VoiceScribe 独立 Python 环境，不写入系统 Python；模型缺失时只有点击安装才会下载。")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "A0A0B0"))

            Text(store.libraryDir.path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(Color(hex: "A0A0B0"))
                .lineLimit(1)
                .truncationMode(.middle)

            VoiceprintCaptureCard(
                speakerName: $captureSpeakerName,
                importSourceType: $importSourceType,
                isRecording: store.isRecording,
                isWorking: store.isWorking,
                microphonePermissionStatus: store.microphonePermissionStatus,
                requestMicrophonePermission: {
                    store.requestMicrophonePermission()
                },
                startRecording: {
                    store.startRecording(speakerName: captureSpeakerName)
                },
                stopRecording: {
                    Task {
                        await store.stopRecordingAndCollect(
                            speakerName: captureSpeakerName,
                            pythonPath: pythonPath,
                            scriptsDir: scriptsDir
                        )
                    }
                },
                importAudio: {
                    openVoiceprintImportPanel()
                }
            )

            if let report = store.dependencyReport {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: report.ready ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(report.ready ? Color(hex: "4EC9B0") : Color(hex: "F5A623"))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.ready ? "声纹模型依赖已就绪" : "声纹模型依赖缺失")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                            if !report.missing.isEmpty {
                                Text(report.missing.joined(separator: ", "))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Color(hex: "A0A0B0"))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if !report.dependencies.isEmpty {
                        VStack(spacing: 6) {
                            ForEach(report.dependencies) { dependency in
                                VoiceprintDependencyRow(
                                    dependency: dependency,
                                    isWorking: store.isWorking,
                                    installAction: {
                                        store.installDependency(dependency, pythonPath: pythonPath)
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color(hex: "12121A"))
                .cornerRadius(8)
            }

            if !store.message.isEmpty {
                Text(store.message)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
            }

            if store.profiles.isEmpty {
                Text("暂无声纹 profile。完成转写后，在角色命名卡中点击“加入声纹库”。")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: "12121A"))
                    .cornerRadius(8)
            } else {
                ForEach(store.profiles) { profile in
                    HStack(spacing: 10) {
                        Image(systemName: "person.wave.2.fill")
                            .foregroundColor(Color(hex: "4EC9B0"))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                            Text("\(profile.sourceSummary) · \(profile.embeddingStatus == "ready" ? "特征已生成" : "等待特征提取")")
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "A0A0B0"))
                        }
                        Spacer()
                        Text("\(profile.samples.count) 段")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Color(hex: "4EC9B0"))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(hex: "4EC9B0").opacity(0.12))
                            .cornerRadius(4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color(hex: "A0A0B0"))
                    }
                    .padding(10)
                    .background(Color(hex: "12121A"))
                    .cornerRadius(8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedProfile = profile
                    }
                }
            }
        }
        .padding(18)
        .background(Color(hex: "1E1E2E").opacity(0.6))
        .cornerRadius(12)
        .sheet(item: $selectedProfile) { profile in
            VoiceprintProfileDetailView(profile: profile, store: store)
        }
    }

    private func openVoiceprintImportPanel() {
        let name = captureSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            store.message = "请先填写人物名称"
            return
        }
        let panel = NSOpenPanel()
        panel.title = "选择要加入声纹库的录音"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.audio, .movie]
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await store.collectVoiceprintSample(
                    speakerName: name,
                    audioURL: url,
                    sourceType: importSourceType,
                    pythonPath: pythonPath,
                    scriptsDir: scriptsDir
                )
            }
        }
    }
}

private struct VoiceprintCaptureCard: View {
    @Binding var speakerName: String
    @Binding var importSourceType: VoiceprintCaptureSourceType
    let isRecording: Bool
    let isWorking: Bool
    let microphonePermissionStatus: String
    let requestMicrophonePermission: () -> Void
    let startRecording: () -> Void
    let stopRecording: () -> Void
    let importAudio: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "waveform.badge.plus")
                    .foregroundColor(Color(hex: "4EC9B0"))
                Text("声纹采集")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                if isRecording {
                    Label("录制中", systemImage: "record.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "FF5C5C"))
                }
            }

            TextField("人物名称，例如：张三", text: $speakerName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .padding(9)
                .background(Color(hex: "12121A"))
                .cornerRadius(7)

            HStack(spacing: 8) {
                Label("麦克风：\(microphonePermissionStatus)", systemImage: microphoneIconName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(microphoneStatusColor)
                Spacer()
                Button(action: requestMicrophonePermission) {
                    HStack(spacing: 4) {
                        Image(systemName: microphonePermissionStatus == "已授权" ? "checkmark.circle" : "lock.open")
                        Text(microphoneButtonTitle)
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(microphoneButtonColor.opacity(0.18))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isWorking || isRecording || microphonePermissionStatus == "已授权")
            }
            .padding(8)
            .background(Color.white.opacity(0.04))
            .cornerRadius(7)

            HStack(spacing: 6) {
                ForEach(VoiceprintCaptureSourceType.allCases) { sourceType in
                    Button(action: { importSourceType = sourceType }) {
                        HStack(spacing: 4) {
                            Image(systemName: sourceType.iconName)
                            Text(sourceType.shortTitle)
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(importSourceType == sourceType ? Color(hex: "4EC9B0") : Color(hex: "A0A0B0"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(importSourceType == sourceType ? Color(hex: "4EC9B0").opacity(0.12) : Color.white.opacity(0.04))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                Button(action: isRecording ? stopRecording : startRecording) {
                    HStack(spacing: 5) {
                        Image(systemName: isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        Text(isRecording ? "停止并保存" : "直接录制")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(isRecording ? Color(hex: "FF5C5C").opacity(0.25) : Color(hex: "4EC9B0").opacity(0.18))
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)

                Button(action: importAudio) {
                    HStack(spacing: 5) {
                        Image(systemName: "tray.and.arrow.down")
                        Text("导入录音")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color(hex: "8E81F6").opacity(0.16))
                    .cornerRadius(7)
                }
                .buttonStyle(.plain)
                .disabled(isWorking || isRecording)
            }

            Text("直接录制会保存为近场样本；导入录音会按上面的来源标签保存到同一个人名下。")
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "A0A0B0"))
        }
        .padding(10)
        .background(Color(hex: "12121A"))
        .cornerRadius(8)
    }

    private var microphoneButtonTitle: String {
        switch microphonePermissionStatus {
        case "已授权":
            return "已授权"
        case "已拒绝", "受限制":
            return "打开设置"
        default:
            return "授权麦克风"
        }
    }

    private var microphoneIconName: String {
        switch microphonePermissionStatus {
        case "已授权":
            return "mic.fill"
        case "已拒绝", "受限制":
            return "mic.slash.fill"
        default:
            return "mic"
        }
    }

    private var microphoneStatusColor: Color {
        switch microphonePermissionStatus {
        case "已授权":
            return Color(hex: "4EC9B0")
        case "已拒绝", "受限制":
            return Color(hex: "FF5C5C")
        default:
            return Color(hex: "F5A623")
        }
    }

    private var microphoneButtonColor: Color {
        microphonePermissionStatus == "已授权" ? Color(hex: "4EC9B0") : Color(hex: "8E81F6")
    }
}

private struct VoiceprintDependencyRow: View {
    let dependency: VoiceprintDependency
    let isWorking: Bool
    let installAction: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: dependency.ready ? "checkmark.circle.fill" : iconName)
                .font(.system(size: 12))
                .foregroundColor(dependency.ready ? Color(hex: "4EC9B0") : Color(hex: "F5A623"))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(dependency.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(statusText)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if dependency.ready {
                Text("已安装")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "4EC9B0"))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color(hex: "4EC9B0").opacity(0.12))
                    .cornerRadius(5)
            } else {
                Button(action: installAction) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle")
                        Text("安装")
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(hex: "4EC9B0").opacity(0.18))
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .help(dependency.installCommand)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.04))
        .cornerRadius(7)
    }

    private var iconName: String {
        switch dependency.kind {
        case "model":
            return "cube.box"
        case "system_binary":
            return "terminal"
        default:
            return "shippingbox"
        }
    }

    private var statusText: String {
        if dependency.ready, let detectedPath = dependency.detectedPath, !detectedPath.isEmpty {
            return detectedPath
        }
        return dependency.ready ? "可用" : dependency.description
    }
}

private struct CompletionSummaryCard: View {
    let summary: TranscriptionCompletionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(Color(hex: "4EC9B0"))
                Text("转写完成")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                if let speed = summary.speedRatio {
                    Text(speed)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(Color(hex: "8E81F6"))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(hex: "8E81F6").opacity(0.15))
                        .cornerRadius(6)
                }
            }

            HStack(spacing: 16) {
                summaryChip(icon: "clock", label: "耗时", value: summary.elapsedFormatted)
                if let dur = summary.audioDurationFormatted {
                    summaryChip(icon: "waveform", label: "音频", value: dur)
                }
                if summary.segmentCount > 0 {
                    summaryChip(icon: "text.alignleft", label: "片段", value: "\(summary.segmentCount)")
                }
                if summary.speakerCount > 0 {
                    summaryChip(icon: "person.2", label: "说话人", value: "\(summary.speakerCount)")
                }
            }

            HStack(spacing: 6) {
                Text(summary.engine)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "8E81F6"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(hex: "8E81F6").opacity(0.12))
                    .cornerRadius(4)
                Text(summary.modelID)
                    .font(.system(size: 10))
                    .foregroundColor(Color(hex: "A0A0B0"))
            }
        }
        .padding(14)
        .background(Color(hex: "1E1E2E"))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(hex: "4EC9B0").opacity(0.3), lineWidth: 1)
        )
        .cornerRadius(12)
        .padding(.horizontal, 24)
    }

    private func summaryChip(icon: String, label: String, value: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "8E81F6"))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(Color(hex: "A0A0B0"))
        }
        .frame(minWidth: 50)
        .padding(8)
        .background(Color(hex: "12121A"))
        .cornerRadius(8)
    }
}

struct PythonExecutablePicker: NSViewRepresentable {
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

struct VoiceprintProfileDetailView: View {
    let profile: VoiceprintProfile
    @ObservedObject var store: VoiceprintStore
    @Environment(\.presentationMode) var presentationMode

    enum DeletionTarget: Identifiable {
        case profile
        case sample(VoiceprintSample)

        var id: String {
            switch self {
            case .profile:
                return "profile"
            case .sample(let sample):
                return "sample-\(sample.path)"
            }
        }
    }

    @State private var deletionTarget: DeletionTarget? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "person.crop.circle.badge.questionmark.fill")
                    .font(.system(size: 22))
                    .foregroundColor(Color(hex: "4EC9B0"))
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.displayName)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                    Text("声纹 ID: \(profile.id) · \(profile.embeddingStatus == "ready" ? "特征已生成" : "等待特征提取")")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "A0A0B0"))
                }
                Spacer()
                Button(action: {
                    store.stopPlayingSample()
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(Color(hex: "A0A0B0"))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(hex: "1E1E2E"))

            Divider()
                .background(Color.white.opacity(0.08))

            // Body ScrollView
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Profile Info Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("基本信息")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "8E81F6"))

                        VStack(alignment: .leading, spacing: 6) {
                            infoRow(label: "创建时间", value: formatDate(profile.createdAt))
                            infoRow(label: "更新时间", value: formatDate(profile.updatedAt))
                            if let model = profile.embeddingModel {
                                infoRow(label: "声纹模型", value: model)
                            }
                            if !profile.sourceAudio.isEmpty {
                                HStack(alignment: .top) {
                                    Text("来源音频")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "A0A0B0"))
                                        .frame(width: 70, alignment: .leading)
                                    Text(profile.sourceAudio)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.white)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    if FileManager.default.fileExists(atPath: profile.sourceAudio) {
                                        Button(action: {
                                            NSWorkspace.shared.selectFile(profile.sourceAudio, inFileViewerRootedAtPath: "")
                                        }) {
                                            Image(systemName: "arrow.right.circle.fill")
                                                .foregroundColor(Color(hex: "4EC9B0"))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color(hex: "12121A"))
                        .cornerRadius(8)
                    }

                    // Samples List
                    VStack(alignment: .leading, spacing: 8) {
                        Text("声纹样本 (\(profile.samples.count)个)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color(hex: "8E81F6"))

                        ForEach(Array(profile.samples.enumerated()), id: \.offset) { index, sample in
                            HStack(spacing: 12) {
                                // Play Button
                                Button(action: {
                                    store.playSample(path: sample.path)
                                }) {
                                    Image(systemName: store.playingSamplePath == sample.path ? "stop.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(store.playingSamplePath == sample.path ? Color(hex: "FF5C5C") : Color(hex: "4EC9B0"))
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(sample.sourceTitle ?? "转写片段")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(sourceBadgeColor(sample.sourceType).opacity(0.15))
                                            .cornerRadius(3)

                                        if let durationText = getSampleDurationText(path: sample.path) {
                                            Text(durationText)
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundColor(Color(hex: "4EC9B0"))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color(hex: "4EC9B0").opacity(0.12))
                                                .cornerRadius(3)
                                        }

                                        if let capturedAt = sample.capturedAt {
                                            Text(formatDate(capturedAt))
                                                .font(.system(size: 10))
                                                .foregroundColor(Color(hex: "A0A0B0"))
                                        }
                                    }

                                    Text(sample.path)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundColor(Color(hex: "A0A0B0"))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }

                                Spacer()

                                // Finder Button
                                if FileManager.default.fileExists(atPath: sample.path) {
                                    Button(action: {
                                        NSWorkspace.shared.selectFile(sample.path, inFileViewerRootedAtPath: "")
                                    }) {
                                        Image(systemName: "folder")
                                            .font(.system(size: 11))
                                            .foregroundColor(Color(hex: "A0A0B0"))
                                            .padding(5)
                                            .background(Color.white.opacity(0.05))
                                            .cornerRadius(4)
                                    }
                                    .buttonStyle(.plain)
                                    .help("在 Finder 中显示样本")
                                }

                                // Delete Sample Button
                                Button(action: {
                                    deletionTarget = .sample(sample)
                                }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "FF5C5C").opacity(0.8))
                                        .padding(5)
                                        .background(Color(hex: "FF5C5C").opacity(0.1))
                                        .cornerRadius(4)
                                }
                                .buttonStyle(.plain)
                                .help("删除此样本")
                            }
                            .padding(8)
                            .background(Color(hex: "12121A"))
                            .cornerRadius(8)
                        }
                    }
                }
                .padding(20)
            }

            Divider()
                .background(Color.white.opacity(0.08))

            // Footer / Deletion Area
            HStack {
                Button(action: {
                    deletionTarget = .profile
                }) {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("删除声纹")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(hex: "FF5C5C").opacity(0.2))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(hex: "FF5C5C").opacity(0.3), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                Button("关闭") {
                    store.stopPlayingSample()
                    presentationMode.wrappedValue.dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color(hex: "1E1E2E"))
        }
        .frame(width: 550, height: 460)
        .background(Color(hex: "2A2A3C"))
        .alert(item: $deletionTarget) { target in
            switch target {
            case .profile:
                return Alert(
                    title: Text("确认删除整个人物声纹？"),
                    message: Text("此操作将永久删除人物「\(profile.displayName)」的声纹信息及所有关联的样本文件。"),
                    primaryButton: .destructive(Text("彻底删除")) {
                        store.deleteProfile(profile)
                        presentationMode.wrappedValue.dismiss()
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .sample(let sample):
                return Alert(
                    title: Text("确认删除样本？"),
                    message: Text("此操作将永久从磁盘删除该声纹样本音频，且不可撤销。"),
                    primaryButton: .destructive(Text("删除")) {
                        store.deleteSample(sample, from: profile)
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "A0A0B0"))
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .foregroundColor(.white)
        }
    }

    private func sourceBadgeColor(_ type: String?) -> Color {
        switch type {
        case "direct": return Color(hex: "4EC9B0")
        case "call": return Color(hex: "FFD35C")
        case "meeting": return Color(hex: "8E81F6")
        case "transcript": return Color(hex: "5CB3FF")
        default: return Color(hex: "A0A0B0")
        }
    }

    private func formatDate(_ isoString: String) -> String {
        let cleaner = isoString.replacingOccurrences(of: "Z", with: "")
        let parts = cleaner.components(separatedBy: "T")
        if parts.count == 2 {
            let datePart = parts[0]
            let timePart = parts[1].prefix(8)
            return "\(datePart) \(timePart)"
        }
        return isoString
    }

    private func getSampleDurationText(path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            return nil
        }
        return String(format: "%.1f秒", player.duration)
    }
}
