import Foundation
import Combine

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

    private let defaultModels = [
        ("qwen-plus", "通义千问-plus"),
        ("qwen-turbo", "通义千问-turbo"),
        ("qwen-max", "通义千问-max"),
        ("claude-3-haiku-20240307", "Claude 3 Haiku"),
        ("gpt-4o-mini", "GPT-4o mini"),
    ]

    init() {
        let saved = UserDefaults.standard.string(forKey: "selectedModel") ?? "qwen-plus"
        selectedModel = saved

        if let data = UserDefaults.standard.data(forKey: "customModels"),
           let models = try? JSONDecoder().decode([LLMModel].self, from: data) {
            customModels = models
        } else {
            customModels = []
        }

        pythonPath = UserDefaults.standard.string(forKey: "pythonPath") ?? ""
    }

    var allModels: [(id: String, name: String)] {
        var result = defaultModels
        for m in customModels {
            result.append((m.id, m.name))
        }
        return result
    }

    private func saveCustomModels() {
        if let data = try? JSONEncoder().encode(customModels) {
            UserDefaults.standard.set(data, forKey: "customModels")
        }
    }

    func addModel(id: String, name: String, apiBase: String) {
        let model = LLMModel(id: id, name: name, apiBase: apiBase)
        if !customModels.contains(where: { $0.id == id }) {
            customModels.append(model)
        }
    }

    func removeModel(at offsets: IndexSet) {
        customModels.remove(atOffsets: offsets)
    }
}

struct LLMModel: Codable, Identifiable {
    var id: String
    var name: String
    var apiBase: String
}
