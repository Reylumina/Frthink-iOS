import Foundation
import NaturalLanguage

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

    struct SentenceWindow: Equatable {
        let text: String
        let utf16Start: Int
        let utf16Length: Int
    }

    struct GrepMatch: Equatable {
        let pageIndex: Int
        let lineNumber: Int
        let utf16Start: Int
        let utf16Length: Int
        let matchedText: String
        let contextSnippet: String
    }

    struct GrepSearchResult: Equatable {
        let matches: [GrepMatch]
        let totalMatchCount: Int
        let regexError: String?
    }

    /// 按页缓存分词、句窗与文档频率的增量 BM25 索引：正文尾页改动时仅重算受影响页，其余页直接命中缓存。
    struct IncrementalBM25Index {
        private struct CachedPage {
            let pageIndex: Int
            let contentHash: String
            let utf16Start: Int
            let utf16Length: Int
            let windows: [SentenceWindow]
            let windowTokens: [[String]]
            let pageDF: [String: Int]
        }

        private var cachedPages: [Int: CachedPage] = [:]

        var cachedPageCount: Int { cachedPages.count }

        /// 返回 `true` 表示该页内容或偏移发生变更并已重算；返回 `false` 表示命中缓存跳过重分词。
        @discardableResult
        mutating func updatePage(index: Int, text: String, utf16Start: Int) -> Bool {
            let hash = SummaryKey.sha256Hex(text)
            if let existing = cachedPages[index],
               existing.contentHash == hash,
               existing.utf16Start == utf16Start {
                return false
            }

            let rawWindows = ManuscriptIndex.buildSentenceWindows(from: text)
            let windows = rawWindows.map {
                SentenceWindow(text: $0.text, utf16Start: $0.utf16Start, utf16Length: $0.utf16Length)
            }
            let windowTokens = windows.map { ManuscriptIndex.tokenize($0.text) }
            var pageDF: [String: Int] = [:]
            for tokens in windowTokens {
                for token in Set(tokens) {
                    pageDF[token, default: 0] += 1
                }
            }

            cachedPages[index] = CachedPage(
                pageIndex: index,
                contentHash: hash,
                utf16Start: utf16Start,
                utf16Length: (text as NSString).length,
                windows: windows,
                windowTokens: windowTokens,
                pageDF: pageDF
            )
            return true
        }

        mutating func removePages(from startIndex: Int) {
            for key in cachedPages.keys where key >= startIndex {
                cachedPages.removeValue(forKey: key)
            }
        }

        func recall(
            queryTerms: [String],
            instructionText: String = "",
            causalLimit: Int? = nil,
            minUTF16Offset: Int = 0,
            excludeTrailingUTF16: Int = 0,
            maxResults: Int = 3,
            maxTokens: Int = 600
        ) -> [Excerpt] {
            guard !cachedPages.isEmpty else { return [] }
            let sortedPages = cachedPages.keys.sorted().compactMap { cachedPages[$0] }
            let maxIndexedEnd = sortedPages.map { $0.utf16Start + $0.utf16Length }.max() ?? 0
            let upperBound = causalLimit.map { min($0, maxIndexedEnd) } ?? maxIndexedEnd
            let effectiveLimit: Int?
            if excludeTrailingUTF16 > 0 {
                effectiveLimit = max(0, upperBound - excludeTrailingUTF16)
            } else {
                effectiveLimit = causalLimit
            }

            let cleanedTerms = ManuscriptIndex.normalizedQueryTerms(
                terms: queryTerms,
                instructionText: instructionText
            )
            let queryTokens = ManuscriptIndex.tokenize(cleanedTerms.joined(separator: " "))
            guard !queryTokens.isEmpty || !cleanedTerms.isEmpty else { return [] }
            let uniqueQueryTokens = Array(Set(queryTokens))

            var candidates: [(globalIndex: Int, text: String, tokens: [String])] = []
            var globalDF: [String: Int] = [:]
            var totalTokenCount = 0
            var idxCounter = 0

            for page in sortedPages {
                if let limit = effectiveLimit, page.utf16Start >= limit { break }
                let pageEnd = page.utf16Start + page.utf16Length
                if minUTF16Offset > 0, pageEnd <= minUTF16Offset { continue }
                let fullPageIncluded = (effectiveLimit == nil || pageEnd <= (effectiveLimit ?? pageEnd))
                    && minUTF16Offset <= page.utf16Start

                if fullPageIncluded {
                    for (token, count) in page.pageDF {
                        globalDF[token, default: 0] += count
                    }
                    for (localIdx, window) in page.windows.enumerated() {
                        let tokens = page.windowTokens[localIdx]
                        totalTokenCount += tokens.count
                        candidates.append((globalIndex: idxCounter, text: window.text, tokens: tokens))
                        idxCounter += 1
                    }
                } else {
                    for (localIdx, window) in page.windows.enumerated() {
                        let globalWindowStart = page.utf16Start + window.utf16Start
                        let globalWindowEnd = globalWindowStart + window.utf16Length
                        if minUTF16Offset > 0, globalWindowStart < minUTF16Offset { continue }
                        if let limit = effectiveLimit, globalWindowEnd > limit { continue }
                        let tokens = page.windowTokens[localIdx]
                        totalTokenCount += tokens.count
                        for token in Set(tokens) {
                            globalDF[token, default: 0] += 1
                        }
                        candidates.append((globalIndex: idxCounter, text: window.text, tokens: tokens))
                        idxCounter += 1
                    }
                }
            }

            guard !candidates.isEmpty else { return [] }
            let docCount = Double(candidates.count)
            let avgLen = max(1.0, Double(totalTokenCount) / docCount)
            let k1 = 1.5
            let b = 0.75

            var scored: [Excerpt] = []
            for item in candidates {
                guard !item.tokens.isEmpty else { continue }
                var tf: [String: Int] = [:]
                for t in item.tokens { tf[t, default: 0] += 1 }
                let docLen = Double(item.tokens.count)

                var score = 0.0
                for q in uniqueQueryTokens {
                    guard let freq = tf[q], freq > 0 else { continue }
                    let n = Double(globalDF[q, default: 0])
                    let idf = log((docCount - n + 0.5) / (n + 0.5) + 1.0)
                    let f = Double(freq)
                    let denom = f + k1 * (1.0 - b + b * (docLen / avgLen))
                    score += idf * ((f * (k1 + 1.0)) / denom)
                }

                for term in cleanedTerms where term.count >= 2 {
                    if item.text.localizedCaseInsensitiveContains(term) {
                        score += 2.5
                    }
                }

                if score > 0.5 {
                    if candidates.count > 1 {
                        score += 0.05 * (Double(item.globalIndex) / Double(candidates.count - 1))
                    }
                    scored.append(Excerpt(index: item.globalIndex, text: item.text, score: score))
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
                if windows.count > 1 {
                    score += 0.05 * (Double(idx) / Double(windows.count - 1))
                }
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

    /// 将正文切分为重叠的 3 句滑动窗口并记录精确 UTF-16 起止范围；无句读长段回退为定长字符窗口。
    static func buildSentenceWindows(
        from text: String,
        windowSentences: Int = 3,
        stride: Int = 2
    ) -> [(text: String, utf16Start: Int, utf16Length: Int)] {
        let nsText = text as NSString
        guard nsText.length > 0 else { return [] }

        var rawSpans: [NSRange] = []
        var currentStart = 0
        var idx = 0

        func flushSpan(upTo end: Int) {
            guard end > currentStart else { return }
            let span = NSRange(location: currentStart, length: end - currentStart)
            let trimmed = nsText.substring(with: span).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                rawSpans.append(span)
            }
            currentStart = end
        }

        let terminators: Set<unichar> = [0x3002, 0xFF01, 0xFF1F, 0x0021, 0x003F] // 。！？!?
        let closingQuotes: Set<unichar> = [0x201D, 0x300D, 0x300F, 0x0022]

        while idx < nsText.length {
            let ch = nsText.character(at: idx)
            if ch == 0x000A {
                flushSpan(upTo: idx)
                currentStart = idx + 1
                idx += 1
                continue
            }
            if terminators.contains(ch) {
                var end = idx + 1
                while end < nsText.length, closingQuotes.contains(nsText.character(at: end)) {
                    end += 1
                }
                flushSpan(upTo: end)
                idx = end
                continue
            }
            idx += 1
        }
        flushSpan(upTo: nsText.length)

        // 展平过长无标点段落，避免单个窗口过大挤占上下文预算。
        var normalizedSpans: [NSRange] = []
        for span in rawSpans {
            if span.length <= 420 {
                normalizedSpans.append(span)
            } else {
                var offset = span.location
                let endLimit = span.location + span.length
                while offset < endLimit {
                    var sliceLen = min(280, endLimit - offset)
                    if offset + sliceLen < endLimit, sliceLen > 1 {
                        let ch = nsText.character(at: offset + sliceLen)
                        if ch >= 0xDC00, ch <= 0xDFFF { sliceLen -= 1 }
                    }
                    normalizedSpans.append(NSRange(location: offset, length: sliceLen))
                    if offset + sliceLen >= endLimit { break }
                    offset += max(1, sliceLen - 40)
                }
            }
        }

        guard !normalizedSpans.isEmpty else { return [] }
        let winSize = max(1, windowSentences)
        let step = max(1, stride)
        var windows: [(text: String, utf16Start: Int, utf16Length: Int)] = []

        if normalizedSpans.count <= winSize {
            let start = normalizedSpans[0].location
            let end = normalizedSpans[normalizedSpans.count - 1].location
                + normalizedSpans[normalizedSpans.count - 1].length
            let combined = NSRange(location: start, length: max(0, end - start))
            let slice = nsText.substring(with: combined).trimmingCharacters(in: .whitespacesAndNewlines)
            if !slice.isEmpty {
                windows.append((text: slice, utf16Start: combined.location, utf16Length: combined.length))
            }
            return windows
        }

        var cursor = 0
        while cursor < normalizedSpans.count {
            let endIdx = min(normalizedSpans.count - 1, cursor + winSize - 1)
            let start = normalizedSpans[cursor].location
            let end = normalizedSpans[endIdx].location + normalizedSpans[endIdx].length
            let combined = NSRange(location: start, length: max(0, end - start))
            let slice = nsText.substring(with: combined).trimmingCharacters(in: .whitespacesAndNewlines)
            if !slice.isEmpty {
                windows.append((text: slice, utf16Start: combined.location, utf16Length: combined.length))
            }
            if endIdx == normalizedSpans.count - 1 { break }
            cursor += step
        }
        return windows
    }

    /// 无索引直查分页原稿：严格在匹配与提取上下文之前按 `causalLimit` 截断，杜绝后续章节剧透泄露。
    static func grepManuscript(
        pages: [String],
        pattern: String,
        contextLines: Int = 1,
        regex: Bool = false,
        causalLimit: Int? = nil,
        maxMatches: Int = 12
    ) -> [GrepMatch] {
        grepManuscriptDetailed(
            pages: pages,
            pattern: pattern,
            contextLines: contextLines,
            regex: regex,
            causalLimit: causalLimit,
            maxMatches: maxMatches
        ).matches
    }

    /// 详细正文检索：保留全量命中计数、显式正则错误及早晚均匀分布采样结果。
    static func grepManuscriptDetailed(
        pages: [String],
        pattern: String,
        contextLines: Int = 1,
        regex: Bool = false,
        causalLimit: Int? = nil,
        maxMatches: Int = 12
    ) -> GrepSearchResult {
        let query = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, maxMatches > 0 else {
            return GrepSearchResult(matches: [], totalMatchCount: 0, regexError: nil)
        }

        let compiledRegex: NSRegularExpression?
        if regex {
            do {
                compiledRegex = try NSRegularExpression(pattern: query)
            } catch {
                return GrepSearchResult(
                    matches: [],
                    totalMatchCount: 0,
                    regexError: error.localizedDescription
                )
            }
        } else {
            compiledRegex = nil
        }

        var headMatches: [GrepMatch] = []
        var recentMatches: [GrepMatch] = []
        var totalMatchCount = 0
        var pageStartUTF16 = 0
        let safeContext = max(0, contextLines)
        let headReserve = min(3, max(1, maxMatches / 2))
        let tailReserve = max(0, maxMatches - headReserve)

        for (pageIdx, rawPage) in pages.enumerated() {
            let rawLength = (rawPage as NSString).length
            defer {
                pageStartUTF16 += rawLength
            }

            if let limit = causalLimit, pageStartUTF16 >= limit {
                break
            }

            let visiblePage: String
            if let limit = causalLimit, pageStartUTF16 + rawLength > limit {
                let cutoffLength = max(0, limit - pageStartUTF16)
                visiblePage = (rawPage as NSString).substring(to: cutoffLength)
            } else {
                visiblePage = rawPage
            }

            guard !visiblePage.isEmpty else { continue }
            let lines = splitLinesWithUTF16Offsets(visiblePage)
            for (lineArrayIdx, lineInfo) in lines.enumerated() {
                let nsLine = lineInfo.text as NSString
                var matchRange = NSRange(location: NSNotFound, length: 0)

                if let compiledRegex {
                    if let first = compiledRegex.firstMatch(
                        in: lineInfo.text,
                        range: NSRange(location: 0, length: nsLine.length)
                    ) {
                        matchRange = first.range
                    }
                } else {
                    matchRange = nsLine.range(of: query, options: [.caseInsensitive])
                }

                guard matchRange.location != NSNotFound else { continue }
                totalMatchCount += 1

                let buildMatch = { () -> GrepMatch in
                    let matchedText = nsLine.substring(with: matchRange)
                    let ctxStart = max(0, lineArrayIdx - safeContext)
                    let ctxEnd = min(lines.count - 1, lineArrayIdx + safeContext)
                    let renderedLines = (ctxStart...ctxEnd).map { idx -> String in
                        let lineText = lines[idx].text
                        if idx == lineArrayIdx {
                            return clippedLineAroundMatch(lineText, matchRange: matchRange, maxLength: 220)
                        }
                        if lineText.count > 90 {
                            return idx < lineArrayIdx
                                ? "…" + String(lineText.suffix(80))
                                : String(lineText.prefix(80)) + "…"
                        }
                        return lineText
                    }
                    let contextSnippet = renderedLines.joined(separator: "\n")
                    return GrepMatch(
                        pageIndex: pageIdx,
                        lineNumber: lineArrayIdx + 1,
                        utf16Start: pageStartUTF16 + lineInfo.utf16Start + matchRange.location,
                        utf16Length: matchRange.length,
                        matchedText: matchedText,
                        contextSnippet: contextSnippet
                    )
                }

                if headMatches.count < maxMatches {
                    headMatches.append(buildMatch())
                } else if tailReserve > 0 {
                    recentMatches.append(buildMatch())
                    if recentMatches.count > tailReserve {
                        recentMatches.removeFirst()
                    }
                }
            }
        }

        let sampledMatches: [GrepMatch]
        if totalMatchCount <= maxMatches || tailReserve == 0 {
            sampledMatches = Array(headMatches.prefix(maxMatches))
        } else {
            // headMatches 至少有 maxMatches 条，取前 headReserve 条 + 最新 tailReserve 条，保证时序不重叠。
            let fixedHead = Array(headMatches.prefix(headReserve))
            let combinedTail = Array((headMatches.dropFirst(headReserve) + recentMatches).suffix(tailReserve))
            sampledMatches = fixedHead + combinedTail
        }

        return GrepSearchResult(
            matches: sampledMatches,
            totalMatchCount: totalMatchCount,
            regexError: nil
        )
    }

    private static func clippedLineAroundMatch(
        _ line: String,
        matchRange: NSRange,
        maxLength: Int
    ) -> String {
        let nsLine = line as NSString
        guard nsLine.length > maxLength,
              matchRange.location != NSNotFound,
              matchRange.location < nsLine.length else {
            return line
        }
        let sideContext = max(20, (maxLength - matchRange.length) / 2)
        var start = max(0, matchRange.location - sideContext)
        if start > 0 && start < nsLine.length {
            let ch = nsLine.character(at: start)
            if ch >= 0xDC00 && ch <= 0xDFFF { start -= 1 }
        }
        var end = min(nsLine.length, matchRange.location + matchRange.length + sideContext)
        if end > start && end < nsLine.length {
            let ch = nsLine.character(at: end - 1)
            if ch >= 0xD800 && ch <= 0xDBFF { end -= 1 }
        }
        let slice = nsLine.substring(with: NSRange(location: start, length: max(0, end - start)))
        let prefix = start > 0 ? "…" : ""
        let suffix = end < nsLine.length ? "…" : ""
        return prefix + slice + suffix
    }

    static func grepManuscript(
        fullManuscript: String,
        pattern: String,
        contextLines: Int = 1,
        regex: Bool = false,
        causalLimit: Int? = nil,
        maxMatches: Int = 12
    ) -> [GrepMatch] {
        grepManuscript(
            pages: [fullManuscript],
            pattern: pattern,
            contextLines: contextLines,
            regex: regex,
            causalLimit: causalLimit,
            maxMatches: maxMatches
        )
    }

    private static func splitLinesWithUTF16Offsets(
        _ text: String
    ) -> [(text: String, utf16Start: Int)] {
        let nsText = text as NSString
        guard nsText.length > 0 else { return [] }
        var lines: [(text: String, utf16Start: Int)] = []
        var lineStart = 0
        var idx = 0

        while idx < nsText.length {
            if nsText.character(at: idx) == 0x000A {
                let len = idx - lineStart
                let line = nsText.substring(with: NSRange(location: lineStart, length: len))
                lines.append((text: line, utf16Start: lineStart))
                lineStart = idx + 1
            }
            idx += 1
        }
        if lineStart <= nsText.length {
            let len = nsText.length - lineStart
            if len > 0 || lines.isEmpty {
                let line = nsText.substring(with: NSRange(location: lineStart, length: len))
                lines.append((text: line, utf16Start: lineStart))
            }
        }
        return lines
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

        func appendCandidate(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2 else { return }
            let key = trimmed.lowercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }

        for term in terms {
            appendCandidate(term)
        }

        let cleanInstruction = instructionText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanInstruction.isEmpty {
            let tokenizer = NLTokenizer(unit: .word)
            tokenizer.string = cleanInstruction
            tokenizer.enumerateTokens(in: cleanInstruction.startIndex..<cleanInstruction.endIndex) { range, _ in
                let word = String(cleanInstruction[range])
                appendCandidate(word)
                return true
            }
            for raw in cleanInstruction.components(
                separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            ) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count <= 6 {
                    appendCandidate(trimmed)
                }
            }
        }
        return result
    }

    /// 真实中文分词（NaturalLanguage `.word`）+ 长词双字滑窗兜底：
    /// 保留完整中文词元以提升 IDF 区分度，避免相邻无关字组假词噪声，同时保留多字专名内部分片召回。
    static func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var tokens: [String] = []
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let raw = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { return true }
            let lower = raw.lowercased()
            let chars = Array(lower)
            let cjkChars = chars.filter(isCJK)
            if !cjkChars.isEmpty {
                if cjkChars.count >= 2 {
                    tokens.append(String(cjkChars))
                    if cjkChars.count >= 3 {
                        for i in 0..<(cjkChars.count - 1) {
                            tokens.append(String([cjkChars[i], cjkChars[i + 1]]))
                        }
                    }
                } else {
                    tokens.append(String(cjkChars[0]))
                }
            } else {
                let asciiWord = String(chars.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
                if asciiWord.count >= 2 {
                    tokens.append(asciiWord)
                }
            }
            return true
        }
        return tokens.isEmpty ? fallbackBigramTokens(text) : tokens
    }

    private static func fallbackBigramTokens(_ text: String) -> [String] {
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
