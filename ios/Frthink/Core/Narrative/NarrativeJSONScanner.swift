import Foundation

/// 叙事结构化输出共用 JSON 提取与字段读取辅助：
/// 采用平衡花括号扫描从模型响应（含代码块或前后附带解释文字）中稳健切出首个合法 JSON 对象。
enum NarrativeJSONScanner {

    /// 从 `start` 起做 JSON 花括号/方括号平衡扫描并返回首个完整闭合片段，不合法则返回 nil。
    static func balancedJSONSlice(in raw: String, from start: String.Index) -> String? {
        let openBrace = Character(UnicodeScalar(0x7B))
        let closeBrace = Character(UnicodeScalar(0x7D))
        let openBracket: Character = "["
        let closeBracket: Character = "]"

        var expectedClosers: [Character] = []
        var inString = false
        var escaping = false

        for index in raw[start...].indices {
            let character = raw[index]
            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"" {
                inString = true
            } else if character == openBrace {
                expectedClosers.append(closeBrace)
            } else if character == openBracket {
                expectedClosers.append(closeBracket)
            } else if character == closeBrace || character == closeBracket {
                guard expectedClosers.last == character else { return nil }
                expectedClosers.removeLast()
                if expectedClosers.isEmpty {
                    return String(raw[start...index])
                }
            }
        }
        return nil
    }

    static func extractFirstJSONObject(from raw: String) -> String? {
        let openBrace = Character(UnicodeScalar(0x7B))
        var searchStart = raw.startIndex
        var attempts = 0

        while attempts < 64, let start = raw[searchStart...].firstIndex(of: openBrace) {
            attempts += 1
            if let candidate = balancedJSONSlice(in: raw, from: start),
               let data = candidate.data(using: .utf8),
               (try? JSONSerialization.jsonObject(with: data)) is [String: Any] {
                return candidate
            }
            searchStart = raw.index(after: start)
        }
        return nil
    }

    static func firstNonEmptyString(_ dict: [String: Any], keys: [String]) -> String {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return ""
    }

    static func optionalNonEmptyString(_ dict: [String: Any], keys: [String]) -> String? {
        let value = firstNonEmptyString(dict, keys: keys)
        return value.isEmpty ? nil : value
    }
}
