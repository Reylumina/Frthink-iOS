import Foundation

/// 全书人物去重（P32 → P33 → P34）。
///
/// 只让模型处理**本轮新增候选**，已有卡片作为只读身份参考：
/// 匹配 existing_id 时沿用已有卡片标准名称并合并候选数据；不直接修改或删除既有卡片。
/// 候选必须每个索引恰好出现一次，否则整份结果作废，保留原样。
enum WorldDedupe {

    struct Outcome {
        var mergedGroups: Int
        var removedCards: Int
        var note: String?
    }

    /// 对「本轮新增候选」去重。`existing` 只读，用于 existing_id / 同名匹配。
    ///
    /// 取消异常需直接外抛：去重取消时由调用方统一处理停止逻辑，
    /// 避免误判为去重失败继续执行合并与持久化。
    static func dedupe(
        candidates: [CharacterCard],
        existing: [CharacterCard],
        client: any LLMClient,
        provider: ProviderSetting
    ) async throws -> (cards: [CharacterCard], outcome: Outcome) {
        // 候选数量不足 2 时无需发起分组去重请求，后续由 WorldMerge 处理同名并入。
        guard candidates.count >= 2 else {
            return (candidates, Outcome(mergedGroups: 0, removedCards: 0, note: nil))
        }

        let existingNames = existing.compactMap { card -> String? in
            guard !card.name.isEmpty else { return nil }
            let aliases = card.aliases.filter { !$0.isEmpty }.joined(separator: "、")
            return "\(card.id)\t\(card.name)\t\(aliases)"
        }
        let candidateLabels = candidates.map { card in
            let aliases = card.aliases.filter { !$0.isEmpty }
            return aliases.isEmpty
                ? card.name
                : "\(card.name)（别称：\(aliases.joined(separator: "、"))）"
        }
        let messages = PromptComposer.dedupeMessages(
            candidates: candidateLabels,
            existingNames: existingNames
        )
        // 与其他世界设定任务配置一致：输出至少 4096，JSON 截断时触发错误处理。
        let request = WorldRequestContext.request(
            provider: provider,
            messages: messages,
            failOnLength: true
        )

        let raw: String
        do {
            raw = try await client.complete(request)
        } catch {
            if error.isLLMCancellation { throw CancellationError() }
            return (candidates, Outcome(
                mergedGroups: 0,
                removedCards: 0,
                note: "人物去重请求失败，已保留原卡片"
            ))
        }

        guard let groups = parseGroups(from: raw) else {
            return (candidates, Outcome(
                mergedGroups: 0,
                removedCards: 0,
                note: "人物去重结果格式无效，已保留原卡片"
            ))
        }

        guard let applied = apply(groups: groups, to: candidates, existing: existing) else {
            return (candidates, Outcome(
                mergedGroups: 0,
                removedCards: 0,
                note: "人物去重结果不完整，已保留原卡片"
            ))
        }
        return applied
    }

    // MARK: - 解析

    /// 候选里出现过的所有称呼，按 `WorldMerge.normalize` 归一。
    ///
    /// 归一化处理大小写与空格差异（如 `Lin Zhao` 与 `lin zhao`），
    /// 避免因格式差异误判为无效去重结果。
    static func candidateNameKeys(_ cards: [CharacterCard]) -> Set<String> {
        Set(cards.flatMap { [$0.name] + $0.aliases }.map(WorldMerge.normalize))
    }

    private struct Group {
        var indexes: [Int]
        var existingID: String
        var canonicalName: String
        var aliases: [String]
    }

    private static func parseGroups(from raw: String) -> [Group]? {
        guard let json = WorldJSON.extractJSON(from: raw),
              let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data),
              let object = root as? [String: Any],
              let list = object["groups"] as? [Any]
        else { return nil }

        var groups: [Group] = []
        for item in list {
            guard let dict = item as? [String: Any] else { continue }
            let indexes = (dict["candidate_indexes"] as? [Any] ?? [])
                .compactMap { ($0 as? NSNumber)?.intValue }
            guard !indexes.isEmpty else { continue }
            groups.append(Group(
                indexes: indexes,
                existingID: (dict["existing_id"] as? String) ?? "",
                canonicalName: (dict["canonical_name"] as? String) ?? "",
                aliases: (dict["aliases"] as? [Any] ?? []).compactMap { $0 as? String }
            ))
        }
        return groups.isEmpty ? nil : groups
    }

    // MARK: - 合并

    private static func apply(
        groups: [Group],
        to cards: [CharacterCard],
        existing: [CharacterCard]
    ) -> (cards: [CharacterCard], outcome: Outcome)? {
        var result = cards
        var seen = Set<Int>()
        var merged = 0
        var removed = 0
        let existingByID = Dictionary(
            existing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // 提前缓存候选中出现的所有称谓键值，避免循环内部重复计算。
        let candidateNames = candidateNameKeys(cards)

        for group in groups {
            let valid = group.indexes.filter { cards.indices.contains($0) }
            guard !valid.isEmpty,
                  valid.count == Set(valid).count,
                  valid.allSatisfy({ !seen.contains($0) })
            else { return nil }
            seen.formUnion(valid)

            var canonical = group.canonicalName
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !group.existingID.isEmpty {
                // existing_id 必须指向真实已有卡；已有卡的主名不可改。
                guard let existingCard = existingByID[group.existingID] else { return nil }
                canonical = existingCard.name
            } else if !canonical.isEmpty {
                // 新人物 canonical_name 必须来自候选中已有的名称。
                guard candidateNames.contains(WorldMerge.normalize(canonical)) else {
                    return nil
                }
            }

            var primary = cards[valid[0]]
            for index in valid.dropFirst() {
                primary = merge(primary, cards[index])
                result[index].name = ""
                removed += 1
            }
            if canonical.isEmpty {
                canonical = primary.name
            }
            guard !canonical.isEmpty else { return nil }

            if canonical != primary.name {
                if !primary.name.isEmpty, !primary.aliases.contains(primary.name) {
                    primary.aliases.append(primary.name)
                }
                primary.name = canonical
            }
            for alias in group.aliases
            where alias != primary.name && !primary.aliases.contains(alias) {
                primary.aliases.append(alias)
            }
            primary.updatedAt = Date()
            result[valid[0]] = primary
            if valid.count > 1 {
                merged += 1
            }
        }

        // 每个候选必须恰好归入一个组；缺任何一个都视为无效，不做部分应用。
        guard seen.count == cards.count else { return nil }

        return (result.filter { !$0.name.isEmpty },
                Outcome(mergedGroups: merged, removedCards: removed, note: nil))
    }

    private static func merge(_ left: CharacterCard, _ right: CharacterCard) -> CharacterCard {
        var card = left
        card.identity = pick(card.identity, right.identity)
        card.personality = pick(card.personality, right.personality)
        card.voice = pick(card.voice, right.voice)
        card.goals = pick(card.goals, right.goals)
        card.boundaries = pick(card.boundaries, right.boundaries)
        card.personalMemory = append(card.personalMemory, right.personalMemory)
        card.relationshipAttitudes = append(card.relationshipAttitudes, right.relationshipAttitudes)
        for alias in right.aliases where !card.aliases.contains(alias) {
            card.aliases.append(alias)
        }
        for entry in right.customEntries
        where !card.customEntries.contains(where: { $0.title == entry.title }) {
            card.customEntries.append(entry)
        }
        return card
    }

    private static func pick(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : a
    }

    private static func append(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a.contains(b) ? a : a + "\n" + b
    }
}
