import Foundation

/// 发送给 LLM 的消息结构。与 `ChatMessage` 区分：`ChatMessage` 为 UI 层
/// 编辑实体（包含多分支），此处仅包含实际发送所需的 role 与 content。
struct LLMMessage: Codable, Hashable {
    var role: String
    var content: String
    var reasoningContent: String? = nil
    var isPrefix: Bool = false

    static func system(_ s: String) -> LLMMessage { .init(role: "system", content: s) }
    static func user(_ s: String) -> LLMMessage { .init(role: "user", content: s) }
    static func assistant(
        _ s: String,
        reasoningContent: String? = nil,
        isPrefix: Bool = false
    ) -> LLMMessage {
        .init(role: "assistant", content: s, reasoningContent: reasoningContent, isPrefix: isPrefix)
    }
}

/// 发给 `tools` 的函数定义（OpenAI function calling）。
struct LLMToolDefinition: Sendable, Hashable {
    var name: String
    var description: String
    var parametersJSON: String
}

/// 模型在 `choices[0].message.tool_calls` 中返回的函数调用。
struct LLMToolCall: Equatable, Sendable {
    var id: String
    var functionName: String
    var arguments: String
}

/// 一次请求。
///
/// 默认请求体保持原版 7 个核心键；仅当用户将思考档位配置为非关闭状态时，
/// 才按 AI 服务商协议追加 reasoning 相关字段。
struct LLMRequest {
    var model: String
    var messages: [LLMMessage]
    var stream: Bool
    var temperature: Double
    var maxTokens: Int
    /// 布尔思考开关覆盖（false 强制关闭，true 至少 high；nil 跟随服务商档位）。
    var thinking: Bool?
    /// 是否发送 `stream_options: {include_usage: true}`。
    var sendStreamOptions: Bool
    /// 幂等键，进 `Idempotency-Key` 头。非空才发。
    var attemptId: String?
    /// 输出因 `finish_reason=length` 被截断时是否直接报错。
    /// 世界刷新等结构化任务要求完整 JSON 输出，截断内容禁止作为有效结果解析。
    var failOnLength: Bool
    /// 工具定义；非空时序列化 `tools`。
    var tools: [LLMToolDefinition]?
    /// 强制指定函数调用名；非空时序列化 `tool_choice`。
    var toolChoiceName: String?
    /// 是否允许并行工具调用；非 nil 时序列化 `parallel_tool_calls`。
    var parallelToolCalls: Bool?
    /// 人物卡入库首次请求不发任何 `thinking`/`reasoning` 字段（`p6=false`）。
    var omitThinking: Bool
    /// 400 重试时无条件附带 `"thinking": {"type": "disabled"}`。
    var forceThinkingDisabledLiteral: Bool

    init(
        model: String,
        messages: [LLMMessage],
        stream: Bool = true,
        temperature: Double = 0.2,
        maxTokens: Int = 4096,
        thinking: Bool? = nil,
        sendStreamOptions: Bool = true,
        attemptId: String? = nil,
        failOnLength: Bool = false,
        tools: [LLMToolDefinition]? = nil,
        toolChoiceName: String? = nil,
        parallelToolCalls: Bool? = nil,
        omitThinking: Bool = false,
        forceThinkingDisabledLiteral: Bool = false
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.thinking = thinking
        self.sendStreamOptions = sendStreamOptions
        self.attemptId = attemptId
        self.failOnLength = failOnLength
        self.tools = tools
        self.toolChoiceName = toolChoiceName
        self.parallelToolCalls = parallelToolCalls
        self.omitThinking = omitThinking
        self.forceThinkingDisabledLiteral = forceThinkingDisabledLiteral
    }

    /// 按原版顺序组装；思考档位非关闭时按AI服务商能力追加字段。
    func jsonBody(
        isDeepSeek: Bool,
        kind: ProviderKind,
        providerLevel: ThinkingLevel,
        offStyle: ReasoningOffStyle = .none
    ) -> Data {
        let lowerModel = model.lowercased()
        let isKimiModel = lowerModel.contains("kimi") || lowerModel.contains("moonshot")
        let supportsReasoningField = isDeepSeek
            || lowerModel.contains("deepseek")
            || isKimiModel
            || lowerModel.contains("glm")

        let serializedMessages: [[String: Any]] = messages.map { msg in
            var dict: [String: Any] = ["role": msg.role, "content": msg.content]
            // DeepSeek / Kimi / GLM 支持在 assistant 消息上携带结构化 reasoning_content，
            // 避免拼进 content 破坏前缀缓存或格式解析。
            if supportsReasoningField,
               msg.role == "assistant",
               let reasoning = msg.reasoningContent,
               !reasoning.isEmpty {
                dict["reasoning_content"] = reasoning
            }
            if msg.role == "assistant", msg.isPrefix {
                if isKimiModel && !isDeepSeek {
                    dict["partial"] = true
                } else if supportsReasoningField {
                    dict["prefix"] = true
                }
            }
            return dict
        }
        var body: [String: Any] = [
            "model": model,
            "messages": serializedMessages,
            "stream": stream,
        ]

        if stream, !isDeepSeek, sendStreamOptions, kind != .openCodeGo {
            body["stream_options"] = ["include_usage": true]
        }

        if forceThinkingDisabledLiteral {
            body["thinking"] = ["type": "disabled"]
            body["temperature"] = temperature
        } else if omitThinking {
            body["temperature"] = temperature
        } else {
            let level = effectiveLevel(providerLevel: providerLevel)
            if level == .off {
                if isDeepSeek {
                    body["thinking"] = ["type": "disabled"]
                } else {
                    // 关闭思考模式下默认不传递额外字段（与原版行为一致）；仅当用户为特定供应方指定字段时才追加，
                    // 防止服务端默认启用推理导致无法关闭。
                    switch offStyle {
                    case .none:
                        break
                    case .reasoningEffortNone:
                        body["reasoning_effort"] = "none"
                    case .thinkingDisabled:
                        body["thinking"] = ["type": "disabled"]
                    case .reasoningDisabled:
                        body["reasoning"] = ["enabled": false]
                    case .enableThinkingFalse:
                        body["enable_thinking"] = false
                    }
                }
                body["temperature"] = temperature
            } else {
                if isDeepSeek {
                    body["thinking"] = ["type": "enabled"]
                    body["reasoning_effort"] = level.rawValue
                } else if kind == .openRouter {
                    body["reasoning"] = ["effort": level.rawValue]
                } else {
                    body["reasoning_effort"] = level.rawValue
                }
            }
        }

        let mappedTools: [[String: Any]] = (tools ?? []).compactMap { tool in
            guard let data = tool.parametersJSON.data(using: .utf8),
                  let params = try? JSONSerialization.jsonObject(with: data) else {
                return nil
            }
            return [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": params,
                ] as [String: Any],
            ]
        }
        if !mappedTools.isEmpty {
            body["tools"] = mappedTools
            if let toolChoiceName, !toolChoiceName.isEmpty {
                body["tool_choice"] = [
                    "type": "function",
                    "function": ["name": toolChoiceName],
                ] as [String: Any]
            }
            if let parallelToolCalls {
                body["parallel_tool_calls"] = parallelToolCalls
            }
        }

        body["max_tokens"] = maxTokens

        // 固定键序序列化，避免嵌套字典 hash 抖动破坏服务端 KV Cache 前缀匹配。
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    private func effectiveLevel(providerLevel: ThinkingLevel) -> ThinkingLevel {
        switch thinking {
        case .some(false):
            return .off
        case .some(true):
            return providerLevel.rank >= ThinkingLevel.high.rank ? providerLevel : .high
        case .none:
            return providerLevel
        }
    }
}

/// 流式事件枚举。除正文增量外，支持携带「思考过程」与「结束原因」：
/// DeepSeek 等推理模型会优先输出 `reasoning_content`。
enum LLMStreamEvent: Equatable {
    case delta(String)
    case reasoning(String)
    case finished(reason: String?)
}

/// 流式 `<think>...</think>` 标签剥离状态机。
///
/// 支持两种场景：
/// 1. 末尾挂了未闭合 `<think>` 预填充（`startsInsideThink = true`），模型首段输出直接作为 `.reasoning`，直到 `</think>` 后切回 `.delta`；
/// 2. 模型在普通文本流中自行输出 `<think>...</think>`，按标签边界自动拆分为 `.reasoning` 与 `.delta`，支持标签被 SSE 分片截断。
struct ThinkTagStreamSplitter {
    private static let openTag = "<think>"
    private static let closeTag = "</think>"

    private var insideThink: Bool
    private var buffer: String = ""
    private var trimLeadingNewlineAfterClose: Bool = false
    private var checkDuplicateOpenTag: Bool

    init(startsInsideThink: Bool = false) {
        self.insideThink = startsInsideThink
        self.checkDuplicateOpenTag = startsInsideThink
    }

    static func startsInsideThink(for messages: [LLMMessage]) -> Bool {
        guard let last = messages.last, last.role == "assistant" else { return false }
        return last.content.contains(openTag) && !last.content.contains(closeTag)
    }

    mutating func push(_ chunk: String) -> [LLMStreamEvent] {
        guard !chunk.isEmpty else { return [] }
        buffer += chunk
        var events: [LLMStreamEvent] = []

        while !buffer.isEmpty {
            if trimLeadingNewlineAfterClose {
                if buffer == "\r" { break }
                if buffer.hasPrefix("\r\n") {
                    buffer.removeFirst(2)
                } else if buffer.hasPrefix("\n") {
                    buffer.removeFirst(1)
                }
                trimLeadingNewlineAfterClose = false
                if buffer.isEmpty { break }
            }

            if insideThink {
                if checkDuplicateOpenTag {
                    if buffer.count < Self.openTag.count && Self.openTag.hasPrefix(buffer) {
                        break
                    }
                    if buffer.hasPrefix(Self.openTag) {
                        buffer.removeFirst(Self.openTag.count)
                        if buffer.hasPrefix("\r\n") {
                            buffer.removeFirst(2)
                        } else if buffer.hasPrefix("\n") {
                            buffer.removeFirst(1)
                        }
                    }
                    checkDuplicateOpenTag = false
                    if buffer.isEmpty { break }
                }
                if let range = buffer.range(of: Self.closeTag) {
                    let thought = String(buffer[..<range.lowerBound])
                    if !thought.isEmpty { events.append(.reasoning(thought)) }
                    buffer.removeSubrange(..<range.upperBound)
                    insideThink = false
                    trimLeadingNewlineAfterClose = true
                } else {
                    let keep = Self.trailingPartialPrefixLength(of: Self.closeTag, in: buffer)
                    let emitCount = buffer.count - keep
                    if emitCount > 0 {
                        let cut = buffer.index(buffer.startIndex, offsetBy: emitCount)
                        events.append(.reasoning(String(buffer[..<cut])))
                        buffer.removeSubrange(..<cut)
                    }
                    break
                }
            } else {
                if let range = buffer.range(of: Self.openTag) {
                    let prose = String(buffer[..<range.lowerBound])
                    if !prose.isEmpty { events.append(.delta(prose)) }
                    buffer.removeSubrange(..<range.upperBound)
                    insideThink = true
                } else {
                    let keep = Self.trailingPartialPrefixLength(of: Self.openTag, in: buffer)
                    let emitCount = buffer.count - keep
                    if emitCount > 0 {
                        let cut = buffer.index(buffer.startIndex, offsetBy: emitCount)
                        events.append(.delta(String(buffer[..<cut])))
                        buffer.removeSubrange(..<cut)
                    }
                    break
                }
            }
        }
        return events
    }

    mutating func finish() -> [LLMStreamEvent] {
        guard !buffer.isEmpty else { return [] }
        let tail = buffer
        buffer = ""
        trimLeadingNewlineAfterClose = false
        return [insideThink ? .reasoning(tail) : .delta(tail)]
    }

    /// 一次性文本（非流式 `complete`）剥离 `<think>...</think>`。
    static func stripThinkTags(
        from text: String,
        startsInsideThink: Bool = false
    ) -> (prose: String, reasoning: String) {
        var splitter = ThinkTagStreamSplitter(startsInsideThink: startsInsideThink)
        let events = splitter.push(text) + splitter.finish()
        var prose = ""
        var reasoning = ""
        for event in events {
            switch event {
            case .delta(let chunk):
                prose += chunk
            case .reasoning(let chunk):
                reasoning += chunk
            case .finished:
                break
            }
        }
        return (prose, reasoning)
    }

    private static func trailingPartialPrefixLength(of tag: String, in text: String) -> Int {
        let maxLen = min(tag.count - 1, text.count)
        guard maxLen > 0 else { return 0 }
        for len in stride(from: maxLen, through: 1, by: -1) {
            if text.hasSuffix(tag.prefix(len)) {
                return len
            }
        }
        return 0
    }
}

enum LLMError: LocalizedError, Equatable {
    case notConfigured
    case missingAPIKey(String)
    case badURL(String)
    case http(status: Int, body: String)
    case decoding(String)
    case cancelled
    /// 空响应错误。附带服务端原始响应内容，便于明确具体错误原因。
    case emptyResponse(detail: String)
    /// 命中输出上限，响应被截断。结构化 JSON 任务不能继续解析。
    case truncated(detail: String)
    /// 服务端在 200 响应里下发的错误，或流在结束标记前中断。
    case streamError(detail: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "暂无可用的 AI 服务商，请先在设置中填写服务地址与 API Key。"
        case .missingAPIKey(let name):
            return "尚未填写 \(name) 的 API Key。"
        case .badURL(let url):
            return "服务地址不合法：\(url)"
        case .http(let status, let body):
            let snippet = body.prefix(300)
            return "请求失败（HTTP \(status)）：\(snippet)"
        case .decoding(let detail):
            return "响应解析失败：\(detail)"
        case .cancelled:
            return "已取消。"
        case .emptyResponse(let detail):
            if detail.isEmpty {
                return "模型返回了空响应，请检查模型兼容性或切换流式模式。"
            }
            return "模型返回了空响应。服务端原始返回：\(detail)"
        case .truncated(let detail):
            return "模型输出触及上限，响应被截断；本段未应用。\(detail)"
        case .streamError(let detail):
            return "生成中断：\(detail)"
        }
    }
}

extension Error {
    /// 取消操作包含三种形态：结构化并发取消、URLSession 错误及客户端统一映射后的 `LLMError`。
    /// 世界、事件、摘要等流程均依赖此判定区分「用户主动停止」与「请求实际失败」。
    var isLLMCancellation: Bool {
        if self is CancellationError { return true }
        if let llm = self as? LLMError { return llm == .cancelled }
        if let url = self as? URLError { return url.code == .cancelled }
        return false
    }
}

protocol LLMClient: Sendable {
    /// 流式生成。调用方 `for try await` 消费。
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
    /// 一次性生成，用于人物卡抽取这类要求完整 JSON 的任务。
    func complete(_ request: LLMRequest) async throws -> String
    /// 一次性函数调用（如 `create_character_card`），返回模型返回的 `tool_calls`。
    func completeToolCall(_ request: LLMRequest) async throws -> [LLMToolCall]
    /// 读取服务端可用模型，用于设置页的模型选择。
    func listModels() async throws -> [String]
    /// 连通性测试：发一条最短请求，失败即抛。
    func testConnection() async throws
}
