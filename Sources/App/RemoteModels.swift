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

struct VoiceScribeRemoteTaskStatus: Codable, Sendable {
    let taskID: String
    let status: String
    let progress: Double
    let estimatedTimeRemaining: String?
    let error: VoiceScribeRemoteTaskError?
    let results: [VoiceScribeRemoteTaskResultFile]
    let currentStage: String?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case status
        case progress
        case estimatedTimeRemaining = "estimated_time_remaining"
        case error
        case results
        case currentStage = "current_stage"
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
