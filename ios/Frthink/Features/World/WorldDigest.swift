// 世界刷新用的正文切段：按 token 预算切片，尽量在换行处断开。

import Foundation

/// 把正文切成可单独送给模型的片段。
enum WorldDigest {
    /// 单段 token 上限：调用方传入实际预算，最大封顶 4000。
    static let tokenChunkCap = 4_000

    /// 段间重叠，避免跨段的人名/因果被切断（Android 96 token）。
    static let overlapTokens = 96

    /// 超长文本阈值：码点数 ≥ 50 万时采用前缀截取分析模式。
    static let wholeTextCodePointThreshold = 500_000

    /// 一个正文分段：文本 + 在全文里的码点范围。
    ///
    /// 包含分段序号与在全文中的码点区间，为提示词提供精确上下文定位信息。
    struct Chunk: Hashable {
        let text: String
        /// 0-based 起点。
        let startCodePoint: Int
        /// 0-based 终点，开区间。
        let endCodePoint: Int
    }

    /// 是否走大书模式（按 `codePointCount` 比较，而非 UTF-16 长度）。
    static func usesWholeTextPass(_ text: String) -> Bool {
        text.unicodeScalars.count >= wholeTextCodePointThreshold
    }

    /// 截取上下文预算允许范围内的最长前缀文本。
    ///
    /// 按 1.2 的安全系数估算 token，超出预算即停。
    static func prefixChunk(of text: String, tokenBudget: Int) -> String {
        guard !text.isEmpty, tokenBudget > 0 else { return "" }
        // 扣除单条消息的基础 token 开销，确保估算总量严格在预算限额内。
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
    /// 中文按 1 字 ≈ 1 token，英文/数字按 0.28，与预算使用同一套权重，
    /// 避免按固定字符数切分导致英文书超预算或古文过碎。
    static func chunks(
        of text: String,
        tokenBudget: Int,
        overlapTokens: Int = overlapTokens
    ) -> [Chunk] {
        guard !text.isEmpty, tokenBudget > 0 else { return [] }

        var result: [Chunk] = []
        var start = text.startIndex
        var startCodePoint = 0

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

            // 保障游标每次至少推进一个字符，防止死循环。
            if cursor == start {
                cursor = text.index(after: start)
            }

            var end = cursor
            if end < text.endIndex, let newlineBreak, newlineBreak > start, newlineBreak <= end {
                end = newlineBreak
            }

            let chunkText = String(text[start..<end])
            let endCodePoint = startCodePoint + chunkText.unicodeScalars.count
            result.append(Chunk(
                text: chunkText,
                startCodePoint: startCodePoint,
                endCodePoint: endCodePoint
            ))
            if end == text.endIndex { break }

            // 从段尾回退预设重叠 token 数作为下一分段起点，优先对齐换行符。
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
            if back > start {
                startCodePoint = endCodePoint
                    - String(text[back..<end]).unicodeScalars.count
                start = back
            } else {
                startCodePoint = endCodePoint
                start = end
            }
        }

        return result
    }

    /// 截取正文尾部指定 token 量的文本用于增量抽取，控制请求上下文体量。
    static func tail(_ text: String, tokens: Int) -> String {
        TokenEstimator.trimTail(text, toTokens: tokens)
    }
}
