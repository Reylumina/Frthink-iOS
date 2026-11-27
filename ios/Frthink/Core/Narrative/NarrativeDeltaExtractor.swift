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

/// 后台增量抽取判定的前一段叙事层级。
enum SceneNarrativeLayer: String, Codable, Hashable {
    /// 同场客观正文的连续推进。
    case canonOngoing = "canon_ongoing"
    /// 前一场客观戏份已明确收尾并切换至新场景。
    case canonClosed = "canon_closed"
    /// 非现实/主观心理或回忆插曲，不代表当前物理世界已发生的客观改变。
    case subjectiveInsert = "subjective_insert"
}

/// 场景切换与前情衔接信号：在现有单步抽取中顺带判定是否发生换场，并强制保留显式时间锚点。
struct SceneTransitionSignal: Codable, Hashable {
    var shifted: Bool
    var previousLayer: SceneNarrativeLayer
    var timeAnchor: String
    var neutralBridge: String

    var shouldAutoPrune: Bool {
        shifted || previousLayer != .canonOngoing
    }

    var formattedBridge: String {
        let cleanTime = timeAnchor.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBridge = neutralBridge.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTime.isEmpty && !cleanBridge.isEmpty {
            return "[\(cleanTime)] \(cleanBridge)"
        }
        return cleanBridge.isEmpty ? cleanTime : cleanBridge
    }
}

/// 单步叙事增量抽取结果：除增量载荷外，记录被丢弃的臆断计划条数、无原文引用降权条数与换场信号。
struct NarrativeDeltaExtractionResult: Codable, Hashable {
    var delta: PlotNodeDelta
    var droppedSpeculativeCount: Int
    var ungroundedFactCount: Int
    var sceneTransition: SceneTransitionSignal?

    init(
        delta: PlotNodeDelta = PlotNodeDelta(),
        droppedSpeculativeCount: Int = 0,
        ungroundedFactCount: Int = 0,
        sceneTransition: SceneTransitionSignal? = nil
    ) {
        self.delta = delta
        self.droppedSpeculativeCount = droppedSpeculativeCount
        self.ungroundedFactCount = ungroundedFactCount
        self.sceneTransition = sceneTransition
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

    static func buildExtractionPayload(
        excerpt: String,
        leadingContext: String = "",
        knownEntities: [EntityPage],
        existingFactsByEntity: [String: [WorldFactEvent]] = [:],
        activeThreads: [ProspectiveThread],
        activeEvents: [EpisodicEvent] = []
    ) -> (messages: [LLMMessage], mapping: NarrativeEntityResolver.ExtractionIDMapping) {
        let scanContext = leadingContext.isEmpty ? excerpt : (leadingContext + "\n" + excerpt)
        let prioritizedEntities = prioritizeKnownEntities(knownEntities, in: scanContext, limit: 20)
        let entityNamesByID = Dictionary(uniqueKeysWithValues: knownEntities.map { ($0.id, $0.name) })
        let prioritizedEvents = prioritizeActiveEvents(
            activeEvents,
            in: scanContext,
            entityNamesByID: entityNamesByID,
            limit: 12
        )
        let sortedThreads = activeThreads.sorted { $0.id < $1.id }
        let relevantFacts = NarrativeEntityExtractor.collectRelevantFacts(
            for: prioritizedEntities,
            existingFactsByEntity: existingFactsByEntity,
            perEntityLimit: 6
        )
        let mapping = NarrativeEntityResolver.ExtractionIDMapping.build(
            entities: prioritizedEntities,
            events: prioritizedEvents,
            threads: sortedThreads,
            facts: relevantFacts
        )

        let systemPrompt = """
        你是冷静、只记录已发生事实的叙事状态抽取器。
        给定一段刚刚采纳落盘的小说正文，以及带短编号（如 E1、F1、EV1、T1）的已知实体与活跃近况、进行中事件、未决伏笔列表，请只抽取「本段新增正文」里「已经明确发生并写出来的」状态变化，返回一个严格 JSON 对象：
        {"new_entities":[{"name":"","kind":"character|location|artifact|lore","identity":"","aliases":[""],"trigger_keywords":[""],"quote":""}],"facts":[{"entity_id":"","attribute":"","value":"","quote":"","retracted":false}],"negated_fact_ids":[""],"beliefs":[{"character_id":"","topic":"","believed_truth":"","knows_secret":false,"quote":""}],"threads":[{"thread_id":"","action":"plant|ready|enacted|satisfied|invalidated|update","goal":"","activation_cue":"","recurrence":"once|recurring","related_entity_ids":[""],"quote":""}],"events":[{"id":"","title":"","arc":"","scene":"","participants":[""],"cause":"","development":"","outcome":"","status":"ongoing|resolved","quote":""}],"scene_card":"","scene_transition":{"shifted":false,"previous_layer":"canon_ongoing|canon_closed|subjective_insert","time_anchor":"","neutral_bridge":""}}
        硬性约束：
        1. 严禁输出 todo、next_steps、未来剧情计划或创作建议，只记录已经发生的持久化状态事实、角色已知/未知信息变化、关键事件与伏笔状态迁移。
        2. 引用已知实体时，`facts.entity_id`、`beliefs.character_id`、`events.participants` 与 `threads.related_entity_ids` 必须优先填写已知实体短编号（如 `"E1"`）；若引用本次 `new_entities` 中刚新建的实体，请填写 `"NEW:实体名"`（如 `"NEW:沈清秋"`）；延续已有进行中事件请填写事件短编号（如 `"EV1"`），推进已有伏笔请填写伏笔短编号（如 `"T1"`）。
        3. new_entities 仅收录本段新出场、不在已知实体列表内且正文有明确专名的实体，严格区分四类：`character`（人物）、`location`（物理地点）、`artifact`（可持有物件）、`lore`（世界观体系、势力、规则或历史概念；`trigger_keywords` 填正文中能带出该词条的关键词，不要把戏外作者写作规范归入 `lore`）。
        4. 禁止把无归属泛称或临时职务称谓（如「师父」「掌柜」「小二」「侍卫」「黑衣人」「少年」「老者」「大人」「路人」）单独建为实体，也不要把这类泛称写入任何实体的 aliases，避免不同角色张冠李戴。
        5. 每条 new_entities、facts 和 events 都尽量附上正文逐字短引用 quote；无法从原文找到依据时宁可留空也不要编造。
        6. beliefs 仅在正文明确写出关键秘密、隐瞒或戏剧性信息差且能附上原文逐字短引用 quote 时才记录，禁止臆测常规认知状态。
        7. facts 的 `attribute` 严格选用规范英文键：`character` 用 `location`、`possession`（或 `possession:<物件>`）、`condition`、`goal`、`status`、`relation:<对象名>`；`location` 用 `layout`、`atmosphere`、`access`、`status`；`artifact` 用 `owner`、`location`、`capability`、`cost`、`status`；`lore` 用 `rule`、`faction`、`history`、`exception`、`status`。严禁把推门、倒茶、质问等瞬时动作（action）、修辞比喻或单句试探话术写入 facts。
        8. events 仅在正文发生、推进或完结实质性剧情事件时填写；同一场景的连续推进必须复用「进行中关键事件」的短编号（只补充新增的 development / outcome，不要重开碎片事件）；完结时将 status 设为 resolved。
        9. threads 推进或收束时优先复用已知伏笔短编号；若一次性伏笔（once）在本段正文已经彻底兑现或解答，直接输出 action 为 satisfied。
        10. 若本段没有任何需要记录的状态变化，对应数组留空即可。
        11. scene_transition 仅在明确发生场次边界切换（时间跳跃、地点转移、叙事视角切分或上一冲突完结）时置 shifted 为 true，同一场戏连续对话动作保持 false；time_anchor 必须保留明确时间点与停留时长线索；neutral_bridge 用 1 句客观中性事实概括前情结果（剥离感官与情绪渲染）；若本段属于主观心理或回忆插曲而未实际改变物理世界，将 previous_layer 设为 subjective_insert 且不得向 facts 写入客观变更。
        12. 若本段正文明确推翻、完成或使下方某条已知实体「当前近况」（如 `F1`）过时失效，请将对应短编号填入 `negated_fact_ids`（如 `["F1"]`）。
        """

        var lines: [String] = []
        if !prioritizedEntities.isEmpty {
            lines.append("【已知实体与当前近况（优先填写短编号 E1/F1…）】")
            for entity in prioritizedEntities {
                let shortID = mapping.entityRealToShort[entity.id] ?? entity.id
                let aliasText = entity.aliases.isEmpty
                    ? ""
                    : "（别名：" + entity.aliases.joined(separator: "、") + "）"
                let anchorSource = !entity.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? entity.identity
                    : entity.summary
                let cleanAnchor = anchorSource
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: "；")
                let clippedAnchor = cleanAnchor.count > 40
                    ? String(cleanAnchor.prefix(40)) + "…"
                    : cleanAnchor
                let anchorSuffix = clippedAnchor.isEmpty ? "" : "：\(clippedAnchor)"
                lines.append("- \(shortID) | \(entity.name)\(aliasText) [\(entity.kind.rawValue)]\(anchorSuffix)")

                let entityFacts = (existingFactsByEntity[entity.id] ?? [])
                    .filter { !$0.isRetracted }
                    .sorted { lhs, rhs in
                        if lhs.attribute != rhs.attribute { return lhs.attribute < rhs.attribute }
                        return lhs.id < rhs.id
                    }
                    .prefix(6)
                if !entityFacts.isEmpty {
                    let factTokens = entityFacts.map { fact in
                        let fShort = mapping.factRealToShort[fact.id] ?? fact.id
                        return "\(fShort)[\(fact.attribute)]=\(fact.value)"
                    }
                    lines.append("  当前近况：" + factTokens.joined(separator: "；"))
                }
            }
        }
        if !sortedThreads.isEmpty {
            lines.append("【当前未决伏笔（优先填写短编号 T1/T2…）】")
            for thread in sortedThreads {
                let shortID = mapping.threadRealToShort[thread.id] ?? thread.id
                var detailParts: [String] = []
                let cue = thread.activationCue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cue.isEmpty {
                    detailParts.append("触发线索：\(cue)")
                }
                if let quoteRaw = thread.evidenceAnchors.last?.quote.trimmingCharacters(in: .whitespacesAndNewlines),
                   !quoteRaw.isEmpty {
                    let clipped = quoteRaw.count > 40 ? String(quoteRaw.prefix(40)) + "…" : quoteRaw
                    detailParts.append("埋设依据：\(clipped)")
                }
                let suffix = detailParts.isEmpty ? "" : "（" + detailParts.joined(separator: "；") + "）"
                lines.append("- \(shortID) [\(thread.state.rawValue)/\(thread.recurrence.rawValue)]: \(thread.goal)\(suffix)")
            }
        }
        if !prioritizedEvents.isEmpty {
            lines.append("【进行中关键事件（延续或完结时优先填写短编号 EV1/EV2…）】")
            for event in prioritizedEvents {
                let shortID = mapping.eventRealToShort[event.id] ?? event.id
                let arcPart = event.arcTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? ""
                    : " [\(event.arcTitle)]"
                let scenePart = event.scene.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? ""
                    : "（\(event.scene)）"
                let progressRaw = !event.development.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? event.development
                    : event.cause
                let cleanProgress = progressRaw
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: "；")
                let clippedProgress = cleanProgress.count > 40
                    ? String(cleanProgress.prefix(40)) + "…"
                    : cleanProgress
                let progressSuffix = clippedProgress.isEmpty ? "" : "｜已有进展：\(clippedProgress)"
                lines.append("- \(shortID)\(arcPart)\(scenePart): \(event.title)\(progressSuffix)")
            }
        }
        let cleanLeading = leadingContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanLeading.isEmpty {
            lines.append("【前情参考（只读，仅用于确认人称指代与承接上文，禁止重复抽取其中的旧事实或旧事件）】")
            lines.append(cleanLeading)
            lines.append("【本段新增正文（仅从此处抽取变更）】")
            lines.append(excerpt)
        } else {
            lines.append("【本段新增正文】")
            lines.append(excerpt)
        }

        return (
            messages: [
                .system(systemPrompt),
                .user(lines.joined(separator: "\n")),
            ],
            mapping: mapping
        )
    }

    /// 阶段 2（剧情事件、角色认知与伏笔）：基于已定型的实体列表抽取剧情推进、信息差与伏笔状态变更。
    static func buildPlotExtractionPayload(
        excerpt: String,
        leadingContext: String = "",
        knownEntities: [EntityPage],
        activeThreads: [ProspectiveThread],
        activeEvents: [EpisodicEvent] = []
    ) -> (messages: [LLMMessage], mapping: NarrativeEntityResolver.ExtractionIDMapping) {
        let scanContext = leadingContext.isEmpty ? excerpt : (leadingContext + "\n" + excerpt)
        let prioritizedEntities = prioritizeKnownEntities(knownEntities, in: scanContext, limit: 20)
        let sortedThreads = activeThreads.sorted { $0.id < $1.id }
        let entityNamesByID = Dictionary(uniqueKeysWithValues: knownEntities.map { ($0.id, $0.name) })
        let boundedEvents = prioritizeActiveEvents(
            activeEvents,
            in: scanContext,
            entityNamesByID: entityNamesByID,
            limit: 12
        )
        let mapping = NarrativeEntityResolver.ExtractionIDMapping.build(
            entities: prioritizedEntities,
            events: boundedEvents,
            threads: sortedThreads
        )

        let systemPrompt = """
        你是冷静、专注于叙事因果与视角边界的剧情记录编辑。
        给定已定型的实体列表（短编号 E1/E2…）、进行中关键事件（EV1/EV2…）、未决伏笔（T1/T2…）与一段刚刚落盘的小说正文，请只抽取「本段新增正文」中明确发生的剧情事件、角色信息差认知与伏笔状态变更，返回一个严格 JSON 对象：
        {"events":[{"id":"","title":"","arc":"","scene":"","participants":[""],"cause":"","development":"","outcome":"","status":"ongoing|resolved","quote":""}],"beliefs":[{"character_id":"","topic":"","believed_truth":"","knows_secret":false,"quote":""}],"threads":[{"thread_id":"","action":"plant|ready|enacted|satisfied|invalidated|update","goal":"","activation_cue":"","recurrence":"once|recurring","related_entity_ids":[""],"quote":""}],"scene_card":""}
        硬性约束：
        1. 严禁输出 todo、next_steps、未来创作建议，也不需要重建实体档案或零散属性。
        2. 涉及已知实体、事件、伏笔时，必须填写对应短编号（如 `"E1"`、`"EV1"`、`"T1"`）。
        3. events：以有剧情意义的场景事件为单位，把 `cause`、`development`、`outcome` 写成连贯叙述段落，避免逐句堆砌流水账；延续进行中事件时复用 `"EV1"` 等短编号，只补充本段新增的发展或结局；仅在事件因果确实收束完结时将 `status` 设为 `"resolved"`。
        4. beliefs：严格区分客观事实与角色认知，仅在正文明确写出角色亲眼目睹、听闻、阅读、欺瞒、误判或明确不知情且能附上原文短引用 `quote` 时记录；不要把“原文未提及某人”臆断为“不知情”。
        5. threads：区分计划与已兑现动作；仅当一次性伏笔（once）在本段正文真正彻底兑现时设为 `"satisfied"`，有新推进则用 `"ready"` / `"enacted"` / `"update"`。
        6. 每条事件与认知尽量附上正文逐字短引用 `quote`；若某类无变更则返回空数组 `[]`。
        """

        var lines: [String] = []
        if !prioritizedEntities.isEmpty {
            lines.append("【已定型实体（填写短编号 E1/E2…）】")
            for entity in prioritizedEntities {
                let shortID = mapping.entityRealToShort[entity.id] ?? entity.id
                let aliasText = entity.aliases.isEmpty
                    ? ""
                    : "（别名：" + entity.aliases.joined(separator: "、") + "）"
                let anchorSource = !entity.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? entity.identity
                    : entity.summary
                let cleanAnchor = anchorSource
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: "；")
                let clippedAnchor = cleanAnchor.count > 36
                    ? String(cleanAnchor.prefix(36)) + "…"
                    : cleanAnchor
                let anchorSuffix = clippedAnchor.isEmpty ? "" : "：\(clippedAnchor)"
                lines.append("- \(shortID) | \(entity.name)\(aliasText) [\(entity.kind.rawValue)]\(anchorSuffix)")
            }
        }
        if !boundedEvents.isEmpty {
            lines.append("【进行中关键事件（延续或收束时填写短编号 EV1/EV2…）】")
            for event in boundedEvents {
                let shortID = mapping.eventRealToShort[event.id] ?? event.id
                var header = "- \(shortID)"
                let cleanArc = event.arcTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanArc.isEmpty { header += " [\(cleanArc)]" }
                let cleanScene = event.scene.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanScene.isEmpty { header += "（\(cleanScene)）" }
                header += ": \(event.title)"
                var details: [String] = []
                let participants = event.participantEntityIDs.compactMap { entityNamesByID[$0] }
                if !participants.isEmpty {
                    details.append("参与：" + participants.joined(separator: "、"))
                }
                let cleanCause = event.cause.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanCause.isEmpty {
                    let clipped = cleanCause.count > 48 ? String(cleanCause.prefix(48)) + "…" : cleanCause
                    details.append("起因：\(clipped)")
                }
                let cleanDev = event.development.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanDev.isEmpty {
                    let clipped = cleanDev.count > 64 ? String(cleanDev.prefix(64)) + "…" : cleanDev
                    details.append("经过：\(clipped)")
                }
                lines.append(details.isEmpty ? header : header + "｜" + details.joined(separator: "｜"))
            }
        }
        if !sortedThreads.isEmpty {
            lines.append("【当前未决伏笔（填写短编号 T1/T2…）】")
            for thread in sortedThreads {
                let shortID = mapping.threadRealToShort[thread.id] ?? thread.id
                var detailParts: [String] = []
                let cue = thread.activationCue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cue.isEmpty {
                    detailParts.append("触发线索：\(cue)")
                }
                if let quoteRaw = thread.evidenceAnchors.last?.quote.trimmingCharacters(in: .whitespacesAndNewlines),
                   !quoteRaw.isEmpty {
                    let clipped = quoteRaw.count > 40 ? String(quoteRaw.prefix(40)) + "…" : quoteRaw
                    detailParts.append("埋设依据：\(clipped)")
                }
                let suffix = detailParts.isEmpty ? "" : "（" + detailParts.joined(separator: "；") + "）"
                lines.append("- \(shortID) [\(thread.state.rawValue)/\(thread.recurrence.rawValue)]: \(thread.goal)\(suffix)")
            }
        }

        let cleanLeading = leadingContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanLeading.isEmpty {
            lines.append("【前情参考（只读，仅用于确认人称指代与承接上文，禁止重复抽取旧事件）】")
            lines.append(cleanLeading)
            lines.append("【本段新增正文（仅从此处抽取剧情与认知变化）】")
            lines.append(excerpt)
        } else {
            lines.append("【本段新增正文】")
            lines.append(excerpt)
        }

        return (
            messages: [
                .system(systemPrompt),
                .user(lines.joined(separator: "\n")),
            ],
            mapping: mapping
        )
    }

    static func parsePlotDelta(
        from raw: String,
        excerpt: String,
        nodeID: String,
        pageIndex: Int = 0,
        baseUTF16Offset: Int = 0,
        knownEntities: [EntityPage] = [],
        activeEvents: [EpisodicEvent] = [],
        idMapping: NarrativeEntityResolver.ExtractionIDMapping? = nil,
        now: Date = Date()
    ) throws -> NarrativeDeltaExtractionResult {
        guard let jsonString = NarrativeJSONScanner.extractFirstJSONObject(from: raw) else {
            throw NarrativeDeltaParseError.noJSON
        }
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NarrativeDeltaParseError.invalidStructure("无法解析为剧情 JSON 字典")
        }

        var droppedSpeculativeCount = 0
        for key in speculativeTopKeys {
            if let list = object[key] as? [Any] {
                droppedSpeculativeCount += list.count
            } else if object[key] != nil {
                droppedSpeculativeCount += 1
            }
        }

        let allowedPlotKeys: Set<String> = [
            "events", "episodic_events", "episodicEvents",
            "beliefs", "epistemic_beliefs",
            "threads", "thread_events",
            "scene_card", "sceneCard",
        ]
        if !object.keys.contains(where: { allowedPlotKeys.contains($0) }) && droppedSpeculativeCount == 0 {
            throw NarrativeDeltaParseError.invalidStructure("缺少 events / beliefs / threads / scene_card 字段")
        }

        let entityLookup = NarrativeEntityResolver.EntityLookupIndex(pages: knownEntities)
        let shouldResolveEntities = !knownEntities.isEmpty || !(idMapping?.isEmpty ?? true)

        let epistemicBeliefs = parseBeliefsArray(
            from: object,
            excerpt: excerpt,
            nodeID: nodeID,
            pageIndex: pageIndex,
            baseUTF16Offset: baseUTF16Offset,
            entityLookup: entityLookup,
            idMapping: idMapping,
            newEntityRefs: [:],
            shouldResolveEntities: shouldResolveEntities,
            now: now,
            droppedSpeculativeCount: &droppedSpeculativeCount
        )
        let threadEvents = parseThreadsArray(
            from: object,
            excerpt: excerpt,
            nodeID: nodeID,
            pageIndex: pageIndex,
            baseUTF16Offset: baseUTF16Offset,
            entityLookup: entityLookup,
            idMapping: idMapping,
            newEntityRefs: [:],
            shouldResolveEntities: shouldResolveEntities,
            now: now,
            droppedSpeculativeCount: &droppedSpeculativeCount
        )
        let episodicEvents = parseEpisodicEvents(
            from: object,
            excerpt: excerpt,
            nodeID: nodeID,
            pageIndex: pageIndex,
            baseUTF16Offset: baseUTF16Offset,
            entityLookup: entityLookup,
            idMapping: idMapping,
            newEntityRefs: [:],
            activeEvents: activeEvents,
            now: now,
            droppedSpeculativeCount: &droppedSpeculativeCount
        )

        let sceneCard = NarrativeJSONScanner.firstNonEmptyString(object, keys: ["scene_card", "sceneCard"])
        let patch: NarrativePyramidPatch? = sceneCard.isEmpty
            ? nil
            : NarrativePyramidPatch(addedRecentSceneCards: [sceneCard])

        let delta = PlotNodeDelta(
            epistemicBeliefs: epistemicBeliefs,
            threadEvents: threadEvents,
            episodicEvents: episodicEvents,
            pyramidPatch: patch
        )
        return NarrativeDeltaExtractionResult(
            delta: delta,
            droppedSpeculativeCount: droppedSpeculativeCount,
            ungroundedFactCount: 0,
            sceneTransition: nil
        )
    }

    static func parseDelta(
        from raw: String,
        excerpt: String,
        nodeID: String,
        pageIndex: Int = 0,
        baseUTF16Offset: Int = 0,
        knownEntities: [EntityPage] = [],
        existingFactsByEntity: [String: [WorldFactEvent]] = [:],
        activeEvents: [EpisodicEvent] = [],
        idMapping: NarrativeEntityResolver.ExtractionIDMapping? = nil,
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
            "facts", "fact_events",
            "negated_fact_ids", "negatedFactIDs", "retracted_fact_ids",
            "beliefs", "epistemic_beliefs",
            "threads", "thread_events",
            "events", "episodic_events", "episodicEvents",
            "scene_card", "sceneCard",
            "scene_transition", "sceneTransition",
        ]
        if !object.keys.contains(where: { allowedTopKeys.contains($0) }) && droppedSpeculativeCount == 0 {
            throw NarrativeDeltaParseError.invalidStructure("缺少 facts / beliefs / threads / scene_card 字段")
        }

        let entityExtraction = parseNewEntities(
            from: object,
            excerpt: excerpt,
            pageIndex: pageIndex,
            baseUTF16Offset: baseUTF16Offset,
            knownEntities: knownEntities,
            idMapping: idMapping,
            now: now
        )
        let newEntityPages = entityExtraction.upserts
        let newEntityRefs = entityExtraction.newEntityRefs
        droppedSpeculativeCount += entityExtraction.droppedCount

        var mergedEntityCatalog = Dictionary(uniqueKeysWithValues: knownEntities.map { ($0.id, $0) })
        for upsert in newEntityPages {
            mergedEntityCatalog[upsert.id] = upsert
        }
        let allEntities = Array(mergedEntityCatalog.values)
        let entityLookup = NarrativeEntityResolver.EntityLookupIndex(pages: allEntities)
        let shouldResolveEntities = !knownEntities.isEmpty
            || !newEntityPages.isEmpty
            || !(idMapping?.isEmpty ?? true)

        var ungroundedCount = 0
        var factEvents = parseFactsArray(
            from: object,
            excerpt: excerpt,
            nodeID: nodeID,
            pageIndex: pageIndex,
            baseUTF16Offset: baseUTF16Offset,
            entityLookup: entityLookup,
            idMapping: idMapping,
            newEntityRefs: newEntityRefs,
            shouldResolveEntities: shouldResolveEntities,
            now: now,
            ungroundedCount: &ungroundedCount
        )
        let negatedFacts = NarrativeEntityExtractor.parseNegatedFacts(
            from: object,
            nodeID: nodeID,
            existingFactsByEntity: existingFactsByEntity,
            idMapping: idMapping,
            now: now
        )
        factEvents.append(contentsOf: negatedFacts)
        let epistemicBeliefs = parseBeliefsArray(
            from: object,
            excerpt: excerpt,
            nodeID: nodeID,
            pageIndex: pageIndex,
            baseUTF16Offset: baseUTF16Offset,
            entityLookup: entityLookup,
            idMapping: idMapping,
            newEntityRefs: newEntityRefs,
            shouldResolveEntities: shouldResolveEntities,
            now: now,
            droppedSpeculativeCount: &droppedSpeculativeCount
        )
        let threadEvents = parseThreadsArray(
            from: object,
            excerpt: excerpt,
            nodeID: nodeID,
            pageIndex: pageIndex,
            baseUTF16Offset: baseUTF16Offset,
            entityLookup: entityLookup,
            idMapping: idMapping,
            newEntityRefs: newEntityRefs,
            shouldResolveEntities: shouldResolveEntities,
            now: now,
            droppedSpeculativeCount: &droppedSpeculativeCount
        )
        let episodicEvents = parseEpisodicEvents(
            from: object,
            excerpt: excerpt,
            nodeID: nodeID,
            pageIndex: pageIndex,
            baseUTF16Offset: baseUTF16Offset,
            entityLookup: entityLookup,
            idMapping: idMapping,
            newEntityRefs: newEntityRefs,
            activeEvents: activeEvents,
            now: now,
            droppedSpeculativeCount: &droppedSpeculativeCount
        )

        let sceneCard = NarrativeJSONScanner.firstNonEmptyString(object, keys: ["scene_card", "sceneCard"])
        let patch: NarrativePyramidPatch? = sceneCard.isEmpty
            ? nil
            : NarrativePyramidPatch(addedRecentSceneCards: [sceneCard])
        let transition = parseSceneTransition(from: object)
        let effectiveFacts = transition?.previousLayer == .subjectiveInsert ? [] : factEvents

        let delta = PlotNodeDelta(
            entityPageUpserts: newEntityPages,
            factEvents: effectiveFacts,
            epistemicBeliefs: epistemicBeliefs,
            threadEvents: threadEvents,
            episodicEvents: episodicEvents,
            pyramidPatch: patch
        )
        return NarrativeDeltaExtractionResult(
            delta: delta,
            droppedSpeculativeCount: droppedSpeculativeCount,
            ungroundedFactCount: ungroundedCount,
            sceneTransition: transition
        )
    }

    // MARK: - 内部解析辅助

    static func parseFactsArray(
        from object: [String: Any],
        excerpt: String,
        nodeID: String,
        pageIndex: Int,
        baseUTF16Offset: Int,
        entityLookup: NarrativeEntityResolver.EntityLookupIndex,
        idMapping: NarrativeEntityResolver.ExtractionIDMapping?,
        newEntityRefs: [String: EntityPage],
        shouldResolveEntities: Bool,
        now: Date,
        ungroundedCount: inout Int
    ) -> [WorldFactEvent] {
        var factEvents: [WorldFactEvent] = []
        let rawFacts = (object["facts"] as? [[String: Any]])
            ?? (object["fact_events"] as? [[String: Any]])
            ?? []
        for (idx, item) in rawFacts.enumerated() {
            let rawEntityID = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["entity_id", "entityID", "entity"])
            let attribute = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["attribute", "attr"])
            let value = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["value"])
            let retracted = parseBool(item["retracted"]) ?? parseBool(item["is_retracted"]) ?? false
            guard !rawEntityID.isEmpty, !attribute.isEmpty, (!value.isEmpty || retracted) else {
                continue
            }

            let resolvedEntityID: String
            let resolvedEntityKind: EntityKind?
            if shouldResolveEntities {
                switch entityLookup.resolve(
                    rawID: rawEntityID,
                    mapping: idMapping,
                    newEntityRefs: newEntityRefs
                ) {
                case .matched(let page):
                    resolvedEntityID = page.id
                    resolvedEntityKind = page.kind
                case .ambiguous, .notFound:
                    ungroundedCount += 1
                    continue
                }
            } else {
                resolvedEntityID = rawEntityID
                resolvedEntityKind = nil
            }

            guard let canonicalAttr = WorldFactEvent.canonicalAttribute(
                attribute,
                entityKind: resolvedEntityKind
            ) else {
                continue
            }

            let quote = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["quote", "evidence"])
            let anchor = verifiedAnchor(
                quote: quote,
                in: excerpt,
                pageIndex: pageIndex,
                baseUTF16Offset: baseUTF16Offset
            )
            // 写前原文证据门控：未命中原文引用且非撤回事件的推测性事实拒绝写入活跃账本，防止错误锁定。
            guard let anchor else {
                ungroundedCount += 1
                if !retracted {
                    continue
                }
                factEvents.append(
                    WorldFactEvent(
                        id: "\(nodeID)_fact_\(idx)_\(SummaryKey.sha256Hex("\(resolvedEntityID):\(canonicalAttr):\(value)").prefix(8))",
                        entityID: resolvedEntityID,
                        attribute: canonicalAttr,
                        value: value,
                        nodeID: nodeID,
                        authority: .inferredByAI,
                        quoteAnchor: nil,
                        isRetracted: true,
                        createdAt: now
                    )
                )
                continue
            }
            factEvents.append(
                WorldFactEvent(
                    id: "\(nodeID)_fact_\(idx)_\(SummaryKey.sha256Hex("\(resolvedEntityID):\(canonicalAttr):\(value)").prefix(8))",
                    entityID: resolvedEntityID,
                    attribute: canonicalAttr,
                    value: value,
                    nodeID: nodeID,
                    authority: .canonProseQuote,
                    quoteAnchor: anchor,
                    isRetracted: retracted,
                    createdAt: now
                )
            )
        }
        return factEvents
    }

    private static func parseBeliefsArray(
        from object: [String: Any],
        excerpt: String,
        nodeID: String,
        pageIndex: Int,
        baseUTF16Offset: Int,
        entityLookup: NarrativeEntityResolver.EntityLookupIndex,
        idMapping: NarrativeEntityResolver.ExtractionIDMapping?,
        newEntityRefs: [String: EntityPage],
        shouldResolveEntities: Bool,
        now: Date,
        droppedSpeculativeCount: inout Int
    ) -> [EpistemicBelief] {
        var epistemicBeliefs: [EpistemicBelief] = []
        let rawBeliefs = (object["beliefs"] as? [[String: Any]])
            ?? (object["epistemic_beliefs"] as? [[String: Any]])
            ?? []
        for (idx, item) in rawBeliefs.enumerated() {
            let rawCharID = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["character_id", "characterID", "character"])
            let topic = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["topic"])
            let believedTruth = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["believed_truth", "believedTruth", "truth"])
            guard !rawCharID.isEmpty, !topic.isEmpty, !believedTruth.isEmpty else {
                continue
            }

            let resolvedCharID: String
            if shouldResolveEntities {
                let charResolution = entityLookup.resolve(
                    rawID: rawCharID,
                    expectedKind: .character,
                    mapping: idMapping,
                    newEntityRefs: newEntityRefs
                )
                switch charResolution {
                case .matched(let page):
                    resolvedCharID = page.id
                case .ambiguous:
                    droppedSpeculativeCount += 1
                    continue
                case .notFound:
                    if case .matched(let fallbackPage) = entityLookup.resolve(
                        rawID: rawCharID,
                        expectedKind: nil,
                        mapping: idMapping,
                        newEntityRefs: newEntityRefs
                    ) {
                        resolvedCharID = fallbackPage.id
                    } else {
                        droppedSpeculativeCount += 1
                        continue
                    }
                }
            } else {
                resolvedCharID = rawCharID
            }

            let knowsSecret = parseBool(item["knows_secret"]) ?? parseBool(item["knowsSecret"]) ?? false
            let quote = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["quote", "evidence"])
            guard let anchor = verifiedAnchor(
                quote: quote,
                in: excerpt,
                pageIndex: pageIndex,
                baseUTF16Offset: baseUTF16Offset
            ) else {
                droppedSpeculativeCount += 1
                continue
            }
            epistemicBeliefs.append(
                EpistemicBelief(
                    id: "\(nodeID)_belief_\(idx)_\(SummaryKey.sha256Hex("\(resolvedCharID):\(topic)").prefix(8))",
                    characterID: resolvedCharID,
                    topic: topic,
                    believedTruth: believedTruth,
                    knowsSecret: knowsSecret,
                    authority: .canonProseQuote,
                    updatedAtNodeID: nodeID,
                    quoteAnchor: anchor,
                    updatedAt: now
                )
            )
        }
        return epistemicBeliefs
    }

    private static func parseThreadsArray(
        from object: [String: Any],
        excerpt: String,
        nodeID: String,
        pageIndex: Int,
        baseUTF16Offset: Int,
        entityLookup: NarrativeEntityResolver.EntityLookupIndex,
        idMapping: NarrativeEntityResolver.ExtractionIDMapping?,
        newEntityRefs: [String: EntityPage],
        shouldResolveEntities: Bool,
        now: Date,
        droppedSpeculativeCount: inout Int
    ) -> [ProspectiveThreadEvent] {
        var threadEvents: [ProspectiveThreadEvent] = []
        let rawThreads = (object["threads"] as? [[String: Any]])
            ?? (object["thread_events"] as? [[String: Any]])
            ?? []
        for (idx, item) in rawThreads.enumerated() {
            let rawThreadID = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["thread_id", "threadID", "id"])
            let action = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["action", "kind"]).lowercased()
            if speculativeThreadActions.contains(action) {
                droppedSpeculativeCount += 1
                continue
            }
            guard !rawThreadID.isEmpty, let kind = parseThreadAction(action) else {
                continue
            }
            let threadID = idMapping?.threadShortToReal[rawThreadID.uppercased()] ?? rawThreadID
            let goal = NarrativeJSONScanner.optionalNonEmptyString(item, keys: ["goal", "title"])
            let cue = NarrativeJSONScanner.optionalNonEmptyString(item, keys: ["activation_cue", "activationCue"])
            let recurrenceRaw = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["recurrence"]).lowercased()
            let recurrence: RecurrenceKind? = recurrenceRaw.isEmpty
                ? nil
                : (recurrenceRaw == "recurring" ? .recurring : .once)
            let rawRelatedIDs = (item["related_entity_ids"] as? [String])
                ?? (item["relatedEntityIDs"] as? [String])
            let resolvedRelatedIDs: [String]?
            if let rawRelatedIDs, shouldResolveEntities {
                var mappedIDs: [String] = []
                for token in rawRelatedIDs {
                    if case .matched(let page) = entityLookup.resolve(
                        rawID: token,
                        mapping: idMapping,
                        newEntityRefs: newEntityRefs
                    ) {
                        mappedIDs.append(page.id)
                    }
                }
                resolvedRelatedIDs = NarrativeEntityResolver.deduplicatedNonEmptyStrings(mappedIDs)
            } else {
                resolvedRelatedIDs = rawRelatedIDs
            }
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
                    relatedEntityIDs: resolvedRelatedIDs,
                    evidenceAnchor: anchor,
                    authority: authority,
                    nodeID: nodeID,
                    createdAt: now
                )
            )
        }
        return threadEvents
    }

    private static func parseSceneTransition(from object: [String: Any]) -> SceneTransitionSignal? {
        guard let raw = (object["scene_transition"] as? [String: Any])
            ?? (object["sceneTransition"] as? [String: Any])
        else {
            return nil
        }
        let shifted = parseBool(raw["shifted"]) ?? false
        let rawLayer = NarrativeJSONScanner.firstNonEmptyString(
            raw,
            keys: ["previous_layer", "previousLayer"]
        ).lowercased()
        let previousLayer: SceneNarrativeLayer
        switch rawLayer {
        case "canon_closed", "closed", "closed_scene":
            previousLayer = .canonClosed
        case "subjective_insert", "subjective", "flashback", "dream":
            previousLayer = .subjectiveInsert
        default:
            previousLayer = .canonOngoing
        }
        let timeAnchor = NarrativeJSONScanner.firstNonEmptyString(
            raw,
            keys: ["time_anchor", "timeAnchor"]
        )
        let neutralBridge = NarrativeJSONScanner.firstNonEmptyString(
            raw,
            keys: ["neutral_bridge", "neutralBridge"]
        )
        if !shifted && previousLayer == .canonOngoing && timeAnchor.isEmpty && neutralBridge.isEmpty {
            return nil
        }
        return SceneTransitionSignal(
            shifted: shifted,
            previousLayer: previousLayer,
            timeAnchor: timeAnchor,
            neutralBridge: neutralBridge
        )
    }

    private static func prioritizeKnownEntities(
        _ entities: [EntityPage],
        in scanText: String,
        limit: Int
    ) -> [EntityPage] {
        guard !entities.isEmpty, limit > 0 else { return [] }
        return entities
            .sorted { lhs, rhs in
                let lhsMentioned = isEntityMentioned(lhs, in: scanText)
                let rhsMentioned = isEntityMentioned(rhs, in: scanText)
                if lhsMentioned != rhsMentioned { return lhsMentioned && !rhsMentioned }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func isEntityMentioned(_ page: EntityPage, in scanText: String) -> Bool {
        guard !scanText.isEmpty else { return false }
        let name = page.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, scanText.localizedCaseInsensitiveContains(name) {
            return true
        }
        return page.aliases.contains { alias in
            let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            return !clean.isEmpty
                && !NarrativeEntityResolver.isGenericRoleTerm(clean)
                && scanText.localizedCaseInsensitiveContains(clean)
        }
    }

    static func prioritizeActiveEvents(
        _ events: [EpisodicEvent],
        in scanText: String,
        entityNamesByID: [String: String],
        limit: Int = 12
    ) -> [EpisodicEvent] {
        guard !events.isEmpty, limit > 0 else { return [] }
        let scored = events.map { event -> (event: EpisodicEvent, score: Int) in
            var score = 0
            if !scanText.isEmpty {
                for entityID in event.participantEntityIDs {
                    if let name = entityNamesByID[entityID]?.trimmingCharacters(in: .whitespacesAndNewlines),
                       name.count >= 2,
                       scanText.localizedCaseInsensitiveContains(name) {
                        score += 3
                    }
                }
                let textTokens = [event.title, event.scene, event.arcTitle]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count >= 2 }
                if textTokens.contains(where: { scanText.localizedCaseInsensitiveContains($0) }) {
                    score += 2
                }
            }
            return (event, score)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.event.updatedAt != rhs.event.updatedAt { return lhs.event.updatedAt > rhs.event.updatedAt }
                return lhs.event.id < rhs.event.id
            }
            .prefix(limit)
            .map(\.event)
    }

    private static func parseNewEntities(
        from object: [String: Any],
        excerpt: String,
        pageIndex: Int,
        baseUTF16Offset: Int,
        knownEntities: [EntityPage],
        idMapping: NarrativeEntityResolver.ExtractionIDMapping?,
        now: Date
    ) -> (upserts: [EntityPage], newEntityRefs: [String: EntityPage], droppedCount: Int) {
        let rawEntities = (object["new_entities"] as? [[String: Any]])
            ?? (object["newEntities"] as? [[String: Any]])
            ?? []
        guard !rawEntities.isEmpty else { return ([], [:], 0) }

        var lookupIndex = NarrativeEntityResolver.EntityLookupIndex(pages: knownEntities)
        var usedIDs = Set(knownEntities.map(\.id))
        var upsertsByID: [String: EntityPage] = [:]
        var orderedUpsertIDs: [String] = []
        var newEntityRefs: [String: EntityPage] = [:]
        var droppedCount = 0

        for item in rawEntities {
            let name = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["name", "title"])
            guard !name.isEmpty else { continue }
            if NarrativeEntityResolver.isGenericRoleTerm(name) {
                droppedCount += 1
                continue
            }

            let kindRaw = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["kind", "type"])
            let kind = NarrativeEntityExtractor.parseKind(kindRaw) ?? .character
            let rawID = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["id", "entity_id"])
            let incomingIdentity = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["identity", "role", "summary"])
            let rawAliases = NarrativeEntityExtractor.parseStringArray(item["aliases"])
            let sanitizedIncomingAliases = NarrativeEntityResolver.sanitizedAliases(
                rawAliases,
                canonicalName: name
            )
            let triggerKeywords = NarrativeEntityExtractor.parseStringArray(
                item["trigger_keywords"] ?? item["triggerKeywords"] ?? item["keywords"]
            )
            .filter { NarrativeEntityResolver.normalizeName($0) != NarrativeEntityResolver.normalizeName(name) }

            switch lookupIndex.resolve(
                rawID: rawID,
                name: name,
                aliases: sanitizedIncomingAliases,
                expectedKind: kind,
                mapping: idMapping,
                newEntityRefs: newEntityRefs
            ) {
            case .matched(var existing):
                let nameKey = NarrativeEntityResolver.normalizeName(name)
                let existingNameKey = NarrativeEntityResolver.normalizeName(existing.name)
                let existingAliasKeys = Set(existing.aliases.map(NarrativeEntityResolver.normalizeName))
                let extraNames = nameKey != existingNameKey ? [name] : []
                let candidateAliases = sanitizedIncomingAliases + extraNames
                let hasNewAlias = candidateAliases.contains {
                    let key = NarrativeEntityResolver.normalizeName($0)
                    return !key.isEmpty && key != existingNameKey && !existingAliasKeys.contains(key)
                }

                // 若名称与已知实体完全相同且无新增别名，直接绑定引用并跳过重复建档。
                if nameKey == existingNameKey && !hasNewAlias {
                    registerNewEntityRef(name: name, aliases: sanitizedIncomingAliases, page: existing, into: &newEntityRefs)
                    continue
                }

                let mergedAliases = NarrativeEntityResolver.sanitizedAliases(
                    existing.aliases + candidateAliases,
                    canonicalName: existing.name
                )
                let mergedKeywords = NarrativeEntityResolver.deduplicatedNonEmptyStrings(
                    existing.triggerKeywords + triggerKeywords
                )
                let mergedIdentity = NarrativeEntityResolver.appendUniqueSentences(
                    existing.identity,
                    incomingIdentity
                )
                let changed = mergedAliases != existing.aliases
                    || mergedKeywords != existing.triggerKeywords
                    || mergedIdentity != existing.identity
                if changed {
                    existing.aliases = mergedAliases
                    existing.triggerKeywords = mergedKeywords
                    existing.identity = mergedIdentity
                    existing.updatedAt = now
                    lookupIndex.register(existing)
                    if upsertsByID[existing.id] == nil {
                        orderedUpsertIDs.append(existing.id)
                    }
                    upsertsByID[existing.id] = existing
                }
                registerNewEntityRef(name: name, aliases: sanitizedIncomingAliases, page: existing, into: &newEntityRefs)
                continue

            case .ambiguous:
                droppedCount += 1
                continue

            case .notFound:
                let quote = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["quote", "evidence"])
                let groundedByName = !excerpt.isEmpty && excerpt.localizedCaseInsensitiveContains(name)
                let groundedByQuote = verifiedAnchor(
                    quote: quote,
                    in: excerpt,
                    pageIndex: pageIndex,
                    baseUTF16Offset: baseUTF16Offset
                ) != nil
                guard groundedByName || groundedByQuote else { continue }

                var slugIndex = 0
                var entityID = ""
                repeat {
                    let seed = slugIndex == 0 ? name : "\(name):\(slugIndex)"
                    entityID = "auto_\(kind.rawValue)_\(SummaryKey.sha256Hex(seed).prefix(8))"
                    slugIndex += 1
                } while !usedIDs.insert(entityID).inserted

                let created = EntityPage(
                    id: entityID,
                    kind: kind,
                    name: name,
                    aliases: sanitizedIncomingAliases,
                    triggerKeywords: triggerKeywords,
                    identity: incomingIdentity,
                    enabled: true,
                    updatedAt: now
                )
                lookupIndex.register(created)
                orderedUpsertIDs.append(entityID)
                upsertsByID[entityID] = created
                registerNewEntityRef(name: name, aliases: sanitizedIncomingAliases, page: created, into: &newEntityRefs)
            }
        }

        let upserts = orderedUpsertIDs.compactMap { upsertsByID[$0] }
        return (upserts, newEntityRefs, droppedCount)
    }

    private static func registerNewEntityRef(
        name: String,
        aliases: [String],
        page: EntityPage,
        into refs: inout [String: EntityPage]
    ) {
        let nameKey = NarrativeEntityResolver.normalizeName(name)
        if !nameKey.isEmpty, refs[nameKey] == nil {
            refs[nameKey] = page
        }
        let pageNameKey = NarrativeEntityResolver.normalizeName(page.name)
        if !pageNameKey.isEmpty, refs[pageNameKey] == nil {
            refs[pageNameKey] = page
        }
        for alias in aliases where !NarrativeEntityResolver.isGenericRoleTerm(alias) {
            let key = NarrativeEntityResolver.normalizeName(alias)
            if !key.isEmpty, refs[key] == nil {
                refs[key] = page
            }
        }
    }

    private static func parseEpisodicEvents(
        from object: [String: Any],
        excerpt: String,
        nodeID: String,
        pageIndex: Int,
        baseUTF16Offset: Int,
        entityLookup: NarrativeEntityResolver.EntityLookupIndex,
        idMapping: NarrativeEntityResolver.ExtractionIDMapping?,
        newEntityRefs: [String: EntityPage],
        activeEvents: [EpisodicEvent],
        now: Date,
        droppedSpeculativeCount: inout Int
    ) -> [EpisodicEvent] {
        let rawEvents = (object["events"] as? [[String: Any]])
            ?? (object["episodic_events"] as? [[String: Any]])
            ?? (object["episodicEvents"] as? [[String: Any]])
            ?? []
        guard !rawEvents.isEmpty else { return [] }

        var activeEventsByID: [String: EpisodicEvent] = [:]
        var activeEventsByLowerTitle: [String: EpisodicEvent] = [:]
        for event in activeEvents {
            activeEventsByID[event.id] = event
            let lower = event.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !lower.isEmpty, activeEventsByLowerTitle[lower] == nil {
                activeEventsByLowerTitle[lower] = event
            }
        }

        var events: [EpisodicEvent] = []
        for (idx, item) in rawEvents.enumerated() {
            let title = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["title", "name"])
            guard !title.isEmpty else { continue }
            let rawID = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["id", "event_id", "eventID"])
            let mappedEventID = idMapping?.eventShortToReal[rawID.uppercased()] ?? rawID
            let existing = (!mappedEventID.isEmpty ? activeEventsByID[mappedEventID] : nil)
                ?? activeEventsByLowerTitle[title.lowercased()]

            let quote = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["quote", "evidence"])
            let anchor = verifiedAnchor(
                quote: quote,
                in: excerpt,
                pageIndex: pageIndex,
                baseUTF16Offset: baseUTF16Offset
            )
            let matchesTitle = !excerpt.isEmpty && excerpt.localizedCaseInsensitiveContains(title)
            guard anchor != nil || matchesTitle || existing != nil else {
                droppedSpeculativeCount += 1
                continue
            }

            let arcTitle = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["arc", "arc_title", "arcTitle", "storyline"])
            let scene = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["scene", "location"])
            let cause = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["cause", "reason"])
            let development = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["development", "progress", "detail"])
            let outcome = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["outcome", "consequence", "result"])
            let statusRaw = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["status", "state"]).lowercased()
            let status: EpisodicEventStatus = (statusRaw == "resolved" || statusRaw == "closed" || statusRaw == "ended" || statusRaw == "done")
                ? .resolved
                : .ongoing

            let rawParticipants = NarrativeEntityExtractor.parseStringArray(
                item["participants"] ?? item["characters"] ?? item["participant_entity_ids"] ?? item["participantEntityIDs"]
            )
            var resolvedParticipants: [String] = []
            for token in rawParticipants {
                if case .matched(let page) = entityLookup.resolve(
                    rawID: token,
                    mapping: idMapping,
                    newEntityRefs: newEntityRefs
                ) {
                    resolvedParticipants.append(page.id)
                }
            }
            let participantIDs = NarrativeEntityResolver.deduplicatedNonEmptyStrings(resolvedParticipants)

            let resolvedID = existing?.id
                ?? (mappedEventID.isEmpty ? "\(nodeID)_evt_\(idx)_\(SummaryKey.sha256Hex(title).prefix(8))" : mappedEventID)
            let authority: AuthorityRank = anchor != nil ? .canonProseQuote : .inferredByAI

            events.append(
                EpisodicEvent(
                    id: resolvedID,
                    title: title,
                    arcTitle: arcTitle,
                    scene: scene,
                    participantEntityIDs: participantIDs,
                    cause: cause,
                    development: development,
                    outcome: outcome,
                    status: status,
                    authority: authority,
                    quoteAnchor: anchor,
                    nodeID: nodeID,
                    updatedAt: now
                )
            )
        }
        return events
    }

    private static let quoteWrapperCharacters = CharacterSet(charactersIn: "「」『』“”\"\"''")

    private static let relaxedAnchorIgnoredChars: Set<Character> = [
        " ", "\t", "\n", "\r", "\u{3000}",
        "，", ",", "。", "、", "；", ";", "：", ":", "！", "!", "？", "?",
        "“", "”", "\"", "‘", "’", "'", "「", "」", "『", "』",
        "（", "(", "）", ")", "—", "–", "-", "…",
    ]

    static func verifiedAnchor(
        quote: String,
        in excerpt: String,
        pageIndex: Int,
        baseUTF16Offset: Int
    ) -> TextSpanAnchor? {
        let cleanQuote = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanQuote.isEmpty else { return nil }
        let nsExcerpt = excerpt as NSString

        let exactRange = nsExcerpt.range(of: cleanQuote)
        if exactRange.location != NSNotFound {
            let paragraph = excerpt
                .components(separatedBy: "\n")
                .first { $0.contains(cleanQuote) }
            return TextSpanAnchor.make(
                pageIndex: pageIndex,
                utf16Start: baseUTF16Offset + exactRange.location,
                utf16Length: exactRange.length,
                quote: cleanQuote,
                paragraphText: paragraph ?? cleanQuote
            )
        }

        var stripped = cleanQuote.trimmingCharacters(in: quoteWrapperCharacters)
        while stripped.hasSuffix("…") {
            stripped = String(stripped.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while stripped.hasSuffix("...") {
            stripped = String(stripped.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !stripped.isEmpty && stripped != cleanQuote {
            let strippedRange = nsExcerpt.range(of: stripped)
            if strippedRange.location != NSNotFound {
                let paragraph = excerpt
                    .components(separatedBy: "\n")
                    .first { $0.contains(stripped) }
                return TextSpanAnchor.make(
                    pageIndex: pageIndex,
                    utf16Start: baseUTF16Offset + strippedRange.location,
                    utf16Length: strippedRange.length,
                    quote: stripped,
                    paragraphText: paragraph ?? stripped
                )
            }
        }

        if let relaxedRange = relaxedAnchorRange(of: stripped.isEmpty ? cleanQuote : stripped, in: excerpt) {
            let matchedSlice = nsExcerpt.substring(with: relaxedRange)
            let paragraph = excerpt
                .components(separatedBy: "\n")
                .first { $0.contains(matchedSlice) }
            return TextSpanAnchor.make(
                pageIndex: pageIndex,
                utf16Start: baseUTF16Offset + relaxedRange.location,
                utf16Length: relaxedRange.length,
                quote: matchedSlice,
                paragraphText: paragraph ?? matchedSlice
            )
        }

        return nil
    }

    /// 对空白与全半角标点容错的原文对齐：仅在去标点长度 >= 4 时启用，返回原始 `excerpt` 的 UTF-16 区间。
    private static func relaxedAnchorRange(of quote: String, in excerpt: String) -> NSRange? {
        let normalizedQuoteChars = quote.lowercased().filter { !relaxedAnchorIgnoredChars.contains($0) }
        guard normalizedQuoteChars.count >= 4 else { return nil }
        let normalizedQuote = String(normalizedQuoteChars)

        var strippedChars: [Character] = []
        var utf16Starts: [Int] = []
        var utf16Ends: [Int] = []
        var utf16Cursor = 0
        for ch in excerpt {
            let chLen = ch.utf16.count
            if !relaxedAnchorIgnoredChars.contains(ch) {
                for lowerChar in ch.lowercased() {
                    strippedChars.append(lowerChar)
                    utf16Starts.append(utf16Cursor)
                    utf16Ends.append(utf16Cursor + chLen)
                }
            }
            utf16Cursor += chLen
        }

        let haystack = String(strippedChars)
        guard let found = haystack.range(of: normalizedQuote) else { return nil }
        let startIndex = haystack.distance(from: haystack.startIndex, to: found.lowerBound)
        let matchCount = haystack.distance(from: found.lowerBound, to: found.upperBound)
        let endIndex = startIndex + matchCount - 1
        guard startIndex >= 0,
              endIndex >= startIndex,
              endIndex < utf16Starts.count else {
            return nil
        }
        let startUTF16 = utf16Starts[startIndex]
        let endUTF16 = utf16Ends[endIndex]
        guard endUTF16 > startUTF16 else { return nil }
        return NSRange(location: startUTF16, length: endUTF16 - startUTF16)
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
