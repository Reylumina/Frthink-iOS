import Foundation

/// 单步叙事增量解析失败错误。
enum NarrativeDeltaParseError: Error, LocalizedError, Equatable {
    case noJSON
    case invalidStructure(String)

    var errorDescription: String? {
        switch self {
        case .noJSON:
            return "模型响应中未找到有效 JSON 对象"
        case .invalidStructure(let detail):
            return "增量 JSON 结构无效：\(detail)"
        }
    }
}

/// 单步叙事增量抽取结果：除增量载荷外，记录被丢弃的臆断计划条数与无原文引用降权条数。
struct NarrativeDeltaExtractionResult: Codable, Hashable {
    var delta: PlotNodeDelta
    var droppedSpeculativeCount: Int
    var ungroundedFactCount: Int

    init(
        delta: PlotNodeDelta = PlotNodeDelta(),
        droppedSpeculativeCount: Int = 0,
        ungroundedFactCount: Int = 0
    ) {
        self.delta = delta
        self.droppedSpeculativeCount = droppedSpeculativeCount
        self.ungroundedFactCount = ungroundedFactCount
    }
}

/// 单步结构化事实与伏笔增量抽取器：
/// 提示词约束后台小模型只抽取「已写定正文中确凿发生的变更」，禁止生成未来计划或 TODO，
/// 解析阶段并依据原文 quote 是否命中决定权威等级（命中正文升为 `.canonProseQuote`，无凭据降为 `.inferredByAI`）。
enum NarrativeDeltaExtractor {

    private static let speculativeTopKeys: Set<String> = [
        "todo", "todos", "next_step", "next_steps", "plan", "plans", "future_plans", "suggestions",
    ]

    private static let speculativeThreadActions: Set<String> = [
        "todo", "plan", "planned", "next_step", "suggestion",
    ]

    static func buildExtractionMessages(
        excerpt: String,
        knownEntities: [EntityPage],
        activeThreads: [ProspectiveThread]
    ) -> [LLMMessage] {
        let systemPrompt = """
        你是一个冷静、只记录已发生事实的叙事状态抽取器。
        给定一段刚刚采纳落盘的小说正文，以及当前已知实体列表和未决伏笔列表，请只抽取这段正文里「已经明确发生并写出来的」状态变化，返回一个严格 JSON 对象：
        {"new_entities":[{"name":"","kind":"character|location|artifact|lore","identity":"","aliases":[""],"trigger_keywords":[""],"quote":""}],"facts":[{"entity_id":"","attribute":"","value":"","quote":"","retracted":false}],"beliefs":[{"character_id":"","topic":"","believed_truth":"","knows_secret":false,"quote":""}],"threads":[{"thread_id":"","action":"plant|ready|enacted|satisfied|invalidated|update","goal":"","activation_cue":"","recurrence":"once|recurring","related_entity_ids":[""],"quote":""}],"scene_card":""}
        硬性约束：
        1. 严禁输出 todo、next_steps、未来剧情计划或创作建议，只记录已经发生的事实、角色已知/未知信息变化与伏笔状态迁移。
        2. new_entities 仅收录本段新出场、不在已知实体列表内且正文有明确名字的重要实体（龙套路人无需收录），并严格区分四类：`character`（人物）、`location`（物理地点）、`artifact`（可持有物件）、`lore`（世界观体系、势力、规则或历史概念；`trigger_keywords` 填正文中能带出该词条的关键词，不要把戏外作者写作规范归入 `lore`）。
        3. 每条 new_entities、facts 和 beliefs 都尽量附上正文逐字短引用 quote；无法从原文找到依据时宁可留空也不要编造。
        4. facts 的 `attribute` 按实体类型选用：`character` 用 location、possession、condition、relation、goal、status；`location` 用 layout、atmosphere、access、status；`artifact` 用 owner、location、capability、cost、status；`lore` 用 rule、faction、history、exception、status。
        5. 若本段没有任何需要记录的状态变化，对应数组留空即可。
        """

        var lines: [String] = []
        if !knownEntities.isEmpty {
            lines.append("【已知实体（优先复用 entity_id）】")
            for entity in knownEntities.sorted(by: { $0.id < $1.id }) {
                let aliasText = entity.aliases.isEmpty
                    ? ""
                    : "（别名：" + entity.aliases.joined(separator: "、") + "）"
                lines.append("- \(entity.id): \(entity.name)\(aliasText) [\(entity.kind.rawValue)]")
            }
        }
        if !activeThreads.isEmpty {
            lines.append("【当前未决伏笔（优先复用 thread_id）】")
            for thread in activeThreads.sorted(by: { $0.id < $1.id }) {
                lines.append("- \(thread.id) [\(thread.state.rawValue)]: \(thread.goal)")
            }
        }
        lines.append("【本段新增正文】")
        lines.append(excerpt)

        return [
            .system(systemPrompt),
            .user(lines.joined(separator: "\n")),
        ]
    }

    static func parseDelta(
        from raw: String,
        excerpt: String,
        nodeID: String,
        pageIndex: Int = 0,
        baseUTF16Offset: Int = 0,
        knownEntities: [EntityPage] = [],
        now: Date = Date()
    ) throws -> NarrativeDeltaExtractionResult {
        guard let jsonString = NarrativeJSONScanner.extractFirstJSONObject(from: raw) else {
            throw NarrativeDeltaParseError.noJSON
        }
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NarrativeDeltaParseError.invalidStructure("无法解析为 JSON 字典")
        }

        var droppedSpeculativeCount = 0
        for key in speculativeTopKeys {
            if let list = object[key] as? [Any] {
                droppedSpeculativeCount += list.count
            } else if object[key] != nil {
                droppedSpeculativeCount += 1
            }
        }

        let allowedTopKeys: Set<String> = [
            "new_entities", "newEntities",
            "facts", "fact_events", "beliefs", "epistemic_beliefs",
            "threads", "thread_events", "scene_card", "sceneCard",
        ]
        if !object.keys.contains(where: { allowedTopKeys.contains($0) }) && droppedSpeculativeCount == 0 {
            throw NarrativeDeltaParseError.invalidStructure("缺少 facts / beliefs / threads / scene_card 字段")
        }

        let newEntityPages = parseNewEntities(
            from: object,
            excerpt: excerpt,
            pageIndex: pageIndex,
            baseUTF16Offset: baseUTF16Offset,
            knownEntities: knownEntities,
            now: now
        )

        var ungroundedCount = 0
        var factEvents: [WorldFactEvent] = []
        let rawFacts = (object["facts"] as? [[String: Any]])
            ?? (object["fact_events"] as? [[String: Any]])
            ?? []
        for (idx, item) in rawFacts.enumerated() {
            let entityID = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["entity_id", "entityID", "entity"])
            let attribute = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["attribute", "attr"])
            let value = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["value"])
            let retracted = parseBool(item["retracted"]) ?? parseBool(item["is_retracted"]) ?? false
            guard !entityID.isEmpty, !attribute.isEmpty, (!value.isEmpty || retracted) else {
                continue
            }

            let quote = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["quote", "evidence"])
            let anchor = verifiedAnchor(
                quote: quote,
                in: excerpt,
                pageIndex: pageIndex,
                baseUTF16Offset: baseUTF16Offset
            )
            let authority: AuthorityRank = anchor != nil ? .canonProseQuote : .inferredByAI
            if anchor == nil {
                ungroundedCount += 1
            }
            factEvents.append(
                WorldFactEvent(
                    id: "\(nodeID)_fact_\(idx)_\(SummaryKey.sha256Hex("\(entityID):\(attribute):\(value)").prefix(8))",
                    entityID: entityID,
                    attribute: attribute,
                    value: value,
                    nodeID: nodeID,
                    authority: authority,
                    quoteAnchor: anchor,
                    isRetracted: retracted,
                    createdAt: now
                )
            )
        }

        var epistemicBeliefs: [EpistemicBelief] = []
        let rawBeliefs = (object["beliefs"] as? [[String: Any]])
            ?? (object["epistemic_beliefs"] as? [[String: Any]])
            ?? []
        for (idx, item) in rawBeliefs.enumerated() {
            let charID = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["character_id", "characterID", "character"])
            let topic = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["topic"])
            let believedTruth = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["believed_truth", "believedTruth", "truth"])
            guard !charID.isEmpty, !topic.isEmpty, !believedTruth.isEmpty else {
                continue
            }
            let knowsSecret = parseBool(item["knows_secret"]) ?? parseBool(item["knowsSecret"]) ?? false
            let quote = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["quote", "evidence"])
            let anchor = verifiedAnchor(
                quote: quote,
                in: excerpt,
                pageIndex: pageIndex,
                baseUTF16Offset: baseUTF16Offset
            )
            let authority: AuthorityRank = anchor != nil ? .canonProseQuote : .inferredByAI
            if anchor == nil {
                ungroundedCount += 1
            }
            epistemicBeliefs.append(
                EpistemicBelief(
                    id: "\(nodeID)_belief_\(idx)_\(SummaryKey.sha256Hex("\(charID):\(topic)").prefix(8))",
                    characterID: charID,
                    topic: topic,
                    believedTruth: believedTruth,
                    knowsSecret: knowsSecret,
                    authority: authority,
                    updatedAtNodeID: nodeID,
                    quoteAnchor: anchor,
                    updatedAt: now
                )
            )
        }

        var threadEvents: [ProspectiveThreadEvent] = []
        let rawThreads = (object["threads"] as? [[String: Any]])
            ?? (object["thread_events"] as? [[String: Any]])
            ?? []
        for (idx, item) in rawThreads.enumerated() {
            let threadID = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["thread_id", "threadID", "id"])
            let action = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["action", "kind"]).lowercased()
            if speculativeThreadActions.contains(action) {
                droppedSpeculativeCount += 1
                continue
            }
            guard !threadID.isEmpty, let kind = parseThreadAction(action) else {
                continue
            }
            let goal = NarrativeJSONScanner.optionalNonEmptyString(item, keys: ["goal", "title"])
            let cue = NarrativeJSONScanner.optionalNonEmptyString(item, keys: ["activation_cue", "activationCue"])
            let recurrenceRaw = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["recurrence"]).lowercased()
            let recurrence: RecurrenceKind? = recurrenceRaw.isEmpty
                ? nil
                : (recurrenceRaw == "recurring" ? .recurring : .once)
            let relatedIDs = (item["related_entity_ids"] as? [String])
                ?? (item["relatedEntityIDs"] as? [String])
            let quote = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["quote", "evidence"])
            let anchor = verifiedAnchor(
                quote: quote,
                in: excerpt,
                pageIndex: pageIndex,
                baseUTF16Offset: baseUTF16Offset
            )
            let authority: AuthorityRank = anchor != nil ? .canonProseQuote : .inferredByAI

            threadEvents.append(
                ProspectiveThreadEvent(
                    id: "\(nodeID)_thread_\(idx)_\(threadID)",
                    threadID: threadID,
                    kind: kind,
                    goal: goal,
                    activationCue: cue,
                    recurrence: recurrence,
                    relatedEntityIDs: relatedIDs,
                    evidenceAnchor: anchor,
                    authority: authority,
                    nodeID: nodeID,
                    createdAt: now
                )
            )
        }

        let sceneCard = NarrativeJSONScanner.firstNonEmptyString(object, keys: ["scene_card", "sceneCard"])
        let patch: NarrativePyramidPatch? = sceneCard.isEmpty
            ? nil
            : NarrativePyramidPatch(addedRecentSceneCards: [sceneCard])

        let delta = PlotNodeDelta(
            entityPageUpserts: newEntityPages,
            factEvents: factEvents,
            epistemicBeliefs: epistemicBeliefs,
            threadEvents: threadEvents,
            pyramidPatch: patch
        )
        return NarrativeDeltaExtractionResult(
            delta: delta,
            droppedSpeculativeCount: droppedSpeculativeCount,
            ungroundedFactCount: ungroundedCount
        )
    }

    // MARK: - 内部解析辅助

    private static func parseNewEntities(
        from object: [String: Any],
        excerpt: String,
        pageIndex: Int,
        baseUTF16Offset: Int,
        knownEntities: [EntityPage],
        now: Date
    ) -> [EntityPage] {
        let rawEntities = (object["new_entities"] as? [[String: Any]])
            ?? (object["newEntities"] as? [[String: Any]])
            ?? []
        guard !rawEntities.isEmpty else { return [] }

        var knownNames = Set<String>()
        var knownIDs = Set<String>()
        for page in knownEntities {
            knownIDs.insert(page.id)
            let cleanName = page.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !cleanName.isEmpty { knownNames.insert(cleanName) }
            for alias in page.aliases {
                let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !cleanAlias.isEmpty { knownNames.insert(cleanAlias) }
            }
        }

        var result: [EntityPage] = []
        for item in rawEntities {
            let name = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["name", "title"])
            guard !name.isEmpty else { continue }
            let lowerName = name.lowercased()
            guard !knownNames.contains(lowerName) else { continue }

            let quote = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["quote", "evidence"])
            let groundedByName = !excerpt.isEmpty && excerpt.localizedCaseInsensitiveContains(name)
            let groundedByQuote = verifiedAnchor(
                quote: quote,
                in: excerpt,
                pageIndex: pageIndex,
                baseUTF16Offset: baseUTF16Offset
            ) != nil
            guard groundedByName || groundedByQuote else { continue }

            let kindRaw = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["kind", "type"])
            let kind = NarrativeEntityExtractor.parseKind(kindRaw) ?? .character
            let identity = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["identity", "role", "summary"])
            let aliases = NarrativeEntityExtractor.parseStringArray(item["aliases"])
                .filter { $0.lowercased() != lowerName }
            let triggerKeywords = NarrativeEntityExtractor.parseStringArray(
                item["trigger_keywords"] ?? item["triggerKeywords"] ?? item["keywords"]
            )
            .filter { $0.lowercased() != lowerName }

            let entityID = "auto_\(kind.rawValue)_\(SummaryKey.sha256Hex(name).prefix(8))"
            guard !knownIDs.contains(entityID) else { continue }
            knownIDs.insert(entityID)
            knownNames.insert(lowerName)
            for alias in aliases {
                knownNames.insert(alias.lowercased())
            }

            result.append(
                EntityPage(
                    id: entityID,
                    kind: kind,
                    name: name,
                    aliases: aliases,
                    triggerKeywords: triggerKeywords,
                    identity: identity,
                    enabled: true,
                    updatedAt: now
                )
            )
        }
        return result
    }

    private static func verifiedAnchor(
        quote: String,
        in excerpt: String,
        pageIndex: Int,
        baseUTF16Offset: Int
    ) -> TextSpanAnchor? {
        let cleanQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuote.isEmpty else { return nil }
        let nsExcerpt = excerpt as NSString
        let range = nsExcerpt.range(of: cleanQuote)
        guard range.location != NSNotFound else { return nil }
        let paragraph = excerpt
            .components(separatedBy: "\n")
            .first { $0.contains(cleanQuote) }
        return TextSpanAnchor.make(
            pageIndex: pageIndex,
            utf16Start: baseUTF16Offset + range.location,
            utf16Length: range.length,
            quote: cleanQuote,
            paragraphText: paragraph ?? cleanQuote
        )
    }

    private static func parseThreadAction(_ raw: String) -> ProspectiveThreadEvent.Kind? {
        switch raw {
        case "plant":
            return .plant
        case "ready", "promote_ready", "promoteready":
            return .promoteReady
        case "enacted", "mark_enacted", "markenacted":
            return .markEnacted
        case "satisfied", "mark_satisfied", "marksatisfied", "resolved":
            return .markSatisfied
        case "invalidated", "invalidate":
            return .invalidate
        case "update", "update_metadata", "updatemetadata":
            return .updateMetadata
        default:
            return nil
        }
    }

    private static func parseBool(_ raw: Any?) -> Bool? {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}
