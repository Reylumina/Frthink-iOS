// 世界资料的 JSON 提取与解析：剥掉 ``` 围栏、截出完整括号、容错读取字段。

import Foundation

/// 世界刷新 / 事件卡的响应解析。
///
/// 模型经常在 JSON 外面套 ```json 围栏或写一段解释，字段取值也不总是严格的
/// 字符串数组；所以这里先扫描出第一个完整的 JSON 对象/数组，再用
/// `JSONSerialization` 逐字段宽容读取，而不是直接用 `Codable` 一把解到底。
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

    /// 从模型响应里截出 JSON 对象或数组。
    ///
    /// 括号配对时会跳过字符串内部的内容和反斜杠转义，所以 `style_notes`
    /// 里出现 `{`、`}` 或 ``` 不会截错。
    ///
    /// 不能只认第一个 `{`/`[`：模型常在 JSON 前写一句带括号的说明（如
    /// 「（[别名] 也要写全）」），从那里截出来的是说明而不是结果。这里按起点
    /// 逐个试到 `JSONSerialization` 认可为止；对象优先，标量数组（说明里的
    /// `[别名]`）跳过，空数组留作兜底。
    static func extractJSON(from raw: String) -> String? {
        var emptyArrayFallback: String?
        var attempts = 0
        var searchStart = raw.startIndex
        while attempts < maxStartAttempts,
              let start = raw[searchStart...].firstIndex(where: { $0 == "{" || $0 == "[" }) {
            attempts += 1
            if let candidate = balancedJSON(in: raw, from: start),
               let data = candidate.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) {
                if root is [String: Any] { return candidate }
                if let list = root as? [Any] {
                    if list.isEmpty {
                        if emptyArrayFallback == nil { emptyArrayFallback = candidate }
                    } else if list.contains(where: { $0 is [String: Any] }) {
                        return candidate
                    }
                }
            }
            searchStart = raw.index(after: start)
        }
        return emptyArrayFallback
    }

    /// 起点尝试上限。正常响应第一个起点就命中；说明文字里最多几十个括号，
    /// 加个上限避免在超长响应上做平方级扫描。
    private static let maxStartAttempts = 128

    /// 从 `start` 起做括号配对，返回第一个完整的对象/数组；括号不配对返回 nil。
    private static func balancedJSON(in raw: String, from start: String.Index) -> String? {
        var expectedClosers: [Character] = []
        var inString = false
        var escaping = false
        var index = start

        while index < raw.endIndex {
            let character = raw[index]
            if inString {
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
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
            index = raw.index(after: index)
        }
        return nil
    }

    private static func decodeRoot(_ raw: String) throws -> Any {
        guard let json = extractJSON(from: raw),
              let data = json.data(using: .utf8) else {
            throw WorldJSONError.noJSON
        }
        do {
            return try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw WorldJSONError.invalidJSON(error.localizedDescription)
        }
    }

    // MARK: - 世界刷新

    /// 解析 `{"characters":[...],"style_notes":"...","plot_events":"..."}`。
    ///
    /// 顶层偶尔会直接返回人物数组，也一并接受；只有完全没有可识别字段时才抛错，
    /// 抛错时调用方负责把原始响应展示给用户。
    static func parseWorldRefresh(_ raw: String) throws -> WorldRefreshPayload {
        // 整个响应只有增量标记（不是 JSON）也算正常收尾。
        if raw.trimmingCharacters(in: .whitespacesAndNewlines) == PromptLibrary.noAdditionsMarker {
            return WorldRefreshPayload(hadNoAdditions: true)
        }

        let root = try decodeRoot(raw)

        if let array = root as? [Any] {
            if array.isEmpty { return WorldRefreshPayload() }
            var payload = WorldRefreshPayload()
            payload.characters = try characterCards(from: array)
            if payload.characters.isEmpty {
                throw WorldJSONError.invalidJSON("人物数组里没有一张有效的卡")
            }
            return payload
        }

        guard let rootObject = root as? [String: Any] else {
            throw WorldJSONError.invalidJSON("顶层不是 JSON 对象或数组")
        }

        let characterValue: Any? = rootObject["characters"]
            ?? rootObject["characters_list"]
        let characterItems: [Any]
        switch characterValue {
        case .none:
            characterItems = []
        case .some(let rawValue):
            if let list = rawValue as? [Any] {
                characterItems = list
            } else if let single = rawValue as? [String: Any] {
                // 少数模型把单个对象当数组返回。
                characterItems = [single]
            } else if rawValue is NSNull {
                characterItems = []
            } else {
                throw WorldJSONError.invalidJSON("characters 不是数组")
            }
        }
        var payload = WorldRefreshPayload()
        payload.characters = try characterCards(from: characterItems)

        let notes = string(field(rootObject, ["style_notes", "styleNotes"]))
        payload.hadNoAdditions = isNoAdditions(notes)
        payload.styleNotes = payload.hadNoAdditions ? "" : notes

        let plot = string(field(rootObject, ["plot_events", "plotEvents"]))
        payload.plotEvents = isNoAdditions(plot) ? "" : plot

        // 有 characters 条目却一张都没解析出来，通常是字段名/类型全错，
        // 不能当成「本轮没有新增」悄悄吞掉。
        if !characterItems.isEmpty, payload.characters.isEmpty, payload.isEmpty {
            throw WorldJSONError.invalidJSON(
                "characters 有 \(characterItems.count) 项，但都没有可用的 name"
            )
        }

        let knownKeys = [
            "characters", "characters_list", "style_notes", "styleNotes",
            "plot_events", "plotEvents",
        ]
        guard knownKeys.contains(where: { rootObject[$0] != nil }) else {
            throw WorldJSONError.invalidJSON("响应里没有 characters / style_notes / plot_events")
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
    ///
    /// 原版要求 `events` / `plot_events` 两个键最多出现一个：模型同时给出两份
    /// 数组时无法判断哪份是准的，直接报错而不是悄悄挑一个。
    static func parseEvents(_ raw: String) throws -> [EventCard] {
        let root = try decodeRoot(raw)

        let items: [Any]
        if let array = root as? [Any] {
            items = array
        } else if let rootObject = root as? [String: Any] {
            let candidates = ["events", "plot_events"]
                .compactMap { rootObject[$0] }
                .filter { !($0 is NSNull) }
            if candidates.count > 1 {
                throw WorldJSONError.invalidJSON("事件卡结果必须包含唯一事件数组")
            }
            if let array = candidates.first as? [Any] {
                items = array
            } else if candidates.count == 1 {
                throw WorldJSONError.invalidJSON("事件卡 events 不是数组")
            } else if rootObject["title"] != nil {
                items = [rootObject]
            } else {
                throw WorldJSONError.invalidJSON("事件卡响应里没有 events 数组")
            }
        } else {
            throw WorldJSONError.invalidJSON("顶层不是 JSON 数组")
        }

        var events: [EventCard] = []
        var skipped = 0
        for item in items {
            guard let object = dictionary(item) else {
                skipped += 1
                continue
            }
            let title = eventTitle(string(field(object, ["title", "name"])))
            guard !title.isEmpty else {
                skipped += 1
                continue
            }
            let scene = prose(field(object, ["scene"]))
            // APK `s2/a.java` 同款校验：人物只接受数组或分隔字符串。对象数组
            // （`[{"name":"…"}]`）或数字会让 iOS 静默得到「没有人物」，直接报错。
            let characterValue = field(object, ["characters", "casts"])
            if let characterValue, !isValidEventCharacters(characterValue) {
                throw WorldJSONError.invalidJSON("事件卡人物格式无效")
            }
            let characters = strings(characterValue)
            let cause = prose(field(object, ["cause"]))
            let development = prose(field(object, ["development"]))
            let consequence = prose(field(object, ["consequence", "result"]))
            // 只有标题、没有任何事件内容，按提示词属于无效项，跳过。
            if scene.isEmpty && characters.isEmpty && cause.isEmpty
                && development.isEmpty && consequence.isEmpty {
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

        if events.isEmpty && skipped > 0 {
            throw WorldJSONError.invalidJSON("事件卡缺少标题或事件内容")
        }
        return events
    }

    // MARK: - 人物卡

    /// 事件卡 `characters` 的合法形态：字符串（按分隔符切）或字符串数组。
    /// 空值在调用处已过滤；对象、数字、混合数组都算非法。
    private static func isValidEventCharacters(_ value: Any) -> Bool {
        if value is String { return true }
        guard let list = value as? [Any] else { return false }
        return list.allSatisfy { $0 is String || $0 is NSNull }
    }

    /// 逐项解析人物卡，并在别称类型不对时按原版报错。
    ///
    /// 原版 `aliases` 只接受字符串、字符串数组或空值；数字、对象、混合数组都会
    /// 抛「人物别称格式无效」。静默丢掉会让同一人物下次刷新时重复建卡。
    private static func characterCards(from items: [Any]) throws -> [CharacterCard] {
        var cards: [CharacterCard] = []
        for item in items {
            guard let object = dictionary(item) else { continue }
            let aliasValue = field(object, ["aliases", "alias", "别称"])
            if let aliasValue, !isValidAliasValue(aliasValue) {
                throw WorldJSONError.invalidJSON("人物别称格式无效")
            }
            if let card = character(from: object) {
                cards.append(card)
            }
        }
        return cards
    }

    private static func isValidAliasValue(_ value: Any) -> Bool {
        if value is String { return true }
        guard let list = value as? [Any] else { return false }
        return list.allSatisfy { $0 is String || $0 is NSNull }
    }

    static func character(from object: [String: Any]) -> CharacterCard? {
        let name = string(field(object, ["name", "canonical_name", "姓名"]))
        guard !name.isEmpty else { return nil }
        return CharacterCard(
            name: name,
            identity: string(field(object, ["identity", "身份"])),
            personality: string(field(object, ["personality", "性格"])),
            voice: string(field(object, ["voice", "语气", "说话方式"])),
            goals: string(field(object, ["goals", "goal", "目标"])),
            boundaries: string(field(object, ["boundaries", "boundary", "底线", "边界"])),
            aliases: strings(field(object, ["aliases", "alias", "别称"])),
            personalMemory: string(field(object, ["personal_memory", "personalMemory", "人物记忆"])),
            relationshipAttitudes: string(field(object, ["relationship_attitudes", "relationshipAttitudes", "关系态度"])),
            customEntries: customEntries(from: field(object, ["custom_entries", "customEntries", "自定义词条"]))
        )
    }

    private static func customEntries(from value: Any?) -> [CharacterCard.CustomEntry] {
        guard let value else { return [] }

        // 少数模型会把词条写成 `{"标题": "内容"}` 的对象。
        if let object = value as? [String: Any] {
            var entries: [CharacterCard.CustomEntry] = []
            for (title, bodyValue) in object {
                let body = string(bodyValue)
                guard !body.isEmpty else { continue }
                entries.append(CharacterCard.CustomEntry(title: title, body: body))
            }
            return entries
        }

        guard let list = value as? [Any] else { return [] }
        return list.compactMap { item in
            if let object = item as? [String: Any] {
                let title = string(field(object, ["title", "name", "heading", "标题"]))
                let body = string(field(object, ["body", "content", "text", "value", "内容"]))
                if title.isEmpty && body.isEmpty { return nil }
                return CharacterCard.CustomEntry(
                    title: title.isEmpty ? "资料" : title,
                    body: body
                )
            }
            let text = string(item)
            return text.isEmpty ? nil : CharacterCard.CustomEntry(title: "资料", body: text)
        }
    }

    // MARK: - 字段取值

    static func dictionary(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    private static func field(_ object: [String: Any], _ keys: [String]) -> Any? {
        for key in keys {
            if let value = object[key], !(value is NSNull) { return value }
        }
        return nil
    }

    /// 把任意 JSON 值转成一段文本：字符串原样，数组用「；」拼接，
    /// 对象里常见的 `text`/`content` 等字段也认。
    static func string(_ value: Any?) -> String {
        guard let value else { return "" }
        switch value {
        case let text as String:
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            return number.stringValue
        case let list as [Any]:
            return list
                .map { string($0) }
                .filter { !$0.isEmpty }
                .joined(separator: "；")
        case let object as [String: Any]:
            return string(field(object, ["text", "content", "value", "body", "summary", "description"]))
        default:
            return ""
        }
    }

    /// 事件卡文本字段是叙述段落。模型可能一句一行、漏标点或写半角标点，
    /// 这里并段并补最小标点：行间缺分隔补「，」，段末补「。」，半角转全角。
    /// 纯英文段落按空格并段，不套中文标点。标题和人物不走这里。
    ///
    /// 空行是段落分隔：段内按上面的规则并成一句，段与段之间保留一个换行。
    /// 以前把空行也当噪声滤掉，模型分好的段全被压成一整块，长「经过」读不动。
    static func prose(_ value: Any?) -> String {
        let lines = string(value)
            .components(separatedBy: .newlines)
            .map { stripListMarker($0.trimmingCharacters(in: .whitespaces)) }

        var paragraphs: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current) }

        return paragraphs
            .map(mergedParagraph)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// 段内并句：行间缺分隔补「，」，段末补「。」，半角转全角。
    private static func mergedParagraph(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        guard lines.contains(where: { containsHan($0) }) else {
            return lines.joined(separator: " ")
        }

        var result = ""
        for line in lines {
            let normalized = normalizePunctuation(line)
            if result.isEmpty {
                result = normalized
                continue
            }
            if !endsWithClause(result) {
                result += "，"
            }
            result += normalized
        }
        result = collapsePunctuation(result)
        if !endsWithSentence(result) {
            while let last = result.last, "，、；：".contains(last) {
                result.removeLast()
            }
            result += "。"
        }
        return result
    }

    /// 事件标题是短语，去掉末尾句读；模型偶尔把整句塞进标题。
    static func eventTitle(_ raw: String) -> String {
        stripListMarker(raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。！？；，、："))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 事件文本标点

    private static func containsHan(_ text: String) -> Bool {
        text.contains { isHan($0) }
    }

    /// 去掉模型顺手加的列表符号；它们不是正文。
    private static func stripListMarker(_ line: String) -> String {
        line
            .replacingOccurrences(
                of: #"^\s*[-–—•·]\s+"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"^\s*\d+[.、)]\s*"#,
                with: "",
                options: .regularExpression
            )
    }

    /// 中文行里的半角标点转全角；数字小数、英文缩写不动。
    ///
    /// 宽度变换交给 Foundation 的 `fullwidthToHalfwidth` 反向执行，不再手写映射表；
    /// 省略号先统一，避免三个半角句点被逐个转成句号。
    private static func normalizePunctuation(_ text: String) -> String {
        let prepared = text.replacingOccurrences(of: "...", with: "……")
        let chars = Array(prepared)
        var result = ""
        result.reserveCapacity(chars.count)
        for (index, ch) in chars.enumerated() {
            guard let fullwidth = fullwidthPunctuation(ch) else {
                result.append(ch)
                continue
            }
            let previous = index > 0 ? chars[index - 1] : nil
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            if isHan(previous) || isHan(next) {
                result.append(fullwidth)
            } else {
                result.append(ch)
            }
        }
        return result
            .replacingOccurrences(
                of: #"\s+([，。！？；：、」』”’）])"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"([「『“‘（])\s+"#,
                with: "$1",
                options: .regularExpression
            )
    }

    /// 半角标点的全角形态。句点要的是中文句号，不是全角句点，单独处理。
    private static func fullwidthPunctuation(_ ch: Character) -> Character? {
        guard ",;:!?".contains(ch) || ch == "." else { return nil }
        if ch == "." { return "。" }
        return String(ch)
            .applyingTransform(.fullwidthToHalfwidth, reverse: true)?
            .first
    }

    private static func isHan(_ ch: Character?) -> Bool {
        guard let ch, ch.unicodeScalars.count == 1,
              let scalar = ch.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
    }

    private static func endsWithClause(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？…，、；：」』”’）".contains(last)
    }

    private static func endsWithSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return "。！？…」』”’）".contains(last)
    }

    /// 并段后清掉「，。」「。。」「，，」这类重复标点，并去掉标点前空格。
    private static func collapsePunctuation(_ text: String) -> String {
        text
            .replacingOccurrences(
                of: #"\s+([，。！？；：、])"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"[，、；：]+(?=[。！？…])"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"。{2,}"#,
                with: "。",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"([。！？…])[，、；：]+"#,
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"[，、；：]{2,}"#,
                with: "，",
                options: .regularExpression
            )
    }

    /// 字符串数组字段：数组逐个取字符串；模型写成「A、B」时按中文顿号等切分。
    static func strings(_ value: Any?) -> [String] {
        guard let value else { return [] }
        if let list = value as? [Any] {
            return list.map { string($0) }.filter { !$0.isEmpty }
        }
        if let text = value as? String {
            return text
                .components(separatedBy: CharacterSet(charactersIn: "、,，;；/|\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    /// 错误提示里引用的原始响应片段，太长会截断。
    static func snippet(_ raw: String, limit: Int = 600) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "（空响应）" }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n…（共 \(trimmed.count) 字，已截断）"
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
