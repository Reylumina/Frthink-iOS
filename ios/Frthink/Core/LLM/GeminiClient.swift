import Foundation

/// Google Gemini 原生 REST 客户端。
///
/// 端点：`{base}/v1beta/models/{model}:streamGenerateContent?alt=sse`、
/// `{base}/v1beta/models/{model}:generateContent`、`{base}/v1beta/models`。
/// 鉴权：`x-goog-api-key: <key>`。
final class GeminiClient: LLMClient {
    private let baseURL: String
    private let apiKey: String
    private let provider: ProviderSetting

    private var session: URLSession { OpenAICompatibleClient.sharedSession }

    init(baseURL: String, apiKey: String, provider: ProviderSetting) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.provider = provider
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

    // MARK: - 请求体组装

    static func requestBody(
        for request: LLMRequest,
        providerLevel: ThinkingLevel
    ) -> Data {
        let systemText = request.messages
            .filter { $0.role == "system" }
            .map(\.content)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n\n")

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
        if !systemText.isEmpty {
            body["systemInstruction"] = [
                "parts": [["text": systemText]],
            ]
        }

        let declarations: [[String: Any]] = (request.tools ?? []).compactMap { tool in
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

        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
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
            let urlRequest = try makeRequest(
                v1betaSubpath: "/models/\(encodedModel):streamGenerateContent?alt=sse",
                body: Self.requestBody(for: req, providerLevel: provider.effectiveThinkingLevel),
                accept: "text/event-stream",
                attemptId: req.attemptId
            )
            let bytes = try await LLMHTTPTransport.openBytes(urlRequest, session: session)
            try await consumeStream(bytes, continuation: continuation)
        }
    }

    private func consumeStream(
        _ bytes: URLSession.AsyncBytes,
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation
    ) async throws {
        var finishReason: String?
        var emittedAnything = false
        var undecodableLines = 0
        var rawLog: [String] = []
        let decoder = JSONDecoder()
        var splitter = ThinkTagStreamSplitter(startsInsideThink: false)
        var collectedToolCalls: [LLMToolCall] = []

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
                        continuation.yield(.reasoning(text))
                    } else {
                        for event in splitter.push(text) {
                            continuation.yield(event)
                        }
                    }
                }
            }
        }

        for event in splitter.finish() {
            emittedAnything = true
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
        let urlRequest = try makeRequest(
            v1betaSubpath: "/models/\(encodedModel):generateContent",
            body: Self.requestBody(for: req, providerLevel: provider.effectiveThinkingLevel)
        )
        let data = try await performData(urlRequest)
        let decoded: GenerateResponse
        do {
            decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
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
        let candidates: [Candidate]?
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
