import Foundation
import Security

protocol VoiceScribeCredentialStore: Sendable {
    func token(for serviceURL: URL) throws -> String?
    func saveToken(_ token: String, for serviceURL: URL) throws
    func deleteToken(for serviceURL: URL) throws
}

struct VoiceScribeKeychainStore: VoiceScribeCredentialStore {
    private let serviceName: String

    init(serviceName: String = "com.voicescribe.app.remote") {
        self.serviceName = serviceName
    }

    func token(for serviceURL: URL) throws -> String? {
        var query = baseQuery(for: serviceURL)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: status)
        }
        return token
    }

    func saveToken(_ token: String, for serviceURL: URL) throws {
        let data = Data(token.utf8)
        let query = baseQuery(for: serviceURL)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError(status: updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    func deleteToken(for serviceURL: URL) throws {
        let status = SecItemDelete(baseQuery(for: serviceURL) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    private func baseQuery(for serviceURL: URL) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: normalized(serviceURL).absoluteString,
        ]
    }

    private func normalized(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        if let message = SecCopyErrorMessageString(status, nil) {
            return "无法访问远程服务凭据：\(message)"
        }
        return "无法访问远程服务凭据（状态码 \(status)）。"
    }
}
