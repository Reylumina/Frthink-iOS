import Foundation

/// 端侧轻量 BM25 历史正文句窗检索（纯内存计算，零外部依赖、零网络调用）。
///
/// 仅在存在「未被当前发送窗口覆盖的早期正文」时工作，用于找回长篇早期（15%–30%）
/// 确立但已滑出编辑末尾窗口的地理、时间、物件与设定细节。
enum ManuscriptIndex {

    struct Excerpt: Equatable {
        let index: Int
        let text: String
        let score: Double
    }

    /// 从完整正文中扣除已被 `activeWindowText` 覆盖的末尾部分，并遵循 `causalLimit` 截断未来剧情，检索最相关的早期句窗。
    static func recallHistoricalExcerpts(
        fullManuscript: String,
        activeWindowText: String,
        queryTerms: [String],
        instructionText: String = "",
        causalLimit: Int? = nil,
        maxResults: Int = 3,
        maxTokens: Int = 600
    ) -> [Excerpt] {
        let prefix = uncoveredHistoryPrefix(
            fullManuscript: fullManuscript,
            activeWindowText: activeWindowText,
            causalLimit: causalLimit
        )
        guard !prefix.isEmpty else { return [] }

        let windows = buildWindows(from: prefix)
        guard !windows.isEmpty else { return [] }

        let cleanedTerms = normalizedQueryTerms(terms: queryTerms, instructionText: instructionText)
        let queryTokens = tokenize(cleanedTerms.joined(separator: " "))
        guard !queryTokens.isEmpty || !cleanedTerms.isEmpty else { return [] }

        let docTokens = windows.map { tokenize($0) }
        let docCount = Double(windows.count)
        let avgLen = max(1.0, Double(docTokens.reduce(0) { $0 + $1.count }) / docCount)

        var df: [String: Int] = [:]
        for tokens in docTokens {
            for token in Set(tokens) {
                df[token, default: 0] += 1
            }
        }

        let k1 = 1.5
        let b = 0.75
        let uniqueQueryTokens = Array(Set(queryTokens))

        var scored: [Excerpt] = []
        for (idx, window) in windows.enumerated() {
            let tokens = docTokens[idx]
            guard !tokens.isEmpty else { continue }
            var tf: [String: Int] = [:]
            for t in tokens { tf[t, default: 0] += 1 }
            let docLen = Double(tokens.count)

            var score = 0.0
            for q in uniqueQueryTokens {
                guard let freq = tf[q], freq > 0 else { continue }
                let n = Double(df[q, default: 0])
                let idf = log((docCount - n + 0.5) / (n + 0.5) + 1.0)
                let f = Double(freq)
                let denom = f + k1 * (1.0 - b + b * (docLen / avgLen))
                score += idf * ((f * (k1 + 1.0)) / denom)
            }

            // 专有名词（人名/地名/关键词）字面命中加权，提高中文实体精确召回。
            for term in cleanedTerms where term.count >= 2 {
                if window.localizedCaseInsensitiveContains(term) {
                    score += 2.5
                }
            }

            if score > 0.5 {
                scored.append(Excerpt(index: idx, text: window, score: score))
            }
        }

        guard !scored.isEmpty else { return [] }
        let top = scored
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.index < $1.index
            }
            .prefix(maxResults)
            .sorted { $0.index < $1.index }

        var selected: [Excerpt] = []
        var usedTokens = 0
        for item in top {
            let cost = TokenEstimator.estimate(item.text)
            if !selected.isEmpty && usedTokens + cost > maxTokens { continue }
            usedTokens += cost
            selected.append(item)
        }
        return selected
    }

    // MARK: - 内部切分与分词

    private static func uncoveredHistoryPrefix(
        fullManuscript: String,
        activeWindowText: String,
        causalLimit: Int?
    ) -> String {
        let causalText: String
        if let limit = causalLimit, limit > 0, limit <= (fullManuscript as NSString).length {
            causalText = (fullManuscript as NSString).substring(to: limit)
        } else {
            causalText = fullManuscript
        }
        let fullCount = causalText.count
        let activeCount = activeWindowText.count
        guard fullCount > activeCount + 80 else { return "" }
        let endIndex = causalText.index(causalText.endIndex, offsetBy: -activeCount)
        return String(causalText[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buildWindows(from text: String) -> [String] {
        let paragraphs = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return [] }

        var windows: [String] = []
        var buffer = ""
        for para in paragraphs {
            if para.count > 420 {
                if !buffer.isEmpty {
                    windows.append(buffer)
                    buffer = ""
                }
                windows.append(contentsOf: splitLongParagraph(para, targetChars: 280))
                continue
            }
            if buffer.isEmpty {
                buffer = para
            } else if buffer.count + para.count + 1 <= 340 {
                buffer += "\n" + para
            } else {
                windows.append(buffer)
                buffer = para
            }
        }
        if !buffer.isEmpty {
            windows.append(buffer)
        }
        return windows
    }

    private static func splitLongParagraph(_ para: String, targetChars: Int) -> [String] {
        var result: [String] = []
        var start = para.startIndex
        while start < para.endIndex {
            let end = para.index(start, offsetBy: targetChars, limitedBy: para.endIndex) ?? para.endIndex
            let slice = String(para[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !slice.isEmpty { result.append(slice) }
            if end == para.endIndex { break }
            start = para.index(end, offsetBy: -40, limitedBy: start) ?? end
        }
        return result
    }

    private static func normalizedQueryTerms(terms: [String], instructionText: String) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        let rawList = terms + instructionText
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        for raw in rawList {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { continue }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var asciiWord = ""
        var cjkRun: [Character] = []

        func flushASCII() {
            if asciiWord.count >= 2 {
                tokens.append(asciiWord.lowercased())
            }
            asciiWord = ""
        }

        func flushCJK() {
            guard !cjkRun.isEmpty else { return }
            if cjkRun.count == 1 {
                tokens.append(String(cjkRun[0]))
            } else {
                for i in 0..<(cjkRun.count - 1) {
                    tokens.append(String([cjkRun[i], cjkRun[i + 1]]))
                }
            }
            cjkRun.removeAll(keepingCapacity: true)
        }

        for ch in text {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                flushCJK()
                asciiWord.append(ch)
            } else if isCJK(ch) {
                flushASCII()
                cjkRun.append(ch)
            } else {
                flushASCII()
                flushCJK()
            }
        }
        flushASCII()
        flushCJK()
        return tokens
    }

    private static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        return (0x4E00...0x9FFF).contains(scalar.value)
    }
}
