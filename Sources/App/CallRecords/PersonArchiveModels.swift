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
    var aliases: [String]
    var phoneNumbers: [String]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        displayName: String = "",
        aliases: [String] = [],
        phoneNumbers: [String] = [],
        createdAt: Date = personArchiveTimestamp(),
        updatedAt: Date = personArchiveTimestamp()
    ) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.phoneNumbers = phoneNumbers
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct PersonMergeRecord: Codable, Equatable, Identifiable {
    var id: String
    var sourcePersonIDs: [String]
    var targetPersonID: String
    var mergedAt: Date

    init(
        id: String = UUID().uuidString,
        sourcePersonIDs: [String] = [],
        targetPersonID: String = "",
        mergedAt: Date = personArchiveTimestamp()
    ) {
        self.id = id
        self.sourcePersonIDs = sourcePersonIDs
        self.targetPersonID = targetPersonID
        self.mergedAt = mergedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case sourcePersonIDs = "sourcePersonIds"
        case targetPersonID = "targetPersonId"
        case mergedAt
    }
}

struct SelectionDraftsFile: Codable, Equatable {
    var schemaVersion: Int
    var drafts: [PersonSelectionDraft]

    init(
        schemaVersion: Int = 1,
        drafts: [PersonSelectionDraft] = []
    ) {
        self.schemaVersion = schemaVersion
        self.drafts = drafts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        drafts = try container.decodeIfPresent(
            [PersonSelectionDraft].self,
            forKey: .drafts
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case drafts
    }
}

struct PersonSelectionDraft: Codable, Equatable {
    var personID: String
    var selectedCallIDs: [String]
    var updatedAt: Date

    init(
        personID: String = "",
        selectedCallIDs: [String] = [],
        updatedAt: Date = personArchiveTimestamp()
    ) {
        self.personID = personID
        self.selectedCallIDs = selectedCallIDs
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case personID = "personId"
        case selectedCallIDs = "selectedCallIds"
        case updatedAt
    }
}

enum PersonOrganizationSourceKind: String, Codable, Equatable {
    case proofread
    case transcript
}

struct PersonOrganizationSourceSnapshot: Codable, Equatable {
    var kind: PersonOrganizationSourceKind
    var relativePath: String
    var content: String
    var capturedAt: Date

    init(
        kind: PersonOrganizationSourceKind = .proofread,
        relativePath: String = "",
        content: String = "",
        capturedAt: Date = personArchiveTimestamp()
    ) {
        self.kind = kind
        self.relativePath = relativePath
        self.content = content
        self.capturedAt = capturedAt
    }
}

struct PersonSnapshot: Codable, Equatable {
    var id: String
    var displayName: String
    var aliases: [String]
    var phoneNumbers: [String]

    init(
        id: String = "",
        displayName: String = "",
        aliases: [String] = [],
        phoneNumbers: [String] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.aliases = aliases
        self.phoneNumbers = phoneNumbers
    }

    init(person: PersonRecord) {
        self.init(
            id: person.id,
            displayName: person.displayName,
            aliases: person.aliases,
            phoneNumbers: person.phoneNumbers
        )
    }
}

struct PersonOrganizationVersion: Codable, Equatable, Identifiable {
    var id: String
    var personID: String
    var personSnapshot: PersonSnapshot
    var sources: [PersonOrganizationSourceSnapshot]
    var content: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        personID: String = "",
        personSnapshot: PersonSnapshot = PersonSnapshot(),
        sources: [PersonOrganizationSourceSnapshot] = [],
        content: String = "",
        createdAt: Date = personArchiveTimestamp()
    ) {
        self.id = id
        self.personID = personID
        self.personSnapshot = personSnapshot
        self.sources = sources
        self.content = content
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case personID = "personId"
        case personSnapshot
        case sources
        case content
        case createdAt
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

private func personArchiveTimestamp() -> Date {
    Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
}
