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

    var body: some View {
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

            if settingsManager.transcriptionEngine == .vibeVoiceMLX {
                HStack(spacing: 10) {
                    Spacer()
                        .frame(width: 86)
                    Text("MLX 引擎同样通过 Python 启动，但检测与安装将按 VibeVoice MLX 路线进行。")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "A0A0B0"))
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
