import Foundation

/// Anthropic Messages API 客户端（`/v1/messages`）。
///
/// 鉴权：`x-api-key` + `anthropic-version: 2023-06-01`。
/// 流式：SSE `content_block_delta`（`text_delta` / `thinking_delta`）、
/// `message_delta`（`stop_reason`）与 `message_stop`。
final class AnthropicClient: LLMClient {
    private static let apiVersion = "2023-06-01"

    private let baseURL: String
    private let apiKey: String
    private let provider: ProviderSetting

    private var session: URLSession { OpenAICompatibleClient.sharedSession }

    init(baseURL: String, apiKey: String, provider: ProviderSetting) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.provider = provider
    }

    // MARK: - URL 与请求头

    private var trimmedBase: String {
        var b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    private func endpoint(_ v1Subpath: String) throws -> URL {
        let path = trimmedBase.hasSuffix("/v1") ? v1Subpath : "/v1" + v1Subpath
        guard let url = URL(string: trimmedBase + path) else {
            throw LLMError.badURL(trimmedBase + path)
        }
        return url
    }

    private func makeRequest(
        v1Subpath: String,
        body: Data?,
        accept: String = "application/json"
    ) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(v1Subpath))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }

    // MARK: - 请求体组装

    /// 将通用 `LLMRequest` 转换为 Anthropic `/v1/messages` 请求体。
    static func requestBody(
        for request: LLMRequest,
        providerLevel: ThinkingLevel
    ) -> Data {
        let systemText = request.messages
            .filter { $0.role == "system" }
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

        // Anthropic 要求非 system 消息从 user 开始且角色交替；连续同角色合并。
        var chatMessages: [[String: Any]] = []
        for msg in request.messages where msg.role != "system" {
            let role = msg.role == "assistant" ? "assistant" : "user"
            if let lastRole = chatMessages.last?["role"] as? String, lastRole == role,
               let prev = chatMessages.last?["content"] as? String {
                chatMessages[chatMessages.count - 1]["content"] = prev + "\n\n" + msg.content
            } else {
                chatMessages.append(["role": role, "content": msg.content])
            }
        }
        if chatMessages.first?["role"] as? String == "assistant" {
            chatMessages.insert(["role": "user", "content": " "], at: 0)
        }
        if chatMessages.isEmpty {
            chatMessages.append(["role": "user", "content": " "])
        }

        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": max(1, request.maxTokens),
            "messages": chatMessages,
            "stream": request.stream,
        ]
        if !systemText.isEmpty {
            // Anthropic 默认不自动缓存；system 达到 1024 tokens 门槛时显式挂 ephemeral 断点。
            if TokenEstimator.estimate(systemText) >= 1024 {
                body["system"] = [[
                    "type": "text",
                    "text": systemText,
                    "cache_control": ["type": "ephemeral"],
                ]]
            } else {
                body["system"] = systemText
            }
        }

        var mappedTools: [[String: Any]] = (request.tools ?? []).compactMap { tool in
            guard let data = tool.parametersJSON.data(using: .utf8),
                  let params = try? JSONSerialization.jsonObject(with: data) else {
                return nil
            }
            return [
                "name": tool.name,
                "description": tool.description,
                "input_schema": params,
            ]
        }
        if !mappedTools.isEmpty, TokenEstimator.estimate(systemText) >= 1024 {
            mappedTools[mappedTools.count - 1]["cache_control"] = ["type": "ephemeral"]
        }
        if chatMessages.count >= 2 {
            let prefixTokens = chatMessages.dropLast().reduce(0) { sum, msg in
                sum + TokenEstimator.estimate(msg["content"] as? String ?? "")
            }
            if prefixTokens >= 1024,
               let text = chatMessages[chatMessages.count - 2]["content"] as? String {
                chatMessages[chatMessages.count - 2]["content"] = [[
                    "type": "text",
                    "text": text,
                    "cache_control": ["type": "ephemeral"],
                ]]
                body["messages"] = chatMessages
            }
        }
        let forcesTool = !mappedTools.isEmpty
            && !(request.toolChoiceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)

        // Anthropic 不允许在强制 tool_choice 时开启 thinking。
        let level = forcesTool ? .off : effectiveThinkingLevel(request: request, providerLevel: providerLevel)
        if level != .off, request.maxTokens > 1024 {
            let rawBudget: Int
            switch level {
            case .off: rawBudget = 0
            case .low: rawBudget = 2048
            case .high: rawBudget = 8192
            case .max: rawBudget = 16384
            }
            let budget = min(rawBudget, request.maxTokens - 1)
            if budget >= 1024 {
                body["thinking"] = ["type": "enabled", "budget_tokens": budget]
                // Anthropic 启用扩展思考时 temperature 必须为 1。
                body["temperature"] = 1.0
            } else {
                body["temperature"] = min(max(request.temperature, 0.0), 1.0)
            }
        } else {
            body["temperature"] = min(max(request.temperature, 0.0), 1.0)
        }

        if !mappedTools.isEmpty {
            body["tools"] = mappedTools
            if let toolChoiceName = request.toolChoiceName, !toolChoiceName.isEmpty {
                var choice: [String: Any] = ["type": "tool", "name": toolChoiceName]
                if request.parallelToolCalls == false {
                    choice["disable_parallel_tool_use"] = true
                }
                body["tool_choice"] = choice
            } else if request.parallelToolCalls == false {
                body["tool_choice"] = ["type": "auto", "disable_parallel_tool_use": true]
            }
        }

        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data()
    }

    private static func effectiveThinkingLevel(
        request: LLMRequest,
        providerLevel: ThinkingLevel
    ) -> ThinkingLevel {
        if request.omitThinking || request.forceThinkingDisabledLiteral {
            return .off
        }
        switch request.thinking {
        case .some(false):
            return .off
        case .some(true):
            return providerLevel.rank >= ThinkingLevel.high.rank ? providerLevel : .high
        case .none:
            return providerLevel
        }
    }

    // MARK: - 流式

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await runStream(request, continuation: continuation)
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runStream(
        _ request: LLMRequest,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async {
        await LLMHTTPTransport.runStream(continuation: continuation) {
            var req = request
            req.stream = true
            let urlRequest = try makeRequest(
                v1Subpath: "/messages",
                body: Self.requestBody(for: req, providerLevel: provider.effectiveThinkingLevel),
                accept: "text/event-stream"
            )
            let bytes = try await LLMHTTPTransport.openBytes(urlRequest, session: session)
            try await consumeStream(
                bytes,
                startsInsideThink: ThinkTagStreamSplitter.startsInsideThink(for: req.messages),
                continuation: continuation
            )
        }
    }

    private func consumeStream(
        _ bytes: URLSession.AsyncBytes,
        startsInsideThink: Bool,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        var stopReason: String?
        var emittedAnything = false
        var sawStop = false
        var undecodableLines = 0
        var rawLog: [String] = []
        let decoder = JSONDecoder()
        var splitter = ThinkTagStreamSplitter(startsInsideThink: startsInsideThink)

        for try await line in bytes.lines {
            if Task.isCancelled {
                continuation.finish(throwing: LLMError.cancelled)
                return
            }
            if rawLog.count < 40, !line.isEmpty {
                rawLog.append(line)
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            guard let data = payload.data(using: .utf8),
                  let event = autoreleasepool(invoking: { try? decoder.decode(StreamEvent.self, from: data) }) else {
                undecodableLines += 1
                continue
            }

            if let error = event.error {
                throw LLMError.streamError(detail: error.detail)
            }
            switch event.type {
            case "content_block_delta":
                if let thinking = event.delta?.thinking, !thinking.isEmpty {
                    emittedAnything = true
                    continuation.yield(.reasoning(thinking))
                }
                if let text = event.delta?.text, !text.isEmpty {
                    emittedAnything = true
                    for splitEvent in splitter.push(text) {
                        continuation.yield(splitEvent)
                    }
                }
            case "message_delta":
                if let reason = event.delta?.stop_reason, !reason.isEmpty {
                    stopReason = reason == "max_tokens" ? "length" : reason
                }
            case "message_stop":
                sawStop = true
            default:
                break
            }
        }

        for splitEvent in splitter.finish() {
            emittedAnything = true
            continuation.yield(splitEvent)
        }

        if emittedAnything, undecodableLines > 0, stopReason == nil, !sawStop {
            throw LLMError.streamError(
                detail: "流中有 \(undecodableLines) 行无法解析，且未收到结束标记；本次回复可能不完整。"
            )
        }

        if !emittedAnything {
            let detail = rawLog.joined(separator: " / ")
            continuation.finish(
                throwing: LLMError.emptyResponse(
                    detail: detail.isEmpty ? "（连接建立但没有收到任何 SSE 行）" : detail
                )
            )
            return
        }

        continuation.yield(.finished(reason: stopReason))
        continuation.finish()
    }

    // MARK: - 非流式

    func complete(_ request: LLMRequest) async throws -> String {
        let response = try await sendMessage(request)
        if request.failOnLength, response.stop_reason == "max_tokens" {
            throw LLMError.truncated(detail: "finish_reason=max_tokens")
        }
        let rawText = response.content?
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined() ?? ""
        let split = ThinkTagStreamSplitter.stripThinkTags(
            from: rawText,
            startsInsideThink: ThinkTagStreamSplitter.startsInsideThink(for: request.messages)
        )
        let text = split.prose
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !split.reasoning.isEmpty {
                throw LLMError.emptyResponse(
                    detail: "仅返回思考内容（\(split.reasoning.count) 字），正文为空。"
                )
            }
            throw LLMError.emptyResponse(detail: "Anthropic 未返回任何文本块")
        }
        return text
    }

    func completeToolCall(_ request: LLMRequest) async throws -> [LLMToolCall] {
        let response: MessageResponse
        do {
            response = try await sendMessage(request)
        } catch let LLMError.http(status, body) where status == 400
            && body.lowercased().contains("thinking")
            && !request.omitThinking {
            var retry = request
            retry.omitThinking = true
            response = try await sendMessage(retry)
        }
        if request.failOnLength, response.stop_reason == "max_tokens" {
            throw LLMError.truncated(detail: "finish_reason=max_tokens")
        }
        let calls: [LLMToolCall] = (response.content ?? []).compactMap { block in
            guard block.type == "tool_use", let name = block.name else { return nil }
            let argsData = (try? JSONSerialization.data(withJSONObject: block.inputObject ?? [:])) ?? Data()
            let args = String(data: argsData, encoding: .utf8) ?? "{}"
            return LLMToolCall(
                id: block.id ?? UUID().uuidString,
                functionName: name,
                arguments: args
            )
        }
        if calls.isEmpty {
            throw LLMError.emptyResponse(detail: "Anthropic 未返回 tool_use 块")
        }
        return calls
    }

    private func sendMessage(_ request: LLMRequest) async throws -> MessageResponse {
        var req = request
        req.stream = false
        let urlRequest = try makeRequest(
            v1Subpath: "/messages",
            body: Self.requestBody(for: req, providerLevel: provider.effectiveThinkingLevel)
        )
        let data = try await performData(urlRequest)
        let decoded: MessageResponse
        do {
            decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
        } catch {
            throw LLMError.decoding(error.localizedDescription)
        }
        if let error = decoded.error {
            throw LLMError.streamError(detail: error.detail)
        }
        return decoded
    }

    // MARK: - 模型列表与连通性测试

    func listModels() async throws -> [String] {
        let urlRequest = try makeRequest(v1Subpath: "/models", body: nil)
        let data = try await performData(urlRequest)
        let decoded: ModelListResponse
        do {
            decoded = try JSONDecoder().decode(ModelListResponse.self, from: data)
        } catch {
            throw LLMError.decoding(error.localizedDescription)
        }
        return Array(Set((decoded.data ?? []).map(\.id))).sorted()
    }

    func testConnection() async throws {
        let resolved = provider.resolvedModel
        let model = resolved.isEmpty
            ? (ModelCatalog.latest(for: .anthropic) ?? "claude-sonnet-5-5")
            : resolved
        let probe = LLMRequest(
            model: model,
            messages: [.user("hi")],
            stream: false,
            temperature: 0,
            maxTokens: 16,
            thinking: false
        )
        _ = try await complete(probe)
    }

    private func performData(_ urlRequest: URLRequest) async throws -> Data {
        try await LLMHTTPTransport.performData(urlRequest, session: session).0
    }

    // MARK: - 响应模型

    private struct APIError: Decodable {
        let type: String?
        let message: String?

        var detail: String {
            let msg = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !msg.isEmpty {
                if let type, !type.isEmpty { return "\(type)：\(msg)" }
                return msg
            }
            return type ?? "服务端返回了错误"
        }
    }

    private struct StreamEvent: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let thinking: String?
            let stop_reason: String?
        }
        let type: String?
        let delta: Delta?
        let error: APIError?
    }

    private struct MessageResponse: Decodable {
        struct ContentBlock: Decodable {
            let type: String
            let text: String?
            let id: String?
            let name: String?
            let input: AnyCodableValue?

            var inputObject: Any? { input?.jsonValue }
        }
        let content: [ContentBlock]?
        let stop_reason: String?
        let error: APIError?
    }

    private struct ModelListResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]?
    }
}

/// 轻量 JSON 值包装，用于将 Anthropic `tool_use.input` 还原为 JSON 字符串。
private enum AnyCodableValue: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case object([String: AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let b = try? container.decode(Bool.self) { self = .bool(b); return }
        if let d = try? container.decode(Double.self) { self = .number(d); return }
        if let s = try? container.decode(String.self) { self = .string(s); return }
        if let arr = try? container.decode([AnyCodableValue].self) { self = .array(arr); return }
        if let obj = try? container.decode([String: AnyCodableValue].self) { self = .object(obj); return }
        self = .null
    }

    var jsonValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .array(let arr): return arr.map(\.jsonValue)
        case .object(let obj): return obj.mapValues(\.jsonValue)
        case .null: return NSNull()
        }
    }
}
