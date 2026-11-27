import Foundation

/// 下一步剧情走向分支推演的解析失败错误。
enum StoryChoiceParseError: Error, LocalizedError, Equatable {
    case noJSON
    case invalidStructure(String)

    var errorDescription: String? {
        switch self {
        case .noJSON:
            return "推演响应中未找到有效 JSON 对象"
        case .invalidStructure(let detail):
            return "分支推演 JSON 结构无效：\(detail)"
        }
    }
}

/// 单条可供作者点选定调的后续剧情分支选项。
struct StoryChoice: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var direction: String
    var tensionHook: String
    var involvedEntityIDs: [String]

    init(
        id: String = UUID().uuidString,
        title: String,
        direction: String,
        tensionHook: String,
        involvedEntityIDs: [String] = []
    ) {
        self.id = id
        self.title = title
        self.direction = direction
        self.tensionHook = tensionHook
        self.involvedEntityIDs = involvedEntityIDs
    }
}

/// 剧情走向推演所需创作基准与场景视角上下文，保证选项严格遵循作者全局预设与在场人设。
struct StoryChoicePlanningContext {
    var globalPreset: String
    var aiFlavorRules: String
    var skills: [Skill]
    var universes: [UniverseEntry]
    var preservedStyle: PreservedStyleDistillation
    var povCharacterID: String?
    var recentDialogue: [ChatMessage]

    init(
        globalPreset: String = "",
        aiFlavorRules: String = "",
        skills: [Skill] = [],
        universes: [UniverseEntry] = [],
        preservedStyle: PreservedStyleDistillation = PreservedStyleDistillation(),
        povCharacterID: String? = nil,
        recentDialogue: [ChatMessage] = []
    ) {
        self.globalPreset = globalPreset
        self.aiFlavorRules = aiFlavorRules
        self.skills = skills
        self.universes = universes
        self.preservedStyle = preservedStyle
        self.povCharacterID = povCharacterID
        self.recentDialogue = recentDialogue
    }
}

/// 分支剧情推演规划器：
/// 继承作者全局预设、技能、文风、常驻世界观与当前 POV 盲区，紧扣在场人物性格与当前场景末尾节奏，
/// 生成 2-3 个可直接用于续写的候选走向，仅在作者明确点击采纳后再写入叙事状态。
enum StoryChoicePlanner {

    static let recommendedTemperature: Double = 0.5

    static func buildPlanningMessages(
        state: MaterializedNarrativeState,
        manuscriptTail: String,
        desiredCount: Int = 3,
        context: StoryChoicePlanningContext = StoryChoicePlanningContext()
    ) -> [LLMMessage] {
        let count = min(max(desiredCount, 2), 3)
        let tail = manuscriptTail.trimmingCharacters(in: .whitespacesAndNewlines)

        let systemPrompt = """
        你是贴合作者设定与角色性格的互动小说走向顾问。
        请把作者提供的创作基准（全局预设、启用技能、去 AI 味规范、世界书、长期写作规则）与在场角色性格、说话口吻和底线作为最高准则，紧接「当前正文末尾」的真实处境、情绪氛围与对话节奏，提出 \(count) 个自然、贴合人设且可直接用于下一步续写的候选走向。
        请只返回一个严格 JSON 对象（不要输出额外说明）：
        {"choices":[{"title":"","direction":"","tone_note":"","involved_entity_ids":[""]}]}
        硬性约束：
        1. 必须优先遵守全局预设、技能、文风偏好与写作规则；不得为了制造波折而违背既定基调或人物底线。
        2. 忠于在场角色的性格、说话口吻、人际关系与当前场面氛围：若正文当前属于日常相处、情感交流、人物日常或舒缓过渡，应顺着当前互动、心理动作或生活细节自然推进，严禁强行生造博弈试探、利益算计或阴谋危机；只有当正文当前本就处于对峙或危机之中时，才提供高张力应对分支。
        3. 严禁让处于未知盲区的视角角色凭空知晓未公开的秘密，也不得作出违背既有客观事实的动作。
        4. \(count) 个选项应在合理边界内从不同角度切入（例如：顺承当前情绪与对话深入、符合在场角色性格的具体动作、或顺势带出环境细节与已有未决线索）。
        5. `title` 用 4-10 字概括走向；`direction` 用 30-75 字写出具体可执行的场景与人物动作推进（可直接发给写作模型续写）；`tone_note` 用简短一句话说明氛围或衔接点（例如「延续对白与细节互动」「顺势照应已有线索」）。
        """

        var userSections: [String] = []

        var creativeBaselineLines: [String] = []
        let cleanPreset = context.globalPreset.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanPreset.isEmpty {
            creativeBaselineLines.append(cleanPreset)
        }
        for skill in context.skills where skill.enabled {
            if let block = skill.promptBlock {
                creativeBaselineLines.append(block)
            }
        }
        let cleanFlavor = context.aiFlavorRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanFlavor.isEmpty {
            creativeBaselineLines.append(
                PromptLibrary.render(PromptLibrary.stylePreferenceTemplate, [
                    "aiFlavorRules": cleanFlavor,
                ])
            )
        }
        for universe in context.universes where universe.enabled {
            let cleanTitle = universe.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanBody = universe.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty || !cleanBody.isEmpty else { continue }
            creativeBaselineLines.append(
                PromptLibrary.render(PromptLibrary.universeBlockTemplate, [
                    "宇宙名": cleanTitle.isEmpty ? "共享世界书" : cleanTitle,
                    "内容": cleanBody,
                ])
            )
        }
        let alwaysOnLore = state.entityPages.values
            .filter { $0.enabled && $0.kind == .lore && $0.activationMode == .always }
            .sorted { $0.name < $1.name }
        if !alwaysOnLore.isEmpty {
            let loreText = alwaysOnLore.prefix(12).map { page in
                let detail = !page.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? page.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    : page.identity.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "- \(page.name)" : "- \(page.name)：\(detail)"
            }.joined(separator: "\n")
            creativeBaselineLines.append("【常驻世界观】\n\(loreText)")
        }
        let cleanTemplate = context.preservedStyle.styleTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTemplate.isEmpty {
            creativeBaselineLines.append(
                PromptLibrary.render(PromptLibrary.imitationTemplateBlockTemplate, [
                    "仿写模板正文": cleanTemplate,
                ])
            )
        }
        if !creativeBaselineLines.isEmpty {
            userSections.append("【作者创作基准（必须优先遵守）】\n" + creativeBaselineLines.joined(separator: "\n\n"))
        }

        let authorityBlock = state.directiveLedger.renderedAuthorityBlock()
        if !authorityBlock.isEmpty {
            userSections.append(authorityBlock)
        }

        let recentChatLines = context.recentDialogue
            .filter { $0.role == .user || $0.role == .assistant }
            .suffix(4)
            .compactMap { msg -> String? in
                let raw = msg.contextMode == .summaryOnly && !msg.prunedSummary.isEmpty
                    ? msg.prunedSummary
                    : msg.content
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: " ")
                guard !clean.isEmpty else { return nil }
                let clipped = clean.count > 120 ? String(clean.prefix(120)) + "…" : clean
                let roleTag = msg.role == .user ? "作者指令" : "上一轮文本"
                return "- \(roleTag)：\(clipped)"
            }
        if !recentChatLines.isEmpty {
            userSections.append("【近期创作意图】\n" + recentChatLines.joined(separator: "\n"))
        }

        let resolvedPOVID = context.povCharacterID.flatMap {
            state.entityPages[$0]?.enabled == true ? $0 : nil
        }
        let povBlindSpots: [EpistemicBelief] = resolvedPOVID.map {
            state.beliefs(for: $0).filter { !$0.knowsSecret }
        } ?? []

        if let povID = resolvedPOVID,
           let povPage = state.entityPages[povID],
           !povBlindSpots.isEmpty {
            let blindLines = povBlindSpots.map { belief in
                "- 盲区[\(belief.topic)]：\(belief.believedTruth)"
            }
            userSections.append(
                "【当前视角（POV：\(povPage.name)）信息盲区（禁止选项提前泄密）】\n"
                    + blindLines.joined(separator: "\n")
            )
        }

        let sceneCandidates = state.entityPages.values
            .filter { $0.enabled && !($0.kind == .lore && $0.activationMode == .always) }
            .sorted { lhs, rhs in
                let lhsMentioned = matchesSceneTail(lhs, in: tail)
                let rhsMentioned = matchesSceneTail(rhs, in: tail)
                if lhsMentioned != rhsMentioned { return lhsMentioned && !rhsMentioned }
                let lhsPOV = (lhs.id == resolvedPOVID)
                let rhsPOV = (rhs.id == resolvedPOVID)
                if lhsPOV != rhsPOV { return lhsPOV && !rhsPOV }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
            .prefix(10)

        if !sceneCandidates.isEmpty {
            let entityLines = sceneCandidates.map { page in
                formatEntityPersonaLine(
                    page: page,
                    state: state,
                    povCharacterID: resolvedPOVID,
                    povBlindSpots: povBlindSpots
                )
            }
            userSections.append("【在场及关联角色/设定人设】\n" + entityLines.joined(separator: "\n"))
        }

        let ongoingEvents = state.sortedEpisodicEvents()
            .filter { $0.status == .ongoing }
            .prefix(5)
        if !ongoingEvents.isEmpty {
            userSections.append(
                "【进行中关键事件】\n" + ongoingEvents.map { "- \($0.formattedSummaryLine)" }.joined(separator: "\n")
            )
        }

        let readyOrPendingThreads = state.threads.values
            .filter { $0.state == .ready || $0.state == .pending }
            .sorted { lhs, rhs in
                if lhs.state != rhs.state { return lhs.state == .ready }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
            .prefix(6)
        if !readyOrPendingThreads.isEmpty {
            let lines = readyOrPendingThreads.map { thread in
                let cue = thread.activationCue.isEmpty ? "" : "（触发条件：\(thread.activationCue)）"
                return "- [\(thread.state.rawValue)/\(thread.id)] \(thread.goal)\(cue)"
            }
            userSections.append("【可用未决线索（仅在顺理成章时酌情照应）】\n" + lines.joined(separator: "\n"))
        }

        let recentScenes = state.pyramid.recentSceneCards.suffix(4)
        if !recentScenes.isEmpty {
            userSections.append("【最近场景卡】\n" + recentScenes.map { "- \($0)" }.joined(separator: "\n"))
        }

        userSections.append("【当前正文末尾】\n" + (tail.isEmpty ? "（暂无正文）" : tail))

        return [
            .system(systemPrompt),
            .user(userSections.joined(separator: "\n\n")),
        ]
    }

    static func parseChoices(from raw: String, limit: Int = 3) throws -> [StoryChoice] {
        guard let jsonString = NarrativeJSONScanner.extractFirstJSONObject(from: raw) else {
            throw StoryChoiceParseError.noJSON
        }
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw StoryChoiceParseError.invalidStructure("无法解析为 JSON 字典")
        }
        guard let rawChoices = (object["choices"] ?? object["branches"] ?? object["options"]) as? [[String: Any]] else {
            throw StoryChoiceParseError.invalidStructure("缺少 choices 数组")
        }

        let maxCount = max(1, limit)
        var parsed: [StoryChoice] = []
        var seenTitles = Set<String>()

        for item in rawChoices {
            let title = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["title", "name", "label"])
            let direction = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["direction", "plot", "summary", "action"])
            let toneNote = NarrativeJSONScanner.firstNonEmptyString(
                item,
                keys: ["tone_note", "toneNote", "note", "tension_hook", "tensionHook", "hook", "risk"]
            )
            guard !title.isEmpty, !direction.isEmpty else { continue }
            guard seenTitles.insert(title).inserted else { continue }

            let entityIDs = ((item["involved_entity_ids"] ?? item["involvedEntityIDs"]) as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            parsed.append(
                StoryChoice(
                    id: "choice_\(parsed.count + 1)_\(SummaryKey.sha256Hex(title).prefix(8))",
                    title: title,
                    direction: direction,
                    tensionHook: toneNote,
                    involvedEntityIDs: entityIDs
                )
            )
            if parsed.count >= maxCount {
                break
            }
        }

        guard !parsed.isEmpty else {
            throw StoryChoiceParseError.invalidStructure("choices 列表为空或缺少必要字段")
        }
        return parsed
    }

    private static func matchesSceneTail(_ page: EntityPage, in tail: String) -> Bool {
        guard !tail.isEmpty else { return false }
        let cleanName = page.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanName.isEmpty, tail.localizedCaseInsensitiveContains(cleanName) {
            return true
        }
        if page.aliases.contains(where: { !$0.isEmpty && tail.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        return page.triggerKeywords.contains { !$0.isEmpty && tail.localizedCaseInsensitiveContains($0) }
    }

    private static func formatEntityPersonaLine(
        page: EntityPage,
        state: MaterializedNarrativeState,
        povCharacterID: String?,
        povBlindSpots: [EpistemicBelief]
    ) -> String {
        var parts: [String] = []
        let cleanIdentity = page.identity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanIdentity.isEmpty {
            parts.append("\(page.kind.identityLabel)：\(cleanIdentity)")
        }
        let cleanSummary = page.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanSummary.isEmpty {
            parts.append("\(page.kind.summaryLabel)：\(NarrativeEntityResolver.trimToSentenceBoundary(cleanSummary, maxLength: 140))")
        }
        if page.kind == .character {
            let cleanVoice = page.voiceProfile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanVoice.isEmpty {
                parts.append("说话风格：\(cleanVoice)")
            }
        }
        if !page.hardBoundaries.isEmpty {
            parts.append("\(page.kind.boundariesLabel)：\(page.hardBoundaries.joined(separator: "；"))")
        }
        let filteredFacts = state.facts(for: page.id)
            .filter { fact in
                povBlindSpots.isEmpty
                    || !NarrativeContextOrchestrator.isFactMaskedByPOVBlindSpot(
                        fact,
                        page: page,
                        povBlindSpots: povBlindSpots
                    )
            }
            .prefix(4)
            .map { "\(NarrativeContextOrchestrator.localizedFactAttribute($0.attribute))=\($0.value)" }
        if !filteredFacts.isEmpty {
            parts.append("近况：" + filteredFacts.joined(separator: "；"))
        }
        if page.kind == .character, let povCharacterID, page.id != povCharacterID {
            let publicBeliefs = state.beliefs(for: page.id)
                .filter { !$0.knowsSecret }
                .prefix(2)
                .map { "认知[\($0.topic)]：\($0.believedTruth)" }
            if !publicBeliefs.isEmpty {
                parts.append(contentsOf: publicBeliefs)
            }
        }
        return parts.isEmpty
            ? "- [\(page.id)] \(page.name)"
            : "- [\(page.id)] \(page.name)：" + parts.joined(separator: "｜")
    }
}
