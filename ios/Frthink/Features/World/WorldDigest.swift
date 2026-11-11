// 世界刷新用的正文切段：按 token 预算切片，尽量在换行处断开。

import Foundation

/// 把正文切成可单独送给模型的片段。
enum WorldDigest {
    /// 单段 token 上限。Android 用 min(4000, 输入预算 × 0.2)；
    /// 这里由调用方把预算传进来，4000 只是封顶。
    static let tokenChunkCap = 4_000

    /// 段间重叠，避免跨段的人名/因果被切断（Android 96 token）。
    static let overlapTokens = 96

    /// 一次点击最多处理多少段。长书不一次跑几十个请求，剩余部分下次刷新继续。
    static let maxChunksPerRun = 8

    /// 大书阈值：码点 ≥ 50 万时原版改成「整篇一次性分析」，一次只取上下文放得下的前缀。
    static let wholeTextCodePointThreshold = 500_000

    /// 是否走大书模式。原版按 `codePointCount` 比较，不是 UTF-16 长度。
    static func usesWholeTextPass(_ text: String) -> Bool {
        text.unicodeScalars.count >= wholeTextCodePointThreshold
    }

    /// 取模型上下文放得下的最长前缀（原版 `b3.d.J`）。
    ///
    /// 原版先按 1.2 的安全系数估算 token，超出预算就停；这里用同一套权重与系数。
    static func prefixChunk(of text: String, tokenBudget: Int) -> String {
        guard !text.isEmpty, tokenBudget > 0 else { return "" }
        // 估算函数会给每条内容加 6 token 固定开销，这里先扣掉，保证最终估算不超预算。
        let limit = Double(max(1, tokenBudget - 6))
        var tokens = 0.0
        var end = text.startIndex
        while end < text.endIndex {
            let character = text[end]
            let weight = character.unicodeScalars.reduce(0.0) {
                $0 + TokenEstimator.weight(of: $1)
            }
            if (tokens + weight) * 1.2 > limit { break }
            tokens += weight
            end = text.index(after: end)
        }
        return String(text[..<end])
    }

    /// 按 token 预算切段，段间保留 overlapTokens 回退。
    ///
    /// 中文按 1 字 ≈ 1 token，英文/数字按 0.28；用和预算同一套权重，
    /// 不再按“4000 字符”拍脑袋——那会让英文书超预算、古文又切太碎。
    static func chunks(
        of text: String,
        tokenBudget: Int,
        overlapTokens: Int = overlapTokens
    ) -> [String] {
        guard !text.isEmpty, tokenBudget > 0 else { return [] }

        var result: [String] = []
        var start = text.startIndex

        while start < text.endIndex {
            var cursor = start
            var tokens = 0.0
            let budget = Double(tokenBudget)
            let softLimit = budget * 0.58
            var newlineBreak: String.Index?

            while cursor < text.endIndex {
                let character = text[cursor]
                let weight = character.unicodeScalars.reduce(0.0) {
                    $0 + TokenEstimator.weight(of: $1)
                }
                if tokens + weight > budget { break }
                tokens += weight
                let after = text.index(after: cursor)
                if character == "\n", tokens >= softLimit {
                    newlineBreak = after
                }
                cursor = after
            }

            // 极端大字符也不能原地打转。
            if cursor == start {
                cursor = text.index(after: start)
            }

            var end = cursor
            if end < text.endIndex, let newlineBreak, newlineBreak > start, newlineBreak <= end {
                end = newlineBreak
            }

            result.append(String(text[start..<end]))
            if end == text.endIndex { break }

            // 从段尾回退约 96 token 作为下一段起点；能落在换行后更好。
            var back = end
            var overlap = 0.0
            while back > start {
                let previous = text.index(before: back)
                overlap += text[previous].unicodeScalars.reduce(0.0) {
                    $0 + TokenEstimator.weight(of: $1)
                }
                back = previous
                if overlap >= Double(overlapTokens) { break }
            }
            if let newline = text[back..<end].firstIndex(of: "\n") {
                back = text.index(after: newline)
            }
            start = back > start ? back : end
        }

        return result
    }

    /// 正文太长时只取末尾若干 token 做事件/文风抽取，避免一次请求过大。
    static func tail(_ text: String, tokens: Int) -> String {
        TokenEstimator.trimTail(text, toTokens: tokens)
    }
}
