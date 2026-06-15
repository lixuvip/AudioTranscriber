import Foundation

struct CallRecordMetadata: Codable, Equatable, Identifiable {
    var id: String { "\(normalizedPhone)_\(timestampDigits)" }
    let originalFileName: String
    let contactName: String?
    let rawPhone: String
    let normalizedPhone: String
    let callDate: Date
    let timestampDigits: String

    var displayName: String {
        let trimmed = contactName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? rawPhone : trimmed
    }

    var timestampText: String {
        Self.displayDateFormatter.string(from: callDate)
    }

    var monthPathComponent: String {
        Self.monthFormatter.string(from: callDate)
    }

    var yearPathComponent: String {
        Self.yearFormatter.string(from: callDate)
    }

    var directorySlug: String {
        let datePart = Self.slugDateFormatter.string(from: callDate)
        let identityPart = contactName.map { "\($0)_\(normalizedPhone)" } ?? normalizedPhone
        return "\(datePart)_\(Self.sanitizePathComponent(identityPart))"
    }

    private static let displayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let slugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    private static func sanitizePathComponent(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
            .union(.newlines)
            .union(.controlCharacters)
        return value
            .components(separatedBy: invalid)
            .joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CallRecordFilenameParser {
    static func parse(fileURL: URL) -> CallRecordMetadata? {
        parse(fileName: fileURL.lastPathComponent)
    }

    static func parse(fileName: String) -> CallRecordMetadata? {
        let baseName = (fileName as NSString).deletingPathExtension
        guard let separator = baseName.lastIndex(of: "_") else { return nil }

        let identityPart = String(baseName[..<separator])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = String(baseName[baseName.index(after: separator)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard timestamp.range(of: #"^\d{14}$"#, options: .regularExpression) != nil,
              !identityPart.isEmpty,
              let callDate = timestampFormatter.date(from: timestamp) else {
            return nil
        }

        let contactName: String?
        let rawPhone: String
        if let atIndex = identityPart.firstIndex(of: "@") {
            let name = String(identityPart[..<atIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let phone = String(identityPart[identityPart.index(after: atIndex)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            contactName = name.isEmpty ? nil : name
            rawPhone = phone
        } else {
            contactName = nil
            rawPhone = identityPart
        }

        let normalizedPhone = rawPhone.filter(\.isNumber)
        guard normalizedPhone.count >= 5 else { return nil }

        return CallRecordMetadata(
            originalFileName: fileName,
            contactName: contactName,
            rawPhone: rawPhone,
            normalizedPhone: normalizedPhone,
            callDate: callDate,
            timestampDigits: timestamp
        )
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()
}

enum CallRecordJobStatus: String, Codable, CaseIterable {
    case pending
    case running
    case summarizing
    case completed
    case failed
    case cancelled
    case ignored

    var title: String {
        switch self {
        case .pending: return "等待中"
        case .running: return "转写中"
        case .summarizing: return "AI 整理中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .ignored: return "已忽略"
        }
    }
}

struct CallRecordBatchJob: Codable, Identifiable, Equatable {
    let id: String
    let sourcePath: String
    let outputDirectoryPath: String
    let metadata: CallRecordMetadata?
    var status: CallRecordJobStatus
    var durationSeconds: Double?
    var progress: Double
    var errorMessage: String?
    var engine: String
    var modelID: String
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?

    var sourceURL: URL {
        URL(fileURLWithPath: sourcePath)
    }

    var outputDirectoryURL: URL {
        URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
    }

    var displayName: String {
        metadata?.displayName ?? sourceURL.deletingPathExtension().lastPathComponent
    }

    var rawPhone: String {
        metadata?.rawPhone ?? ""
    }

    var callTimeText: String {
        metadata?.timestampText ?? "-"
    }

    var canRun: Bool {
        status == .pending || status == .failed || status == .cancelled
    }
}
