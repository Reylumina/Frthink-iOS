// 世界资料的合并规则：同名/同别称命中已有卡片就补充，不新增重复卡片。

import Foundation

/// 世界书合并。
///
/// 合并语义：旧内容只读，新内容永远追加；
/// 文本字段按标点切句去重，事件按 title 去重，人物按本名或别称匹配。
enum WorldMerge {

    // MARK: - 结果

    struct CharacterResult {
        var cards: [CharacterCard] = []
        var added = 0
        var updated = 0
        var skipped = 0
    }

    struct EventResult {
        var cards: [EventCard] = []
        var added = 0
        var updated = 0
        var skipped = 0
    }

    // MARK: - 人物

    /// 同名或同别称的人物更新已有卡；匹配到多张时用第一张并在状态里提一句，
    /// 不抛错——手动建重卡不应该让整轮刷新失败。
    /// 按姓名/别称交集对候选卡做连通分量合并（对应 APK `L1.r.b` / `q0`）。
    ///
    /// 例如 A(林昭), B(小昭), C(林昭/别称小昭) 三张卡会合并为一张，避免后续去重出现孤立碎片。
    static func consolidateConnected(_ cards: [CharacterCard]) -> [CharacterCard] {
        guard cards.count >= 2 else { return cards }
        var parent = Array(0..<cards.count)
        func find(_ x: Int) -> Int {
            var v = x
            while parent[v] != v {
                parent[v] = parent[parent[v]]
                v = parent[v]
            }
            return v
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }

        var ownerByKey: [String: Int] = [:]
        for (idx, card) in cards.enumerated() {
            for key in nameSet(name: card.name, aliases: card.aliases) {
                if let first = ownerByKey[key] {
                    union(first, idx)
                } else {
                    ownerByKey[key] = idx
                }
            }
        }

        var groups: [Int: [Int]] = [:]
        var orderedRoots: [Int] = []
        for idx in cards.indices {
            let root = find(idx)
            if groups[root] == nil { orderedRoots.append(root) }
            groups[root, default: []].append(idx)
        }
        return orderedRoots.compactMap { root in
            guard let members = groups[root], let first = members.first else { return nil }
            return members.dropFirst().reduce(cards[first]) { acc, idx in
                merge(existing: acc, incoming: cards[idx])
            }
        }
    }

    static func mergeCharacters(
        existing: [CharacterCard],
        incoming: [CharacterCard]
    ) -> CharacterResult {
        var result = CharacterResult(cards: existing)

        for raw in incoming {
            var card = raw
            card.name = raw.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !card.name.isEmpty else {
                result.skipped += 1
                continue
            }
            card.aliases = cleanedAliases(canonical: card.name, aliases: raw.aliases)

            if let index = matchIndex(for: card, in: result.cards) {
                let before = result.cards[index]
                var merged = merge(existing: before, incoming: card)
                // 已有卡片的主名与 ID 不变，只补充内容。
                merged.id = before.id
                merged.name = before.name
                let changed = merged.identity != before.identity
                    || merged.personality != before.personality
                    || merged.voice != before.voice
                    || merged.goals != before.goals
                    || merged.boundaries != before.boundaries
                    || merged.personalMemory != before.personalMemory
                    || merged.relationshipAttitudes != before.relationshipAttitudes
                    || merged.aliases != before.aliases
                    || merged.customEntries != before.customEntries
                if changed {
                    merged.updatedAt = Date()
                    result.cards[index] = merged
                    result.updated += 1
                }
            } else {
                var newCard = card
                newCard.id = UUID().uuidString
                newCard.updatedAt = Date()
                result.cards.append(newCard)
                result.added += 1
            }
        }
        return result
    }

    private static func matchIndex(for card: CharacterCard, in cards: [CharacterCard]) -> Int? {
        let canonical = normalize(card.name)
        if !canonical.isEmpty,
           let exact = cards.firstIndex(where: { normalize($0.name) == canonical }) {
            return exact
        }

        let names = nameSet(name: card.name, aliases: card.aliases)
        guard !names.isEmpty else { return nil }
        for index in cards.indices {
            let existingNames = nameSet(name: cards[index].name, aliases: cards[index].aliases)
            if !existingNames.isDisjoint(with: names) {
                return index
            }
        }
        return nil
    }

    private static func nameSet(name: String, aliases: [String]) -> Set<String> {
        var result: Set<String> = []
        for value in [name] + aliases {
            let key = normalize(value)
            if !key.isEmpty { result.insert(key) }
        }
        return result
    }

    private static func merge(existing: CharacterCard, incoming: CharacterCard) -> CharacterCard {
        var card = existing
        card.identity = appended(existing.identity, incoming.identity)
        card.personality = appended(existing.personality, incoming.personality)
        card.voice = appended(existing.voice, incoming.voice)
        card.goals = appended(existing.goals, incoming.goals)
        card.boundaries = appended(existing.boundaries, incoming.boundaries)
        card.personalMemory = appended(existing.personalMemory, incoming.personalMemory)
        card.relationshipAttitudes = appended(
            existing.relationshipAttitudes,
            incoming.relationshipAttitudes
        )
        card.aliases = cleanedAliases(
            canonical: existing.name,
            aliases: existing.aliases + incoming.aliases + [incoming.name]
        )
        card.customEntries = mergedCustomEntries(
            existing: existing.customEntries,
            incoming: incoming.customEntries
        )
        return card
    }

    // MARK: - 事件

    /// 事件去重键是输入后的 title；同名事件只补充场景、人物与因果文本。
    static func mergeEvents(existing: [EventCard], incoming: [EventCard]) -> EventResult {
        var result = EventResult(cards: existing)

        for raw in incoming {
            let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                result.skipped += 1
                continue
            }

            if let index = result.cards.firstIndex(where: {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == title
            }) {
                let before = result.cards[index]
                var merged = before
                if merged.scene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    merged.scene = raw.scene
                }
                merged.characters = uniqueStrings(before.characters + raw.characters)
                merged.cause = appended(before.cause, raw.cause, separator: "")
                merged.development = appended(before.development, raw.development, separator: "")
                merged.consequence = appended(before.consequence, raw.consequence, separator: "")
                let changed = merged.scene != before.scene
                    || merged.characters != before.characters
                    || merged.cause != before.cause
                    || merged.development != before.development
                    || merged.consequence != before.consequence
                if changed {
                    merged.updatedAt = Date()
                    result.cards[index] = merged
                    result.updated += 1
                }
            } else {
                var newEvent = raw
                newEvent.title = title
                newEvent.characters = uniqueStrings(raw.characters)
                newEvent.id = UUID().uuidString
                newEvent.updatedAt = Date()
                result.cards.append(newEvent)
                result.added += 1
            }
        }
        return result
    }

    // MARK: - 文风笔记

    /// `style_notes` 追加到 `styleNotes`：逐行去重，已有内容里出现过的行不再追加。
    /// 增量标记 `[NO_ADDITIONS]` 视为没有新增。
    static func appendStyleNotes(existing: String, incoming: String) -> String {
        let source = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !isNoAdditions(source) else { return existing }

        let oldText = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldText.isEmpty else { return source }

        let oldKey = comparisonKey(oldText)
        var seen: Set<String> = []
        var additions: [String] = []
        for line in source.split(whereSeparator: { $0.isNewline }) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = comparisonKey(trimmed)
            guard !key.isEmpty, !oldKey.contains(key), !seen.contains(key) else { continue }
            seen.insert(key)
            additions.append(trimmed)
        }
        guard !additions.isEmpty else { return existing }
        return oldText + "\n\n" + additions.joined(separator: "\n")
    }

    static func isNoAdditions(_ text: String) -> Bool {
        text.uppercased().contains(PromptLibrary.noAdditionsMarker)
    }

    // MARK: - 文本追加

    /// 旧文本只读：新文本按换行与句末标点切分，过滤已在旧文本出现的句子，
    /// 保留原有标点与逗号从句并追加；事件字段传空分隔符以保持同轮段落连贯。
    static func appended(_ existing: String, _ incoming: String, separator: String = "\n") -> String {
        let oldText = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { return existing }
        guard !oldText.isEmpty else { return newText }

        let oldKey = comparisonKey(oldText)
        var seen: Set<String> = []
        var additions: [String] = []
        for piece in splitSentences(newText) {
            let key = comparisonKey(piece)
            guard !key.isEmpty, !oldKey.contains(key), !seen.contains(key) else { continue }
            seen.insert(key)
            additions.append(piece)
        }
        guard !additions.isEmpty else { return existing }
        let block = separator.isEmpty ? joinParagraph(additions) : additions.joined(separator: separator)
        return oldText + "\n" + block
    }

    private static func joinParagraph(_ sentences: [String]) -> String {
        var out = ""
        for sentence in sentences {
            if !out.isEmpty, let last = out.last,
               !sentenceTerminators.contains(last), !trailingClosers.contains(last) {
                out.append("。")
            }
            out.append(sentence)
        }
        return out
    }

    // MARK: - 别称 / 自定义词条

    static func cleanedAliases(canonical: String, aliases: [String]) -> [String] {
        let canonicalKey = normalize(canonical)
        var seen: Set<String> = [canonicalKey]
        var result: [String] = []
        for alias in aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalize(trimmed)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
            if result.count >= 100 { break }
        }
        return result
    }

    private static func mergedCustomEntries(
        existing: [CharacterCard.CustomEntry],
        incoming: [CharacterCard.CustomEntry]
    ) -> [CharacterCard.CustomEntry] {
        var entries = existing
        for raw in incoming {
            let title = raw.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = raw.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty || !body.isEmpty else { continue }
            let finalTitle = title.isEmpty ? "资料" : title
            let key = normalize(finalTitle)

            if let index = entries.firstIndex(where: { normalize($0.title) == key }) {
                var entry = entries[index]
                entry.body = appended(entry.body, body)
                entries[index] = entry
            } else {
                entries.append(CharacterCard.CustomEntry(title: finalTitle, body: body))
            }
            if entries.count >= 200 { break }
        }
        return entries
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalize(trimmed)
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    // MARK: - 归一化

    /// 姓名/别称比较：去首尾空白、转小写、去掉所有空白（「陆 明」与「陆明」算同一人）。
    static func normalize(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { !$0.isWhitespace }
    }

    /// 句子/行去重比较：再去掉标点与 Markdown 标记，避免同一句话换种标点被重复追加。
    private static let comparisonPunctuation: Set<Character> = [
        "；", ";", "，", ",", "。", "！", "!", "？", "?", "、",
        "\n", "\r", "\t", " ", "#", "-", "*",
        "“", "”", "\"", "‘", "’", "（", "(", "）", ")", "【", "[", "】", "]",
        "：", ":", "—", "…",
    ]

    private static func comparisonKey(_ text: String) -> String {
        text.lowercased().filter {
            !$0.isWhitespace && !comparisonPunctuation.contains($0)
        }
    }

    private static let sentenceTerminators: Set<Character> = [
        "。", "！", "？", "!", "?", "；", ";",
    ]
    private static let trailingClosers: Set<Character> = [
        "”", "」", "』", "’", "）", ")", "\"", "'", "】", "]",
    ]

    /// 按换行与句末标点切分，保留逗号从句与句末原始标点。
    private static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch.isNewline {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
                i += 1
                continue
            }
            current.append(ch)
            if sentenceTerminators.contains(ch) {
                while i + 1 < chars.count, trailingClosers.contains(chars[i + 1]) {
                    i += 1
                    current.append(chars[i])
                }
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }
}
