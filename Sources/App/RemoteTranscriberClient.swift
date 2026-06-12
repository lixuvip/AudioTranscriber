import Foundation
import UniformTypeIdentifiers

protocol VoiceScribeRemoteTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
    func download(for request: URLRequest) async throws -> (URL, URLResponse)
}

struct VoiceScribeURLSessionTransport: VoiceScribeRemoteTransport {
    let session: URLSession

    init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.connectionProxyDictionary = [:] // Bypass proxy to avoid network tool interference
            self.session = URLSession(configuration: config)
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        try await session.download(for: request)
    }
}

enum VoiceScribeRemoteClientError: LocalizedError, Equatable {
    case invalidServiceURL
    case nonPrivateServiceAddress
    case missingCredential
    case unauthorized
    case unsupportedAPIVersion(String)
    case invalidResponse
    case server(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidServiceURL:
            return "Mac mini 服务地址无效。"
        case .nonPrivateServiceAddress:
            return "仅允许家庭局域网私有 IPv4 地址或 Tailscale 地址。"
        case .missingCredential:
            return "尚未保存 Mac mini 服务访问令牌。"
        case .unauthorized:
            return "Mac mini 服务访问令牌不匹配。"
        case .unsupportedAPIVersion(let version):
            return "Mac mini 服务 API 版本不受支持：\(version)。"
        case .invalidResponse:
            return "Mac mini 服务返回了无法解析的响应。"
        case .server(_, let message):
            return message
        }
    }
}

struct RemoteTranscriberClient: Sendable {
    private let transport: VoiceScribeRemoteTransport
    private let credentialStore: VoiceScribeCredentialStore
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        transport: VoiceScribeRemoteTransport = VoiceScribeURLSessionTransport(),
        credentialStore: VoiceScribeCredentialStore = VoiceScribeKeychainStore()
    ) {
        self.transport = transport
        self.credentialStore = credentialStore
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    func health(serviceURL: String, isRelay: Bool = false, timeout: TimeInterval = 10) async throws -> VoiceScribeRemoteHealth {
        let request = try authorizedRequest(
            serviceURL: serviceURL,
            path: "/v1/health",
            method: "GET",
            timeout: timeout,
            isRelay: isRelay
        )
        let health: VoiceScribeRemoteHealth = try await send(request)
        guard health.apiVersion == "1" else {
            throw VoiceScribeRemoteClientError.unsupportedAPIVersion(health.apiVersion)
        }
        return health
    }

    func systemStats(serviceURL: String) async throws -> RemoteSystemStats {
        let request = try authorizedRequest(
            serviceURL: serviceURL,
            path: "/v1/system/stats",
            method: "GET",
            timeout: 5.0
        )
        return try await send(request)
    }

    func uploadAudio(
        at fileURL: URL,
        serviceURL: String,
        isRelay: Bool = false
    ) async throws -> VoiceScribeRemoteUpload {
        let boundary = "VoiceScribe-\(UUID().uuidString)"
        let path = isRelay ? "/v1/uploads?service=voicescribe" : "/v1/uploads"
        var request = try authorizedRequest(
            serviceURL: serviceURL,
            path: path,
            method: "POST",
            timeout: 600, // 10 minutes timeout for big files
            isRelay: isRelay
        )
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        
        let fileData = try Data(contentsOf: fileURL)
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
                    .utf8
            )
        )
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        
        return try await send(request)
    }

    func createTask(
        serviceURL: String,
        uploadID: String?,
        arguments: [String: String],
        isRelay: Bool = false
    ) async throws -> VoiceScribeRemoteTaskStatus {
        var request = try authorizedRequest(
            serviceURL: serviceURL,
            path: "/v1/tasks",
            method: "POST",
            timeout: 10,
            isRelay: isRelay
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Remove direct paths for safety
        let forbidden = ["voxcpm_root", "output_directory", "reference_audio_path", "audio_path", "out_dir"]
        let sanitized = arguments.filter { !forbidden.contains($0.key) }
        
        var reqPayload = VoiceScribeRemoteTaskCreateRequest(
            command: "transcribe",
            arguments: sanitized,
            uploadID: uploadID
        )
        if isRelay {
            reqPayload.service = "voicescribe"
        }
        request.httpBody = try encoder.encode(reqPayload)
        
        return try await send(request)
    }

    func taskStatus(
        taskID: String,
        serviceURL: String,
        isRelay: Bool = false
    ) async throws -> VoiceScribeRemoteTaskStatus {
        let request = try authorizedRequest(
            serviceURL: serviceURL,
            path: "/v1/tasks/\(taskID)",
            method: "GET",
            timeout: 10,
            isRelay: isRelay
        )
        return try await send(request)
    }

    func downloadResult(
        taskID: String,
        index: Int,
        serviceURL: String,
        isRelay: Bool = false
    ) async throws -> (URL, HTTPURLResponse) {
        let request = try authorizedRequest(
            serviceURL: serviceURL,
            path: "/v1/tasks/\(taskID)/result/\(index)",
            method: "GET",
            timeout: 300,
            isRelay: isRelay
        )
        let (fileURL, response) = try await transport.download(for: request)
        let http = try checkedHTTPResponse(response, data: nil)
        return (fileURL, http)
    }

    func deleteTask(
        taskID: String,
        serviceURL: String,
        isRelay: Bool = false
    ) async throws {
        let request = try authorizedRequest(
            serviceURL: serviceURL,
            path: "/v1/tasks/\(taskID)",
            method: "DELETE",
            timeout: 10,
            isRelay: isRelay
        )
        let (data, response) = try await transport.data(for: request)
        _ = try checkedHTTPResponse(response, data: data)
    }

    private func send<Response: Decodable>(
        _ request: URLRequest
    ) async throws -> Response {
        let (data, response) = try await transport.data(for: request)
        _ = try checkedHTTPResponse(response, data: data)
        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw VoiceScribeRemoteClientError.invalidResponse
        }
    }

    private func authorizedRequest(
        serviceURL: String,
        path: String,
        method: String,
        timeout: TimeInterval,
        isRelay: Bool = false
    ) throws -> URLRequest {
        let baseURL = try validatedBaseURL(serviceURL, isRelay: isRelay)
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw VoiceScribeRemoteClientError.invalidServiceURL
        }
        guard let token = try credentialStore.token(for: baseURL), !token.isEmpty else {
            throw VoiceScribeRemoteClientError.missingCredential
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validatedBaseURL(_ value: String, isRelay: Bool = false) throws -> URL {
        var normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedValue.lowercased().hasPrefix("http://") && !normalizedValue.lowercased().hasPrefix("https://") {
            let isLocal = normalizedValue.hasPrefix("localhost") || normalizedValue.hasPrefix("127.0.0.1")
            normalizedValue = (isLocal ? "http://" : "https://") + normalizedValue
        }
        
        guard let url = URL(string: normalizedValue),
              url.scheme == "http" || url.scheme == "https",
              let host = url.host else {
            throw VoiceScribeRemoteClientError.invalidServiceURL
        }
        
        if isRelay {
            let isLocal = host == "localhost" || host == "127.0.0.1"
            if !isLocal && url.scheme != "https" {
                throw VoiceScribeRemoteClientError.invalidServiceURL
            }
        }
        
        return url
    }

    private func checkedHTTPResponse(
        _ response: URLResponse,
        data: Data?
    ) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw VoiceScribeRemoteClientError.invalidResponse
        }
        if http.statusCode == 401 {
            throw VoiceScribeRemoteClientError.unauthorized
        }
        guard (200...299).contains(http.statusCode) else {
            let message = data.flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }?["detail"] as? String ?? "Mac mini 服务请求失败（HTTP \(http.statusCode)）。"
            throw VoiceScribeRemoteClientError.server(
                statusCode: http.statusCode,
                message: message
            )
        }
        return http
    }
}
