import Foundation
import Combine

enum RuntimeEnvironment: String, CaseIterable, Identifiable {
    case macAppleSilicon
    case windowsCompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macAppleSilicon:
            return "Mac"
        case .windowsCompatible:
            return "Windows/通用"
        }
    }

    var description: String {
        switch self {
        case .macAppleSilicon:
            return "Apple Silicon Mac，优先支持 MLX 模型"
        case .windowsCompatible:
            return "Windows 或跨平台 Python 环境，优先使用 FunASR"
        }
    }
}

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case funASR
    case vibeVoiceMLX

    var id: String { rawValue }

    var title: String {
        switch self {
        case .funASR:
            return "FunASR + cam++"
        case .vibeVoiceMLX:
            return "VibeVoice MLX"
        }
    }

    var description: String {
        switch self {
        case .funASR:
            return "支持 cam++ 说话人区分，适合会议转写"
        case .vibeVoiceMLX:
            return "Apple Silicon 优化，支持说话人和时间戳"
        }
    }

    static func available(for environment: RuntimeEnvironment) -> [TranscriptionEngine] {
        switch environment {
        case .macAppleSilicon:
            return [.vibeVoiceMLX, .funASR]
        case .windowsCompatible:
            return [.funASR]
        }
    }

    var defaultModelID: String {
        switch self {
        case .funASR:
            return "paraformer-zh + cam++"
        case .vibeVoiceMLX:
            return "mlx-community/VibeVoice-ASR-4bit"
        }
    }
}

enum LLMProviderType: String, CaseIterable, Codable, Identifiable {
    case openAICompatible
    case openAIResponses
    case anthropicMessages

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAICompatible:
            return "OpenAI Compatible"
        case .openAIResponses:
            return "OpenAI Responses"
        case .anthropicMessages:
            return "Anthropic Messages"
        }
    }
}

@MainActor
class SettingsManager: ObservableObject {
    @Published var selectedModel: String {
        didSet { UserDefaults.standard.set(selectedModel, forKey: "selectedModel") }
    }

    @Published var customModels: [LLMModel] {
        didSet { saveCustomModels() }
    }

    @Published var pythonPath: String {
        didSet { UserDefaults.standard.set(pythonPath, forKey: "pythonPath") }
    }

    @Published var runtimeEnvironment: RuntimeEnvironment {
        didSet { UserDefaults.standard.set(runtimeEnvironment.rawValue, forKey: "runtimeEnvironment") }
    }

    @Published var transcriptionEngine: TranscriptionEngine {
        didSet { UserDefaults.standard.set(transcriptionEngine.rawValue, forKey: "transcriptionEngine") }
    }

    @Published var transcriptionModelID: String {
        didSet { UserDefaults.standard.set(transcriptionModelID, forKey: "transcriptionModelID") }
    }

    @Published var summaryPrompt: String {
        didSet { UserDefaults.standard.set(summaryPrompt, forKey: "summaryPrompt") }
    }

    @Published var performanceTier: String {
        didSet { UserDefaults.standard.set(performanceTier, forKey: "performanceTier") }
    }

    init() {
        let saved = UserDefaults.standard.string(forKey: "selectedModel") ?? ""
        selectedModel = saved

        if let data = UserDefaults.standard.data(forKey: "customModels"),
           let models = try? JSONDecoder().decode([LLMModel].self, from: data) {
            customModels = models
        } else {
            customModels = []
        }

        pythonPath = UserDefaults.standard.string(forKey: "pythonPath") ?? ""
        let savedRuntimeEnvironment = RuntimeEnvironment(rawValue: UserDefaults.standard.string(forKey: "runtimeEnvironment") ?? "") ?? .macAppleSilicon
        runtimeEnvironment = savedRuntimeEnvironment

        let savedEngine = TranscriptionEngine(rawValue: UserDefaults.standard.string(forKey: "transcriptionEngine") ?? "")
        let allowedEngines = TranscriptionEngine.available(for: savedRuntimeEnvironment)
        let resolvedEngine = allowedEngines.contains(savedEngine ?? .funASR) ? (savedEngine ?? allowedEngines[0]) : allowedEngines[0]
        transcriptionEngine = resolvedEngine

        let savedModelID = UserDefaults.standard.string(forKey: "transcriptionModelID") ?? ""
        transcriptionModelID = savedModelID.isEmpty ? resolvedEngine.defaultModelID : savedModelID
        summaryPrompt = UserDefaults.standard.string(forKey: "summaryPrompt") ?? ""
        let savedTier = UserDefaults.standard.string(forKey: "performanceTier") ?? ""
        performanceTier = PerformanceTier.allCases.contains(where: { $0.rawValue == savedTier }) ? savedTier : ""
    }

    var allModels: [(id: String, name: String)] {
        var result: [(id: String, name: String)] = []
        for m in customModels {
            result.append((m.id, m.name))
        }
        return result
    }

    private func saveCustomModels() {
        if let data = try? JSONEncoder().encode(customModels) {
            UserDefaults.standard.set(data, forKey: "customModels")
        }
        if selectedModel.isEmpty, let first = customModels.first {
            selectedModel = first.id
        } else if !selectedModel.isEmpty,
                  !customModels.contains(where: { $0.id == selectedModel }) {
            selectedModel = customModels.first?.id ?? ""
        }
    }

    func addModel(id: String, name: String, apiBase: String, apiKey: String, providerType: LLMProviderType) {
        let model = LLMModel(id: id, name: name, apiBase: apiBase, apiKey: apiKey, providerType: providerType)
        if !customModels.contains(where: { $0.id == id }) {
            customModels.append(model)
            if selectedModel.isEmpty {
                selectedModel = id
            }
        }
    }

    func removeModel(at offsets: IndexSet) {
        customModels.remove(atOffsets: offsets)
    }

    func deleteModel(id: String) {
        customModels.removeAll { $0.id == id }
    }

    func availableTranscriptionEngines() -> [TranscriptionEngine] {
        TranscriptionEngine.available(for: runtimeEnvironment)
    }

    func updateRuntimeEnvironment(_ environment: RuntimeEnvironment) {
        runtimeEnvironment = environment
        let allowedEngines = availableTranscriptionEngines()
        if !allowedEngines.contains(transcriptionEngine), let first = allowedEngines.first {
            transcriptionEngine = first
            transcriptionModelID = first.defaultModelID
        }
    }

    func updateTranscriptionEngine(_ engine: TranscriptionEngine) {
        transcriptionEngine = engine
        if transcriptionModelID.isEmpty || transcriptionModelID == transcriptionEngine.defaultModelID {
            transcriptionModelID = engine.defaultModelID
        }
    }
}

struct LLMModel: Codable, Identifiable {
    var id: String
    var name: String
    var apiBase: String
    var apiKey: String
    var providerType: LLMProviderType
}
