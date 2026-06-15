import Foundation

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
        let decoded = try makeDecoder().decode(T.self, from: data)
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

    enum StoreError: Error, Equatable {
        case roundTripMismatch
    }
}
