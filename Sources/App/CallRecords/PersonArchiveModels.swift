import Foundation

struct PeopleFile: Codable, Equatable {
    var schemaVersion: Int
    var people: [PersonRecord]
    var mergeHistory: [PersonMergeRecord]
    var unassignedPhoneNumbers: [String]

    init(
        schemaVersion: Int = 1,
        people: [PersonRecord] = [],
        mergeHistory: [PersonMergeRecord] = [],
        unassignedPhoneNumbers: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.people = people
        self.mergeHistory = mergeHistory
        self.unassignedPhoneNumbers = unassignedPhoneNumbers
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        people = try container.decodeIfPresent([PersonRecord].self, forKey: .people) ?? []
        mergeHistory = try container.decodeIfPresent(
            [PersonMergeRecord].self,
            forKey: .mergeHistory
        ) ?? []
        unassignedPhoneNumbers = try container.decodeIfPresent(
            [String].self,
            forKey: .unassignedPhoneNumbers
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case people
        case mergeHistory
        case unassignedPhoneNumbers
    }
}

struct PersonRecord: Codable, Equatable, Identifiable {
    var id: String
    var displayName: String
    var phoneNumbers: [String]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        displayName: String = "",
        phoneNumbers: [String] = [],
        createdAt: Date = personArchiveTimestamp(),
        updatedAt: Date = personArchiveTimestamp()
    ) {
        self.id = id
        self.displayName = displayName
        self.phoneNumbers = phoneNumbers
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct PersonMergeRecord: Codable, Equatable, Identifiable {
    var id: String
    var targetPersonID: String
    var beforePeople: [PersonRecord]
    var createdAt: Date
    var revertedAt: Date?

    init(
        id: String = UUID().uuidString,
        targetPersonID: String = "",
        beforePeople: [PersonRecord] = [],
        createdAt: Date = personArchiveTimestamp(),
        revertedAt: Date? = nil
    ) {
        self.id = id
        self.targetPersonID = targetPersonID
        self.beforePeople = beforePeople
        self.createdAt = createdAt
        self.revertedAt = revertedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case targetPersonID = "targetPersonId"
        case beforePeople
        case createdAt
        case revertedAt
    }
}

struct SelectionDraftsFile: Codable, Equatable {
    var schemaVersion: Int
    var drafts: [String: PersonSelectionDraft]

    init(
        schemaVersion: Int = 1,
        drafts: [String: PersonSelectionDraft] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.drafts = drafts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        drafts = try container.decodeIfPresent(
            [String: PersonSelectionDraft].self,
            forKey: .drafts
        ) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case drafts
    }
}

struct PersonSelectionDraft: Codable, Equatable {
    var callIDs: [String]
    var updatedAt: Date

    init(
        callIDs: [String] = [],
        updatedAt: Date = personArchiveTimestamp()
    ) {
        self.callIDs = callIDs
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case callIDs = "callIds"
        case updatedAt
    }
}

enum PersonOrganizationSourceKind: String, Codable, Equatable {
    case proofread
    case transcript
}

struct PersonOrganizationSourceSnapshot: Codable, Equatable {
    var callID: String
    var sourceKind: PersonOrganizationSourceKind
    var sourcePath: String
    var contentHash: String

    init(
        callID: String = "",
        sourceKind: PersonOrganizationSourceKind = .proofread,
        sourcePath: String = "",
        contentHash: String = ""
    ) {
        self.callID = callID
        self.sourceKind = sourceKind
        self.sourcePath = sourcePath
        self.contentHash = contentHash
    }

    private enum CodingKeys: String, CodingKey {
        case callID = "callId"
        case sourceKind
        case sourcePath
        case contentHash
    }
}

struct PersonSnapshot: Codable, Equatable {
    var displayName: String
    var phoneNumbers: [String]

    init(
        displayName: String = "",
        phoneNumbers: [String] = []
    ) {
        self.displayName = displayName
        self.phoneNumbers = phoneNumbers
    }
}

struct PersonOrganizationPreparation: Equatable {
    let personSnapshot: PersonSnapshot
    let callIDs: [String]
    let sources: [PersonOrganizationSourceSnapshot]
    let unavailableCallIDs: [String]
    let markdown: String
}

enum PersonOrganizationInputError: LocalizedError {
    case noSelectedCalls
    case noReadableCalls

    var errorDescription: String? {
        switch self {
        case .noSelectedCalls:
            return "请至少选择一条通话"
        case .noReadableCalls:
            return "所选通话没有可读取的转写内容"
        }
    }
}

struct PersonOrganizationVersion: Codable, Equatable, Identifiable {
    var id: String
    var personID: String
    var personSnapshot: PersonSnapshot
    var callIDs: [String]
    var sourceSnapshots: [PersonOrganizationSourceSnapshot]
    var modelID: String
    var templateID: String
    var customPrompt: String
    var createdAt: Date
    var resultPath: String

    init(
        id: String = UUID().uuidString,
        personID: String = "",
        personSnapshot: PersonSnapshot = PersonSnapshot(),
        callIDs: [String] = [],
        sourceSnapshots: [PersonOrganizationSourceSnapshot] = [],
        modelID: String = "",
        templateID: String = "",
        customPrompt: String = "",
        createdAt: Date = personArchiveTimestamp(),
        resultPath: String = ""
    ) {
        self.id = id
        self.personID = personID
        self.personSnapshot = personSnapshot
        self.callIDs = callIDs
        self.sourceSnapshots = sourceSnapshots
        self.modelID = modelID
        self.templateID = templateID
        self.customPrompt = customPrompt
        self.createdAt = createdAt
        self.resultPath = resultPath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case personID = "personId"
        case personSnapshot
        case callIDs = "callIds"
        case sourceSnapshots
        case modelID = "modelId"
        case templateID = "templateId"
        case customPrompt
        case createdAt
        case resultPath
    }
}

struct OrganizationVersionsFile: Codable, Equatable {
    var schemaVersion: Int
    var versions: [PersonOrganizationVersion]

    init(
        schemaVersion: Int = 1,
        versions: [PersonOrganizationVersion] = []
    ) {
        self.schemaVersion = schemaVersion
        self.versions = versions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        versions = try container.decodeIfPresent(
            [PersonOrganizationVersion].self,
            forKey: .versions
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case versions
    }
}

enum PersonArchiveAccess: Equatable {
    case writable
    case recoveredFromBackup
    case readOnly(reason: String)
}

struct JSONLoadResult<Value> {
    let value: Value
    let access: PersonArchiveAccess
}

extension JSONLoadResult: Equatable where Value: Equatable {}

enum PersonArchiveError: LocalizedError, Equatable {
    case readOnly(String)
    case personNotFound(String)
    case phoneConflict(phone: String, ownerID: String)
    case invalidMerge
    case mergeNotFound(String)

    var errorDescription: String? {
        switch self {
        case .readOnly(let reason):
            return reason
        case .personNotFound(let id):
            return "人物不存在：\(id)"
        case .phoneConflict(let phone, _):
            return "号码 \(phone) 已属于其他人物"
        case .invalidMerge:
            return "至少选择两个不同人物进行合并"
        case .mergeNotFound(let id):
            return "找不到可撤销的合并记录：\(id)"
        }
    }
}

struct PersonTimelineCall: Identifiable, Equatable {
    let entry: CallRecordIndexEntry

    var id: String {
        entry.id
    }

    var preferredSourcePath: String {
        if let source = preferredSource {
            return source.path
        }
        return entry.speakerTextPath.isEmpty ? entry.transcriptPath : entry.speakerTextPath
    }

    var preferredSourceKind: PersonOrganizationSourceKind? {
        preferredSource?.kind
    }

    var isAvailable: Bool {
        preferredSource != nil
    }

    private var preferredSource: (kind: PersonOrganizationSourceKind, path: String)? {
        let candidates: [(PersonOrganizationSourceKind, String)] = [
            (.proofread, entry.speakerTextPath),
            (.transcript, entry.transcriptPath)
        ]

        for (kind, path) in candidates where Self.isReadableFile(atPath: path) {
            return (kind, path)
        }
        return nil
    }

    private static func isReadableFile(atPath path: String) -> Bool {
        guard !path.isEmpty else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
    }
}

private func personArchiveTimestamp() -> Date {
    let milliseconds = floor(Date().timeIntervalSince1970 * 1_000) / 1_000
    return Date(timeIntervalSince1970: milliseconds)
}
