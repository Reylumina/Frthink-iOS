import CryptoKit
import Foundation

/// 对话摘要的键与哈希规则。
///
/// 原版 `p000a.a.J/o/G`：
/// - 键格式 `user:<messageID>:<sha256(content)>`
/// - `sourceHash` = 去重、排序后的键用 `\n` 拼接，再取 SHA-256
///
/// U2 在把摘要注入提示词前会用同一规则校验 `sourceHash` 和 user 前缀，
/// 所以导出和工作区更新都必须走这里，不能各写一套。
enum SummaryKey {
    static func messageKey(id: String, content: String) -> String {
        "user:\(id):\(sha256Hex(content))"
    }

    /// 从原版键里取消息 id；不是 `user:` 键时返回 nil。
    static func messageID(from key: String) -> String? {
        guard key.hasPrefix("user:") else { return nil }
        let rest = key.dropFirst("user:".count)
        guard let separator = rest.lastIndex(of: ":") else { return nil }
        let id = rest[..<separator]
        return id.isEmpty ? nil : String(id)
    }

    static func sourceHash(keys: [String]) -> String {
        let joined = Set(keys).sorted().joined(separator: "\n")
        return sha256Hex(joined)
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
