import Foundation

struct VoiceScribeRemoteHealth: Codable, Sendable {
    let apiVersion: String
    let serviceVersion: String
    let runtimeState: String
    let queueDepth: Int
    let activeTaskID: String?
    let availableDiskBytes: Int
    let availableEngines: [String]?

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case serviceVersion = "service_version"
        case runtimeState = "runtime_state"
        case queueDepth = "queue_depth"
        case activeTaskID = "active_task_id"
        case availableDiskBytes = "available_disk_bytes"
        case availableEngines = "available_engines"
    }
}

struct VoiceScribeRemoteUpload: Codable, Sendable {
    let uploadID: String
    let filename: String
    let sizeBytes: Int
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case uploadID = "upload_id"
        case filename
        case sizeBytes = "size_bytes"
        case sha256
    }
}

struct VoiceScribeRemoteTaskCreateRequest: Codable, Sendable {
    var service: String?
    let command: String
    let arguments: [String: String]
    let uploadID: String?

    enum CodingKeys: String, CodingKey {
        case service
        case command
        case arguments
        case uploadID = "upload_id"
    }
}

struct VoiceScribeRemoteTaskResultFile: Codable, Sendable {
    let index: Int
    let filename: String
    let category: String
    let sizeBytes: Int
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case index
        case filename
        case category
        case sizeBytes = "size_bytes"
        case sha256
    }
}

indirect enum VoiceScribeRemoteJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: VoiceScribeRemoteJSONValue])
    case array([VoiceScribeRemoteJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([VoiceScribeRemoteJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: VoiceScribeRemoteJSONValue].self) {
            self = .object(value)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return String(value)
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }
}

struct VoiceScribeRemoteTaskStatus: Codable, Sendable {
    let taskID: String
    let status: String
    let phase: String?
    let progress: Double
    let estimatedTimeRemaining: String?
    let error: VoiceScribeRemoteTaskError?
    let results: [VoiceScribeRemoteTaskResultFile]
    let details: [String: VoiceScribeRemoteJSONValue]
    let outputCount: Int
    let currentStage: String?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case status
        case phase
        case progress
        case estimatedTimeRemaining = "estimated_time_remaining"
        case error
        case results
        case details
        case outputCount = "output_count"
        case currentStage = "current_stage"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try container.decode(String.self, forKey: .taskID)
        status = try container.decode(String.self, forKey: .status)
        phase = try container.decodeIfPresent(String.self, forKey: .phase)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        estimatedTimeRemaining = try container.decodeIfPresent(String.self, forKey: .estimatedTimeRemaining)
        error = try container.decodeIfPresent(VoiceScribeRemoteTaskError.self, forKey: .error)
        results = try container.decodeIfPresent([VoiceScribeRemoteTaskResultFile].self, forKey: .results) ?? []
        details = try container.decodeIfPresent([String: VoiceScribeRemoteJSONValue].self, forKey: .details) ?? [:]
        outputCount = try container.decodeIfPresent(Int.self, forKey: .outputCount) ?? results.count
        currentStage = try container.decodeIfPresent(String.self, forKey: .currentStage)
            ?? details["current_stage"]?.stringValue
            ?? details["stage"]?.stringValue
            ?? details["message"]?.stringValue
            ?? phase
    }
}

struct VoiceScribeRemoteTaskError: Codable, Sendable {
    let code: String
    let message: String
}

struct RemoteSystemStats: Codable, Sendable {
    let cpuUsage: Double
    let memoryUsage: Double
    let gpuUsage: Double
    let diskUsage: Double

    enum CodingKeys: String, CodingKey {
        case cpuUsage = "cpu_usage"
        case memoryUsage = "memory_usage"
        case gpuUsage = "gpu_usage"
        case diskUsage = "disk_usage"
    }
}
