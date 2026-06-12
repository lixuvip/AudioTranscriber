import Foundation
import Combine

enum ExecutionTarget: String, CaseIterable, Identifiable {
    case local
    case remote
    case relay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local:
            return "本机运行"
        case .remote:
            return "远程 Mac mini"
        case .relay:
            return "公网中转服务器"
        }
    }
}

enum RuntimeEnvironment: String, CaseIterable, Identifiable {
    case macAppleSilicon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macAppleSilicon:
            return "Mac"
        }
    }

    var description: String {
        switch self {
        case .macAppleSilicon:
            return "Apple Silicon Mac，优先支持 MLX 模型"
        }
    }
}

enum TranscriptionEngine: String, CaseIterable, Identifiable {
    case funASR
    case vibeVoiceMLX
    case qwen3ASR
    case qwen3ASRVoiceprint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .funASR:
            return "FunASR + cam++"
        case .vibeVoiceMLX:
            return "VibeVoice MLX"
        case .qwen3ASR:
            return "Qwen3-ASR"
        case .qwen3ASRVoiceprint:
            return "Qwen3-ASR + 声纹库"
        }
    }

    var description: String {
        switch self {
        case .funASR:
            return "本地转写引擎；paraformer 可配合 cam++ 区分说话人并生成角色段落，不读取声纹库。SenseVoice/Fun-ASR-Nano 仅做转写或弱分段。"
        case .vibeVoiceMLX:
            return "Apple Silicon MLX 本地转写；主要负责高效 ASR 和时间戳解析，当前不接入声纹库，不能直接用已采集声纹识别具体人物。"
        case .qwen3ASR:
            return "Apple Silicon MLX 转写引擎；可选 pyannote 做多说话人区分，适合中文和方言。声纹库暂不参与在线识别，只用于后续人物样本沉淀。"
        case .qwen3ASRVoiceprint:
            return "组合引擎：先用 Qwen3-ASR + pyannote 转写并区分说话人，再读取本地声纹库匹配已知人物；需要 SpeechBrain ECAPA 声纹模型。"
        }
    }

    static func available(for environment: RuntimeEnvironment) -> [TranscriptionEngine] {
        switch environment {
        case .macAppleSilicon:
            return [.vibeVoiceMLX, .qwen3ASR, .qwen3ASRVoiceprint, .funASR]
        }
    }

    var defaultModelID: String {
        switch self {
        case .funASR:
            return "paraformer-zh + cam++"
        case .vibeVoiceMLX:
            return "mlx-community/VibeVoice-ASR-4bit"
        case .qwen3ASR:
            return "Qwen/Qwen3-ASR-0.6B"
        case .qwen3ASRVoiceprint:
            return "Qwen/Qwen3-ASR-0.6B"
        }
    }

    var availableModelIDs: [String] {
        switch self {
        case .funASR:
            return [
                "paraformer-zh + cam++",
                "iic/speech_SenseVoiceSmall",
                "FunAudioLLM/Fun-ASR-Nano-2512",
            ]
        case .vibeVoiceMLX:
            return [
                "mlx-community/VibeVoice-ASR-4bit",
            ]
        case .qwen3ASR:
            return [
                "Qwen/Qwen3-ASR-0.6B",
                "Qwen/Qwen3-ASR-1.7B",
            ]
        case .qwen3ASRVoiceprint:
            return [
                "Qwen/Qwen3-ASR-0.6B",
                "Qwen/Qwen3-ASR-1.7B",
            ]
        }
    }

    var scriptEngineRawValue: String {
        switch self {
        case .qwen3ASRVoiceprint:
            return TranscriptionEngine.qwen3ASR.rawValue
        default:
            return rawValue
        }
    }

    var usesVoiceprintLibrary: Bool {
        self == .qwen3ASRVoiceprint
    }

    var isMLXBased: Bool {
        self == .vibeVoiceMLX || self == .qwen3ASR || self == .qwen3ASRVoiceprint
    }

    var isQwen3Based: Bool {
        self == .qwen3ASR || self == .qwen3ASRVoiceprint
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
    @Published var hfToken: String {
        didSet { UserDefaults.standard.set(hfToken, forKey: "hfToken") }
    }

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

    @Published var lastSummaryModelID: String {
        didSet { UserDefaults.standard.set(lastSummaryModelID, forKey: "lastSummaryModelID") }
    }

    @Published var executionTarget: ExecutionTarget {
        didSet { UserDefaults.standard.set(executionTarget.rawValue, forKey: "executionTarget") }
    }

    @Published var remoteServiceURL: String {
        didSet { UserDefaults.standard.set(remoteServiceURL, forKey: "remoteServiceURL") }
    }

    @Published var remoteTailscaleURL: String {
        didSet { UserDefaults.standard.set(remoteTailscaleURL, forKey: "remoteTailscaleURL") }
    }

    @Published var relayServiceURL: String {
        didSet { UserDefaults.standard.set(relayServiceURL, forKey: "relayServiceURL") }
    }

    @Published var speakerDiarizationEnabled: Bool {
        didSet { UserDefaults.standard.set(speakerDiarizationEnabled, forKey: "speakerDiarizationEnabled") }
    }

    @Published var remoteAvailableEngines: [TranscriptionEngine] = [.vibeVoiceMLX, .funASR, .qwen3ASR]

    init() {
        hfToken = UserDefaults.standard.string(forKey: "hfToken") ?? ""
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
        // Validate saved modelID matches the resolved engine; reset to default if not
        let validPrefixes: [String]
        switch resolvedEngine {
        case .funASR:       validPrefixes = ["paraformer", "fsmn", "iic/", "damo/", "funasr", "FunAudioLLM/"]
        case .vibeVoiceMLX: validPrefixes = ["mlx-community/VibeVoice", "mlx-community/Whisper"]
        case .qwen3ASR, .qwen3ASRVoiceprint:
            validPrefixes = ["Qwen/Qwen3-ASR", "Qwen/Qwen3-ForcedAligner"]
        }
        let isValid = savedModelID.isEmpty || validPrefixes.contains(where: { savedModelID.hasPrefix($0) })
        transcriptionModelID = isValid ? (savedModelID.isEmpty ? resolvedEngine.defaultModelID : savedModelID) : resolvedEngine.defaultModelID
        summaryPrompt = UserDefaults.standard.string(forKey: "summaryPrompt") ?? ""
        let savedTier = UserDefaults.standard.string(forKey: "performanceTier") ?? ""
        performanceTier = PerformanceTier.allCases.contains(where: { $0.rawValue == savedTier }) ? savedTier : ""
        lastSummaryModelID = UserDefaults.standard.string(forKey: "lastSummaryModelID") ?? ""

        let savedExecutionTarget = ExecutionTarget(rawValue: UserDefaults.standard.string(forKey: "executionTarget") ?? "") ?? .local
        executionTarget = savedExecutionTarget
        remoteServiceURL = UserDefaults.standard.string(forKey: "remoteServiceURL") ?? "http://192.168.3.79:8766"
        remoteTailscaleURL = UserDefaults.standard.string(forKey: "remoteTailscaleURL") ?? ""
        relayServiceURL = UserDefaults.standard.string(forKey: "relayServiceURL") ?? "https://api.example.com"
        remoteAvailableEngines = [.vibeVoiceMLX, .funASR, .qwen3ASR]
        
        if UserDefaults.standard.object(forKey: "speakerDiarizationEnabled") == nil {
            speakerDiarizationEnabled = true
        } else {
            speakerDiarizationEnabled = UserDefaults.standard.bool(forKey: "speakerDiarizationEnabled")
        }
    }

    func updateRemoteAvailableEngines(with rawList: [String]?) {
        guard let rawList = rawList else { return }
        let parsed = rawList.compactMap { TranscriptionEngine(rawValue: $0) }
        if !parsed.isEmpty {
            self.remoteAvailableEngines = parsed
            if !parsed.contains(transcriptionEngine) {
                transcriptionEngine = parsed[0]
                transcriptionModelID = parsed[0].defaultModelID
            }
        }
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
        if !lastSummaryModelID.isEmpty,
           !customModels.contains(where: { $0.id == lastSummaryModelID }) {
            lastSummaryModelID = customModels.first?.id ?? ""
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
        if executionTarget == .remote {
            return remoteAvailableEngines
        }
        return TranscriptionEngine.available(for: runtimeEnvironment)
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
        transcriptionModelID = engine.defaultModelID
    }
}

struct LLMModel: Codable, Identifiable {
    var id: String
    var name: String
    var apiBase: String
    var apiKey: String
    var providerType: LLMProviderType
}
