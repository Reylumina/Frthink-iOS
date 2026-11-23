import Foundation

/// OpenAI 兼容协议的客户端。DeepSeek、OpenRouter、以及任何自建网关都走这一份。
///
/// 端点：`{base}/chat/completions`、`{base}/models`。
/// 鉴权：`Authorization: Bearer <key>`。
/// 流式：SSE，每行 `data: {...}`，结尾 `data: [DONE]`。
final class OpenAICompatibleClient: LLMClient {
    private let baseURL: String
    private let apiKey: String
    private let provider: ProviderSetting

    /// 全应用共享一条 URLSession。
    ///
    /// 复用连接池与 TLS 会话缓存，避免每次请求新建 session 持有多余连接。
    ///
    /// - `ephemeral` 且 `urlCache = nil`：LLM 响应不应写入 URL 缓存，SSE 流式数据亦同。
    /// - `waitsForConnectivity = false`：交互式请求遇网络断开立即返回错误，避免长时间挂起。
    static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // 流式响应可能长时间无增量数据，设置充足的请求超时；资源超时用于防范连接异常挂起。
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 900
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    private var session: URLSession { Self.sharedSession }

    init(baseURL: String, apiKey: String, provider: ProviderSetting) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.provider = provider
    }

    // MARK: - URL

    private var trimmedBase: String {
        var b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    private func endpoint(_ path: String, useDeepSeekBeta: Bool = false) throws -> URL {
        var base = trimmedBase
        if useDeepSeekBeta, provider.isDeepSeek {
            if base.hasSuffix("/v1") {
                base = String(base.dropLast(3)) + "/beta"
            } else if !base.hasSuffix("/beta") {
                base += "/beta"
            }
        }
        guard let url = URL(string: base + path) else {
            throw LLMError.badURL(base + path)
        }
        return url
    }

    private func makeRequest(
        path: String,
        body: Data?,
        accept: String = "application/json",
        attemptId: String? = nil,
        useDeepSeekBeta: Bool = false
    ) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(path, useDeepSeekBeta: useDeepSeekBeta))
        request.httpMethod = body == nil ? "GET" : "POST"
        // 生成请求永不命中缓存；共享 session 里也不保留响应体。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if provider.isOpenCode {
            request.setValue(openCodeSessionID, forHTTPHeaderField: "x-opencode-session")
        } else if !provider.isDeepSeek {
            // 为支持 Session Affinity 的兼容网关提供稳定会话亲和键，提升前缀 KV Cache 路由命中率。
            request.setValue(openCodeSessionID, forHTTPHeaderField: "X-Session-Affinity")
        }
        // 幂等键：一次「尝试」的稳定标识，重试时原版会加后缀。
        if let attemptId, !attemptId.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue(attemptId, forHTTPHeaderField: "Idempotency-Key")
        }
        request.httpBody = body
        return request
    }

    private var openCodeSessionID: String {
        let key = "opencode.session.\(provider.id)"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: key)
        return value
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
        do {
            var req = request
            req.stream = true
            var (bytes, http) = try await openStream(for: req)

            // 最多按顺序回退三次：剥离不支持的 stream_options、tools 或末尾 prefill。
            for _ in 0..<3 where (400..<500).contains(http.statusCode) {
                let body = try await Self.drain(bytes)
                if !provider.isDeepSeek,
                   req.sendStreamOptions,
                   Self.isUnsupportedStreamOptions(status: http.statusCode, body: body) {
                    req.sendStreamOptions = false
                    (bytes, http) = try await openStream(for: req)
                    continue
                }
                if !(req.tools?.isEmpty ?? true),
                   Self.isUnsupportedTools(status: http.statusCode, body: body) {
                    req.tools = nil
                    req.toolChoiceName = nil
                    req.parallelToolCalls = nil
                    (bytes, http) = try await openStream(for: req)
                    continue
                }
                if Self.isUnsupportedPrefill(status: http.statusCode, body: body),
                   let stripped = Self.strippingTrailingPrefill(from: req.messages) {
                    req.messages = stripped
                    (bytes, http) = try await openStream(for: req)
                    continue
                }
                throw LLMError.http(status: http.statusCode, body: body)
            }

            guard (200..<300).contains(http.statusCode) else {
                let body = try await Self.drain(bytes)
                throw LLMError.http(status: http.statusCode, body: body)
            }
            try await consumeStream(
                bytes,
                startsInsideThink: ThinkTagStreamSplitter.startsInsideThink(for: req.messages),
                continuation: continuation
            )
        } catch is CancellationError {
            continuation.finish(throwing: LLMError.cancelled)
        } catch let urlError as URLError where urlError.code == .cancelled {
            continuation.finish(throwing: LLMError.cancelled)
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func openStream(for req: LLMRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let usesPrefixBeta = provider.isDeepSeek && req.messages.last?.isPrefix == true
        let urlRequest = try makeRequest(
            path: "/chat/completions",
            body: req.jsonBody(
                isDeepSeek: provider.isDeepSeek,
                kind: provider.kind,
                providerLevel: provider.effectiveThinkingLevel,
                offStyle: provider.effectiveReasoningOffStyle
            ),
            accept: "text/event-stream",
            attemptId: req.attemptId,
            useDeepSeekBeta: usesPrefixBeta
        )
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("未获取到 HTTP 状态码")
        }
        return (bytes, http)
    }

    private static func isUnsupportedStreamOptions(status: Int, body: String) -> Bool {
        guard status == 400 || status == 422 else { return false }
        let lower = body.lowercased()
        guard lower.contains("stream_options") else { return false }
        let markers = [
            "unsupported", "not supported", "unknown", "unrecognized",
            "not allowed", "not permitted", "extra fields", "invalid",
            "不支持", "不允许",
        ]
        return markers.contains { lower.contains($0) }
    }

    static func isUnsupportedPrefill(status: Int, body: String) -> Bool {
        guard status == 400 || status == 422 else { return false }
        let lower = body.lowercased()
        let keys = [
            "prefix", "partial", "prefill", "reasoning_content",
            "last message", "role must be user", "end with a user",
            "assistant message",
        ]
        return keys.contains { lower.contains($0) }
    }

    static func isUnsupportedTools(status: Int, body: String) -> Bool {
        guard status == 400 || status == 422 else { return false }
        let lower = body.lowercased()
        let mentionsTools = lower.contains("tool") || lower.contains("function")
        guard mentionsTools else { return false }
        let markers = [
            "unsupported", "not supported", "unknown", "unrecognized",
            "not allowed", "not permitted", "invalid", "disabled",
            "不支持", "不允许",
        ]
        return markers.contains { lower.contains($0) }
    }

    static func strippingTrailingPrefill(from messages: [LLMMessage]) -> [LLMMessage]? {
        guard let last = messages.last, last.role == "assistant" else { return nil }
        guard last.isPrefix || ThinkTagStreamSplitter.startsInsideThink(for: messages) else {
            return nil
        }
        return Array(messages.dropLast())
    }

    private func consumeStream(
        _ bytes: URLSession.AsyncBytes,
        startsInsideThink: Bool,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        var finishReason: String?
        var emittedAnything = false
        var sawDone = false
        var undecodableLines = 0
        // 记录接收到的原始 SSE 行数据。在判定「空响应」时附带输出，
        // 便于区分鉴权失效、参数错误或模型名称不匹配等问题。
        var rawLog: [String] = []
        // 单条数据流复用同一个解码器实例，避免为每个 chunk 重复创建 JSONDecoder。
        let chunkDecoder = JSONDecoder()
        var splitter = ThinkTagStreamSplitter(startsInsideThink: startsInsideThink)
        var pendingToolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
        var maxToolIndex = -1

        for try await line in bytes.lines {
            if Task.isCancelled {
                continuation.finish(throwing: LLMError.cancelled)
                return
            }
            if rawLog.count < 40, !line.isEmpty {
                rawLog.append(line)
            }
            guard line.hasPrefix("data:") else { continue }
            let payload = line
                .dropFirst("data:".count)
                .trimmingCharacters(in: .whitespaces)

            if payload == "[DONE]" {
                sawDone = true
                break
            }
            if payload.isEmpty { continue }

            guard let data = payload.data(using: .utf8) else { continue }
            // 在长时间流式处理中限制临时对象的作用域，利用 autoreleasepool
            // 及时释放单行内存，防止大量行数据累积导致内存峰值过高。
            guard let chunk = autoreleasepool(invoking: {
                try? chunkDecoder.decode(StreamChunk.self, from: data)
            }) else {
                undecodableLines += 1
                continue
            }
            try handleChunk(
                chunk,
                splitter: &splitter,
                continuation: continuation,
                finishReason: &finishReason,
                emittedAnything: &emittedAnything,
                pendingToolCalls: &pendingToolCalls,
                maxToolIndex: &maxToolIndex
            )
        }

        for event in splitter.finish() {
            emittedAnything = true
            continuation.yield(event)
        }

        if !pendingToolCalls.isEmpty {
            let calls: [LLMToolCall] = pendingToolCalls.keys.sorted().compactMap { idx in
                guard let builder = pendingToolCalls[idx] else { return nil }
                let cleanName = builder.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanName.isEmpty else { return nil }
                let callID = builder.id.trimmingCharacters(in: .whitespacesAndNewlines)
                let rawArgs = builder.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
                return LLMToolCall(
                    id: callID.isEmpty ? UUID().uuidString : callID,
                    functionName: cleanName,
                    arguments: rawArgs.isEmpty ? "{}" : builder.arguments
                )
            }
            if !calls.isEmpty {
                emittedAnything = true
                continuation.yield(.toolCalls(calls))
            }
        }

        if emittedAnything, undecodableLines > 0, finishReason == nil, !sawDone {
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
        continuation.yield(.finished(reason: finishReason))
        continuation.finish()
    }

    private func handleChunk(
        _ chunk: StreamChunk,
        splitter: inout ThinkTagStreamSplitter,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation,
        finishReason: inout String?,
        emittedAnything: inout Bool,
        pendingToolCalls: inout [Int: (id: String, name: String, arguments: String)],
        maxToolIndex: inout Int
    ) throws {
        // 状态码 200 的流式响应中亦可能下发错误信息（如限流、内容审核、上下文溢出），
        // 必须捕获处理，防止不完整正文被误判为正常结束。
        if let streamError = chunk.error {
            throw LLMError.streamError(detail: streamError.detail)
        }

        if let choice = chunk.choices?.first {
            if finishReason == nil,
               let rawReason = choice.finish_reason ?? choice.delta?.stop_reason ?? chunk.stop_reason,
               !rawReason.isEmpty {
                finishReason = rawReason
            }
            let delta = choice.delta
            let content = delta?.contentText ?? chunk.contentText
            let reasoning = delta?.reasoningText ?? chunk.reasoningText

            if let reasoning, !reasoning.isEmpty {
                emittedAnything = true
                continuation.yield(.reasoning(reasoning))
            }
            if let toolDeltas = delta?.tool_calls, !toolDeltas.isEmpty {
                emittedAnything = true
                for tc in toolDeltas {
                    let idx = tc.index ?? (maxToolIndex + 1)
                    maxToolIndex = max(maxToolIndex, idx)
                    var current = pendingToolCalls[idx] ?? (id: "", name: "", arguments: "")
                    if let id = tc.id, !id.isEmpty { current.id = id }
                    if let name = tc.function?.name, !name.isEmpty { current.name = name }
                    if let args = tc.function?.arguments, !args.isEmpty { current.arguments += args }
                    pendingToolCalls[idx] = current
                }
            }
            if let content, !content.isEmpty {
                emittedAnything = true
                for event in splitter.push(content) {
                    continuation.yield(event)
                }
            }
            return
        }

        if finishReason == nil { finishReason = chunk.stop_reason }
        if let content = chunk.contentText, !content.isEmpty {
            emittedAnything = true
            for event in splitter.push(content) {
                continuation.yield(event)
            }
        } else if let reasoning = chunk.reasoningText, !reasoning.isEmpty {
            emittedAnything = true
            continuation.yield(.reasoning(reasoning))
        }
    }

    /// 错误信息中回显原始响应的长度上限，确保足以识别错误分类。
    private static func clip(_ text: String) -> String {
        let limit = 600
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "…"
    }

    // MARK: - 一次性

    /// 发送单次请求并统一收口 HTTP 状态：规范化取消异常，非 2xx 附带原始响应。
    /// 供单次补全、连通性探测及模型列表查询复用，统一状态码判定逻辑。
    private func send(_ urlRequest: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await LLMHTTPTransport.performData(urlRequest, session: session)
    }

    /// `/chat/completions` 的非流式响应。返回解码结果和原文，正文/思考的判断留给调用方。
    private func completionPayload(_ request: LLMRequest) async throws -> (CompletionResponse, String) {
        var req = request
        req.stream = false
        let usesPrefixBeta = provider.isDeepSeek && req.messages.last?.isPrefix == true
        let urlRequest = try makeRequest(
            path: "/chat/completions",
            body: req.jsonBody(
                isDeepSeek: provider.isDeepSeek,
                kind: provider.kind,
                providerLevel: provider.effectiveThinkingLevel,
                offStyle: provider.effectiveReasoningOffStyle
            ),
            useDeepSeekBeta: usesPrefixBeta
        )
        let data: Data
        do {
            (data, _) = try await send(urlRequest)
        } catch let LLMError.http(status, body) where !(req.tools?.isEmpty ?? true)
            && Self.isUnsupportedTools(status: status, body: body) {
            req.tools = nil
            req.toolChoiceName = nil
            req.parallelToolCalls = nil
            let retryRequest = try makeRequest(
                path: "/chat/completions",
                body: req.jsonBody(
                    isDeepSeek: provider.isDeepSeek,
                    kind: provider.kind,
                    providerLevel: provider.effectiveThinkingLevel,
                    offStyle: provider.effectiveReasoningOffStyle
                ),
                useDeepSeekBeta: usesPrefixBeta
            )
            (data, _) = try await send(retryRequest)
        } catch let LLMError.http(status, body) where Self.isUnsupportedPrefill(status: status, body: body) {
            guard let stripped = Self.strippingTrailingPrefill(from: req.messages) else {
                throw LLMError.http(status: status, body: body)
            }
            req.messages = stripped
            let retryRequest = try makeRequest(
                path: "/chat/completions",
                body: req.jsonBody(
                    isDeepSeek: provider.isDeepSeek,
                    kind: provider.kind,
                    providerLevel: provider.effectiveThinkingLevel,
                    offStyle: provider.effectiveReasoningOffStyle
                )
            )
            (data, _) = try await send(retryRequest)
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let decoded = try? JSONDecoder().decode(CompletionResponse.self, from: data) else {
            throw LLMError.emptyResponse(detail: Self.clip(raw))
        }
        if let streamError = decoded.error {
            throw LLMError.streamError(detail: streamError.detail)
        }
        return (decoded, raw)
    }

    func complete(_ request: LLMRequest) async throws -> String {
        let (decoded, raw) = try await completionPayload(request)
        let choice = decoded.choices?.first
        if request.failOnLength,
           choice?.finish_reason?.lowercased() == "length" {
            throw LLMError.truncated(detail: "finish_reason=length")
        }
        let message = choice?.message
        let rawText = message?.content ?? message?.text ?? message?.output_text ?? ""
        let split = ThinkTagStreamSplitter.stripThinkTags(
            from: rawText,
            startsInsideThink: ThinkTagStreamSplitter.startsInsideThink(for: request.messages)
        )
        let text = split.prose
        if text.isEmpty {
            // 推理型模型可能仅返回 reasoning_content 或未闭合的 <think>。
            let reasoning = message?.reasoning_content
                ?? message?.reasoning
                ?? message?.analysis
                ?? message?.thinking
                ?? message?.thought
                ?? split.reasoning
            if !reasoning.isEmpty {
                throw LLMError.emptyResponse(
                    detail: "仅返回思考内容（\(reasoning.count) 字），正文为空；通常由 thinking / max_tokens 配置所致。"
                )
            }
            throw LLMError.emptyResponse(detail: Self.clip(raw))
        }
        return text
    }

    func completeToolCall(_ request: LLMRequest) async throws -> [LLMToolCall] {
        let decoded: CompletionResponse
        do {
            (decoded, _) = try await completionPayload(request)
        } catch let LLMError.http(status, body) where Self.shouldRetryToolCallWithThinkingDisabled(
            status: status,
            body: body,
            alreadyDisabled: request.forceThinkingDisabledLiteral
        ) {
            var retry = request
            retry.omitThinking = false
            retry.forceThinkingDisabledLiteral = true
            retry.attemptId = (request.attemptId ?? UUID().uuidString) + "-thinking-disabled"
            (decoded, _) = try await completionPayload(retry)
        }

        let choice = decoded.choices?.first
        if request.failOnLength,
           choice?.finish_reason?.lowercased() == "length" {
            throw LLMError.truncated(detail: "finish_reason=length")
        }
        let calls = (choice?.message?.tool_calls ?? []).compactMap { call -> LLMToolCall? in
            guard let fn = call.function,
                  let name = fn.name, !name.isEmpty,
                  let args = fn.arguments else {
                return nil
            }
            return LLMToolCall(
                id: call.id ?? "",
                functionName: name,
                arguments: args
            )
        }
        guard !calls.isEmpty else {
            throw LLMError.decoding("模型未返回人物卡工具结果")
        }
        return calls
    }

    private static func shouldRetryToolCallWithThinkingDisabled(
        status: Int,
        body: String,
        alreadyDisabled: Bool
    ) -> Bool {
        guard !alreadyDisabled, status == 400 else { return false }
        let lower = body.lowercased()
        guard lower.contains("thinking mode") else { return false }
        return lower.range(of: #"tool[_\s-]?choice"#, options: .regularExpression) != nil
    }

    // MARK: - 模型列表

    func listModels() async throws -> [String] {
        let (data, _) = try await send(try makeRequest(path: "/models", body: nil))
        guard let decoded = try? JSONDecoder().decode(ModelListResponse.self, from: data) else {
            throw LLMError.decoding("模型列表结构不符合预期")
        }
        var seen = Set<String>()
        return (decoded.data ?? [])
            .map(\.id)
            .filter { seen.insert($0).inserted }
            .sorted()
    }

    // MARK: - 连通性

    func testConnection() async throws {
        // 探测请求仅验证服务地址、API Key 及模型有效性。分配充足的 max_tokens，避免推理型模型仅输出 reasoning。
        let probe = LLMRequest(
            model: provider.resolvedModel,
            messages: [.user("你好")],
            stream: false,
            temperature: 0.2,
            maxTokens: 64
        )
        _ = try await probeOnly(probe)
    }

    /// HTTP 200 且能解成 completion 即连通；只有 reasoning_content 也算正常。
    private func probeOnly(_ request: LLMRequest) async throws -> String {
        let (decoded, raw) = try await completionPayload(request)
        guard let choice = decoded.choices?.first else {
            throw LLMError.emptyResponse(detail: Self.clip(raw))
        }
        // 包含正文内容或思考过程之一，即表明该请求链路联通正常。
        let message = choice.message
        let text = message?.content
            ?? message?.text
            ?? message?.output_text
            ?? ""
        if !text.isEmpty { return text }
        let reasoning = message?.reasoning_content
            ?? message?.reasoning
            ?? message?.analysis
            ?? message?.thinking
            ?? message?.thought
            ?? ""
        if !reasoning.isEmpty { return reasoning }
        throw LLMError.emptyResponse(detail: Self.clip(raw))
    }

    // MARK: - 辅助

    /// 出错时把响应体读出来，方便把服务端的原文带给用户。
    static func drain(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var buffer = ""
        for try await line in bytes.lines {
            buffer += line
            if buffer.count > 4000 { break }
        }
        return buffer
    }

    /// 自检用：从一行 SSE JSON 里取错误详情，验证错误块不会被静默丢掉。
    static func streamErrorDetail(from data: Data) -> String? {
        (try? JSONDecoder().decode(StreamChunk.self, from: data))?.error?.detail
    }

    // MARK: - 线格式

    private struct StreamChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable {
                struct ToolCallDelta: Decodable {
                    struct FunctionDelta: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let index: Int?
                    let id: String?
                    let function: FunctionDelta?
                }

                let content: String?
                let text: String?
                let output_text: String?
                let reasoning_content: String?
                let reasoning: String?
                let analysis: String?
                let thinking: String?
                let thought: String?
                let stop_reason: String?
                let tool_calls: [ToolCallDelta]?

                var contentText: String? {
                    content ?? text ?? output_text
                }

                var reasoningText: String? {
                    [reasoning_content, reasoning, analysis, thinking, thought]
                        .compactMap { $0 }
                        .first
                }
            }
            let delta: Delta?
            let finish_reason: String?
        }
        let choices: [Choice]?
        let content: String?
        let text: String?
        let reasoning_content: String?
        let reasoning: String?
        let analysis: String?
        let thinking: String?
        let thought: String?
        let stop_reason: String?
        let error: StreamError?

        var contentText: String? {
            content ?? text
        }

        var reasoningText: String? {
            [reasoning_content, reasoning, analysis, thinking, thought]
                .compactMap { $0 }
                .first
        }
    }

    /// 200 响应里也可能以 `{"error":{...}}` 返回限流、过滤等错误。
    private struct StreamError: Decodable {
        let message: String?
        let type: String?

        var detail: String {
            let text = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty {
                if let type, !type.isEmpty { return "\(type)：\(text)" }
                return text
            }
            return type ?? "服务端返回了错误"
        }
    }

    private struct CompletionResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                struct ToolCall: Decodable {
                    struct Function: Decodable {
                        let name: String?
                        let arguments: String?
                    }
                    let id: String?
                    let function: Function?
                }
                let content: String?
                let text: String?
                let output_text: String?
                let tool_calls: [ToolCall]?
                /// 思考型模型把推理过程放这里，`content` 可能为空。
                let reasoning_content: String?
                let reasoning: String?
                let analysis: String?
                let thinking: String?
                let thought: String?
            }
            let message: Message?
            let finish_reason: String?
        }
        let choices: [Choice]?
        let error: StreamError?
    }

    private struct ModelListResponse: Decodable {
        struct Model: Decodable { let id: String }
        let data: [Model]?
    }
}
