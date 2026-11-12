#if DEBUG
import Foundation

/// 只在 DEBUG 与 `-mockStream` 下启用的本地 SSE 伪装。
///
/// 走真正的 `URLSession` / `OpenAICompatibleClient` 流式解析，不替换客户端，
/// 也不联网；用来在模拟器里反复验证首屏、增量排版和结束态。
final class MockStreamURLProtocol: URLProtocol {
    static let host = "mock.frthink.local"

    private var streamTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "text/event-stream"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        streamTask = Task.detached { [weak self] in
            for chunk in MockStreamPayload.chunks {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 35_000_000)
                guard let self, !Task.isCancelled else { return }
                self.send(chunk)
            }
            guard let self, !Task.isCancelled else { return }
            self.client?.urlProtocol(self, didLoad: Data("data: [DONE]\n\n".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func send(_ text: String) {
        let object: [String: Any] = [
            "choices": [
                ["delta": ["content": text]]
            ]
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }
        var data = Data("data: ".utf8)
        data.append(json)
        data.append(Data("\n\n".utf8))
        client?.urlProtocol(self, didLoad: data)
    }
}

/// 一段足够长的正文，确保测试覆盖多屏、长段落与中文标点。
enum MockStreamPayload {
    static let chunks: [String] = (1...90).map { index in
        """
        第\(index)段：林昭把梯子挪到最里侧的书架前，灰尘在手电的光柱里浮着，像静止的雪。\
        她抽出第三本的时候，有什么东西从书页间滑了出来，轻飘飘地落在脚边。\
        是一封信，信封上写着地址，邮票还在，却从来没有盖过邮戳。窗外的雨声突然变得很远，\
        整间书店像是被谁按下了静音键。
        """
    }
}
#endif
