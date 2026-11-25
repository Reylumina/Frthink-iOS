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

/// 分支剧情推演规划器：
/// 根据当前物化状态中的写作规则、就绪伏笔与最近场次，按适度发散温度生成 2-3 个差异化走向供作者选择，
/// 仅在作者明确点击采纳后再写入叙事状态。
enum StoryChoicePlanner {

    static let recommendedTemperature: Double = 0.75

    static func buildPlanningMessages(
        state: MaterializedNarrativeState,
        manuscriptTail: String,
        desiredCount: Int = 3
    ) -> [LLMMessage] {
        let count = min(max(desiredCount, 2), 3)
        let systemPrompt = """
        你是一个冷静且擅长戏剧结构的小说剧情推演策划。
        请严格遵守写作规则，并结合就绪伏笔、关键实体状态与当前场景末尾，提出 \(count) 个相互区别、可执行且富有张力的下一步剧情分支选项。
        请返回一个严格 JSON 对象（不要输出额外说明）：
        {"choices":[{"title":"","direction":"","tension_hook":"","involved_entity_ids":[""]}]}
        硬性约束：
        1. 必须输出 \(count) 个明确分支，彼此冲突焦点与节奏重心应明显不同。
        2. 不得违反写作规则，也不要让角色说出或做出违背既有客观事实的动作。
        3. title 用 4-10 字概括分支；direction 说明核心动作与场面推进（30-70 字）；tension_hook 指出风险、悬念或可顺势兑现的伏笔。
        """

        var userSections: [String] = []
        let authorityBlock = state.directiveLedger.renderedAuthorityBlock()
        if !authorityBlock.isEmpty {
            userSections.append(authorityBlock)
        }

        let readyOrPendingThreads = state.threads.values
            .filter { $0.state == .ready || $0.state == .pending }
            .sorted { lhs, rhs in
                if lhs.state != rhs.state {
                    return lhs.state == .ready
                }
                return lhs.id < rhs.id
            }
            .prefix(12)
        if !readyOrPendingThreads.isEmpty {
            let lines = readyOrPendingThreads.map { thread in
                let cue = thread.activationCue.isEmpty ? "" : "（触发条件：\(thread.activationCue)）"
                return "- [\(thread.state.rawValue)/\(thread.id)] \(thread.goal)\(cue)"
            }
            userSections.append("【当前未回收伏笔】\n" + lines.joined(separator: "\n"))
        }

        let keyEntities = state.entityPages.values
            .filter(\.enabled)
            .sorted { $0.id < $1.id }
            .prefix(12)
        if !keyEntities.isEmpty {
            var entityLines: [String] = []
            for entity in keyEntities {
                let facts = state.facts(for: entity.id).prefix(4).map { "\($0.attribute)=\($0.value)" }
                let factSuffix = facts.isEmpty ? "" : "｜" + facts.joined(separator: "；")
                entityLines.append("- [\(entity.id)] \(entity.name)\(factSuffix)")
            }
            userSections.append("【关键实体当前状态】\n" + entityLines.joined(separator: "\n"))
        }

        let ongoingEvents = state.sortedEpisodicEvents()
            .filter { $0.status == .ongoing }
            .prefix(5)
        if !ongoingEvents.isEmpty {
            userSections.append(
                "【进行中关键事件】\n" + ongoingEvents.map { "- \($0.formattedSummaryLine)" }.joined(separator: "\n")
            )
        }

        let recentScenes = state.pyramid.recentSceneCards.suffix(4)
        if !recentScenes.isEmpty {
            userSections.append("【最近场景卡】\n" + recentScenes.map { "- \($0)" }.joined(separator: "\n"))
        }

        let tail = manuscriptTail.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let tensionHook = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["tension_hook", "tensionHook", "hook", "risk"])
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
                    tensionHook: tensionHook,
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
}
