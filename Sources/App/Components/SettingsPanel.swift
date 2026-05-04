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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
            HStack(spacing: 10) {
                Image(systemName: "brain")
                    .foregroundColor(Color(hex: "7C6FE3"))
                    .frame(width: 16)
                Text("LLM")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: "A0A0B0"))
                    .frame(width: 60, alignment: .leading)

                Picker("", selection: $settingsManager.selectedModel) {
                    Text("qwen-plus").tag("qwen-plus")
                    Text("qwen-turbo").tag("qwen-turbo")
                    Text("qwen-max").tag("qwen-max")
                    Text("claude-3-haiku").tag("claude-3-haiku-20240307")
                    Text("gpt-4o-mini").tag("gpt-4o-mini")
                    ForEach(settingsManager.customModels) { m in
                        Text("\(m.name) (\(m.id))").tag(m.id)
                    }
                }
                .pickerStyle(.menu)
                .background(Color(hex: "1E1E2E"))
                .cornerRadius(6)

                Button(action: { showingAddModel = true }) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 14))
                        .foregroundColor(Color(hex: "7C6FE3"))
                }
                .buttonStyle(.plain)
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
                onSave: {
                    let m = LLMModel(id: newModelId, name: newModelName, apiBase: newModelApiBase)
                    if !settingsManager.customModels.contains(where: { $0.id == newModelId }) {
                        settingsManager.customModels.append(m)
                    }
                    newModelName = ""
                    newModelId = ""
                    newModelApiBase = ""
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
                TextField("例如：我的模型", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Model ID")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                TextField("例如：gpt-4o", text: $id)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("API Base URL")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "A0A0B0"))
                TextField("例如：https://api.openai.com/v1", text: $apiBase)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Button("添加") { onSave() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || id.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
        .background(Color(hex: "2A2A3C"))
    }
}
