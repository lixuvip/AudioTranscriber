import Foundation

enum AtomicJSONFileStore {
    static func load<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        defaultValue: T
    ) -> JSONLoadResult<T> {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return JSONLoadResult(value: defaultValue, access: .writable)
        }

        do {
            return JSONLoadResult(
                value: try decode(type, from: url),
                access: .writable
            )
        } catch {
            let primaryError = error
            let backupURL = backupURL(for: url)
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

    static func save<T: Codable>(_ value: T, to url: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = url.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let encoder = makeEncoder()
        let data = try encoder.encode(value)
        _ = try makeDecoder().decode(T.self, from: data)

        if fileManager.fileExists(atPath: url.path) {
            let backupURL = backupURL(for: url)
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }
            try fileManager.copyItem(at: url, to: backupURL)
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

    private static func backupURL(for url: URL) -> URL {
        url.appendingPathExtension("backup")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
