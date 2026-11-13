import Foundation
import Security

/// API Key 存 Keychain，不落 JSON。
///
/// Android 端把 key 放在 DataStore（`deepseek_api_key` 等键）。iOS 上有
/// Keychain 就没理由把凭据明文写进应用沙盒里的文件。
enum Keychain {
    private static let service = "com.frthink.app.apikey"

    @discardableResult
    static func set(_ value: String, for account: String) -> Bool {
        guard !value.isEmpty else {
            let status = delete(service: service, account: account)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        return upsert(service: service, account: account, data: Data(value.utf8)) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        guard case .found(let data) = readData(service: service, account: account),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    static func delete(_ account: String) {
        _ = delete(service: service, account: account)
    }

    /// 每个供应方一个 account，避免换模型时串 key。
    static func account(for providerID: String) -> String {
        "provider.\(providerID)"
    }

    // MARK: - 书稿加密主密钥

    /// 和 API Key 分开一个 service：换 key、清 key 时不会误伤书稿。
    private static let payloadService = "com.frthink.app.payload"
    private static let payloadAccount = "master"

    enum PayloadKeyStatus {
        case found(Data)
        case notFound
        case failed(OSStatus)
    }

    @discardableResult
    static func setPayloadKey(_ value: Data) -> OSStatus {
        guard !value.isEmpty else {
            return delete(service: payloadService, account: payloadAccount)
        }
        return upsert(service: payloadService, account: payloadAccount, data: value)
    }

    private static func upsert(service: String, account: String, data: Data) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // 后台保存可能在锁屏后发生；AfterFirstUnlock 是能后台写盘的最低档。
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil)
        }
        return updateStatus
    }

    private static func delete(service: String, account: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        return SecItemDelete(query as CFDictionary)
    }

    static func readPayloadKey() -> PayloadKeyStatus {
        readData(service: payloadService, account: payloadAccount)
    }

    private static func readData(service: String, account: String) -> PayloadKeyStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return .found(data)
        }
        if status == errSecItemNotFound {
            return .notFound
        }
        return .failed(status)
    }

    static func payloadKey() -> Data? {
        if case .found(let data) = readPayloadKey() {
            return data
        }
        return nil
    }
}
