// 世界设定 JSON 提取与解析：定位有效 JSON 片段，通过 Codable + 容错值模型反序列化。

import Foundation

/// 世界刷新 / 事件卡的响应解析。
enum WorldJSON {

    // MARK: - 结果

    struct WorldRefreshPayload {
        var characters: [CharacterCard] = []
        var styleNotes = ""
        var plotEvents = ""
        /// 出现在 style_notes 里的增量标记，表示本轮没有新增。
        var hadNoAdditions = false

        var isEmpty: Bool {
            characters.isEmpty && styleNotes.isEmpty && plotEvents.isEmpty
        }
    }

    // MARK: - 提取

    private static let maxStartAttempts = 128

    /// 从模型响应里截出首个有效闭合的 JSON 对象或对象数组；空数组作回退候选。
    static func extractJSON(from raw: String) -> String? {
        var emptyArrayFallback: String?
        var attempts = 0
        var searchStart = raw.startIndex

        while attempts < maxStartAttempts,
              let start = raw[searchStart...].firstIndex(where: { $0 == "{" || $0 == "[" }) {
            attempts += 1
            if let candidate = balancedJSON(in: raw, from: start),
               let data = candidate.data(using: .utf8),
               let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                switch value {
                case .object:
                    return candidate
                case .array(let list) where list.isEmpty:
                    emptyArrayFallback = emptyArrayFallback ?? candidate
                case .array(let list) where list.contains(where: \.isObject):
                    return candidate
                default:
                    break
                }
            }
            searchStart = raw.index(after: start)
        }
        return emptyArrayFallback
    }

    /// 从 `start` 起做括号配对，返回第一个完整的对象/数组；括号不配对返回 nil。
    private static func balancedJSON(in raw: String, from start: String.Index) -> String? {
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
            switch character {
            case "\"":
                inString = true
            case "{":
                expectedClosers.append("}")
            case "[":
                expectedClosers.append("]")
            case "}", "]":
                guard expectedClosers.last == character else { return nil }
                expectedClosers.removeLast()
                if expectedClosers.isEmpty {
                    return String(raw[start...index])
                }
            default:
                break
            }
        }
        return nil
    }

    private static func decodeRoot(_ raw: String) throws -> JSONValue {
        guard let json = extractJSON(from: raw),
              let data = json.data(using: .utf8) else {
            throw WorldJSONError.noJSON
        }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw WorldJSONError.invalidJSON(error.localizedDescription)
        }
    }

    // MARK: - 世界刷新

    /// 解析 `{"characters":[...],"style_notes":"...","plot_events":"..."}` 或顶层人物数组。
    static func parseWorldRefresh(_ raw: String) throws -> WorldRefreshPayload {
        if raw.trimmingCharacters(in: .whitespacesAndNewlines) == PromptLibrary.noAdditionsMarker {
            return WorldRefreshPayload(hadNoAdditions: true)
        }

        let root = try decodeRoot(raw)

        if case .array(let list) = root {
            guard !list.isEmpty else { return WorldRefreshPayload() }
            let cards = try decodeCharacters(from: list)
            guard !cards.isEmpty else {
                throw WorldJSONError.invalidJSON("人物数组里没有一张有效的卡")
            }
            return WorldRefreshPayload(characters: cards)
        }

        guard case .object(let object) = root else {
            throw WorldJSONError.invalidJSON("顶层不是 JSON 对象或数组")
        }

        let knownKeys = [
            "characters", "characters_list", "style_notes", "styleNotes",
            "plot_events", "plotEvents",
        ]
        guard knownKeys.contains(where: { object[$0] != nil }) else {
            throw WorldJSONError.invalidJSON("响应里没有 characters / style_notes / plot_events")
        }

        let rawItems = try extractCharacterItems(from: object)
        var payload = WorldRefreshPayload()
        payload.characters = try decodeCharacters(from: rawItems)

        let notes = object.firstPresent(["style_notes", "styleNotes"])?.proseString ?? ""
        payload.hadNoAdditions = isNoAdditions(notes)
        payload.styleNotes = payload.hadNoAdditions ? "" : notes

        let plot = object.firstPresent(["plot_events", "plotEvents"])?.proseString ?? ""
        payload.plotEvents = isNoAdditions(plot) ? "" : plot

        if !rawItems.isEmpty, payload.characters.isEmpty, payload.isEmpty {
            throw WorldJSONError.invalidJSON("characters 有 \(rawItems.count) 项，但都没有可用的 name")
        }
        return payload
    }

    static func isNoAdditions(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .contains(PromptLibrary.noAdditionsMarker)
    }

    // MARK: - 事件卡

    /// 解析事件卡 JSON 数组；也接受 `{"events":[...]}` 或单个事件对象。
    static func parseEvents(_ raw: String) throws -> [EventCard] {
        let items = try extractEventItems(from: try decodeRoot(raw))
        var events: [EventCard] = []
        var skipped = 0

        for case .object(let object) in items {
            let title = WorldProseNormalizer.normalizeEventTitle(
                object.firstNonNull(["title", "name"])?.proseString ?? ""
            )
            guard !title.isEmpty else {
                skipped += 1
                continue
            }

            if let charValue = object.firstNonNull(["characters", "casts"]) {
                guard charValue.isStringOrStringArray else {
                    throw WorldJSONError.invalidJSON("事件卡人物格式无效")
                }
            }

            let characters = object.firstNonNull(["characters", "casts"])?.stringList ?? []
            let scene = WorldProseNormalizer.normalizeProse(object.firstNonNull(["scene"])?.proseString ?? "")
            let cause = WorldProseNormalizer.normalizeProse(object.firstNonNull(["cause"])?.proseString ?? "")
            let development = WorldProseNormalizer.normalizeProse(object.firstNonNull(["development"])?.proseString ?? "")
            let consequence = WorldProseNormalizer.normalizeProse(object.firstNonNull(["consequence", "result"])?.proseString ?? "")

            let hasContent = !scene.isEmpty || !characters.isEmpty || !cause.isEmpty
                || !development.isEmpty || !consequence.isEmpty
            guard hasContent else {
                skipped += 1
                continue
            }

            events.append(
                EventCard(
                    title: title,
                    scene: scene,
                    characters: characters,
                    cause: cause,
                    development: development,
                    consequence: consequence
                )
            )
        }
        skipped += items.filter { !$0.isObject }.count

        if events.isEmpty && skipped > 0 {
            throw WorldJSONError.invalidJSON("事件卡缺少标题或事件内容")
        }
        return events
    }

    // MARK: - 人物卡

    /// 从 tool call JSON Data 直接解析单张人物卡。
    static func parseCharacter(from data: Data) -> CharacterCard? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object(let object) = value else {
            return nil
        }
        return character(from: object)
    }

    private static func extractCharacterItems(from object: [String: JSONValue]) throws -> [JSONValue] {
        guard let rawValue = object["characters"] ?? object["characters_list"] else {
            return []
        }
        switch rawValue {
        case .array(let list):
            return list
        case .object:
            return [rawValue]
        case .null:
            return []
        default:
            throw WorldJSONError.invalidJSON("characters 不是数组")
        }
    }

    private static func extractEventItems(from root: JSONValue) throws -> [JSONValue] {
        if case .array(let array) = root { return array }
        guard case .object(let object) = root else {
            throw WorldJSONError.invalidJSON("顶层不是 JSON 数组")
        }

        let candidates = ["events", "plot_events"].compactMap { key -> JSONValue? in
            guard let val = object[key], !val.isNull else { return nil }
            return val
        }
        if candidates.count > 1 {
            throw WorldJSONError.invalidJSON("事件卡结果必须包含唯一事件数组")
        }
        if let first = candidates.first {
            guard case .array(let array) = first else {
                throw WorldJSONError.invalidJSON("事件卡 events 不是数组")
            }
            return array
        }
        if object["title"] != nil {
            return [.object(object)]
        }
        throw WorldJSONError.invalidJSON("事件卡响应里没有 events 数组")
    }

    private static func decodeCharacters(from items: [JSONValue]) throws -> [CharacterCard] {
        var cards: [CharacterCard] = []
        for case .object(let object) in items {
            if let aliasValue = object.firstNonNull(["aliases", "alias", "别称"]) {
                guard aliasValue.isStringOrStringArray else {
                    throw WorldJSONError.invalidJSON("人物别称格式无效")
                }
            }
            if let card = character(from: object) {
                cards.append(card)
            }
        }
        return cards
    }

    private static func character(from object: [String: JSONValue]) -> CharacterCard? {
        let name = object.firstNonNull(["name", "canonical_name", "姓名"])?.proseString ?? ""
        guard !name.isEmpty else { return nil }
        return CharacterCard(
            name: name,
            identity: object.firstNonNull(["identity", "身份"])?.proseString ?? "",
            personality: object.firstNonNull(["personality", "性格"])?.proseString ?? "",
            voice: object.firstNonNull(["voice", "语气", "说话方式"])?.proseString ?? "",
            goals: object.firstNonNull(["goals", "goal", "目标"])?.proseString ?? "",
            boundaries: object.firstNonNull(["boundaries", "boundary", "底线", "边界"])?.proseString ?? "",
            aliases: object.firstNonNull(["aliases", "alias", "别称"])?.stringList ?? [],
            personalMemory: object.firstNonNull(["personal_memory", "personalMemory", "人物记忆"])?.proseString ?? "",
            relationshipAttitudes: object.firstNonNull(["relationship_attitudes", "relationshipAttitudes", "关系态度"])?.proseString ?? "",
            customEntries: customEntries(from: object.firstNonNull(["custom_entries", "customEntries", "自定义词条"]))
        )
    }

    private static func customEntries(from value: JSONValue?) -> [CharacterCard.CustomEntry] {
        guard let value else { return [] }
        switch value {
        case .object(let map):
            return map.compactMap { title, bodyValue in
                let body = bodyValue.proseString
                return body.isEmpty ? nil : CharacterCard.CustomEntry(title: title, body: body)
            }
        case .array(let list):
            return list.compactMap { item in
                if case .object(let object) = item {
                    let title = object.firstNonNull(["title", "name", "heading", "标题"])?.proseString ?? ""
                    let body = object.firstNonNull(["body", "content", "text", "value", "内容"])?.proseString ?? ""
                    guard !title.isEmpty || !body.isEmpty else { return nil }
                    return CharacterCard.CustomEntry(title: title.isEmpty ? "资料" : title, body: body)
                }
                let text = item.proseString
                return text.isEmpty ? nil : CharacterCard.CustomEntry(title: "资料", body: text)
            }
        default:
            return []
        }
    }

    /// 错误提示里引用的原始响应片段，太长会截断。
    static func snippet(_ raw: String, limit: Int = 600) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "（空响应）" }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n…（共 \(trimmed.count) 字，已截断）"
    }
}

// MARK: - 容错 JSON 值模型

private enum JSONValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let d = try? container.decode(Double.self) { self = .number(d); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let arr = try? container.decode([JSONValue].self) { self = .array(arr); return }
        if let obj = try? container.decode([String: JSONValue].self) { self = .object(obj); return }
        self = .null
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    var isStringOrStringArray: Bool {
        switch self {
        case .string:
            return true
        case .array(let list):
            return list.allSatisfy {
                switch $0 {
                case .string, .null: return true
                default: return false
                }
            }
        default:
            return false
        }
    }

    var proseString: String {
        switch self {
        case .string(let text):
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let number):
            return NSNumber(value: number).stringValue
        case .bool(let flag):
            return flag ? "true" : "false"
        case .array(let list):
            return list.map(\.proseString).filter { !$0.isEmpty }.joined(separator: "；")
        case .object(let object):
            return object.firstNonNull(["text", "content", "value", "body", "summary", "description"])?.proseString ?? ""
        case .null:
            return ""
        }
    }

    var stringList: [String] {
        switch self {
        case .array(let list):
            return list.map(\.proseString).filter { !$0.isEmpty }
        case .string(let text):
            return text
                .components(separatedBy: CharacterSet(charactersIn: "、,，;；/|\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        default:
            return []
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func firstPresent(_ keys: [String]) -> JSONValue? {
        for key in keys {
            if let value = self[key] { return value }
        }
        return nil
    }

    func firstNonNull(_ keys: [String]) -> JSONValue? {
        for key in keys {
            if let value = self[key], !value.isNull { return value }
        }
        return nil
    }
}

enum WorldJSONError: LocalizedError {
    case noJSON
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .noJSON:
            return "响应里找不到完整的 JSON"
        case .invalidJSON(let detail):
            return detail.isEmpty ? "JSON 不合法" : "JSON 不合法：\(detail)"
        }
    }
}
