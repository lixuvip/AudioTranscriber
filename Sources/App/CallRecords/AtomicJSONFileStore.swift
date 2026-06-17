import Foundation

/// 原子 JSON 持久化（临时文件 + 原子替换 + .backup 回退）。
///
/// 编解码统一使用 snake_case（`convertToSnakeCase` / `convertFromSnakeCase`）。这两者对
/// 「驼峰 + 尾部缩写」的键名**不可逆**：`modelID → model_id → modelId ≠ modelID`。
/// 因此任何含此类属性的模型都必须显式声明 `CodingKeys`，并映射到 `convertFromSnakeCase`
/// 产出的驼峰形式（本仓库约定示例：`case modelID = "modelId"`、`case callIDs = "callIds"`）。
/// `save(_:to:)` 在写盘前会做一次「编码 → 解码」往返校验；若模型未遵守该约定，会抛出
/// `StoreError.nonRoundTrippingKeys` 并中止写入，而不是把会丢键的数据落到磁盘。
enum AtomicJSONFileStore {
    static func load<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        defaultValue: T
    ) -> JSONLoadResult<T> {
        let fileManager = FileManager.default
        let backupURL = backupURL(for: url)

        guard fileManager.fileExists(atPath: url.path) else {
            guard fileManager.fileExists(atPath: backupURL.path) else {
                return JSONLoadResult(value: defaultValue, access: .writable)
            }

            do {
                return JSONLoadResult(
                    value: try decode(type, from: backupURL),
                    access: .recoveredFromBackup
                )
            } catch {
                return JSONLoadResult(
                    value: defaultValue,
                    access: .readOnly(
                        reason: "主文件不存在，备份文件无法读取（\(error.localizedDescription)），已进入只读模式。"
                    )
                )
            }
        }

        do {
            return JSONLoadResult(
                value: try decode(type, from: url),
                access: .writable
            )
        } catch {
            let primaryError = error
            do {
                return JSONLoadResult(
                    value: try decode(type, from: backupURL),
                    access: .recoveredFromBackup
                )
            } catch {
                let reason = """
                主文件无法读取（\(primaryError.localizedDescription)），\
                备份文件也无法读取（\(error.localizedDescription)），已进入只读模式。
                """
                return JSONLoadResult(
                    value: defaultValue,
                    access: .readOnly(reason: reason)
                )
            }
        }
    }

    static func save<T: Codable & Equatable>(_ value: T, to url: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let encoder = makeEncoder()
        let data = try encoder.encode(value)
        let decoded: T
        do {
            decoded = try makeDecoder().decode(T.self, from: data)
        } catch {
            // 解码失败基本都是「驼峰缩写属性 + 缺显式 CodingKeys」导致：snake_case 策略
            // 不可逆（modelID→model_id→modelId），重解码找不到键。给出可操作的诊断，
            // 而非把含义不明的 keyNotFound 抛给上层。
            throw StoreError.nonRoundTrippingKeys(
                type: String(describing: T.self),
                detail: String(describing: error)
            )
        }
        guard decoded == value else {
            throw StoreError.roundTripMismatch
        }

        if fileManager.fileExists(atPath: url.path),
           (try? decode(T.self, from: url)) != nil {
            try updateBackup(from: url, fileManager: fileManager)
        }

        let temporaryURL = directoryURL.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: temporaryURL)
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(
                    url,
                    withItemAt: temporaryURL
                )
            } else {
                try fileManager.moveItem(at: temporaryURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func decode<T: Decodable>(
        _ type: T.Type,
        from url: URL
    ) throws -> T {
        let data = try Data(contentsOf: url)
        return try makeDecoder().decode(type, from: data)
    }

    private static func updateBackup(
        from url: URL,
        fileManager: FileManager
    ) throws {
        let backupURL = backupURL(for: url)
        let directoryURL = url.deletingLastPathComponent()
        let temporaryBackupURL = directoryURL.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).backup.tmp"
        )

        do {
            try fileManager.copyItem(at: url, to: temporaryBackupURL)
            if fileManager.fileExists(atPath: backupURL.path) {
                _ = try fileManager.replaceItemAt(
                    backupURL,
                    withItemAt: temporaryBackupURL
                )
            } else {
                try fileManager.moveItem(at: temporaryBackupURL, to: backupURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryBackupURL)
            throw error
        }
    }

    private static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("backup")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalDateFormatter.string(from: date))
        }
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            if let date = fractionalDateFormatter.date(from: dateString)
                ?? wholeSecondDateFormatter.date(from: dateString) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO8601 date: \(dateString)"
            )
        }
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private static let fractionalDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }()

    private static let wholeSecondDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    enum StoreError: Error, Equatable, LocalizedError {
        case roundTripMismatch
        case nonRoundTrippingKeys(type: String, detail: String)

        var errorDescription: String? {
            switch self {
            case .roundTripMismatch:
                return "编码后再解码的结果与原值不一致，已中止写入以避免数据损坏。"
            case .nonRoundTrippingKeys(let type, _):
                return "\(type) 存在无法在 snake_case 策略下往返的键，已中止写入。"
                    + "请为驼峰缩写属性（如 modelID/personID）添加显式 CodingKeys，"
                    + "并映射到驼峰形式（例如 case modelID = \"modelId\"）。"
            }
        }
    }
}
