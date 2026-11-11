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
    /// 之前每个 client（每次发送/续写/重测）都新建一条 session：连接池、TLS
    /// 会话缓存都用不上，旧 session 还持有连接。共享一条之后长连接可以复用。
    ///
    /// - `ephemeral` + `urlCache = nil`：LLM 响应不该进 URL 缓存，SSE 更不该。
    /// - `waitsForConnectivity = false`：交互式请求断网就立刻报错，不挂 3 分钟。
    private static let sharedSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // 流式响应可能几分钟没有新字节，请求超时给足；资源超时兜住挂死的情况。
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

    private func endpoint(_ path: String) throws -> URL {
        guard let url = URL(string: trimmedBase + path) else {
            throw LLMError.badURL(trimmedBase + path)
        }
        return url
    }

    private func makeRequest(
        path: String,
        body: Data?,
        accept: String = "application/json",
        attemptId: String? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        // 生成请求永不命中缓存；共享 session 里也不保留响应体。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        // OpenCode Go 用会话头保持同一对话的路由与缓存；按 host 识别，兼容并入 OpenAI 兼容的配置。
        if provider.kind == .openCodeGo
            || provider.baseURLForDisplay.lowercased().contains("opencode.ai") {
            request.setValue(openCodeSessionID, forHTTPHeaderField: "x-opencode-session")
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
                do {
                    var req = request
                    req.stream = true
                    let urlRequest = try makeRequest(
                        path: "/chat/completions",
                        body: req.jsonBody(isDeepSeek: provider.isDeepSeek, kind: provider.kind, providerLevel: provider.effectiveThinkingLevel),
                        accept: "text/event-stream",
                        attemptId: req.attemptId
                    )
                    let (bytes, response) = try await session.bytes(for: urlRequest)

                    guard let http = response as? HTTPURLResponse else {
                        throw LLMError.decoding("拿不到 HTTP 状态码")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        let body = try await Self.drain(bytes)
                        throw LLMError.http(status: http.statusCode, body: body)
                    }

                    var finishReason: String?
                    var emittedAnything = false
                    var sawDone = false
                    var undecodableLines = 0
                    // 收到的原始 SSE 行。判定「空响应」时一并带出去——
                    // 只说「空响应」没法区分是鉴权、参数还是模型名的问题。
                    var rawLog: [String] = []
                    // 一个解码器复用整条流：每个 chunk 新建 JSONDecoder 是纯浪费。
                    let chunkDecoder = JSONDecoder()

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
                        // 长时间流式循环里每行都在产生临时对象，autoreleasepool
                        // 把每块的生命周期限制在本行，避免几万行后一起释放。
                        guard let chunk = autoreleasepool(invoking: {
                            try? chunkDecoder.decode(StreamChunk.self, from: data)
                        }) else {
                            undecodableLines += 1
                            continue
                        }
                        // 200 流里也会下发错误（限流、内容过滤、上下文超限），
                        // 不能整块丢掉，否则半截正文会被当成正常结束。
                        if let streamError = chunk.error {
                            throw LLMError.streamError(detail: streamError.detail)
                        }

                        if let choice = chunk.choices?.first {
                            if finishReason == nil {
                                finishReason = choice.finish_reason
                                    ?? choice.delta?.stop_reason
                                    ?? chunk.stop_reason
                            }
                            let delta = choice.delta
                            let content = delta?.content
                                ?? delta?.text
                                ?? delta?.output_text
                                ?? chunk.content
                                ?? chunk.text
                            let reasoning = delta?.reasoning_content
                                ?? chunk.reasoning_content
                                ?? chunk.reasoning
                                ?? chunk.analysis
                                ?? chunk.thinking
                                ?? chunk.thought

                            if let reasoning, !reasoning.isEmpty {
                                emittedAnything = true
                                continuation.yield(.reasoning(reasoning))
                            }
                            if let content, !content.isEmpty {
                                emittedAnything = true
                                continuation.yield(.delta(content))
                            }
                        } else {
                            if finishReason == nil { finishReason = chunk.stop_reason }
                            if let content = chunk.content ?? chunk.text, !content.isEmpty {
                                emittedAnything = true
                                continuation.yield(.delta(content))
                            } else if let reasoning = chunk.reasoning_content
                                ?? chunk.reasoning
                                ?? chunk.analysis
                                ?? chunk.thinking
                                ?? chunk.thought,
                                !reasoning.isEmpty {
                                emittedAnything = true
                                continuation.yield(.reasoning(reasoning))
                            }
                        }
                    }

                    if emittedAnything, undecodableLines > 0,
                       finishReason == nil, !sawDone {
                        throw LLMError.streamError(
                            detail: "流里有 \(undecodableLines) 行无法解析，且没有收到结束标记；本次回复可能不完整。"
                        )
                    }

                    if !emittedAnything {
                        let detail = rawLog.joined(separator: " / ")
                        continuation.finish(
                            throwing: LLMError.emptyResponse(
                                detail: detail.isEmpty
                                    ? "（连接建立但没有收到任何 SSE 行）"
                                    : detail
                            )
                        )
                        return
                    }
                    continuation.yield(.finished(reason: finishReason))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: LLMError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// 报错里回显的原文长度上限，够看清是哪一类错误即可。
    private static func clip(_ text: String) -> String {
        let limit = 600
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "…"
    }

    // MARK: - 一次性

    func complete(_ request: LLMRequest) async throws -> String {
        var req = request
        req.stream = false
        let urlRequest = try makeRequest(
            path: "/chat/completions",
            body: req.jsonBody(isDeepSeek: provider.isDeepSeek, kind: provider.kind, providerLevel: provider.effectiveThinkingLevel)
        )
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            // URLSession 的取消是 URLError.cancelled，和结构化并发取消不是同一种；
            // 统一成 LLMError.cancelled，调用方才能把「停止」和「失败」分开。
            if error.isLLMCancellation { throw LLMError.cancelled }
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("拿不到 HTTP 状态码")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let decoded = try? JSONDecoder().decode(CompletionResponse.self, from: data) else {
            throw LLMError.emptyResponse(detail: Self.clip(raw))
        }
        if let streamError = decoded.error {
            throw LLMError.streamError(detail: streamError.detail)
        }
        let message = decoded.choices?.first?.message
        if request.failOnLength,
           decoded.choices?.first?.finish_reason?.lowercased() == "length" {
            throw LLMError.truncated(detail: "finish_reason=length")
        }
        let text = message?.content ?? message?.text ?? message?.output_text ?? ""
        if text.isEmpty {
            // 思考型模型可能只回 reasoning_content。这不是坏响应，
            // 是输出通道被参数关掉了，得说清楚。
            let reasoning = message?.reasoning_content
                ?? message?.reasoning
                ?? message?.analysis
                ?? message?.thinking
                ?? message?.thought
                ?? ""
            if !reasoning.isEmpty {
                throw LLMError.emptyResponse(
                    detail: "只返回了思考内容（\(reasoning.count) 字），正文为空；多为 thinking / max_tokens 配置所致。"
                )
            }
            throw LLMError.emptyResponse(detail: Self.clip(raw))
        }
        return text
    }

    // MARK: - 模型列表

    func listModels() async throws -> [String] {
        let request = try makeRequest(path: "/models", body: nil)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("拿不到 HTTP 状态码")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let decoded = try? JSONDecoder().decode(ModelListResponse.self, from: data) else {
            throw LLMError.decoding("模型列表结构不符合预期")
        }
        return (decoded.data ?? []).map(\.id).sorted()
    }

    // MARK: - 连通性

    func testConnection() async throws {
        // 探针只验证地址、Key、模型名。max_tokens 给足，避免思考型模型只回 reasoning。
        var probe = LLMRequest(
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
        var req = request
        req.stream = false
        let urlRequest = try makeRequest(
            path: "/chat/completions",
            body: req.jsonBody(
                isDeepSeek: provider.isDeepSeek,
                kind: provider.kind,
                providerLevel: provider.effectiveThinkingLevel
            )
        )
        let (data, response) = try await session.data(for: urlRequest)

        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("拿不到 HTTP 状态码")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard let decoded = try? JSONDecoder().decode(CompletionResponse.self, from: data),
              let choice = decoded.choices?.first
        else {
            throw LLMError.emptyResponse(detail: Self.clip(raw))
        }
        // 正文或思考，有一样就算这条链路是通的。
        let text = choice.message?.content ?? ""
        if !text.isEmpty { return text }
        let reasoning = choice.message?.reasoning_content ?? ""
        if !reasoning.isEmpty { return reasoning }
        throw LLMError.emptyResponse(detail: Self.clip(raw))
    }

    // MARK: - 辅助

    /// 出错时把响应体读出来，方便把服务端的原文带给用户。
    private static func drain(_ bytes: URLSession.AsyncBytes) async throws -> String {
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
                let content: String?
                let text: String?
                let output_text: String?
                let reasoning_content: String?
                let stop_reason: String?
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
                let content: String?
                let text: String?
                let output_text: String?
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
