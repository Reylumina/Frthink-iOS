import Foundation

/// 流式文本的滑动窗口：只保留末尾一段，但不要每来一个字就整体平移。
///
/// 窗口满了之后继续追加，直到超过 `maxCharacters + trimStep` 才一次性
/// 丢掉开头一段。这样绝大多数更新仍是纯 append，`UITextView` 不用整段重排。
struct StreamingTextWindow {
    let maxCharacters: Int
    let trimStep: Int
    private(set) var baseOffset = 0

    init(maxCharacters: Int = 6_000, trimStep: Int = 2_000) {
        self.maxCharacters = max(1, maxCharacters)
        self.trimStep = max(1, trimStep)
    }

    /// 返回要渲染的文本，以及是否发生了窗口重置（调用方需要整段替换）。
    mutating func rendered(_ fullText: String) -> (text: String, reset: Bool) {
        let count = fullText.count
        if count <= maxCharacters {
            let reset = baseOffset != 0
            baseOffset = 0
            return (fullText, reset)
        }
        // 文本被替换成更短内容时，旧 baseOffset 可能已经越过新结尾。
        if count <= baseOffset {
            baseOffset = alignedOffset(in: fullText, target: count - maxCharacters)
            return ("…\n" + String(fullText.dropFirst(baseOffset)), true)
        }

        if baseOffset == 0 || count - baseOffset > maxCharacters + trimStep {
            baseOffset = alignedOffset(in: fullText, target: count - maxCharacters)
            return ("…\n" + String(fullText.dropFirst(baseOffset)), true)
        }

        let suffix = String(fullText.suffix(count - baseOffset))
        return ("…\n" + suffix, false)
    }

    private static let maxAlignmentLookahead = 500

    /// 尽量对齐到段落边界，避免把行内 `**` / `*` 截成单边标记。
    private func alignedOffset(in text: String, target: Int) -> Int {
        let clamped = max(0, min(target, text.count))
        let start = text.index(text.startIndex, offsetBy: clamped)
        if let newline = text[start...].firstIndex(of: "\n") {
            let next = text.index(after: newline)
            let offset = text.distance(from: text.startIndex, to: next)
            if offset - clamped <= Self.maxAlignmentLookahead {
                return offset
            }
        }
        return clamped
    }
}
