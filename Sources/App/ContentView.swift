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
