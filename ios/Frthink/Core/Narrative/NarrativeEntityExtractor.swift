import Foundation

/// 档案提取器：从正文末尾或指定片区增量提取、更新四类档案（人物、地点、物件、世界观），
/// 与既有实体按 ID 或名称自动对齐合并，保留作者手工调整与冲突历史。
enum NarrativeEntityExtractor {

    static func buildExtractionMessages(
        manuscriptTail: String,
        existingPages: [EntityPage],
        targetKind: EntityKind? = nil
    ) -> [LLMMessage] {
        let kindScopeInstruction: String
        if let targetKind {
            kindScopeInstruction = "本次只需重点提取并完善分类为 `\(targetKind.rawValue)`（\(targetKind.displayName)）的条目。"
        } else {
            kindScopeInstruction = "请区分正文中活跃的四类档案：`character`（人物）、`location`（地点）、`artifact`（物件）与 `lore`（世界观）。"
        }

        let systemPrompt = """
        你是小说设定整理编辑，负责从正文中提取并更新四类档案。
        \(kindScopeInstruction)
        请只返回一个 JSON 对象，不要附加额外说明：
        {"entities":[{"id":"","kind":"character|location|artifact|lore","name":"","aliases":[""],"trigger_keywords":[""],"activation_mode":"mentioned|always","identity":"","summary":"","voice_profile":"","hard_boundaries":[""]}]}
        分类说明：
        - `character`（人物）：有自主行动或视角的角色。`identity` 写身份与立场，`summary` 写性格与当前处境，`voice_profile` 写说话口吻与用词习惯，`hard_boundaries` 写人物底线与不可违背的原则。
        - `location`（地点）：具体的物理场所。`identity` 写位置与所属区域，`summary` 写空间布局、环境氛围与出入口，`hard_boundaries` 写地形或准入限制；`voice_profile` 留空。
        - `artifact`（物件）：可持有或使用的道具、信物与器物。`identity` 写当前持有者或归属，`summary` 写外观、用途与当前状态，`hard_boundaries` 写触发条件、代价或损耗限制；`voice_profile` 留空。
        - `lore`（世界观）：世界内的力量体系、宗门势力、社会制度、历史事件或自然法则。不要把戏外作者的写作要求（如视角限制、行文节奏、字数要求、去 AI 味规范）归入 `lore`。`identity` 写所属类别，`summary` 写具体机制与词条内容，`hard_boundaries` 写世界内不可违背的规则与例外，`trigger_keywords` 填正文中提及即可带入该词条的关键词（不要重复填写名称本身）；只有作用于全局的基础铁律才将 `activation_mode` 设为 `"always"`，其余保持 `"mentioned"`。
        整理要求：
        1. 若条目已在下方「现有档案」中出现，请沿用其准确 `id`，只补充或修正有原文依据的新信息。
        2. 新出现的重要角色、地点、物件或世界观条目可新建档案（`id` 留空），内容必须依据正文，不得臆造。
        3. `summary` 用一至三句概括；非 `character` 分类禁止填写 `voice_profile`。
        4. 若正文中没有新增或变化的条目，返回 `{"entities":[]}`。
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
            let incomingTriggerKeywords = parseStringArray(
                item["trigger_keywords"] ?? item["triggerKeywords"] ?? item["keywords"]
            )
            let rawActivation = NarrativeJSONScanner.firstNonEmptyString(
                item,
                keys: ["activation_mode", "activationMode"]
            ).lowercased()
            let parsedActivation: EntityActivationMode =
                rawActivation == "always" ? .always : .mentioned
            let incomingIdentity = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["identity", "role"])
            let incomingSummary = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["summary", "description", "brief"])
            let incomingVoice = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["voice_profile", "voiceProfile", "voice"])
            let incomingBoundaries = parseStringArray(item["hard_boundaries"] ?? item["hardBoundaries"] ?? item["boundaries"])

            if let existing {
                var merged = existing
                merged.aliases = deduplicatedStrings(existing.aliases + incomingAliases)
                merged.triggerKeywords = deduplicatedStrings(existing.triggerKeywords + incomingTriggerKeywords)
                if merged.kind == .lore, parsedActivation == .always {
                    merged.activationMode = .always
                }
                if !incomingIdentity.isEmpty { merged.identity = incomingIdentity }
                if !incomingSummary.isEmpty { merged.summary = incomingSummary }
                if !incomingVoice.isEmpty, merged.kind == .character { merged.voiceProfile = incomingVoice }
                if !incomingBoundaries.isEmpty {
                    merged.hardBoundaries = deduplicatedStrings(existing.hardBoundaries + incomingBoundaries)
                }
                let contentChanged = merged.aliases != existing.aliases
                    || merged.triggerKeywords != existing.triggerKeywords
                    || merged.activationMode != existing.activationMode
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
                    triggerKeywords: deduplicatedStrings(incomingTriggerKeywords),
                    activationMode: resolvedKind == .lore ? parsedActivation : .mentioned,
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
        case "lore", "设定", "规则", "世界观", "体系", "势力", "概念":
            return .lore
        default:
            return nil
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
