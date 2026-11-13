import Foundation

/// 发给 LLM 的一条消息。与 `ChatMessage` 分开：`ChatMessage` 是 UI 的
/// 编辑单元（带分支），这里只带最终要发出去的 role/content。
struct LLMMessage: Codable, Hashable {
    var role: String
    var content: String

    static func system(_ s: String) -> LLMMessage { .init(role: "system", content: s) }
    static func user(_ s: String) -> LLMMessage { .init(role: "user", content: s) }
    static func assistant(_ s: String) -> LLMMessage { .init(role: "assistant", content: s) }
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
/// 默认请求体保持原版 7 键；只有用户把思考档位调到非关闭时，
/// 才按AI服务商追加 reasoning 字段。
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
    /// 世界刷新这类结构化任务必须整段 JSON，截断不能当正常结果解析。
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
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
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
                    // 关闭思考默认什么都不发（原版行为）；用户按供应方挑了字段才追加，
                    // 否则默认开推理的服务端根本关不掉。
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

        if let tools, !tools.isEmpty {
            body["tools"] = tools.compactMap { tool -> [String: Any]? in
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
        }
        if let toolChoiceName, !toolChoiceName.isEmpty {
            body["tool_choice"] = [
                "type": "function",
                "function": ["name": toolChoiceName],
            ] as [String: Any]
        }
        if let parallelToolCalls {
            body["parallel_tool_calls"] = parallelToolCalls
        }

        body["max_tokens"] = maxTokens

        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
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

/// 流式事件。除了正文增量，还要能把「思考过程」和「结束原因」带出来：
/// DeepSeek 的 reasoning 模型会先吐 `reasoning_content`。
enum LLMStreamEvent: Equatable {
    case delta(String)
    case reasoning(String)
    case finished(reason: String?)
}

enum LLMError: LocalizedError, Equatable {
    case notConfigured
    case missingAPIKey(String)
    case badURL(String)
    case http(status: Int, body: String)
    case decoding(String)
    case cancelled
    /// 空响应。带上服务端原始返回，否则「空响应」三个字什么也说明不了。
    case emptyResponse(detail: String)
    /// 命中输出上限，响应被截断。结构化 JSON 任务不能继续解析。
    case truncated(detail: String)
    /// 服务端在 200 响应里下发的错误，或流在结束标记前中断。
    case streamError(detail: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "还没有可用的AI服务商，请先到设置里填写服务地址和 API Key。"
        case .missingAPIKey(let name):
            return "\(name) 的 API Key 还没填写。"
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
    /// 取消有三种形状：结构化并发、URLSession，以及客户端归一后的 `LLMError`。
    /// 世界/事件/摘要这些流程都靠它区分「用户点了停止」与「请求真的失败」。
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
