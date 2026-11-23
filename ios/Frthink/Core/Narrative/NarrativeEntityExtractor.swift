import Foundation

/// 设定档案提取器：从正文末尾或指定片区增量提炼/更新四类设定（人物、地点、物件、设定），
/// 与既有实体按 ID 或名称自动对齐合并，保留作者手工调整与冲突历史。
enum NarrativeEntityExtractor {

    static func buildExtractionMessages(
        manuscriptTail: String,
        existingPages: [EntityPage],
        targetKind: EntityKind? = nil
    ) -> [LLMMessage] {
        let kindScopeInstruction: String
        if let targetKind {
            kindScopeInstruction = "本次只需重点提取并完善分类为 `\(targetKind.rawValue)`（\(kindDisplayName(targetKind))）的条目。"
        } else {
            kindScopeInstruction = "请覆盖正文中活跃的 `character`（人物）、`location`（地点）、`artifact`（物件）与 `lore`（世界设定）。"
        }

        let systemPrompt = """
        你是一个严谨的小说设定整理编辑，负责从正文中提炼与更新设定档案。
        \(kindScopeInstruction)
        请严格返回一个 JSON 对象（不要输出额外说明）：
        {"entities":[{"id":"","kind":"character|location|artifact|lore","name":"","aliases":[""],"identity":"","summary":"","voice_profile":"","hard_boundaries":[""]}]}
        约束要求：
        1. 若设定已在下方「现有档案」中出现，请沿用其 exact `id`，仅补充或修正有原文依据的新信息。
        2. 新发现的重要角色、关键地点、关键物件或世界规则可新建条目（`id` 留空即可），仅依据正文明确描写，不得凭空捏造。
        3. `summary` 用 1-3 句简明概括当前设定现状；`voice_profile` 仅人物填写说话口吻或风格；`hard_boundaries` 列出不可违背的行为底线或规则。
        4. 若正文中没有任何新增或变更的设定，返回 `{"entities":[]}`。
        """

        var userLines: [String] = []
        let relevantPages = existingPages
            .filter { targetKind == nil || $0.kind == targetKind }
            .sorted { lhs, rhs in
                if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.name < rhs.name
            }
        if !relevantPages.isEmpty {
            userLines.append("【现有档案（优先沿用 id）】")
            for page in relevantPages.prefix(60) {
                let aliasText = page.aliases.isEmpty ? "" : "（别名：\(page.aliases.joined(separator: "、"))）"
                let brief = page.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let summaryPart = brief.isEmpty ? "" : "：\(brief)"
                userLines.append("- [\(page.kind.rawValue)] \(page.id) | \(page.name)\(aliasText)\(summaryPart)")
            }
        }
        userLines.append("【正文参考片段】")
        userLines.append(manuscriptTail)

        return [
            .system(systemPrompt),
            .user(userLines.joined(separator: "\n")),
        ]
    }

    static func parseEntities(
        from raw: String,
        existingPages: [EntityPage],
        targetKind: EntityKind? = nil,
        now: Date = Date()
    ) throws -> (upserts: [EntityPage], added: Int, updated: Int) {
        guard let jsonString = NarrativeJSONScanner.extractFirstJSONObject(from: raw) else {
            throw NarrativeDeltaParseError.noJSON
        }
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NarrativeDeltaParseError.invalidStructure("无法解析为设定 JSON 字典")
        }

        guard let rawItems = (object["entities"] as? [[String: Any]])
                ?? (object["items"] as? [[String: Any]])
                ?? (object["pages"] as? [[String: Any]]) else {
            throw NarrativeDeltaParseError.invalidStructure("缺少 entities 数组字段")
        }

        let pagesByID = Dictionary(uniqueKeysWithValues: existingPages.map { ($0.id, $0) })
        var usedIDs = Set(pagesByID.keys)
        var upserts: [EntityPage] = []
        var added = 0
        var updated = 0

        for item in rawItems {
            let name = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["name", "title"])
            guard !name.isEmpty else { continue }

            let rawKind = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["kind", "type", "category"])
            let resolvedKind = targetKind ?? parseKind(rawKind) ?? .character
            let rawID = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["id", "entity_id"])
            let existing = resolveExistingPage(
                id: rawID,
                name: name,
                kind: resolvedKind,
                pagesByID: pagesByID,
                existingPages: existingPages
            )

            let incomingAliases = parseStringArray(item["aliases"])
            let incomingIdentity = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["identity", "role"])
            let incomingSummary = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["summary", "description", "brief"])
            let incomingVoice = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["voice_profile", "voiceProfile", "voice"])
            let incomingBoundaries = parseStringArray(item["hard_boundaries"] ?? item["hardBoundaries"] ?? item["boundaries"])

            if let existing {
                var merged = existing
                merged.aliases = deduplicatedStrings(existing.aliases + incomingAliases)
                if !incomingIdentity.isEmpty { merged.identity = incomingIdentity }
                if !incomingSummary.isEmpty { merged.summary = incomingSummary }
                if !incomingVoice.isEmpty, merged.kind == .character { merged.voiceProfile = incomingVoice }
                if !incomingBoundaries.isEmpty {
                    merged.hardBoundaries = deduplicatedStrings(existing.hardBoundaries + incomingBoundaries)
                }
                let contentChanged = merged.aliases != existing.aliases
                    || merged.identity != existing.identity
                    || merged.summary != existing.summary
                    || merged.voiceProfile != existing.voiceProfile
                    || merged.hardBoundaries != existing.hardBoundaries
                guard contentChanged else { continue }
                merged.updatedAt = now
                upserts.append(merged)
                updated += 1
            } else {
                var candidateID = rawID
                if candidateID.isEmpty || !usedIDs.insert(candidateID).inserted {
                    var slugIndex = 0
                    repeat {
                        let seed = slugIndex == 0
                            ? "\(resolvedKind.rawValue):\(name)"
                            : "\(resolvedKind.rawValue):\(name):\(slugIndex)"
                        candidateID = "\(resolvedKind.rawValue)_\(SummaryKey.sha256Hex(seed).prefix(12))"
                        slugIndex += 1
                    } while !usedIDs.insert(candidateID).inserted
                }
                let created = EntityPage(
                    id: candidateID,
                    kind: resolvedKind,
                    name: name,
                    aliases: deduplicatedStrings(incomingAliases),
                    summary: incomingSummary,
                    identity: incomingIdentity,
                    voiceProfile: resolvedKind == .character ? incomingVoice : "",
                    hardBoundaries: deduplicatedStrings(incomingBoundaries),
                    updatedAt: now
                )
                upserts.append(created)
                added += 1
            }
        }
        return (upserts, added, updated)
    }

    private static func resolveExistingPage(
        id: String,
        name: String,
        kind: EntityKind,
        pagesByID: [String: EntityPage],
        existingPages: [EntityPage]
    ) -> EntityPage? {
        if !id.isEmpty, let byID = pagesByID[id] {
            return byID
        }
        let lowerName = name.lowercased()
        if let sameKind = existingPages.first(where: { page in
            page.kind == kind && (
                page.name.lowercased() == lowerName
                    || page.aliases.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == lowerName }
            )
        }) {
            return sameKind
        }
        return existingPages.first { page in
            page.name.lowercased() == lowerName
        }
    }

    static func parseKind(_ raw: String) -> EntityKind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "character", "人物", "角色":
            return .character
        case "location", "地点", "场景":
            return .location
        case "artifact", "物件", "物品", "道具":
            return .artifact
        case "lore", "设定", "规则", "世界观":
            return .lore
        default:
            return nil
        }
    }

    private static func kindDisplayName(_ kind: EntityKind) -> String {
        switch kind {
        case .character: return "人物"
        case .location: return "地点"
        case .artifact: return "物件"
        case .lore: return "设定"
        }
    }

    static func parseStringArray(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return deduplicatedStrings(strings)
        }
        if let raw = value as? String {
            let parts = raw
                .replacingOccurrences(of: "，", with: "\n")
                .replacingOccurrences(of: "、", with: "\n")
                .replacingOccurrences(of: ",", with: "\n")
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            return deduplicatedStrings(parts)
        }
        return []
    }

    private static func deduplicatedStrings(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                out.append(trimmed)
            }
        }
        return out
    }
}
