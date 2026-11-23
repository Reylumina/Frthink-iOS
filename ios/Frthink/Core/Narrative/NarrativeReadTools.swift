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
            description: "按 ID、名称或别名读取离场角色、地点、物件或设定的完整独立档案与关联事实。",
            parametersJSON: """
            {"type":"object","properties":{"entity_id":{"type":"string","description":"实体 ID、姓名或别名"},"section":{"type":"string","description":"可选节标题筛选，例如 声音档案 / 行为底线 / 当前事实"}},"required":["entity_id"]}
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
            let pattern = (args["pattern"] as? String) ?? ""
            let contextLines = (args["context_lines"] as? Int) ?? 1
            let regex = (args["regex"] as? Bool) ?? false
            output = executeGrep(
                pattern: pattern,
                contextLines: contextLines,
                regex: regex,
                context: context
            )
        case readEntityPageName:
            let entityKey = (args["entity_id"] as? String) ?? ""
            let section = args["section"] as? String
            output = executeReadEntity(
                entityKey: entityKey,
                section: section,
                state: context.materializedState
            )
        case restoreTurnName:
            let stepRange = (args["step_range"] as? String) ?? ""
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
            output: boundedOutput(output, maxChars: 1_800)
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
        let matches = ManuscriptIndex.grepManuscript(
            pages: context.pages,
            pattern: trimmed,
            contextLines: min(3, max(0, contextLines)),
            regex: regex,
            causalLimit: context.causalLimit,
            maxMatches: 8
        )
        guard !matches.isEmpty else {
            return "在当前锚点之前的正文中未找到「\(trimmed)」。"
        }
        let lines = matches.enumerated().map { idx, hit in
            "[\(idx + 1)] 第 \(hit.pageIndex + 1) 页 第 \(hit.lineNumber) 行\n\(hit.contextSnippet)"
        }
        return lines.joined(separator: "\n---\n")
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

        let matchedPage: EntityPage? = state.entityPages[needle]
            ?? state.entityPages.values.first { page in
                page.name.caseInsensitiveCompare(needle) == .orderedSame
                    || page.aliases.contains { $0.caseInsensitiveCompare(needle) == .orderedSame }
            }

        guard let page = matchedPage else {
            return "未找到与「\(needle)」匹配的实体档案页。"
        }

        let fullMarkdown = page.renderedMarkdown(
            resolvedFacts: state.facts(for: page.id),
            beliefs: state.beliefs(for: page.id)
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

    private static func parseArguments(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return dict
    }

    private static func boundedOutput(_ text: String, maxChars: Int) -> String {
        guard text.count > maxChars else { return text }
        return String(text.prefix(maxChars)) + "\n…（结果已截断）"
    }
}
