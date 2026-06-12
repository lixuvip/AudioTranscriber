import SwiftUI

struct SettingsPanel: View {
    @Binding var outputDir: String
    @ObservedObject var settingsManager: SettingsManager
    var onBrowseOutput: () -> Void
    var onPickPython: () -> Void
    var onAutoDetectPython: () -> Void
    var onClearPython: () -> Void

    @State private var showingAddModel = false
    @State private var newModelName = ""
    @State private var newModelId = ""
    @State private var newModelApiBase = ""
    @State private var newModelApiKey = ""
    @State private var newModelProviderType = LLMProviderType.openAICompatible

    @State private var remoteToken = ""
    @State private var connectionStatus = ""
    @State private var connectionColor = "A0A0B0"
    @State private var isTestingConnection = false

    private func normalizedURL(_ value: String) -> URL? {
        var normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedValue.isEmpty { return nil }
        if !normalizedValue.lowercased().hasPrefix("http://") && !normalizedValue.lowercased().hasPrefix("https://") {
            normalizedValue = "http://" + normalizedValue
        }
        return URL(string: normalizedValue)
    }

    private func loadTokenFromKeychain() {
        let store = VoiceScribeKeychainStore()
        if settingsManager.executionTarget == .relay {
            if let url = normalizedURL(settingsManager.relayServiceURL),
               let saved = try? store.token(for: url), !saved.isEmpty {
                remoteToken = saved
                return
            }
        } else {
            if let url = normalizedURL(settingsManager.remoteServiceURL),
               let saved = try? store.token(for: url), !saved.isEmpty {
                remoteToken = saved
                return
            }
            if let tsUrl = normalizedURL(settingsManager.remoteTailscaleURL),
               let saved = try? store.token(for: tsUrl), !saved.isEmpty {
                remoteToken = saved
                return
            }
        }
        remoteToken = ""
    }

    private func saveTokenToKeychain() {
        let store = VoiceScribeKeychainStore()
        if settingsManager.executionTarget == .relay {
            if let url = normalizedURL(settingsManager.relayServiceURL) {
                do {
                    if remoteToken.isEmpty {
                        try store.deleteToken(for: url)
                    } else {
                        try store.saveToken(remoteToken, for: url)
                    }
                } catch {
                    print("Keychain save failed for relayServiceURL: \(error)")
                }
            }
        } else {
            if let url = normalizedURL(settingsManager.remoteServiceURL) {
                do {
                    if remoteToken.isEmpty {
                        try store.deleteToken(for: url)
                    } else {
                        try store.saveToken(remoteToken, for: url)
                    }
                } catch {
                    print("Keychain save failed for remoteServiceURL: \(error)")
                }
            }
            if let tsUrl = normalizedURL(settingsManager.remoteTailscaleURL) {
                do {
                    if remoteToken.isEmpty {
                        try store.deleteToken(for: tsUrl)
                    } else {
                        try store.saveToken(remoteToken, for: tsUrl)
                    }
                } catch {
                    print("Keychain save failed for remoteTailscaleURL: \(error)")
                }
            }
        }
    }

    private func testConnection() {
        saveTokenToKeychain()
        isTestingConnection = true
        connectionStatus = "正在测试..."
        connectionColor = "7C6FE3"
        Task {
            let client = RemoteTranscriberClient()
            
            if settingsManager.executionTarget == .relay {
                let relayClean = settingsManager.relayServiceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if relayClean.isEmpty {
                    connectionStatus = "中转服务器地址为空"
                    connectionColor = "F08A8A"
                    isTestingConnection = false
                    return
                }
                do {
                    let health = try await client.health(serviceURL: relayClean, isRelay: true, timeout: 5)
                    await MainActor.run {
                        settingsManager.updateRemoteAvailableEngines(with: health.availableEngines)
                    }
                    connectionStatus = "连接中转服务器成功 ✓ (队列: \(health.queueDepth)人)"
                    connectionColor = "4EC9B0"
                } catch {
                    connectionStatus = "连接中转服务器失败 ✗: \(error.localizedDescription)"
                    connectionColor = "F08A8A"
                }
                isTestingConnection = false
                return
            }
            
            var primarySuccess = false
            var primaryQueue = 0
            var primaryError: Error?
            var activeHealth: VoiceScribeRemoteHealth?
            
            // 1. 测试局域网地址
            do {
                let health = try await client.health(serviceURL: settingsManager.remoteServiceURL, timeout: 5)
                primarySuccess = true
                primaryQueue = health.queueDepth
                activeHealth = health
            } catch {
                primaryError = error
            }
            
            if primarySuccess, let health = activeHealth {
                await MainActor.run {
                    settingsManager.updateRemoteAvailableEngines(with: health.availableEngines)
                }
                connectionStatus = "连接成功 ✓ (局域网, 队列: \(primaryQueue)人)"
                connectionColor = "4EC9B0"
                isTestingConnection = false
                return
            }
            
            // 2. 如果局域网失败，尝试测试 Tailscale 地址
            let tsAddress = settingsManager.remoteTailscaleURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tsAddress.isEmpty {
                do {
                    let health = try await client.health(serviceURL: tsAddress, timeout: 5)
                    await MainActor.run {
                        settingsManager.updateRemoteAvailableEngines(with: health.availableEngines)
                    }
                    connectionStatus = "连接成功 ✓ (Tailscale 降级, 队列: \(health.queueDepth)人)"
                    connectionColor = "4EC9B0"
                } catch {
                    connectionStatus = "局域网失败 (\(primaryError?.localizedDescription ?? "未知错误")), Tailscale 亦失败 ✗: \(error.localizedDescription)"
                    connectionColor = "F08A8A"
                }
            } else {
                connectionStatus = "局域网连接失败 ✗: \(primaryError?.localizedDescription ?? "未知错误")"
                connectionColor = "F08A8A"
            }
            isTestingConnection = false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 执行设备选择
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath.circle")
                    .foregroundColor(Color(hex: "7C6FE3"))
                    .frame(width: 16)
                Text("执行设备")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .frame(width: 60, alignment: .leading)

                Picker("", selection: $settingsManager.executionTarget) {
                    ForEach(ExecutionTarget.allCases) { target in
                        Text(target.title).tag(target)
                    }
                }
                .pickerStyle(.menu)
                .background(Color(hex: "1E1E2E"))
                .cornerRadius(6)
                .onChange(of: settingsManager.executionTarget) { _ in
                    loadTokenFromKeychain()
                }

                Spacer()
            }

            HStack(spacing: 10) {
                Image(systemName: "cpu")
                    .foregroundColor(Color(hex: "7C6FE3"))
                    .frame(width: 16)
                Text("引擎")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .frame(width: 60, alignment: .leading)

                Picker("", selection: Binding(
                    get: { settingsManager.transcriptionEngine },
                    set: { settingsManager.updateTranscriptionEngine($0) }
                )) {
                    ForEach(settingsManager.availableTranscriptionEngines()) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .pickerStyle(.menu)
                .background(Color(hex: "1E1E2E"))
                .cornerRadius(6)

                Text(settingsManager.transcriptionEngine.description)
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 10) {
                Image(systemName: "cube.box")
                    .foregroundColor(Color(hex: "7C6FE3"))
                    .frame(width: 16)
                Text("模型")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .frame(width: 60, alignment: .leading)

                TextField("模型 ID 或别名", text: $settingsManager.transcriptionModelID)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color(hex: "1E1E2E"))
                    .cornerRadius(6)
            }

            HStack(spacing: 10) {
                Image(systemName: "person.2.wave.2")
                    .foregroundColor(Color(hex: "7C6FE3"))
                    .frame(width: 16)
                Text("说话人区分")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .frame(width: 60, alignment: .leading)

                Toggle("", isOn: $settingsManager.speakerDiarizationEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: Color(hex: "7C6FE3")))
                    .labelsHidden()

                Text(settingsManager.speakerDiarizationEnabled ? "已开启 (区分并提取说话人角色和时间戳)" : "已关闭")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
            }

            if settingsManager.executionTarget == .remote || settingsManager.executionTarget == .relay {
                VStack(alignment: .leading, spacing: 8) {
                    if settingsManager.executionTarget == .relay {
                        HStack(spacing: 10) {
                            Spacer().frame(width: 16)
                            Text("中转服务器")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "A0A0B0"))
                                .frame(width: 60, alignment: .leading)
                            
                            TextField("https://api.example.com", text: $settingsManager.relayServiceURL)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color(hex: "1E1E2E"))
                                .cornerRadius(6)
                                .onChange(of: settingsManager.relayServiceURL) { _ in
                                    loadTokenFromKeychain()
                                }
                        }
                        .padding(.leading, 10)
                    } else {
                        HStack(spacing: 10) {
                            Spacer().frame(width: 16)
                            Text("服务器地址")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "A0A0B0"))
                                .frame(width: 60, alignment: .leading)
                            
                            TextField("http://192.168.3.79:8766", text: $settingsManager.remoteServiceURL)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color(hex: "1E1E2E"))
                                .cornerRadius(6)
                                .onChange(of: settingsManager.remoteServiceURL) { _ in
                                    loadTokenFromKeychain()
                                }
                        }
                        .padding(.leading, 10)

                        HStack(spacing: 10) {
                            Spacer().frame(width: 16)
                            Text("Tailscale地址")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "A0A0B0"))
                                .frame(width: 60, alignment: .leading)
                            
                            TextField("http://100.x.y.z:8766 (选填)", text: $settingsManager.remoteTailscaleURL)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(8)
                                .background(Color(hex: "1E1E2E"))
                                .cornerRadius(6)
                                .onChange(of: settingsManager.remoteTailscaleURL) { _ in
                                    loadTokenFromKeychain()
                                }
                        }
                        .padding(.leading, 10)
                    }

                    HStack(spacing: 10) {
                        Spacer().frame(width: 16)
                        Text(settingsManager.executionTarget == .relay ? "中转访问令牌" : "访问令牌")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "A0A0B0"))
                            .frame(width: 60, alignment: .leading)
                        
                        SecureField(settingsManager.executionTarget == .relay ? "中转服务器访问令牌 Bearer Token" : "在 Mac mini 上配置的 Bearer Token", text: $remoteToken)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color(hex: "1E1E2E"))
                            .cornerRadius(6)
                            .onChange(of: remoteToken) { _ in
                                saveTokenToKeychain()
                            }
                    }
                    .padding(.leading, 10)

                    HStack(spacing: 10) {
                        Spacer().frame(width: 86)
                        
                        Button(action: testConnection) {
                            Text("测试连接")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .background(Color(hex: "7C6FE3"))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                        .disabled(isTestingConnection)

                        if !connectionStatus.isEmpty {
                            Text(connectionStatus)
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: connectionColor))
                        }
                        
                        Spacer()
                    }
                    .padding(.leading, 10)
                }
                .transition(.opacity.combined(with: .slide))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "desktopcomputer")
                            .foregroundColor(Color(hex: "7C6FE3"))
                            .frame(width: 16)
                        Text("环境")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(hex: "A0A0B0"))
                            .frame(width: 60, alignment: .leading)

                        Picker("", selection: Binding(
                            get: { settingsManager.runtimeEnvironment },
                            set: { settingsManager.updateRuntimeEnvironment($0) }
                        )) {
                            ForEach(RuntimeEnvironment.allCases) { environment in
                                Text(environment.title).tag(environment)
                            }
                        }
                        .pickerStyle(.menu)
                        .background(Color(hex: "1E1E2E"))
                        .cornerRadius(6)

                        Text(settingsManager.runtimeEnvironment.description)
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "A0A0B0"))
                    }



                    // Python 路径
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .foregroundColor(Color(hex: "7C6FE3"))
                            .frame(width: 16)
                        Text("Python")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(hex: "A0A0B0"))
                            .frame(width: 60, alignment: .leading)

                        TextField("自动检测或手动选择", text: $settingsManager.pythonPath)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color(hex: "1E1E2E"))
                            .cornerRadius(6)

                        Button(action: onAutoDetectPython) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "A0A0B0"))
                                .padding(8)
                                .background(Color(hex: "1E1E2E"))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        Button(action: onPickPython) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "A0A0B0"))
                                .padding(8)
                                .background(Color(hex: "1E1E2E"))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)

                        Button(action: onClearPython) {
                            Image(systemName: "xmark.circle")
                                .font(.system(size: 12))
                                .foregroundColor(Color(hex: "A0A0B0"))
                                .padding(8)
                                .background(Color(hex: "1E1E2E"))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }

                    if settingsManager.transcriptionEngine.isMLXBased {
                        HStack(spacing: 10) {
                            Spacer()
                                .frame(width: 86)
                            Text("MLX 引擎同样通过 Python 启动，检测与安装会按当前选择的转写路线进行。")
                                .font(.system(size: 11))
                                .foregroundColor(Color(hex: "A0A0B0"))
                        }
                    }
                }
            }

            // 输出目录
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundColor(Color(hex: "7C6FE3"))
                    .frame(width: 16)
                Text("输出")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .frame(width: 60, alignment: .leading)

                TextField("默认保存在音频同目录", text: $outputDir)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color(hex: "1E1E2E"))
                    .cornerRadius(6)

                Button(action: onBrowseOutput) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "A0A0B0"))
                        .padding(8)
                        .background(Color(hex: "1E1E2E"))
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            // LLM 模型
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "brain")
                        .foregroundColor(Color(hex: "7C6FE3"))
                        .frame(width: 16)
                    Text("LLM")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: "A0A0B0"))
                        .frame(width: 60, alignment: .leading)

                    Spacer()

                    Button(action: { showingAddModel = true }) {
                        HStack(spacing: 4) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 12))
                            Text("添加模型")
                                .font(.system(size: 12))
                        }
                        .foregroundColor(Color(hex: "7C6FE3"))
                    }
                    .buttonStyle(.plain)
                }

                if settingsManager.customModels.isEmpty {
                    Text("请添加线上模型以使用摘要功能")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "A0A0B0"))
                        .padding(.leading, 86)
                } else {
                    ForEach(settingsManager.customModels) { model in
                        let isSelected = model.id == settingsManager.selectedModel
                        HStack(spacing: 10) {
                            Button(action: {
                                settingsManager.selectedModel = model.id
                            }) {
                                HStack(spacing: 10) {
                                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 16))
                                        .foregroundColor(isSelected ? Color(hex: "7C6FE3") : Color(hex: "5A5A6C"))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(model.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(.white)
                                        Text("\(model.id) · \(model.providerType.title)")
                                            .font(.system(size: 10))
                                            .foregroundColor(Color(hex: "A0A0B0"))
                                    }
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button(action: {
                                settingsManager.deleteModel(id: model.id)
                            }) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "F08A8A"))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                        .padding(.leading, 76)
                        .background(isSelected ? Color(hex: "2A2A4C") : Color(hex: "1E1E2E"))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? Color(hex: "7C6FE3") : Color.clear, lineWidth: 1)
                        )
                    }
                }
            }

            if !settingsManager.customModels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "text.bubble")
                            .foregroundColor(Color(hex: "7C6FE3"))
                            .frame(width: 16)
                        Text("摘要提示")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(hex: "A0A0B0"))
                            .frame(width: 60, alignment: .leading)

                        TextField("可选：补充摘要要求，例如重点关注待办、风险、决策", text: $settingsManager.summaryPrompt, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(Color(hex: "1E1E2E"))
                            .cornerRadius(6)
                    }

                    HStack(spacing: 10) {
                        Spacer()
                            .frame(width: 86)
                        Text("示例：请重点整理决策事项和待办；请按角色分别总结观点；请保留争议点和风险点")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "A0A0B0"))
                    }
                }
            }
        }
        .padding(14)
        .background(Color(hex: "2A2A3C"))
        .cornerRadius(12)
        .padding(.horizontal, 24)
        .sheet(isPresented: $showingAddModel) {
            AddModelSheet(
                name: $newModelName,
                id: $newModelId,
                apiBase: $newModelApiBase,
                apiKey: $newModelApiKey,
                providerType: $newModelProviderType,
                onSave: {
                    settingsManager.addModel(
                        id: newModelId,
                        name: newModelName,
                        apiBase: newModelApiBase,
                        apiKey: newModelApiKey,
                        providerType: newModelProviderType
                    )
                    newModelName = ""
                    newModelId = ""
                    newModelApiBase = ""
                    newModelApiKey = ""
                    newModelProviderType = .openAICompatible
                    showingAddModel = false
                }
            )
        }
        .onAppear {
            loadTokenFromKeychain()
        }
    }
}

struct AddModelSheet: View {
    @Binding var name: String
    @Binding var id: String
    @Binding var apiBase: String
    @Binding var apiKey: String
    @Binding var providerType: LLMProviderType
    var onSave: () -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("添加自定义模型")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 4) {
                Text("模型名称")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                TextField("", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model ID")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                TextField("", text: $id)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("接口形态")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                Picker("", selection: $providerType) {
                    ForEach(LLMProviderType.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API Base URL")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                TextField("", text: $apiBase)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API Token / Key")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                SecureField("", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Button("添加") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || id.isEmpty || apiBase.isEmpty || apiKey.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(Color(hex: "2A2A3C"))
    }
}
