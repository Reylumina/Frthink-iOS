import Foundation

/// Google Gemini 原生 REST 客户端。
///
/// 端点：`{base}/v1beta/models/{model}:streamGenerateContent?alt=sse`、
/// `{base}/v1beta/models/{model}:generateContent`、`{base}/v1beta/models`。
/// 鉴权：`x-goog-api-key: <key>`。
final class GeminiClient: LLMClient {
    private final class ExplicitCacheRegistry: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (name: String, expiresAt: Date)] = [:]

        func get(key: String) -> String? {
            lock.lock()
            defer { lock.unlock() }
            guard let item = entries[key] else { return nil }
            guard item.expiresAt > Date().addingTimeInterval(60) else {
                entries.removeValue(forKey: key)
                return nil
            }
            return item.name
        }

        func set(key: String, name: String, ttlSeconds: TimeInterval = 840) {
            lock.lock()
            entries[key] = (name: name, expiresAt: Date().addingTimeInterval(ttlSeconds))
            lock.unlock()
        }

        func remove(key: String) {
            lock.lock()
            entries.removeValue(forKey: key)
            lock.unlock()
        }
    }

    private static let cacheRegistry = ExplicitCacheRegistry()
    private static let explicitCacheMinTokens = 4_096

    private let baseURL: String
    private let apiKey: String
    private let provider: ProviderSetting
    private let onUsage: (@Sendable (Int) -> Void)?

    private var session: URLSession { OpenAICompatibleClient.sharedSession }

    init(
        baseURL: String,
        apiKey: String,
        provider: ProviderSetting,
        onUsage: (@Sendable (Int) -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.provider = provider
        self.onUsage = onUsage
    }

    // MARK: - URL

    static func normalizedBaseURL(_ raw: String) -> String {
        var b = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if b.lowercased().hasSuffix("/v1beta") {
            b = String(b.dropLast("/v1beta".count))
        }
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    private func endpoint(_ v1betaSubpath: String) throws -> URL {
        let base = Self.normalizedBaseURL(baseURL)
        guard let url = URL(string: base + "/v1beta" + v1betaSubpath) else {
            throw LLMError.badURL(base + "/v1beta" + v1betaSubpath)
        }
        return url
    }

    private func makeRequest(
        v1betaSubpath: String,
        body: Data?,
        accept: String = "application/json",
        attemptId: String? = nil
    ) throws -> URLRequest {
        var request = URLRequest(url: try endpoint(v1betaSubpath))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if let attemptId, !attemptId.trimmingCharacters(in: .whitespaces).isEmpty {
            request.setValue(attemptId, forHTTPHeaderField: "Idempotency-Key")
        }
        request.httpBody = body
        return request
    }

    // MARK: - 请求体组装与显式缓存

    private static func systemPromptText(for request: LLMRequest) -> String {
        request.messages
            .filter { $0.role == "system" }
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")
    }

    private static func toolDeclarations(for request: LLMRequest) -> [[String: Any]] {
        (request.tools ?? []).compactMap { tool in
            guard let data = tool.parametersJSON.data(using: .utf8),
                  let params = try? JSONSerialization.jsonObject(with: data) else {
                return nil
            }
            return [
                "name": tool.name,
                "description": tool.description,
                "parameters": params,
            ]
        }
    }

    static func requestBody(
        for request: LLMRequest,
        providerLevel: ThinkingLevel,
        cachedContentName: String? = nil
    ) -> Data {
        let systemText = systemPromptText(for: request)
        let declarations = toolDeclarations(for: request)

        var contents: [[String: Any]] = []
        var toolNamesByCallID: [String: String] = [:]
        for msg in request.messages where msg.role != "system" {
            let role: String
            let messageParts: [[String: Any]]

            if msg.role == "tool" {
                role = "user"
                let functionName = msg.toolCallID.flatMap { toolNamesByCallID[$0] } ?? "tool"
                messageParts = [[
                    "functionResponse": [
                        "name": functionName,
                        "response": ["result": msg.content],
                    ],
                ]]
            } else if msg.role == "assistant", let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                role = "model"
                var builtParts: [[String: Any]] = []
                if !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    builtParts.append(["text": msg.content])
                }
                for call in toolCalls {
                    toolNamesByCallID[call.id] = call.functionName
                    let argsObject: Any
                    if let data = call.arguments.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: data) {
                        argsObject = obj
                    } else {
                        argsObject = [String: Any]()
                    }
                    builtParts.append([
                        "functionCall": [
                            "name": call.functionName,
                            "args": argsObject,
                        ],
                    ])
                }
                messageParts = builtParts
            } else {
                role = msg.role == "assistant" ? "model" : "user"
                messageParts = [["text": msg.content]]
            }

            if let lastRole = contents.last?["role"] as? String, lastRole == role,
               var existingParts = contents.last?["parts"] as? [[String: Any]] {
                if messageParts.count == 1,
                   let incomingText = messageParts[0]["text"] as? String,
                   let prevText = existingParts.last?["text"] as? String {
                    existingParts[existingParts.count - 1]["text"] = prevText + "\n\n" + incomingText
                } else {
                    existingParts.append(contentsOf: messageParts)
                }
                contents[contents.count - 1]["parts"] = existingParts
            } else {
                contents.append([
                    "role": role,
                    "parts": messageParts,
                ])
            }
        }
        if contents.isEmpty {
            contents.append([
                "role": "user",
                "parts": [["text": " "]],
            ])
        }

        var generationConfig: [String: Any] = [
            "temperature": min(max(request.temperature, 0.0), 2.0),
            "maxOutputTokens": max(1, request.maxTokens),
        ]

        let forcesTool = !(request.tools?.isEmpty ?? true)
            && !(request.toolChoiceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let level = forcesTool ? .off : effectiveThinkingLevel(request: request, providerLevel: providerLevel)
        if level != .off {
            let geminiLevel: String = (level == .low) ? "LOW" : "HIGH"
            generationConfig["thinkingConfig"] = [
                "includeThoughts": true,
                "thinkingLevel": geminiLevel,
            ]
        }

        var body: [String: Any] = [
            "contents": contents,
            "generationConfig": generationConfig,
        ]
        if let cachedContentName, !cachedContentName.isEmpty {
            // Gemini REST 规范：使用显式 cachedContent 时，不可重复发送已固化的 systemInstruction 与 tools。
            body["cachedContent"] = cachedContentName
        } else {
            if !systemText.isEmpty {
                body["systemInstruction"] = [
                    "parts": [["text": systemText]],
                ]
            }
            if !declarations.isEmpty {
                body["tools"] = [["functionDeclarations": declarations]]
                if let toolName = request.toolChoiceName, !toolName.isEmpty {
                    body["toolConfig"] = [
                        "functionCallingConfig": [
                            "mode": "ANY",
                            "allowedFunctionNames": [toolName],
                        ],
                    ]
                }
            }
        }

        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    private struct CachedContentResponse: Decodable {
        let name: String?
    }

    private func resolveExplicitCacheName(for request: LLMRequest) async -> (key: String, name: String)? {
        guard request.toolChoiceName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else {
            return nil
        }
        let systemText = Self.systemPromptText(for: request)
        guard !systemText.isEmpty else { return nil }
        let declarations = Self.toolDeclarations(for: request)
        let toolsJSON: String
        if !declarations.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: declarations, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            toolsJSON = str
        } else {
            toolsJSON = ""
        }
        let estimatedStaticTokens = TokenEstimator.estimate(systemText)
            + (toolsJSON.isEmpty ? 0 : TokenEstimator.estimate(toolsJSON))
        guard estimatedStaticTokens >= Self.explicitCacheMinTokens else {
            return nil
        }

        let normalizedBase = Self.normalizedBaseURL(baseURL)
        let cacheKey = SummaryKey.sha256Hex("\(normalizedBase)|\(request.model)|\(systemText)|\(toolsJSON)")
        if let existing = Self.cacheRegistry.get(key: cacheKey) {
            return (cacheKey, existing)
        }

        var createBody: [String: Any] = [
            "model": "models/\(request.model)",
            "ttl": "900s",
            "systemInstruction": [
                "parts": [["text": systemText]],
            ],
        ]
        if !declarations.isEmpty {
            createBody["tools"] = [["functionDeclarations": declarations]]
        }
        guard let payload = try? JSONSerialization.data(withJSONObject: createBody),
              let urlRequest = try? makeRequest(v1betaSubpath: "/cachedContents", body: payload),
              let data = try? await performData(urlRequest),
              let created = try? JSONDecoder().decode(CachedContentResponse.self, from: data),
              let name = created.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else {
            return nil
        }

        Self.cacheRegistry.set(key: cacheKey, name: name)
        return (cacheKey, name)
    }

    private static func effectiveThinkingLevel(
        request: LLMRequest,
        providerLevel: ThinkingLevel
    ) -> ThinkingLevel {
        if request.omitThinking || request.forceThinkingDisabledLiteral {
            return .off
        }
        switch request.thinking {
        case false:
            return .off
        case true:
            return providerLevel.rank >= ThinkingLevel.high.rank ? providerLevel : .high
        case nil:
            return providerLevel
        }
    }

    // MARK: - 流式

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await runStream(request, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        _ request: LLMRequest,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async {
        await LLMHTTPTransport.runStream(continuation: continuation) {
            var req = request
            req.stream = true
            let encodedModel = req.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? req.model
            let explicitCache = await resolveExplicitCacheName(for: req)
            do {
                let urlRequest = try makeRequest(
                    v1betaSubpath: "/models/\(encodedModel):streamGenerateContent?alt=sse",
                    body: Self.requestBody(
                        for: req,
                        providerLevel: provider.effectiveThinkingLevel,
                        cachedContentName: explicitCache?.name
                    ),
                    accept: "text/event-stream",
                    attemptId: req.attemptId
                )
                let bytes = try await LLMHTTPTransport.openBytes(urlRequest, session: session)
                try await consumeStream(bytes, request: req, continuation: continuation)
            } catch let error as LLMError {
                if let explicitCache,
                   case .http(let status, _) = error,
                   status == 400 || status == 404 {
                    Self.cacheRegistry.remove(key: explicitCache.key)
                    let fallbackRequest = try makeRequest(
                        v1betaSubpath: "/models/\(encodedModel):streamGenerateContent?alt=sse",
                        body: Self.requestBody(
                            for: req,
                            providerLevel: provider.effectiveThinkingLevel
                        ),
                        accept: "text/event-stream",
                        attemptId: req.attemptId
                    )
                    let bytes = try await LLMHTTPTransport.openBytes(fallbackRequest, session: session)
                    try await consumeStream(bytes, request: req, continuation: continuation)
                } else {
                    throw error
                }
            }
        }
    }

    private func consumeStream(
        _ bytes: URLSession.AsyncBytes,
        request: LLMRequest,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        var finishReason: String?
        var emittedAnything = false
        var undecodableLines = 0
        var reportedPromptTokens = 0
        var reportedCachedTokens = 0
        var reportedCompletionTokens = 0
        var reportedTotalTokens = 0
        var accumulatedOutput = ""
        var accumulatedReasoning = ""
        var rawLog: [String] = []
        let decoder = JSONDecoder()
        var splitter = ThinkTagStreamSplitter(startsInsideThink: false)
        var collectedToolCalls: [LLMToolCall] = []
        defer {
            if reportedPromptTokens > 0 || reportedCachedTokens > 0 {
                LLMTokenUsage.recordCacheObservation(
                    provider: provider.kind.rawValue,
                    promptTokens: reportedPromptTokens,
                    cachedTokens: reportedCachedTokens
                )
            }
            let tokens = LLMTokenUsage.resolveTotal(
                reportedPrompt: reportedPromptTokens,
                reportedCompletion: reportedCompletionTokens,
                reportedTotal: reportedTotalTokens,
                request: request,
                outputText: accumulatedOutput,
                reasoningText: accumulatedReasoning,
                toolCalls: collectedToolCalls,
                emittedAnything: emittedAnything
                    || reportedTotalTokens > 0
                    || reportedPromptTokens > 0
                    || reportedCompletionTokens > 0
            )
            if tokens > 0 {
                onUsage?(tokens)
            }
        }

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
                  let chunk = autoreleasepool(invoking: { try? decoder.decode(GenerateResponse.self, from: data) }) else {
                undecodableLines += 1
                continue
            }

            if let error = chunk.error {
                throw LLMError.streamError(detail: error.detail)
            }
            if let usage = chunk.usageMetadata {
                if let p = usage.promptTokenCount, p > 0 {
                    reportedPromptTokens = p
                }
                if let ct = usage.cachedContentTokenCount, ct > 0 {
                    reportedCachedTokens = max(reportedCachedTokens, ct)
                }
                let c = (usage.candidatesTokenCount ?? 0) + (usage.thoughtsTokenCount ?? 0)
                if c > 0 {
                    reportedCompletionTokens = c
                }
                if let t = usage.totalTokenCount, t > 0 {
                    reportedTotalTokens = t
                }
            }
            if let candidate = chunk.candidates?.first {
                if let rawReason = candidate.finishReason, !rawReason.isEmpty {
                    finishReason = rawReason == "MAX_TOKENS" ? "length" : rawReason.lowercased()
                }
                for part in candidate.content?.parts ?? [] {
                    if let fc = part.functionCall {
                        let argsData = (try? JSONSerialization.data(withJSONObject: fc.argsObject ?? [:])) ?? Data()
                        let args = String(data: argsData, encoding: .utf8) ?? "{}"
                        collectedToolCalls.append(
                            LLMToolCall(
                                id: UUID().uuidString,
                                functionName: fc.name,
                                arguments: args
                            )
                        )
                        emittedAnything = true
                    }
                    guard let text = part.text, !text.isEmpty else { continue }
                    emittedAnything = true
                    if part.thought == true {
                        accumulatedReasoning += text
                        continuation.yield(.reasoning(text))
                    } else {
                        for event in splitter.push(text) {
                            switch event {
                            case .delta(let delta):
                                accumulatedOutput += delta
                            case .reasoning(let delta):
                                accumulatedReasoning += delta
                            case .toolCalls, .finished:
                                break
                            }
                            continuation.yield(event)
                        }
                    }
                }
            }
        }

        for event in splitter.finish() {
            emittedAnything = true
            switch event {
            case .delta(let delta):
                accumulatedOutput += delta
            case .reasoning(let delta):
                accumulatedReasoning += delta
            case .toolCalls, .finished:
                break
            }
            continuation.yield(event)
        }

        if !collectedToolCalls.isEmpty {
            emittedAnything = true
            continuation.yield(.toolCalls(collectedToolCalls))
        }

        if emittedAnything, undecodableLines > 0, finishReason == nil {
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

    // MARK: - 非流式

    func complete(_ request: LLMRequest) async throws -> String {
        let response = try await sendGenerateContent(request)
        if request.failOnLength, response.candidates?.first?.finishReason == "MAX_TOKENS" {
            throw LLMError.truncated(detail: "finish_reason=MAX_TOKENS")
        }
        let parts = response.candidates?.first?.content?.parts ?? []
        let thoughtText = parts.filter { $0.thought == true }.compactMap(\.text).joined()
        let rawText = parts.filter { $0.thought != true }.compactMap(\.text).joined()
        let split = ThinkTagStreamSplitter.stripThinkTags(from: rawText, startsInsideThink: false)
        let text = split.prose
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let reasoning = thoughtText + split.reasoning
            if !reasoning.isEmpty {
                throw LLMError.emptyResponse(detail: "仅返回思考内容（\(reasoning.count) 字），正文为空。")
            }
            throw LLMError.emptyResponse(detail: "Gemini 未返回任何文本块")
        }
        return text
    }

    func completeToolCall(_ request: LLMRequest) async throws -> [LLMToolCall] {
        let response = try await sendGenerateContent(request)
        let parts = response.candidates?.first?.content?.parts ?? []
        let calls: [LLMToolCall] = parts.compactMap { part in
            guard let fc = part.functionCall else { return nil }
            let argsData = (try? JSONSerialization.data(withJSONObject: fc.argsObject ?? [:])) ?? Data()
            let args = String(data: argsData, encoding: .utf8) ?? "{}"
            return LLMToolCall(
                id: UUID().uuidString,
                functionName: fc.name,
                arguments: args
            )
        }
        if calls.isEmpty {
            throw LLMError.emptyResponse(detail: "Gemini 未返回 functionCall 块")
        }
        return calls
    }

    private func sendGenerateContent(_ request: LLMRequest) async throws -> GenerateResponse {
        var req = request
        req.stream = false
        let encodedModel = req.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? req.model
        let explicitCache = await resolveExplicitCacheName(for: req)
        let data: Data
        do {
            let urlRequest = try makeRequest(
                v1betaSubpath: "/models/\(encodedModel):generateContent",
                body: Self.requestBody(
                    for: req,
                    providerLevel: provider.effectiveThinkingLevel,
                    cachedContentName: explicitCache?.name
                )
            )
            data = try await performData(urlRequest)
        } catch let error as LLMError {
            if let explicitCache,
               case .http(let status, _) = error,
               status == 400 || status == 404 {
                Self.cacheRegistry.remove(key: explicitCache.key)
                let fallbackRequest = try makeRequest(
                    v1betaSubpath: "/models/\(encodedModel):generateContent",
                    body: Self.requestBody(for: req, providerLevel: provider.effectiveThinkingLevel)
                )
                data = try await performData(fallbackRequest)
            } else {
                throw error
            }
        }
        let decoded: GenerateResponse
        do {
            decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        } catch {
            throw LLMError.decoding(error.localizedDescription)
        }
        if let error = decoded.error {
            throw LLMError.streamError(detail: error.detail)
        }
        let u = decoded.usageMetadata
        let promptTokens = u?.promptTokenCount ?? 0
        let completionTokens = (u?.candidatesTokenCount ?? 0) + (u?.thoughtsTokenCount ?? 0)
        let totalTokens = u?.totalTokenCount ?? 0
        let parts = decoded.candidates?.first?.content?.parts ?? []
        let outputText = parts.filter { $0.thought != true }.compactMap(\.text).joined()
        let reasoningText = parts.filter { $0.thought == true }.compactMap(\.text).joined()
        let toolCalls: [LLMToolCall] = parts.compactMap { part in
            guard let fc = part.functionCall else { return nil }
            let argsData = (try? JSONSerialization.data(withJSONObject: fc.argsObject ?? [:])) ?? Data()
            let args = String(data: argsData, encoding: .utf8) ?? "{}"
            return LLMToolCall(id: "", functionName: fc.name, arguments: args)
        }
        let hasPayload = !outputText.isEmpty
            || !reasoningText.isEmpty
            || !toolCalls.isEmpty
            || totalTokens > 0
            || promptTokens > 0
            || completionTokens > 0
        let tokens = LLMTokenUsage.resolveTotal(
            reportedPrompt: promptTokens,
            reportedCompletion: completionTokens,
            reportedTotal: totalTokens,
            request: req,
            outputText: outputText,
            reasoningText: reasoningText,
            toolCalls: toolCalls,
            emittedAnything: hasPayload
        )
        if promptTokens > 0 {
            LLMTokenUsage.recordCacheObservation(
                provider: provider.kind.rawValue,
                promptTokens: promptTokens,
                cachedTokens: u?.cachedContentTokenCount ?? 0
            )
        }
        if tokens > 0 {
            onUsage?(tokens)
        }
        return decoded
    }

    // MARK: - 模型列表与连通性测试

    func listModels() async throws -> [String] {
        let urlRequest = try makeRequest(v1betaSubpath: "/models", body: nil)
        let data = try await performData(urlRequest)
        let decoded: ModelListResponse
        do {
            decoded = try JSONDecoder().decode(ModelListResponse.self, from: data)
        } catch {
            throw LLMError.decoding(error.localizedDescription)
        }
        let ids = (decoded.models ?? []).compactMap { model -> String? in
            let raw = model.name.hasPrefix("models/")
                ? String(model.name.dropFirst("models/".count))
                : model.name
            return raw.isEmpty ? nil : raw
        }
        return Array(Set(ids)).sorted()
    }

    func testConnection() async throws {
        let model = provider.model.trimmingCharacters(in: .whitespaces).isEmpty
            ? (ModelCatalog.latest(for: .gemini) ?? "gemini-4-argon")
            : provider.model.trimmingCharacters(in: .whitespaces)
        let probe = LLMRequest(
            model: model,
            messages: [.user("ping")],
            stream: false,
            temperature: 0,
            maxTokens: 256,
            thinking: false
        )
        _ = try await sendGenerateContent(probe)
    }

    private func performData(_ urlRequest: URLRequest) async throws -> Data {
        try await LLMHTTPTransport.performData(urlRequest, session: session).0
    }

    // MARK: - 响应结构

    private struct GenerateResponse: Decodable {
        struct UsageMetadata: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let thoughtsTokenCount: Int?
            let totalTokenCount: Int?
            let cachedContentTokenCount: Int?
        }

        let candidates: [Candidate]?
        let usageMetadata: UsageMetadata?
        let error: APIError?

        struct Candidate: Decodable {
            let content: Content?
            let finishReason: String?
        }

        struct Content: Decodable {
            let parts: [Part]?
        }

        struct Part: Decodable {
            let text: String?
            let thought: Bool?
            let functionCall: FunctionCall?
        }

        struct FunctionCall: Decodable {
            let name: String
            let argsObject: [String: Any]?

            enum CodingKeys: String, CodingKey { case name, args }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                if let raw = try? c.decode([String: AnyDecodable].self, forKey: .args) {
                    argsObject = raw.mapValues(\.value)
                } else {
                    argsObject = nil
                }
            }
        }

        struct APIError: Decodable {
            let message: String?
            let status: String?
            var detail: String { message ?? status ?? "未知 Gemini 错误" }
        }
    }

    private struct ModelListResponse: Decodable {
        let models: [ModelItem]?

        struct ModelItem: Decodable {
            let name: String
        }
    }
}

private struct AnyDecodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Int.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode([AnyDecodable].self) { value = v.map(\.value) }
        else if let v = try? c.decode([String: AnyDecodable].self) { value = v.mapValues(\.value) }
        else { value = NSNull() }
    }
}
