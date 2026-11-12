import Foundation

/// 全书人物去重（规格 D 的 P32 → P33 → P34）。
///
/// 原版只让模型处理**本轮新增候选**，已有卡片作为只读身份参考：
/// 命中 existing_id 就沿用已有卡的主名，候选之间合并；不修改、不删除已有卡。
/// 候选必须每个索引恰好出现一次，否则整份结果作废，保留原样。
enum WorldDedupe {

    struct Outcome {
        var mergedGroups: Int
        var removedCards: Int
        var note: String?
    }

    /// 对「本轮新增候选」去重。`existing` 只读，用于 existing_id / 同名匹配。
    ///
    /// 取消要原样抛出：去重被取消时调用方按「已停止」收尾，不能把它当成
    /// 「去重失败」继续合并，否则用户点了停止还会写库。
    static func dedupe(
        candidates: [CharacterCard],
        existing: [CharacterCard],
        client: any LLMClient,
        provider: ProviderSetting
    ) async throws -> (cards: [CharacterCard], outcome: Outcome) {
        // 单张候选不需要分组请求；后面 WorldMerge 会按同名/别称并入已有卡。
        guard candidates.count >= 2 else {
            return (candidates, Outcome(mergedGroups: 0, removedCards: 0, note: nil))
        }

        let existingNames = existing
            .flatMap { [$0.name] + $0.aliases }
            .filter { !$0.isEmpty }
        let messages = PromptComposer.dedupeMessages(
            candidates: candidates.map(\.name),
            existingNames: existingNames
        )
        // 与其它世界任务同参数：输出至少 4096，整段 JSON 被截断时直接报错。
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
    /// 模型常把同一名字写成大小写/空格不同的形态（`Lin Zhao` / `lin zhao`），
    /// 原样比对会把整份去重结果判成无效。
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
        // 循环不变量：候选里出现过的所有称呼。每组都重算会变成 O(组 × 卡)。
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
