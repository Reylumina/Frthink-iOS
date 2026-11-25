import Foundation

/// 流式 `<think>...</think>` 标签剥离状态机：按标签边界自动拆分为 `.reasoning` 与 `.delta`，支持标签被 SSE 分片截断。
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
            case .toolCalls, .finished:
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
