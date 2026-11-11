import Foundation
import Security

/// API Key 存 Keychain，不落 JSON。
///
/// Android 端把 key 放在 DataStore（`deepseek_api_key` 等键）。iOS 上有
/// Keychain 就没理由把凭据明文写进应用沙盒里的文件。
enum Keychain {
    private static let service = "com.frthink.app.apikey"

    static func set(_ value: String, for account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 每个供应方一个 account，避免换模型时串 key。
    static func account(for providerID: String) -> String {
        "provider.\(providerID)"
    }

    // MARK: - 书稿加密主密钥

    /// 和 API Key 分开一个 service：换 key、清 key 时不会误伤书稿。
    private static let payloadService = "com.frthink.app.payload"
    private static let payloadAccount = "master"

    static func setPayloadKey(_ value: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: payloadService,
            kSecAttrAccount as String: payloadAccount,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = value
        // 后台保存可能在锁屏后发生；AfterFirstUnlock 是能后台写盘的最低档。
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func payloadKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: payloadService,
            kSecAttrAccount as String: payloadAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return data
    }
}
