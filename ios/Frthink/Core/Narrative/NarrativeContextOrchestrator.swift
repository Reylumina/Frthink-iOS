import Foundation

/// 尾部场次正文截取档位，兼顾局部衔接连贯性与上下文窗口预算。
enum ManuscriptTailTier: Int, Codable, Hashable, CaseIterable {
    case short = 2_000
    case standard = 6_000
    case long = 12_000

    static func from(codePoints: Int) -> ManuscriptTailTier {
        if codePoints <= 3_000 { return .short }
        if codePoints <= 8_500 { return .standard }
        return .long
    }
}

/// 缓存优先三段式上下文编排产物：分离冻结系统前缀、历史交互流与尾部动态工作区，
/// 并按渠道能力决定携带只读工具契约或启用本地预检索回填。
struct OrchestratedPrompt {
    var messages: [LLMMessage]
    var frozenSystemPrefix: String
    var tools: [LLMToolDefinition]
    var updatedReFoldBoundary: ReFoldBoundary
    var onStageEntityIDs: Set<String>
    var usedFallbackBM25: Bool
    var estimatedInputTokens: Int
}

/// 三段式上下文编排器：
/// 将缓慢变化的指令、静态文风基石与顶层目录索引固定在系统消息前缀以最大化 KV-Cache 命中，
/// 中段历史交由 ReFold 维持 append-only 可逆边界，仅在尾部拼接逐字规则、最小充分在场状态与场景锚点。
enum NarrativeContextOrchestrator {

    static func buildFrozenSystemPrefix(
        globalPreset: String,
        aiFlavorRules: String,
        skills: [Skill],
        universes: [UniverseEntry],
        preservedStyle: PreservedStyleDistillation,
        bookIndexLines: [String],
        volumeOneLiners: [String] = [],
        alwaysOnLorePages: [EntityPage] = []
    ) -> String {
        var sections: [String] = []

        let preset = globalPreset.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preset.isEmpty {
            sections.append(preset)
        }

        for skill in skills where skill.enabled {
            if let block = skill.promptBlock {
                sections.append(block)
            }
        }

        let flavor = aiFlavorRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !flavor.isEmpty {
            sections.append(
                PromptLibrary.render(PromptLibrary.stylePreferenceTemplate, [
                    "aiFlavorRules": flavor,
                ])
            )
        }

        for universe in universes where universe.enabled {
            let cleanTitle = universe.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanBody = universe.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty || !cleanBody.isEmpty else { continue }
            sections.append(
                PromptLibrary.render(PromptLibrary.universeBlockTemplate, [
                    "宇宙名": cleanTitle.isEmpty ? "共享世界书" : cleanTitle,
                    "内容": cleanBody,
                ])
            )
        }

        let template = preservedStyle.styleTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !template.isEmpty {
            sections.append(
                PromptLibrary.render(PromptLibrary.imitationTemplateBlockTemplate, [
                    "仿写模板正文": template,
                ])
            )
        }

        if let centroid = preservedStyle.centroidExemplar {
            let centroidText = centroid.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !centroidText.isEmpty {
                let rawTitle = centroid.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let technique = rawTitle.isEmpty ? "保持全书主基调的句式节奏与叙述质感。" : rawTitle
                let wrappedCentroid = """
                <style_reference_only do_not_continue="true">
                以下全书质心节选仅用于锚定整本作品的基准语感与文风质感，严禁续写其中人物或剧情：
                <style_reference index="centroid" do_not_continue="true">
                技法要求：\(technique)
                \(centroidText)
                </style_reference>
                </style_reference_only>
                """
                sections.append(wrappedCentroid)
            }
        }

        let activeAlwaysLore = alwaysOnLorePages
            .filter { $0.enabled && $0.kind == .lore && $0.activationMode == .always }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.id < rhs.id
            }
        if !activeAlwaysLore.isEmpty {
            var loreLines = ["【常驻世界观】"]
            for page in activeAlwaysLore.prefix(24) {
                var loreParts: [String] = []
                let cleanIdentity = page.identity.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanIdentity.isEmpty { loreParts.append("类别：\(cleanIdentity)") }
                let cleanSummary = page.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanSummary.isEmpty { loreParts.append(cleanSummary) }
                if !page.hardBoundaries.isEmpty {
                    loreParts.append("规则：\(page.hardBoundaries.joined(separator: "；"))")
                }
                if loreParts.isEmpty {
                    loreLines.append("- \(page.name)")
                } else {
                    loreLines.append("- \(page.name)：" + loreParts.joined(separator: "｜"))
                }
            }
            sections.append(loreLines.joined(separator: "\n"))
        }

        let cleanVolumes = volumeOneLiners
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanVolumes.isEmpty {
            let cappedVolumes = Array(cleanVolumes.prefix(12))
            sections.append("【全书卷纲脉络】\n" + cappedVolumes.map { "- \($0)" }.joined(separator: "\n"))
        }

        if !bookIndexLines.isEmpty {
            let capped = Array(bookIndexLines.prefix(200))
            sections.append("【全书实体与伏笔索引目录（细节可按需调用 read_entity_page / grep_manuscript 查阅）】\n" + capped.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }

    /// 裁剪无关实体，仅提取当前场景在场实体事实、POV 安全私有认知、就绪伏笔、因果祖先脉络与近期场拍。
    static func buildQueryConeBlock(
        state: MaterializedNarrativeState,
        scanText: String,
        povCharacterID: String? = nil,
        causalAncestors: [String] = [],
        plannedBeat: String? = nil
    ) -> (block: String, onStageEntityIDs: Set<String>) {
        let tier2Candidates = state.entityPages.values
            .filter { $0.enabled && !($0.kind == .lore && $0.activationMode == .always) }
            .sorted { lhs, rhs in
                if lhs.kind.rawValue != rhs.kind.rawValue {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.id < rhs.id
            }

        var selectedPages: [EntityPage] = []
        var onStageIDs = Set<String>()

        for page in tier2Candidates {
            let matchesScan = !scanText.isEmpty && (
                scanText.localizedCaseInsensitiveContains(page.name)
                    || page.aliases.contains { !$0.isEmpty && scanText.localizedCaseInsensitiveContains($0) }
                    || page.triggerKeywords.contains { !$0.isEmpty && scanText.localizedCaseInsensitiveContains($0) }
            )
            let isPOV = povCharacterID != nil && page.id == povCharacterID
            if matchesScan || isPOV {
                selectedPages.append(page)
                onStageIDs.insert(page.id)
            }
        }

        // 无显式命中时，仅在角色总量极小（不超过 3 人）时兜底全放入，避免大量离场角色稀释注意力。
        if selectedPages.isEmpty {
            let characters = tier2Candidates.filter { $0.kind == .character }
            if characters.count <= 3 {
                selectedPages = characters
                onStageIDs = Set(characters.map(\.id))
            }
        }

        var parts: [String] = []

        let kindSections: [(EntityKind, String)] = [
            (.character, "【当前在场人物与认知边界】"),
            (.location, "【当前地点】"),
            (.artifact, "【当前物件】"),
            (.lore, "【相关世界观】"),
        ]
        for (kind, headerTitle) in kindSections {
            let group = selectedPages.filter { $0.kind == kind }
            guard !group.isEmpty else { continue }
            var lines = [headerTitle]
            for page in group {
                lines.append(formatQueryConePageLine(for: page, state: state, povCharacterID: povCharacterID))
            }
            parts.append(lines.joined(separator: "\n"))
        }

        let scoredReadyThreads = state.threads.values
            .filter { $0.state == .ready || ($0.state == .enacted && $0.recurrence == .recurring) }
            .map { thread in
                (
                    thread: thread,
                    score: threadSceneRelevanceScore(thread, onStageIDs: onStageIDs, scanText: scanText)
                )
            }
            .sorted { lhs, rhs in
                let leftMatched = lhs.score > 0
                let rightMatched = rhs.score > 0
                if leftMatched != rightMatched { return leftMatched }
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.thread.state != rhs.thread.state { return lhs.thread.state == .ready }
                if lhs.thread.updatedAt != rhs.thread.updatedAt { return lhs.thread.updatedAt > rhs.thread.updatedAt }
                return lhs.thread.id < rhs.thread.id
            }
        let sceneMatchedReady = scoredReadyThreads.filter { $0.score > 0 }.map(\.thread)
        let selectedReadyThreads = sceneMatchedReady.isEmpty
            ? Array(scoredReadyThreads.prefix(2).map(\.thread))
            : Array(sceneMatchedReady.prefix(3))

        let selectedPendingThreads = state.threads.values
            .filter { $0.state == .pending && threadActivationCueMatches($0, scanText: scanText) }
            .map { thread in
                (
                    thread: thread,
                    score: threadSceneRelevanceScore(thread, onStageIDs: onStageIDs, scanText: scanText)
                )
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.thread.updatedAt != rhs.thread.updatedAt { return lhs.thread.updatedAt > rhs.thread.updatedAt }
                return lhs.thread.id < rhs.thread.id
            }
            .prefix(2)
            .map(\.thread)

        let oneHopOffStagePages = collectOneHopRelatedOffStagePages(
            selectedPages: selectedPages,
            onStageIDs: onStageIDs,
            enabledPages: tier2Candidates,
            readyThreads: selectedReadyThreads + selectedPendingThreads,
            state: state
        )
        if !oneHopOffStagePages.isEmpty {
            var relatedLines = ["【关联离场实体（一跳）】"]
            for page in oneHopOffStagePages {
                var briefParts: [String] = []
                let summaryRaw = [page.summary, page.identity]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                if let summaryRaw {
                    let clipped = summaryRaw.count > 60 ? String(summaryRaw.prefix(60)) + "…" : summaryRaw
                    briefParts.append("简述：\(clipped)")
                }
                let keyFacts = state.facts(for: page.id).prefix(2)
                for fact in keyFacts {
                    briefParts.append("\(fact.attribute)=\(fact.value)")
                }
                let header = "- \(page.name)（\(page.kind.rawValue)/\(page.id)）"
                if briefParts.isEmpty {
                    relatedLines.append(header)
                } else {
                    relatedLines.append("\(header)：" + briefParts.joined(separator: "｜"))
                }
            }
            parts.append(relatedLines.joined(separator: "\n"))
        }

        if !selectedReadyThreads.isEmpty {
            var threadLines = ["【条件已就绪待推进伏笔】"]
            for thread in selectedReadyThreads {
                threadLines.append(formattedThreadContextLine(thread))
            }
            parts.append(threadLines.joined(separator: "\n"))
        }

        if !selectedPendingThreads.isEmpty {
            var pendingLines = ["【当前场景关联潜伏伏笔（可自然呼应，不必强行收线）】"]
            for thread in selectedPendingThreads {
                pendingLines.append(formattedThreadContextLine(thread))
            }
            parts.append(pendingLines.joined(separator: "\n"))
        }

        if !causalAncestors.isEmpty {
            parts.append("【当前情节因果脉络】\n" + causalAncestors.map { "- \($0)" }.joined(separator: "\n"))
        }

        if let cleanBeat = plannedBeat?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cleanBeat.isEmpty {
            parts.append("【本幕待写目标】\n- \(cleanBeat)")
        }

        let closedPlotlines = state.pyramid.closedPlotlines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .suffix(5)
        if !closedPlotlines.isEmpty {
            parts.append("【近期阶段/章节摘要】\n" + closedPlotlines.map { "- \($0)" }.joined(separator: "\n"))
        }

        let recentCards = state.pyramid.recentSceneCards.suffix(3)
        if !recentCards.isEmpty {
            parts.append("【近期场拍卡】\n" + recentCards.map { "- \($0)" }.joined(separator: "\n"))
        }

        if let eventsBlock = buildEpisodicEventsBlock(
            state: state,
            onStageIDs: onStageIDs,
            scanText: scanText
        ) {
            parts.append(eventsBlock)
        }

        return (parts.joined(separator: "\n\n"), onStageIDs)
    }

    private static func formatQueryConePageLine(
        for page: EntityPage,
        state: MaterializedNarrativeState,
        povCharacterID: String?
    ) -> String {
        let identityLabel: String
        let summaryLabel: String?
        let boundaryLabel: String
        switch page.kind {
        case .character:
            identityLabel = "身份"
            summaryLabel = nil
            boundaryLabel = "底线"
        case .location:
            identityLabel = "定位"
            summaryLabel = "布局与氛围"
            boundaryLabel = "空间限制"
        case .artifact:
            identityLabel = "归属"
            summaryLabel = "用途与状态"
            boundaryLabel = "代价与限制"
        case .lore:
            identityLabel = "类别"
            summaryLabel = "说明"
            boundaryLabel = "规则与例外"
        }

        var detailParts: [String] = []
        let cleanIdentity = page.identity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanIdentity.isEmpty {
            detailParts.append("\(identityLabel)：\(cleanIdentity)")
        }
        if let summaryLabel {
            let cleanSummary = page.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanSummary.isEmpty, cleanSummary != cleanIdentity {
                detailParts.append("\(summaryLabel)：\(cleanSummary)")
            }
        }
        if page.kind == .character {
            let cleanVoice = page.voiceProfile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanVoice.isEmpty {
                detailParts.append("声线：\(cleanVoice)")
            }
        }
        if !page.hardBoundaries.isEmpty {
            detailParts.append("\(boundaryLabel)：\(page.hardBoundaries.joined(separator: "；"))")
        }
        for fact in state.facts(for: page.id) {
            detailParts.append("\(fact.attribute)=\(fact.value)")
        }
        if page.kind == .character {
            // POV 隔离：若指定了视角角色，仅暴露该视角角色自身认知，屏蔽其他角色未公开的秘密认知。
            let visibleBeliefs = state.beliefs(for: page.id).filter { belief in
                guard let povCharacterID else { return true }
                return page.id == povCharacterID || !belief.knowsSecret
            }
            for belief in visibleBeliefs {
                let prefix = belief.knowsSecret ? "已知[\(belief.topic)]" : "盲区/误认为[\(belief.topic)]"
                detailParts.append("\(prefix)：\(belief.believedTruth)")
            }
        }

        let header = "- \(page.name)（\(page.kind.rawValue)/\(page.id)）"
        return detailParts.isEmpty ? header : "\(header)：" + detailParts.joined(separator: "｜")
    }

    /// 从就绪伏笔的关联实体及在场实体的关系事实出发，做纯符号一跳扩展，补全最多 2 个离场关键实体。
    private static func collectOneHopRelatedOffStagePages(
        selectedPages: [EntityPage],
        onStageIDs: Set<String>,
        enabledPages: [EntityPage],
        readyThreads: [ProspectiveThread],
        state: MaterializedNarrativeState,
        limit: Int = 2
    ) -> [EntityPage] {
        guard limit > 0 else { return [] }
        let offStagePages = enabledPages.filter { !onStageIDs.contains($0.id) }
        guard !offStagePages.isEmpty else { return [] }

        var matchedIDs = Set<String>()

        for thread in readyThreads {
            for entityID in thread.relatedEntityIDs where !onStageIDs.contains(entityID) {
                matchedIDs.insert(entityID)
            }
        }

        let relationValues: [String] = selectedPages.flatMap { page in
            state.facts(for: page.id).compactMap { fact -> String? in
                if fact.attribute == WorldFactEvent.StandardAttribute.relation || fact.attribute == "关系" {
                    return fact.value
                }
                if fact.attribute.hasPrefix("relation:") {
                    let target = String(fact.attribute.dropFirst("relation:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return target.isEmpty ? fact.value : "\(target) \(fact.value)"
                }
                return nil
            }
        }
        if !relationValues.isEmpty {
            for candidate in offStagePages {
                let name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let aliases = candidate.aliases
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count >= 2 }
                let hit = relationValues.contains { value in
                    if !name.isEmpty {
                        if value == name { return true }
                        if name.count >= 2 && value.localizedCaseInsensitiveContains(name) {
                            return true
                        }
                    }
                    return aliases.contains { value.localizedCaseInsensitiveContains($0) }
                }
                if hit {
                    matchedIDs.insert(candidate.id)
                }
            }
        }

        guard !matchedIDs.isEmpty else { return [] }
        return Array(offStagePages.filter { matchedIDs.contains($0.id) }.prefix(limit))
    }

    private static func threadActivationCueMatches(
        _ thread: ProspectiveThread,
        scanText: String
    ) -> Bool {
        let cleanCue = thread.activationCue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scanText.isEmpty, !cleanCue.isEmpty else { return false }
        let delimiters = CharacterSet(charactersIn: "，。、；;！？!?,.\n\t：:")
            .union(.whitespaces)
        let tokens = cleanCue.components(separatedBy: delimiters)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        return (cleanCue.count >= 2 && scanText.localizedCaseInsensitiveContains(cleanCue))
            || tokens.contains { scanText.localizedCaseInsensitiveContains($0) }
    }

    private static func threadSceneRelevanceScore(
        _ thread: ProspectiveThread,
        onStageIDs: Set<String>,
        scanText: String
    ) -> Int {
        var score = 0
        if thread.relatedEntityIDs.contains(where: { onStageIDs.contains($0) }) {
            score += 3
        }
        if threadActivationCueMatches(thread, scanText: scanText) {
            score += 2
        }
        return score
    }

    private static func formattedThreadContextLine(_ thread: ProspectiveThread) -> String {
        var suffixParts: [String] = []
        let cue = thread.activationCue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cue.isEmpty {
            suffixParts.append("触发线索：\(cue)")
        }
        if let quoteRaw = thread.evidenceAnchors.last?.quote.trimmingCharacters(in: .whitespacesAndNewlines),
           !quoteRaw.isEmpty {
            let clipped = quoteRaw.count > 40 ? String(quoteRaw.prefix(40)) + "…" : quoteRaw
            suffixParts.append("埋设依据：\(clipped)")
        }
        if suffixParts.isEmpty {
            return "- [\(thread.id)] \(thread.goal)"
        }
        return "- [\(thread.id)] \(thread.goal)（" + suffixParts.joined(separator: "；") + "）"
    }

    private static func buildEpisodicEventsBlock(
        state: MaterializedNarrativeState,
        onStageIDs: Set<String>,
        scanText: String
    ) -> String? {
        guard !state.episodicEvents.isEmpty else { return nil }
        let scored = state.episodicEvents.values
            .map { event -> (event: EpisodicEvent, score: Int) in
                var score = event.status == .ongoing ? 1 : 0
                let participantHits = event.participantEntityIDs.filter { onStageIDs.contains($0) }.count
                score += participantHits * 3
                if !scanText.isEmpty {
                    let tokens = [event.title, event.scene, event.arcTitle]
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { $0.count >= 2 }
                    if tokens.contains(where: { scanText.localizedCaseInsensitiveContains($0) }) {
                        score += 2
                    }
                }
                return (event, score)
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.event.status != rhs.event.status { return lhs.event.status == .ongoing }
                if lhs.event.updatedAt != rhs.event.updatedAt { return lhs.event.updatedAt > rhs.event.updatedAt }
                return lhs.event.id < rhs.event.id
            }

        let sceneMatched = scored.filter { $0.score > 1 }.prefix(4).map(\.event)
        let chosen: [EpisodicEvent]
        if !sceneMatched.isEmpty {
            chosen = Array(sceneMatched)
        } else {
            chosen = Array(scored.filter { $0.event.status == .ongoing }.prefix(2).map(\.event))
        }
        guard !chosen.isEmpty else { return nil }
        return "【相关关键事件】\n" + chosen.map { "- \($0.formattedSummaryLine)" }.joined(separator: "\n")
    }

    static func effectiveTailText(
        manuscript: String,
        continuationAnchor: Int?,
        tailTier: ManuscriptTailTier,
        tailCodePointLimitOverride: Int? = nil
    ) -> (causalPrefix: String, causalCutoff: Int?, tailText: String) {
        let nsManuscript = manuscript as NSString
        let causalPrefix: String
        let causalCutoff: Int?
        if let anchor = continuationAnchor, anchor > 0, anchor <= nsManuscript.length {
            causalPrefix = nsManuscript.substring(to: anchor)
            causalCutoff = anchor
        } else {
            causalPrefix = manuscript
            causalCutoff = nil
        }
        let limit = max(1, tailCodePointLimitOverride ?? tailTier.rawValue)
        let tailText = PromptComposer.codePointTail(causalPrefix, limit: limit)
        return (causalPrefix, causalCutoff, tailText)
    }

    static func compose(
        workspace: NarrativeWorkspace,
        manuscript: String,
        history: [LLMMessage],
        userInstruction: String?,
        settings: AppSettings,
        enabledUniverseEntryIDs: [String],
        continuationAnchor: Int? = nil,
        tailTier: ManuscriptTailTier = .standard,
        tailCodePointLimitOverride: Int? = nil,
        inputBudget: Int,
        enableTools: Bool,
        povCharacterID: String? = nil,
        bm25Index: ManuscriptIndex.IncrementalBM25Index? = nil
    ) -> OrchestratedPrompt {
        let state = workspace.currentState()

        let enabledUniverses = settings.enabledUniverseEntries(for: enabledUniverseEntryIDs)
        let bookIndex = state.bookIndexLines(maxLines: 200)
        let alwaysOnLorePages = state.entityPages.values.filter {
            $0.enabled && $0.kind == .lore && $0.activationMode == .always
        }
        var effectiveStyle = workspace.preservedStyle
        if !settings.corpusEnabled {
            effectiveStyle.centroidExemplar = nil
            effectiveStyle.exemplars = []
        }
        let frozenSystemPrefix = buildFrozenSystemPrefix(
            globalPreset: settings.globalPreset,
            aiFlavorRules: settings.aiFlavorRules,
            skills: settings.skills,
            universes: enabledUniverses,
            preservedStyle: effectiveStyle,
            bookIndexLines: bookIndex,
            volumeOneLiners: state.pyramid.volumeOneLiners,
            alwaysOnLorePages: alwaysOnLorePages
        )

        // 按继续写作锚点执行严格因果截断，杜绝锚点之后的正文进入下文工作区。
        let tailSlice = effectiveTailText(
            manuscript: manuscript,
            continuationAnchor: continuationAnchor,
            tailTier: tailTier,
            tailCodePointLimitOverride: tailCodePointLimitOverride
        )
        let causalPrefix = tailSlice.causalPrefix
        let causalCutoff = tailSlice.causalCutoff
        let tailText = tailSlice.tailText
        let cleanInstruction = userInstruction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let scanText = [cleanInstruction, tailText].filter { !$0.isEmpty }.joined(separator: "\n")

        let resolvedPOVID = povCharacterID.flatMap {
            state.entityPages[$0]?.enabled == true ? $0 : nil
        }
        let causalAncestors = workspace.storyGraph.causalAncestorSummaries(
            of: workspace.storyGraph.headNodeID,
            limit: 6
        )
        let plannedBeat = workspace.storyGraph.plannedBeatSummary()
        let queryCone = buildQueryConeBlock(
            state: state,
            scanText: scanText,
            povCharacterID: resolvedPOVID,
            causalAncestors: causalAncestors,
            plannedBeat: plannedBeat
        )

        let systemTokens = frozenSystemPrefix.isEmpty ? 0 : TokenEstimator.estimate(frozenSystemPrefix)
        let effectiveWindow = settings.contextWindowTokens > 0
            ? settings.contextWindowTokens
            : TokenEstimator.contextWindow(for: settings.activeProvider?.resolvedModel ?? "")
        let historyBudget = max(1_024, inputBudget - systemTokens - TokenEstimator.estimate(tailText))
        let reFoldPlan = ReFoldManager.apply(
            history: history,
            boundary: workspace.reFoldBoundary,
            modelContextWindow: effectiveWindow,
            effectiveInputBudget: historyBudget,
            allowRestoreTool: enableTools
        )

        // 构建尾部动态工作区：逐字规则 -> Query-Cone 最小状态 -> 场次正文 Tail -> 尾部动态文风样本 -> 工具回退预检。
        var tailSections: [String] = []

        let currentBranchID = workspace.storyGraph.nodes[workspace.storyGraph.headNodeID]?.branchLabel
        let authorityRules = state.directiveLedger.renderedAuthorityBlock(
            branchID: currentBranchID,
            entityIDs: queryCone.onStageEntityIDs
        )
        if !authorityRules.isEmpty {
            tailSections.append(authorityRules)
        }

        if !queryCone.block.isEmpty {
            tailSections.append(queryCone.block)
        }

        if !tailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tailSections.append("【当前场次正文】\n" + tailText)
        }

        if settings.corpusEnabled {
            let centroidID = effectiveStyle.centroidExemplar?.id
            let sceneCandidateEntries = effectiveStyle.exemplars
                .filter { entry in
                    if let centroidID, entry.id == centroidID { return false }
                    return true
                }
                .map { entry in
                    PromptAssembly.Corpus(
                        libraryID: "preserved-exemplars",
                        libraryName: "场景示范",
                        entryID: entry.id,
                        entryName: entry.title,
                        category: "仿写样本",
                        text: entry.text
                    )
                }
            let sceneStyleRef = StyleDistiller.styleReferenceBlock(
                from: sceneCandidateEntries,
                maxSamples: 1,
                tokenBudget: max(256, inputBudget / 6),
                instructionText: cleanInstruction.isEmpty ? nil : cleanInstruction,
                queryText: PromptComposer.codePointTail(tailText, limit: 800)
            )
            if let renderedStyle = sceneStyleRef.block?.rendered, !renderedStyle.isEmpty {
                tailSections.append(renderedStyle)
            }
        }

        let prefetch = buildLexicalPrefetchSection(
            workspace: workspace,
            state: state,
            onStageEntityIDs: queryCone.onStageEntityIDs,
            causalPrefix: causalPrefix,
            tailText: tailText,
            scanText: scanText,
            cleanInstruction: cleanInstruction,
            causalCutoff: causalCutoff,
            inputBudget: inputBudget,
            enableTools: enableTools,
            bm25Index: bm25Index
        )
        if let section = prefetch.section {
            tailSections.append(section)
        }
        let usedFallbackBM25 = prefetch.usedFallbackBM25

        var assembled: [LLMMessage] = []
        if !frozenSystemPrefix.isEmpty {
            assembled.append(.system(frozenSystemPrefix))
        }
        assembled.append(contentsOf: reFoldPlan.messages)

        let tailWorkspace = tailSections.joined(separator: "\n\n")
        if !tailWorkspace.isEmpty {
            assembled.append(.user(tailWorkspace))
        }
        if !cleanInstruction.isEmpty {
            assembled.append(.user(cleanInstruction))
        }

        let finalMessages = enableTools ? assembled : mergeConsecutiveNonSystemRoles(assembled)
        let activeTools = enableTools ? NarrativeReadTools.definitions : []

        return OrchestratedPrompt(
            messages: finalMessages,
            frozenSystemPrefix: frozenSystemPrefix,
            tools: activeTools,
            updatedReFoldBoundary: reFoldPlan.updatedBoundary,
            onStageEntityIDs: queryCone.onStageEntityIDs,
            usedFallbackBM25: usedFallbackBM25,
            estimatedInputTokens: TokenEstimator.estimate(messages: finalMessages)
        )
    }

    /// 构建语境感知选区改写提示词：注入前后文衔接片段、在场实体约束、活跃规则与仿写基准（StoryLens）。
    static func buildRewritePrompt(
        workspace: NarrativeWorkspace?,
        manuscript: String,
        range: NSRange,
        selection: String,
        instruction: String,
        settings: AppSettings
    ) -> [LLMMessage] {
        var systemParts = [
            "你是中文小说编辑。只改写【待改写片段】，严格保留未要求改动的人物事实、视角、时态和上下文衔接。只输出改写后的片段本身，不要重复上下文、不要解释、不要加引号、不要 Markdown、不要复述要求。"
        ]
        if let styleTemplate = workspace?.preservedStyle.styleTemplate.trimmingCharacters(in: .whitespacesAndNewlines),
           !styleTemplate.isEmpty {
            systemParts.append("【仿写模板】\n\(styleTemplate)")
        }
        let flavor = settings.aiFlavorRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !flavor.isEmpty {
            systemParts.append("【文风与去 AI 规范】\n\(flavor)")
        }

        let nsManuscript = manuscript as NSString
        let safeStart = max(0, min(range.location, nsManuscript.length))
        let safeEnd = max(safeStart, min(range.location + max(0, range.length), nsManuscript.length))
        let beforeContext = PromptComposer.codePointTail(nsManuscript.substring(to: safeStart), limit: 500)
        let afterContext = String(nsManuscript.substring(from: safeEnd).prefix(300))
        let cleanInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)

        var userSections: [String] = []
        if let workspace {
            let state = workspace.currentState()
            let scanText = [beforeContext, selection, cleanInstruction]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let cone = buildQueryConeBlock(
                state: state,
                scanText: scanText,
                povCharacterID: workspace.activePOVCharacterID
            )
            let currentBranchID = workspace.storyGraph.nodes[workspace.storyGraph.headNodeID]?.branchLabel
            let authorityRules = state.directiveLedger.renderedAuthorityBlock(
                branchID: currentBranchID,
                entityIDs: cone.onStageEntityIDs
            )
            if !authorityRules.isEmpty {
                userSections.append(authorityRules)
            }
            if !cone.block.isEmpty {
                userSections.append(cone.block)
            }
        }

        if !beforeContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userSections.append("【上文衔接（仅供衔接，勿重复输出）】\n\(beforeContext)")
        }
        userSections.append("【待改写片段】\n\(selection)")
        if !afterContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userSections.append("【下文衔接（仅供衔接，勿重复输出）】\n\(afterContext)")
        }
        let finalRequirement = cleanInstruction.isEmpty
            ? "保留原意和人物视角，让文字更自然、更有画面感。"
            : cleanInstruction
        userSections.append("【改写要求】\n\(finalRequirement)")

        return [
            .system(systemParts.joined(separator: "\n\n")),
            .user(userSections.joined(separator: "\n\n")),
        ]
    }

    /// 无工具路径下合并连续同角色非 system 消息，满足严格角色交替的兼容网关要求。
    private static func mergeConsecutiveNonSystemRoles(_ messages: [LLMMessage]) -> [LLMMessage] {
        var result: [LLMMessage] = []
        for msg in messages {
            if msg.role != "system",
               var last = result.last,
               last.role == msg.role,
               msg.toolCalls == nil,
               last.toolCalls == nil {
                last.content = last.content.isEmpty
                    ? msg.content
                    : (msg.content.isEmpty ? last.content : last.content + "\n\n" + msg.content)
                result[result.count - 1] = last
            } else {
                result.append(msg)
            }
        }
        return result
    }

    private static func buildLexicalPrefetchSection(
        workspace: NarrativeWorkspace,
        state: MaterializedNarrativeState,
        onStageEntityIDs: Set<String>,
        causalPrefix: String,
        tailText: String,
        scanText: String,
        cleanInstruction: String,
        causalCutoff: Int?,
        inputBudget: Int,
        enableTools: Bool,
        bm25Index: ManuscriptIndex.IncrementalBM25Index?
    ) -> (section: String?, usedFallbackBM25: Bool) {
        let onStageNames = onStageEntityIDs.compactMap { state.entityPages[$0]?.name }
        let maxExcerpts = enableTools ? 2 : 3
        let maxAnchors = enableTools ? 3 : 6
        let recallBudget = enableTools
            ? min(350, max(160, inputBudget / 12))
            : min(600, max(200, inputBudget / 8))

        let excerpts: [ManuscriptIndex.Excerpt]
        if let bm25Index, bm25Index.cachedPageCount > 0 {
            excerpts = bm25Index.recall(
                queryTerms: onStageNames,
                instructionText: cleanInstruction,
                causalLimit: causalCutoff,
                excludeTrailingUTF16: (tailText as NSString).length,
                maxResults: maxExcerpts,
                maxTokens: recallBudget
            )
        } else {
            excerpts = ManuscriptIndex.recallHistoricalExcerpts(
                fullManuscript: causalPrefix,
                activeWindowText: tailText,
                queryTerms: onStageNames,
                instructionText: cleanInstruction,
                causalLimit: causalCutoff,
                maxResults: maxExcerpts,
                maxTokens: recallBudget
            )
        }

        let anchorQuery = cleanInstruction.isEmpty ? scanText : cleanInstruction
        let rawHits = workspace.anchorIndex
            .anchors(beforeUTF16: causalCutoff)
            .filter { anchor in
                guard tailText.isEmpty || !tailText.contains(anchor.span.quote) else {
                    return false
                }
                return anchorQuery.localizedCaseInsensitiveContains(anchor.surfaceText)
                    || onStageNames.contains { name in
                        !name.isEmpty && (
                            anchor.surfaceText.localizedCaseInsensitiveContains(name)
                                || anchor.span.quote.localizedCaseInsensitiveContains(name)
                        )
                    }
            }
            .sorted { lhs, rhs in
                let leftScore = anchorPriorityScore(lhs, instruction: cleanInstruction)
                let rightScore = anchorPriorityScore(rhs, instruction: cleanInstruction)
                if leftScore != rightScore { return leftScore > rightScore }
                return lhs.span.utf16Start > rhs.span.utf16Start
            }

        var seenAnchorKeys = Set<String>()
        var anchorHits: [MechanicalAnchor] = []
        for hit in rawHits {
            let dedupKey = "\(hit.kind.rawValue)\u{1F}\(hit.surfaceText)\u{1F}\(hit.span.paragraphHash)"
            guard seenAnchorKeys.insert(dedupKey).inserted else { continue }
            anchorHits.append(hit)
            if anchorHits.count >= maxAnchors { break }
        }

        var lines: [String] = []
        if !excerpts.isEmpty {
            let header = enableTools
                ? "【高关联早期细节预检（需更多原文可调用 grep_manuscript / read_entity_page）】"
                : "【自动预检早期正文片段】"
            lines.append(header)
            for item in excerpts {
                lines.append(item.text)
            }
        }
        if !anchorHits.isEmpty {
            lines.append(enableTools ? "【高关联细节锚点】" : "【关联细节锚点】")
            for hit in anchorHits {
                lines.append("- [\(hit.kind.rawValue)] \(hit.surfaceText)：\(hit.span.quote)")
            }
        }
        guard !lines.isEmpty else { return (nil, false) }
        // 明确状态时序优先级：早期细节回忆不得覆盖当前在场事实与关键事件（抗状态漂移）。
        let precedenceRule = "以下早期片段与锚点仅作细节回忆；若与当前在场事实、关键事件或正文状态冲突，一律以当前最新状态为准。"
        return (([precedenceRule] + lines).joined(separator: "\n"), !enableTools)
    }

    private static func anchorPriorityScore(
        _ anchor: MechanicalAnchor,
        instruction: String
    ) -> Int {
        var score = 0
        if !instruction.isEmpty, instruction.localizedCaseInsensitiveContains(anchor.surfaceText) {
            score += 4
        }
        switch anchor.kind {
        case .artifactOrCount:
            score += 3
        case .timeMarker, .location:
            score += 2
        case .entityMention:
            score += 1
        }
        return score
    }
}
