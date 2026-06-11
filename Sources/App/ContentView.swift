import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @StateObject private var envChecker = EnvironmentChecker()
    @StateObject private var transcriber = Transcriber()
    @StateObject private var settingsManager = SettingsManager()
    @StateObject private var historyManager = HistoryManager()

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

    private var outputDir: URL? {
        customOutputDir.isEmpty ? nil : URL(fileURLWithPath: customOutputDir)
    }

    private var effectiveOutputDir: URL? {
        outputDir ?? selectedFileURL?.deletingLastPathComponent()
    }

    enum MainTab {
        case workspace
        case batchQueue
        case editor
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
                            case .editor:
                                editorTab
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
        }
        .onChange(of: transcriber.pendingHistoryEntry) { entry in
            if let entry = entry {
                historyManager.add(entry)
                transcriber.pendingHistoryEntry = nil
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
        case .editor: return "交互校对编辑器"
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
                            onChange: { id, newName in
                                transcriber.updateSpeakerRole(id: id, displayName: newName)
                            },
                            onApply: {
                                transcriber.applySpeakerNames()
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
                LogView(logs: transcriber.logs)
                    .frame(minHeight: 180)
                
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

    // MARK: - Batch Queue Tab (批量队列 - 炫酷占位)
    
    private var batchQueueTab: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Text("🗂️")
                .font(.system(size: 64))
                .shadow(color: Color(hex: "8E81F6").opacity(0.5), radius: 10)
            
            Text("多文件并行批量转写队列")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            Text("支持批量拖入多个音视频文件，后台按队列顺序自动、高性能本地离线转写。")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: "A0A0B0"))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            
            VStack(alignment: .leading, spacing: 10) {
                mockQueueRow(file: "01_会议录音_Q3规划.m4a", status: "已完成 ✓", color: "4EC9B0")
                mockQueueRow(file: "02_播客访谈_探讨大模型.mp3", status: "等待中...", color: "A0A0B0")
                mockQueueRow(file: "03_视频花絮_产品Demo.mp4", status: "等待中...", color: "A0A0B0")
            }
            .padding(14)
            .background(Color(hex: "1E1E2E"))
            .cornerRadius(12)
            .frame(width: 400)
            
            Spacer()
        }
    }
    
    private func mockQueueRow(file: String, status: String, color: String) -> some View {
        HStack {
            Image(systemName: "doc.audiovisual.fill")
                .foregroundColor(Color(hex: "8E81F6"))
            Text(file)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
            Spacer()
            Text(status)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(hex: color))
        }
        .padding(.vertical, 4)
    }

    // MARK: - Editor Tab (交互校对编辑器)
    
    private var editorTab: some View {
        GeometryReader { geo in
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
                                            onChange: { id, newName in
                                                transcriber.updateSpeakerRole(id: id, displayName: newName)
                                            },
                                            onApply: {
                                                transcriber.applySpeakerNames()
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
    }
    
    private func segmentRow(index: Int, segment: TranscriptSegment) -> some View {
        let isSpeakerA = segment.placeholder.contains("A")
        return HStack(alignment: .top, spacing: 14) {
            // Timecode clickable badge
            Button(action: {
                transcriber.seekAudio(to: segment.start)
            }) {
                Text(formatTimecode(segment.start))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "8E81F6"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(hex: "8E81F6").opacity(0.12))
                    .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 6) {
                // Speaker badge + Edit controls
                HStack(alignment: .center) {
                    Menu {
                        ForEach(transcriber.speakerRoles) { role in
                            Button(action: {
                                transcriber.updateSpeakerRole(id: segment.speakerKey, displayName: role.displayName)
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
        VStack(spacing: 8) {
            // Waveform
            WaveformVisualizer(isAnimating: transcriber.isAudioPlaying)
                .padding(.horizontal, 8)
            
            // Audio Controls
            HStack {
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
                
                Spacer()
                
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
}

// MARK: - Core components definitions copies for completeness

private struct SpeakerRolesCard: View {
    let roles: [SpeakerRole]
    var onChange: (String, String) -> Void
    var onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundColor(Color(hex: "8E81F6"))
                Text("角色命名优化")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button("应用到整理版") {
                    onApply()
                }
                .buttonStyle(.borderedProminent)
            }

            Text("转写后会先生成角色A、角色B、角色C。你可以在这里改成真实姓名或身份，整理版文本和后续摘要都会优先使用这些名称。")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "A0A0B0"))

            ForEach(roles) { role in
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
                }
            }
        }
        .padding(16)
        .background(Color(hex: "1E1E2E"))
        .cornerRadius(12)
        .padding(.horizontal, 24)
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
