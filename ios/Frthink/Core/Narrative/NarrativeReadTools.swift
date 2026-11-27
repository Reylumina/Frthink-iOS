import Foundation

/// 只读叙事工具执行所需的本地上下文，全部检索严格限定于当前写作锚点之前的已确立内容。
struct NarrativeToolContext {
    var pages: [String]
    var causalLimit: Int?
    var materializedState: MaterializedNarrativeState
    var losslessHistory: [LLMMessage]

    init(
        pages: [String] = [],
        causalLimit: Int? = nil,
        materializedState: MaterializedNarrativeState,
        losslessHistory: [LLMMessage] = []
    ) {
        self.pages = pages
        self.causalLimit = causalLimit
        self.materializedState = materializedState
        self.losslessHistory = losslessHistory
    }
}

/// 单次只读工具调用的隔离输出。
struct NarrativeToolExecution: Equatable {
    var callID: String
    var toolName: String
    var output: String
}

/// 固定只读回查工具契约与本地执行器：工具列表保持静态以利前缀缓存，
/// 不支持工具调用的网关则自动跳过工具声明并在本地完成预补检。
enum NarrativeReadTools {

    static let maxStepsPerTurn = 2

    static let grepManuscriptName = "grep_manuscript"
    static let readEntityPageName = "read_entity_page"
    static let restoreTurnName = "restore_turn"

    static let definitions: [LLMToolDefinition] = [
        LLMToolDefinition(
            name: grepManuscriptName,
            description: "在已写正文中按字面或正则检索远期确切措辞，自动截断当前续写锚点之后的未发生剧情。",
            parametersJSON: """
            {"type":"object","properties":{"pattern":{"type":"string","description":"检索关键词或正则表达式"},"context_lines":{"type":"integer","description":"前后保留行数，默认 1"},"regex":{"type":"boolean","description":"是否作为正则表达式匹配"}},"required":["pattern"]}
            """
        ),
        LLMToolDefinition(
            name: readEntityPageName,
            description: "按 ID、名称或别名读取离场人物、地点、物件或世界观的完整档案与关联事实。",
            parametersJSON: """
            {"type":"object","properties":{"entity_id":{"type":"string","description":"实体 ID、姓名或别名"},"section":{"type":"string","description":"可选节标题筛选，如：声音档案、行为底线、核心规则与例外、当前事实"}},"required":["entity_id"]}
            """
        ),
        LLMToolDefinition(
            name: restoreTurnName,
            description: "恢复已被历史折叠的早期对话步骤原文，仅当需要核对早期具体指示或废弃草稿时调用。",
            parametersJSON: """
            {"type":"object","properties":{"step_range":{"type":"string","description":"步骤序号或区间，例如 2 或 1-3"}},"required":["step_range"]}
            """
        ),
    ]

    /// 判断当前服务商是否宜默认开启原生只读工具声明；不支持或已降级的通道返回 false。
    static func supportsNativeTools(provider: ProviderSetting?) -> Bool {
        guard let provider else { return false }
        if provider.isOpenCode || provider.kind == .openCodeGo {
            return false
        }
        switch provider.kind {
        case .anthropic, .gemini, .deepseek, .openRouter, .openAICompatible:
            return true
        case .openCodeGo:
            return false
        }
    }

    static func execute(
        call: LLMToolCall,
        context: NarrativeToolContext
    ) -> NarrativeToolExecution {
        let args = parseArguments(call.arguments)
        let output: String

        switch call.functionName {
        case grepManuscriptName:
            let pattern = NarrativeJSONScanner.firstNonEmptyString(args, keys: ["pattern", "query", "keyword"])
            let contextLines = (args["context_lines"] as? Int) ?? 1
            let regex = (args["regex"] as? Bool) ?? false
            output = executeGrep(
                pattern: pattern,
                contextLines: contextLines,
                regex: regex,
                context: context
            )
        case readEntityPageName:
            let entityKey = NarrativeJSONScanner.firstNonEmptyString(args, keys: ["entity_id", "name", "entity_name", "query"])
            let section = args["section"] as? String
            output = executeReadEntity(
                entityKey: entityKey,
                section: section,
                state: context.materializedState
            )
        case restoreTurnName:
            let stepRange = NarrativeJSONScanner.firstNonEmptyString(args, keys: ["step_range", "range", "turn"])
            output = ReFoldManager.restoreTurns(
                stepRange: stepRange,
                from: context.losslessHistory
            )
        default:
            output = "未知只读工具：\(call.functionName)"
        }

        return NarrativeToolExecution(
            callID: call.id,
            toolName: call.functionName,
            output: boundedOutput(output, maxChars: 2_600)
        )
    }

    private static func executeGrep(
        pattern: String,
        contextLines: Int,
        regex: Bool,
        context: NarrativeToolContext
    ) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "检索关键词不能为空。"
        }
        let result = ManuscriptIndex.grepManuscriptDetailed(
            pages: context.pages,
            pattern: trimmed,
            contextLines: min(3, max(0, contextLines)),
            regex: regex,
            causalLimit: context.causalLimit,
            maxMatches: 8
        )
        if let regexError = result.regexError {
            return "正则表达式「\(trimmed)」语法无效（\(regexError)）。请修正正则表达式，或将 regex 设为 false 后改用关键词检索。"
        }
        if !result.matches.isEmpty {
            let header = result.totalMatchCount > result.matches.count
                ? "共命中 \(result.totalMatchCount) 处（按时间顺序展示最早与最新共 \(result.matches.count) 处）："
                : "共命中 \(result.totalMatchCount) 处："
            let formattedEntries = result.matches.enumerated().map { idx, hit in
                "[\(idx + 1)] 第 \(hit.pageIndex + 1) 页 第 \(hit.lineNumber) 行\n\(hit.contextSnippet)"
            }
            return joinCompleteBlocks(
                header: header,
                blocks: formattedEntries,
                totalCount: result.totalMatchCount,
                charBudget: 2_450
            )
        }

        if !regex {
            let fallbackExcerpts = recallBM25Fallback(
                query: trimmed,
                pages: context.pages,
                causalLimit: context.causalLimit
            )
            if !fallbackExcerpts.isEmpty {
                let blocks = fallbackExcerpts.enumerated().map { idx, item in
                    "[BM25相关段落 \(idx + 1)]\n\(item.text)"
                }
                return joinCompleteBlocks(
                    header: "字面精确匹配「\(trimmed)」未命中，已自动切换关联段落检索：",
                    blocks: blocks,
                    totalCount: blocks.count,
                    charBudget: 2_450
                )
            }
        }

        return "在当前锚点之前的正文中未找到「\(trimmed)」（建议改用更简短的核心人名、地名或物件名重试）。"
    }

    private static func joinCompleteBlocks(
        header: String,
        blocks: [String],
        totalCount: Int,
        charBudget: Int
    ) -> String {
        guard !blocks.isEmpty else { return header }
        var kept: [String] = []
        var usedChars = header.count + 1
        let separator = "\n---\n"
        for block in blocks {
            let cost = (kept.isEmpty ? 0 : separator.count) + block.count
            if !kept.isEmpty && usedChars + cost > charBudget {
                break
            }
            kept.append(block)
            usedChars += cost
        }
        var output = header + "\n" + kept.joined(separator: separator)
        if kept.count < blocks.count {
            output += "\n（输出预算已满，已完整展示 \(kept.count) 条，全书共命中 \(totalCount) 处；如需缩小范围请使用更具体的关键词。）"
        }
        return output
    }

    private static func recallBM25Fallback(
        query: String,
        pages: [String],
        causalLimit: Int?
    ) -> [ManuscriptIndex.Excerpt] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|｜/、，,"))
        let splitTerms = query
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let queryTerms = splitTerms.count > 1 ? splitTerms : [query]

        var causalPrefix = ""
        var offset = 0
        for page in pages {
            let pageLen = (page as NSString).length
            if let limit = causalLimit {
                if offset >= limit { break }
                if offset + pageLen > limit {
                    let take = max(0, limit - offset)
                    causalPrefix += (page as NSString).substring(to: take)
                    break
                }
            }
            causalPrefix += page
            offset += pageLen
        }
        guard !causalPrefix.isEmpty else { return [] }

        return ManuscriptIndex.recallHistoricalExcerpts(
            fullManuscript: causalPrefix,
            activeWindowText: "",
            queryTerms: queryTerms,
            instructionText: query,
            causalLimit: nil,
            maxResults: 5,
            maxTokens: 900
        )
    }

    private static func executeReadEntity(
        entityKey: String,
        section: String?,
        state: MaterializedNarrativeState
    ) -> String {
        let needle = entityKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return "未提供实体 ID 或名称。"
        }

        if let exactByID = state.entityPages[needle] {
            return renderEntityPage(exactByID, section: section, state: state)
        }

        let allPages = state.entityPages.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }
        let normalizedNeedle = NarrativeEntityResolver.normalizeName(needle)

        let exactNormalizedHits = allPages.filter { page in
            let nameMatch = NarrativeEntityResolver.normalizeName(page.name) == normalizedNeedle
            let aliasMatch = page.aliases.contains {
                NarrativeEntityResolver.normalizeName($0) == normalizedNeedle
            }
            let keywordMatch = page.triggerKeywords.contains {
                NarrativeEntityResolver.normalizeName($0) == normalizedNeedle
            }
            return nameMatch || aliasMatch || keywordMatch
        }
        if !exactNormalizedHits.isEmpty {
            return exactNormalizedHits.prefix(3)
                .map { renderEntityPage($0, section: section, state: state) }
                .joined(separator: "\n\n---\n\n")
        }

        if normalizedNeedle.count >= 2 {
            let fuzzyHits = allPages.filter { page in
                let haystacks = [page.name] + page.aliases + page.triggerKeywords
                return haystacks.contains { raw in
                    let norm = NarrativeEntityResolver.normalizeName(raw)
                    guard norm.count >= 2 else { return false }
                    return norm.contains(normalizedNeedle) || normalizedNeedle.contains(norm)
                }
            }
            if !fuzzyHits.isEmpty {
                if fuzzyHits.count <= 3 {
                    return fuzzyHits
                        .map { renderEntityPage($0, section: section, state: state) }
                        .joined(separator: "\n\n---\n\n")
                }
                let candidates = fuzzyHits.prefix(10).map {
                    "- \($0.name)（\($0.kind.displayName)，ID: \($0.id)）"
                }
                return "「\(needle)」匹配到多个档案，请改用以下更精确的实体 ID 或全名查询：\n"
                    + candidates.joined(separator: "\n")
            }
        }

        let relatedBlocks = searchEventsAndThreads(matching: needle, state: state)
        if !relatedBlocks.isEmpty {
            return "未找到与「\(needle)」直接匹配的实体档案，但在剧情事件与伏笔中检索到关联条目：\n\n"
                + relatedBlocks.joined(separator: "\n\n")
        }

        let available = allPages.prefix(12).map { "- \($0.name)（\($0.kind.displayName)，ID: \($0.id)）" }
        if available.isEmpty {
            return "未找到与「\(needle)」匹配的实体档案页，当前世界书尚未建立任何档案。"
        }
        return "未找到与「\(needle)」匹配的实体档案、事件或伏笔。当前可查阅档案示例（共 \(allPages.count) 项）：\n"
            + available.joined(separator: "\n")
    }

    private static func renderEntityPage(
        _ page: EntityPage,
        section: String?,
        state: MaterializedNarrativeState
    ) -> String {
        let fullMarkdown = page.renderedMarkdown(
            resolvedFacts: state.facts(for: page.id),
            beliefs: state.beliefs(for: page.id),
            relatedEvents: state.events(for: page.id)
        )
        let cleanSection = section?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanSection.isEmpty else {
            return fullMarkdown
        }

        let blocks = fullMarkdown.components(separatedBy: "\n## ")
        if let hit = blocks.dropFirst().first(where: { $0.localizedCaseInsensitiveContains(cleanSection) }) {
            return "# \(page.name)\n\n## \(hit)"
        }
        return fullMarkdown
    }

    private static func searchEventsAndThreads(
        matching needle: String,
        state: MaterializedNarrativeState
    ) -> [String] {
        var sections: [String] = []
        let eventHits = state.sortedEpisodicEvents().filter { event in
            [event.title, event.arcTitle, event.scene, event.cause, event.development, event.outcome]
                .contains { !$0.isEmpty && $0.localizedCaseInsensitiveContains(needle) }
        }
        if !eventHits.isEmpty {
            let lines = eventHits.prefix(4).map { "- \($0.formattedSummaryLine)" }
            sections.append("【匹配关键事件】\n" + lines.joined(separator: "\n"))
        }

        let threadHits = state.threads.values
            .sorted { $0.updatedAt > $1.updatedAt }
            .filter { thread in
                thread.goal.localizedCaseInsensitiveContains(needle)
                    || thread.activationCue.localizedCaseInsensitiveContains(needle)
            }
        if !threadHits.isEmpty {
            let lines = threadHits.prefix(4).map {
                let cue = $0.activationCue.isEmpty ? "" : "（线索：\($0.activationCue)）"
                return "- [\($0.state.displayName)] \($0.goal)\(cue)"
            }
            sections.append("【匹配伏笔】\n" + lines.joined(separator: "\n"))
        }
        return sections
    }

    private static func parseArguments(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    private static func boundedOutput(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        let prefixSlice = String(text.prefix(maxChars))
        if let newlineRange = prefixSlice.range(of: "\n", options: .backwards),
           prefixSlice.distance(from: prefixSlice.startIndex, to: newlineRange.lowerBound) >= maxChars / 2 {
            return String(prefixSlice[..<newlineRange.lowerBound]) + "\n…（结果已按整行边界截断）"
        }
        return prefixSlice + "\n…（结果已截断）"
    }
}
