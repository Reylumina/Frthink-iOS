// LLM 客户端共用的 HTTP/SSE 传输层：统一状态码校验、取消异常归一化与流式错误体读取。

import Foundation

enum LLMHTTPTransport {

    /// 执行单次 HTTP 请求并校验 2xx 状态码，将 URLSession/Task 取消统一映射为 `LLMError.cancelled`。
    static func performData(
        _ urlRequest: URLRequest,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            if error.isLLMCancellation { throw LLMError.cancelled }
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("未获取到 HTTP 状态码")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return (data, http)
    }

    /// 打开 SSE 字节流并校验 2xx 状态码；非 2xx 时排空错误响应体并抛出 `LLMError.http`。
    static func openBytes(
        _ urlRequest: URLRequest,
        session: URLSession
    ) async throws -> URLSession.AsyncBytes {
        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.decoding("未获取到 HTTP 状态码")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = try await drain(bytes)
            throw LLMError.http(status: http.statusCode, body: body)
        }
        return bytes
    }

    /// 排空非 2xx 响应的错误字节流，上限 16 KB 防止异常响应占满内存。
    static func drain(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var collected = ""
        for try await line in bytes.lines {
            collected += line + "\n"
            if collected.count >= 16_384 { break }
        }
        return collected
    }

    /// 包装流式执行体，将结构化并发取消与 URLError 取消统一收口为 `LLMError.cancelled`。
    static func runStream(
        continuation: AsyncThrowingStream<LLMStreamEvent, Error>.Continuation,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
        } catch is CancellationError {
            continuation.finish(throwing: LLMError.cancelled)
        } catch let urlError as URLError where urlError.code == .cancelled {
            continuation.finish(throwing: LLMError.cancelled)
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
