import Foundation

@main
struct AtomicJSONFileStoreCheck {
    /// 含驼峰缩写属性、且按本仓库约定声明 CodingKeys —— 应能正常往返。
    struct GoodModel: Codable, Equatable {
        var id: String
        var modelID: String
        var callIDs: [String]

        enum CodingKeys: String, CodingKey {
            case id
            case modelID = "modelId"
            case callIDs = "callIds"
        }
    }

    /// 含驼峰缩写属性但用合成 CodingKeys —— save 应拦截并抛 nonRoundTrippingKeys。
    struct BadModel: Codable, Equatable {
        var id: String
        var modelID: String
    }

    static func main() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AtomicStoreCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1) 合规模型：保存后能读回，且磁盘键为 snake_case。
        let goodURL = dir.appendingPathComponent("good.json")
        let good = GoodModel(id: "x", modelID: "m1", callIDs: ["a", "b"])
        try AtomicJSONFileStore.save(good, to: goodURL)
        let loaded = AtomicJSONFileStore.load(
            GoodModel.self,
            from: goodURL,
            defaultValue: GoodModel(id: "", modelID: "", callIDs: [])
        )
        guard loaded.value == good else {
            fatalError("good 模型未能往返: \(loaded.value)")
        }
        let raw = try String(contentsOf: goodURL, encoding: .utf8)
        guard raw.contains("model_id"), raw.contains("call_ids") else {
            fatalError("磁盘键应为 snake_case，实际:\n\(raw)")
        }
        print("✅ 合规模型往返正确，磁盘键为 snake_case")

        // 2) 不合规模型：save 应抛 nonRoundTrippingKeys，且不写出文件。
        let badURL = dir.appendingPathComponent("bad.json")
        do {
            try AtomicJSONFileStore.save(BadModel(id: "x", modelID: "m"), to: badURL)
            fatalError("BadModel 本应抛 nonRoundTrippingKeys，却成功写入")
        } catch let error as AtomicJSONFileStore.StoreError {
            guard case .nonRoundTrippingKeys = error else {
                fatalError("期望 nonRoundTrippingKeys，实际 \(error)")
            }
            guard !FileManager.default.fileExists(atPath: badURL.path) else {
                fatalError("写入应被中止，但 bad.json 仍被创建")
            }
            print("✅ 不合规模型被拦截：\(error.localizedDescription)")
        }

        print("AtomicJSONFileStoreCheck passed")
    }
}
