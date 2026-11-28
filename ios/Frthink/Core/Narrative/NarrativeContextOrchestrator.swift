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
/// 将缓慢变化的指令、静态文风基石与常驻世界观固定在系统消息前缀以最大化 KV-Cache 命中，
/// 中段历史交由 ReFold 维持 append-only 可逆边界，仅在尾部动态区注入卷纲、参考资料、在场状态与尾段正文，紧贴用户指令。
enum NarrativeContextOrchestrator {

    static func buildFrozenSystemPrefix(
        globalPreset: String,
        aiFlavorRules: String,
        skills: [Skill],
        universes: [UniverseEntry],
        preservedStyle: PreservedStyleDistillation,
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

        return sections.joined(separator: "\n\n")
    }

    /// 裁剪无关实体，仅提取当前场景在场实体事实、POV 安全私有认知、就绪伏笔、因果祖先脉络与近期场拍。
    static func buildQueryConeBlock(
        state: MaterializedNarrativeState,
        scanText: String,
        povCharacterID: String? = nil,
        causalAncestors: [String] = [],
        plannedBeat: String? = nil,
        includeInternalID: Bool = true,
        includePlannedBeat: Bool = true
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
                lines.append(
                    formatQueryConePageLine(
                        for: page,
                        state: state,
                        povCharacterID: povCharacterID,
                        includeInternalID: includeInternalID
                    )
                )
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
                    let label = localizedFactAttribute(fact.attribute)
                    briefParts.append("\(label)：\(fact.value)")
                }
                let header = includeInternalID
                    ? "- \(page.name)（\(page.kind.rawValue)/\(page.id)）"
                    : "- \(page.name)"
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

        if includePlannedBeat,
           let cleanBeat = plannedBeat?.trimmingCharacters(in: .whitespacesAndNewlines),
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

        let recentCards = deduplicatedRecentSceneCards(
            state.pyramid.recentSceneCards.suffix(3),
            excludingCausalAncestors: causalAncestors
        )
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

    private static func deduplicatedRecentSceneCards<S: Sequence>(
        _ cards: S,
        excludingCausalAncestors causalAncestors: [String]
    ) -> [String] where S.Element == String {
        let ancestorKeys = causalAncestors.map(plotSummaryComparisonKey).filter { !$0.isEmpty }
        var seen = Set<String>()
        var result: [String] = []
        for raw in cards {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = plotSummaryComparisonKey(trimmed)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            let coveredByAncestor = ancestorKeys.contains { anc in
                anc == key || (key.count >= 4 && anc.contains(key)) || (anc.count >= 4 && key.contains(anc))
            }
            guard !coveredByAncestor else { continue }
            result.append(trimmed)
        }
        return result
    }

    private static func plotSummaryComparisonKey(_ text: String) -> String {
        let strippedBranch: String
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            strippedBranch = String(text[text.index(after: close)...])
        } else {
            strippedBranch = text
        }
        return NarrativeEntityResolver.normalizeName(strippedBranch)
    }

    private static func formatQueryConePageLine(
        for page: EntityPage,
        state: MaterializedNarrativeState,
        povCharacterID: String?,
        includeInternalID: Bool
    ) -> String {
        let identityLabel: String
        let summaryLabel: String?
        let boundaryLabel: String
        switch page.kind {
        case .character:
            identityLabel = "身份"
            summaryLabel = "性格与背景"
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
        let cleanIdentity = compactEntitySnippet(page.identity, maxLength: 120)
        if !cleanIdentity.isEmpty {
            detailParts.append("\(identityLabel)：\(cleanIdentity)")
        }
        if let summaryLabel {
            let cleanSummary = compactEntitySnippet(page.summary, maxLength: 220)
            if !cleanSummary.isEmpty, cleanSummary != cleanIdentity {
                detailParts.append("\(summaryLabel)：\(cleanSummary)")
            }
        }
        if page.kind == .character {
            let cleanVoice = compactEntitySnippet(page.voiceProfile, maxLength: 100)
            if !cleanVoice.isEmpty {
                detailParts.append("声线：\(cleanVoice)")
            }
        }
        if !page.hardBoundaries.isEmpty {
            detailParts.append("\(boundaryLabel)：\(page.hardBoundaries.joined(separator: "；"))")
        }
        let povBlindSpots: [EpistemicBelief]
        if let povCharacterID {
            povBlindSpots = state.beliefs(for: povCharacterID).filter { !$0.knowsSecret }
        } else {
            povBlindSpots = []
        }
        for fact in state.facts(for: page.id) {
            if !povBlindSpots.isEmpty,
               isFactMaskedByPOVBlindSpot(fact, page: page, povBlindSpots: povBlindSpots) {
                continue
            }
            let attrLabel = localizedFactAttribute(fact.attribute)
            detailParts.append("\(attrLabel)：\(fact.value)")
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

        let header = includeInternalID
            ? "- \(page.name)（\(page.kind.rawValue)/\(page.id)）"
            : "- \(page.name)"
        return detailParts.isEmpty ? header : "\(header)：" + detailParts.joined(separator: "｜")
    }

    private static func compactEntitySnippet(_ raw: String, maxLength: Int) -> String {
        let sentences = NarrativeEntityResolver.splitSentences(raw)
        let joined = sentences.joined(separator: " ")
        guard !joined.isEmpty else { return "" }
        guard joined.count > maxLength, maxLength > 24 else { return joined }

        if sentences.count >= 2 {
            let first = sentences[0]
            var keptTail: [String] = []
            var tailCost = 0
            // 优先保住完整首句（核心定位）与末尾最新完整句，不从半句话中间硬截。
            for sentence in sentences.dropFirst().reversed() {
                let extra = keptTail.isEmpty ? sentence.count : (sentence.count + 1)
                if !keptTail.isEmpty && first.count + 1 + tailCost + extra > maxLength {
                    break
                }
                keptTail.append(sentence)
                tailCost += extra
            }
            let tailText = keptTail.reversed().joined(separator: " ")
            if first.count + 1 + tailText.count <= maxLength {
                return keptTail.count == sentences.count - 1
                    ? "\(first) \(tailText)"
                    : "\(first)…\(tailText)"
            }
            // 若首句过长导致与最新完整句超预算，优先保留完整最新句并按预算裁剪首句前缀。
            if let latest = sentences.last, latest.count + 4 < maxLength {
                let headBudget = max(10, maxLength - latest.count - 1)
                return String(first.prefix(headBudget)) + "…" + latest
            }
        }
        return String(joined.prefix(maxLength)) + "…"
    }

    static func localizedFactAttribute(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("relation:") {
            let target = String(trimmed.dropFirst("relation:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return target.isEmpty ? "关系" : "与\(target)关系"
        }
        if lower.hasPrefix("possession:") {
            let target = String(trimmed.dropFirst("possession:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return target.isEmpty ? "持有" : "持有·\(target)"
        }
        if lower.hasPrefix("condition:") {
            let target = String(trimmed.dropFirst("condition:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return target.isEmpty ? "状态" : "状态·\(target)"
        }
        switch lower {
        case "location": return "位置"
        case "possession": return "持有"
        case "condition": return "状态"
        case "goal": return "目标"
        case "status": return "现状"
        case "relation": return "关系"
        case "layout": return "格局"
        case "atmosphere": return "氛围"
        case "access": return "准入"
        case "owner": return "归属"
        case "capability": return "用途"
        case "cost": return "代价"
        case "rule": return "规则"
        case "faction": return "势力"
        case "history": return "历史"
        case "exception": return "例外"
        default: return trimmed
        }
    }

    /// 若当前处于某角色的 POV 视角且该角色在特定主题上处于盲区/误认（`!knowsSecret`），
    /// 必须在送入模型前硬裁剪对应的全知客观事实，避免提示词泄密引发“知识的诅咒”。
    static func isFactMaskedByPOVBlindSpot(
        _ fact: WorldFactEvent,
        page: EntityPage,
        povBlindSpots: [EpistemicBelief]
    ) -> Bool {
        let rawAttr = fact.attribute.trimmingCharacters(in: .whitespacesAndNewlines)
        let attrBody: String
        if let colonRange = rawAttr.range(of: ":") {
            attrBody = String(rawAttr[colonRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            attrBody = rawAttr
        }
        let pageName = page.name.trimmingCharacters(in: .whitespacesAndNewlines)

        return povBlindSpots.contains { belief in
            if belief.slotKey == fact.slotKey {
                return true
            }
            let topic = belief.topic.trimmingCharacters(in: .whitespacesAndNewlines)
            guard topic.count >= 2 else { return false }
            let sameSubject = belief.characterID == fact.entityID
                || (!pageName.isEmpty && topic.localizedCaseInsensitiveContains(pageName))
            guard sameSubject else { return false }

            return rawAttr.localizedCaseInsensitiveContains(topic)
                || (!attrBody.isEmpty && attrBody.localizedCaseInsensitiveContains(topic))
                || (attrBody.count >= 2 && topic.localizedCaseInsensitiveContains(attrBody))
                || fact.value.localizedCaseInsensitiveContains(topic)
        }
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

        let sceneMatched = Array(scored.filter { $0.score > 1 }.prefix(6).map(\.event))
        let chosenRaw: [EpisodicEvent]
        if !sceneMatched.isEmpty {
            chosenRaw = sceneMatched
        } else {
            chosenRaw = Array(scored.filter { $0.event.status == .ongoing }.prefix(4).map(\.event))
        }
        guard !chosenRaw.isEmpty else { return nil }
        let chosen = chosenRaw.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
            return lhs.id < rhs.id
        }
        return "【相关关键事件】\n" + chosen.map { "- \($0.formattedSummaryLine)" }.joined(separator: "\n")
    }

    static func effectiveTailText(
        manuscript: String,
        continuationAnchor: Int?,
        sceneBoundaryOffset: Int? = nil,
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
        let nsPrefix = causalPrefix as NSString
        let activeSceneText: String
        if let boundary = sceneBoundaryOffset, boundary > 0 {
            if boundary >= nsPrefix.length {
                activeSceneText = ""
            } else {
                let safeStart = nsPrefix.rangeOfComposedCharacterSequence(at: boundary).location
                activeSceneText = nsPrefix.substring(from: safeStart)
            }
        } else {
            activeSceneText = causalPrefix
        }
        let limit = max(1, tailCodePointLimitOverride ?? tailTier.rawValue)
        let tailText = activeSceneText.isEmpty ? "" : PromptComposer.codePointTail(activeSceneText, limit: limit)
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
        sceneBoundaryOffset: Int? = nil,
        tailTier: ManuscriptTailTier = .standard,
        tailCodePointLimitOverride: Int? = nil,
        inputBudget: Int,
        enableTools: Bool,
        povCharacterID: String? = nil,
        bm25Index: ManuscriptIndex.IncrementalBM25Index? = nil
    ) -> OrchestratedPrompt {
        let state = workspace.currentState()

        let enabledUniverses = settings.enabledUniverseEntries(for: enabledUniverseEntryIDs)
        let bookIndex = enableTools ? state.bookIndexLines(maxLines: 80) : []
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
            alwaysOnLorePages: alwaysOnLorePages
        )

        // 按继续写作锚点执行严格因果截断，并按换场边界过滤前场正文原文。
        let tailSlice = effectiveTailText(
            manuscript: manuscript,
            continuationAnchor: continuationAnchor,
            sceneBoundaryOffset: sceneBoundaryOffset,
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
            plannedBeat: plannedBeat,
            includeInternalID: enableTools,
            includePlannedBeat: false
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

        // 构建尾部动态工作区（按高注意力分布与续写邻接原则）：
        // 参考资料前置（卷纲 -> 工具目录[仅开启工具] -> 早期细节预检 -> 仿写样本 -> Query-Cone）-> 当前场次正文 -> 硬规则与本幕目标（紧贴用户指令）。
        var tailSections: [String] = []

        let cleanVolumes = state.pyramid.volumeOneLiners
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanVolumes.isEmpty {
            let cappedVolumes = Array(cleanVolumes.prefix(12))
            tailSections.append("【全书卷纲脉络】\n" + cappedVolumes.map { "- \($0)" }.joined(separator: "\n"))
        }

        if enableTools, !bookIndex.isEmpty {
            let cappedIndex = Array(bookIndex.prefix(80))
            tailSections.append("【全书实体与伏笔索引目录（细节可按需调用 read_entity_page / grep_manuscript 查阅）】\n" + cappedIndex.joined(separator: "\n"))
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
            sceneBoundaryOffset: sceneBoundaryOffset,
            inputBudget: inputBudget,
            enableTools: enableTools,
            bm25Index: bm25Index
        )
        if let section = prefetch.section {
            tailSections.append(section)
        }
        let usedFallbackBM25 = prefetch.usedFallbackBM25

        if !queryCone.block.isEmpty {
            tailSections.append(queryCone.block)
        }

        if !tailText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tailSections.append("【当前场次正文】\n" + tailText)
        }

        // 文风范例放在正文之后；正文不足时用全书质心补位。
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
            } else if tailText.count < 1_000,
                      let centroid = effectiveStyle.centroidExemplar,
                      !centroid.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let centroidCorpus = PromptAssembly.Corpus(
                    libraryID: "preserved-centroid",
                    libraryName: "全书质心",
                    entryID: centroid.id,
                    entryName: centroid.title,
                    category: "仿写样本",
                    text: centroid.text
                )
                let centroidRef = StyleDistiller.styleReferenceBlock(
                    from: [centroidCorpus],
                    maxSamples: 1,
                    tokenBudget: max(256, inputBudget / 6),
                    instructionText: nil,
                    queryText: nil
                )
                if let renderedCentroid = centroidRef.block?.rendered, !renderedCentroid.isEmpty {
                    tailSections.append(renderedCentroid)
                }
            }
        }

        let currentBranchID = workspace.storyGraph.nodes[workspace.storyGraph.headNodeID]?.branchLabel
        let authorityRules = state.directiveLedger.renderedAuthorityBlock(
            branchID: currentBranchID,
            entityIDs: queryCone.onStageEntityIDs
        )
        if !authorityRules.isEmpty {
            tailSections.append(authorityRules)
        }

        let priorityNotice = buildPriorityNotice(
            globalPreset: settings.globalPreset,
            aiFlavorRules: settings.aiFlavorRules
        )
        if !priorityNotice.isEmpty {
            tailSections.append(priorityNotice)
        }

        if let cleanBeat = plannedBeat?.trimmingCharacters(in: .whitespacesAndNewlines),
           !cleanBeat.isEmpty {
            tailSections.append("【本幕待写目标】\n- \(cleanBeat)")
        }

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

    private static func buildPriorityNotice(
        globalPreset: String,
        aiFlavorRules: String
    ) -> String {
        let hasGlobalGuide = !globalPreset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !aiFlavorRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasGlobalGuide else { return "" }
        return "【规则优先级】\n- 全局预设、启用技能与去 AI 味规则优先于单书仿写规范与文风范例。"
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
        sceneBoundaryOffset: Int?,
        inputBudget: Int,
        enableTools: Bool,
        bm25Index: ManuscriptIndex.IncrementalBM25Index?
    ) -> (section: String?, usedFallbackBM25: Bool) {
        let onStageNames = onStageEntityIDs.compactMap { state.entityPages[$0]?.name }
        let maxExcerpts = enableTools ? 1 : 2
        let maxAnchors = enableTools ? 3 : 4
        let recallBudget = enableTools
            ? min(220, max(120, inputBudget / 16))
            : min(480, max(180, inputBudget / 10))
        // 换场边界激活时仅允许检索本场起点的正文，避免前场高刺激原文回流（前情交由档案与摘要承接）。
        let minOffset: Int
        if let boundary = sceneBoundaryOffset, boundary > 0 {
            minOffset = causalCutoff.map { min(boundary, $0) } ?? boundary
        } else {
            minOffset = 0
        }

        let excerpts: [ManuscriptIndex.Excerpt]
        if let bm25Index, bm25Index.cachedPageCount > 0 {
            excerpts = bm25Index.recall(
                queryTerms: onStageNames,
                instructionText: cleanInstruction,
                causalLimit: causalCutoff,
                minUTF16Offset: minOffset,
                excludeTrailingUTF16: (tailText as NSString).length,
                maxResults: maxExcerpts,
                maxTokens: recallBudget
            )
        } else if minOffset > 0 {
            let prefixNS = causalPrefix as NSString
            if minOffset >= prefixNS.length {
                excerpts = []
            } else {
                excerpts = ManuscriptIndex.recallHistoricalExcerpts(
                    fullManuscript: prefixNS.substring(from: minOffset),
                    activeWindowText: tailText,
                    queryTerms: onStageNames,
                    instructionText: cleanInstruction,
                    causalLimit: nil,
                    maxResults: maxExcerpts,
                    maxTokens: recallBudget
                )
            }
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
                if minOffset > 0, anchor.span.utf16Start < minOffset {
                    return false
                }
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
        // 按正文时间顺序重排锚点，防止高分早段内容与后段发生时序倒错。
        anchorHits.sort {
            if $0.span.utf16Start != $1.span.utf16Start {
                return $0.span.utf16Start < $1.span.utf16Start
            }
            return $0.id < $1.id
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
