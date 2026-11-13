// 本文件负责：阅读页的纯数据层 —— 原文/译文取文、按段切块、偏移定位与全文搜索。

import Foundation

/// 阅读页显示的正文来源。原文是书稿本身，译文是把分段按顺序拼起来的那一篇。
enum ReaderMode: String, CaseIterable, Identifiable {
    case source
    case translation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .source:
            return "原文"
        case .translation:
            return "译文"
        }
    }

    /// 搜索框占位符，跟着当前模式走（原版文案「搜索正文」/「搜索译文」）。
    var searchPlaceholder: String {
        switch self {
        case .source:
            return "搜索正文"
        case .translation:
            return "搜索译文"
        }
    }
}

enum ReaderText {
    /// 译文 = `translations` 按 `segment` 升序拼接。
    ///
    /// 同一段号可能留有多条记录（重译、换目标语言、换设备），取 `updatedAt` 最新的
    /// 那条，段与段之间空一行 —— 拼出来要像一篇散文，而不是一堆碎块。
    static func translation(_ segments: [TranslationSegment]) -> String {
        var newest: [Int: TranslationSegment] = [:]
        for segment in segments where !segment.payload.isEmpty {
            if let existing = newest[segment.segment] {
                if segment.updatedAt >= existing.updatedAt {
                    newest[segment.segment] = segment
                }
            } else {
                newest[segment.segment] = segment
            }
        }
        return newest.keys.sorted().compactMap { newest[$0]?.payload }.joined(separator: "\n\n")
    }
}

/// 正文里的一块。主切法是空行，超长段落再按句末切。
///
/// `start` 同时是块在全文里的 UTF-16 偏移和它作为滚动锚点的稳定 id ——
/// 章节、命中、书签都换算成「哪一块的 start」，滚过去就完事了。
struct ReaderBlock: Identifiable, Equatable {
    let start: Int
    let length: Int

    var id: Int { start }
    var range: NSRange { NSRange(location: start, length: length) }
}

/// 一篇切好块的正文。块索引来自保存时的 `body.meta`，阅读时不拼全文。
///
/// `fullText` 只在导出等必须全文的路径调用；搜索逐页扫描，普通滚动按块取页。
struct ReaderDocument {
    let blocks: [ReaderBlock]
    /// 全文 UTF-16 长度。边界夹取用它。
    let length: Int
    /// 全文可见字符数，只用于页脚「多少字」。
    let characterCount: Int
    private let plainText: String
    private let pageSource: ReaderPageSource?

    static let empty = ReaderDocument(text: "")

    init(text: String) {
        self.blocks = BodyBlockIndex.blocks(from: text).map {
            ReaderBlock(start: $0.start, length: $0.length)
        }
        self.length = (text as NSString).length
        self.characterCount = text.count
        self.plainText = text
        self.pageSource = nil
    }

    init(
        blocks: [ReaderBlock],
        length: Int,
        characterCount: Int,
        pageSource: ReaderPageSource
    ) {
        self.blocks = blocks
        self.length = length
        self.characterCount = characterCount
        self.plainText = ""
        self.pageSource = pageSource
    }

    /// 整本正文。只在导出这类必须全文的路径调用；搜索不要用它。
    var text: String {
        pageSource?.fullText ?? plainText
    }

    /// 按块取正文。分页来源只解密块覆盖的页。
    func text(for block: ReaderBlock) -> String {
        if let pageSource {
            return pageSource.text(in: block.range)
        }
        return (plainText as NSString).substring(with: block.range)
    }

    /// 搜全文。分页文档逐页扫描，只保留相邻两页，避免先拼出整本书。
    func searchMatches(query: String) async -> [ReaderMatch] {
        if let pageSource {
            return await pageSource.searchMatches(query: query)
        }
        return ReaderSearch.matches(in: plainText, query: query)
    }
}

/// 按页取正文的缓存。页面固定 UTF-16 大小，块可能跨页。
final class ReaderPageSource {
    private let pageCount: Int
    private let pageSize: Int
    private let loader: (Int) -> String?
    private let lock = NSLock()
    private var cache: [Int: String] = [:]
    private var recency: [Int] = []
    private let cacheLimit = 8

    init(pageCount: Int, pageSize: Int, loader: @escaping (Int) -> String?) {
        self.pageCount = max(0, pageCount)
        self.pageSize = max(1, pageSize)
        self.loader = loader
    }

    func text(in range: NSRange) -> String {
        guard pageCount > 0, range.length > 0 else { return "" }
        let first = min(max(0, range.location / pageSize), pageCount - 1)
        let last = min(max(first, (range.location + range.length - 1) / pageSize), pageCount - 1)
        var joined = ""
        for index in first...last {
            joined += page(index)
        }
        let pageStart = first * pageSize
        let ns = joined as NSString
        let start = max(0, min(range.location - pageStart, ns.length))
        let length = max(0, min(range.length, ns.length - start))
        return ns.substring(with: NSRange(location: start, length: length))
    }

    var fullText: String {
        (0..<pageCount).map(page).joined()
    }

    /// 逐页扫描；跨页命中用上一页尾部 256 字的滚动窗口兜住。
    func searchMatches(query: String) async -> [ReaderMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, pageCount > 0 else { return [] }
        var results: [ReaderMatch] = []
        var prefix = ""
        var base = 0
        for index in 0..<pageCount {
            if Task.isCancelled || results.count >= ReaderSearch.limit { break }
            let pageText = page(index)
            let prefixLength = (prefix as NSString).length
            let combined = prefix + pageText
            let pageBase = base - prefixLength
            for match in ReaderSearch.matches(in: combined, query: needle) {
                let global = match.offset + pageBase
                // 完全落在上一页尾部的内容已经报过，只收触及本页的命中。
                guard global + match.length > base else { continue }
                results.append(ReaderMatch(
                    offset: global,
                    length: match.length,
                    snippet: match.snippet
                ))
                if results.count >= ReaderSearch.limit { break }
            }
            prefix = String(pageText.suffix(256))
            base += (pageText as NSString).length
            await Task.yield()
        }
        return results
    }

    private func page(_ index: Int) -> String {
        lock.lock()
        if let cached = cache[index] {
            touch(index)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let text = loader(index) ?? ""

        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[index] {
            touch(index)
            return cached
        }
        cache[index] = text
        touch(index)
        if recency.count > cacheLimit, let oldest = recency.first {
            recency.removeFirst()
            if oldest != index { cache[oldest] = nil }
        }
        return text
    }

    private func touch(_ index: Int) {
        recency.removeAll { $0 == index }
        recency.append(index)
    }
}

enum ReaderLocator {
    /// 偏移落在第几块（二分）。偏移超界时夹到首块或尾块。
    static func blockIndex(for offset: Int, in blocks: [ReaderBlock]) -> Int {
        guard !blocks.isEmpty else { return 0 }
        var low = 0
        var high = blocks.count - 1
        var answer = 0
        while low <= high {
            let mid = (low + high) / 2
            if blocks[mid].start <= offset {
                answer = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return answer
    }
}

/// 一处搜索命中。`offset` / `length` 都是全文里的 UTF-16 区间。
struct ReaderMatch: Identifiable, Equatable {
    let offset: Int
    let length: Int
    let snippet: String

    var id: Int { offset }
}

enum ReaderSearch {
    /// 一次最多收这么多命中。列表再长也没人翻，还拖慢搜索。
    static let limit = 400

    static func matches(in text: String, query: String) -> [ReaderMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let ns = text as NSString
        guard ns.length > 0 else { return [] }

        var results: [ReaderMatch] = []
        var cursor = 0
        while cursor < ns.length, results.count < limit {
            let remaining = NSRange(location: cursor, length: ns.length - cursor)
            let found = ns.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: remaining
            )
            guard found.location != NSNotFound else { break }
            results.append(
                ReaderMatch(
                    offset: found.location,
                    length: found.length,
                    snippet: snippet(in: ns, around: found)
                )
            )
            cursor = found.location + max(found.length, 1)
        }
        return results
    }

    /// 把命中按所在块分组，段落渲染时只查自己那一段的区间，不用全文扫。
    static func grouped(_ matches: [ReaderMatch], by blocks: [ReaderBlock]) -> [Int: [NSRange]] {
        var result: [Int: [NSRange]] = [:]
        guard !blocks.isEmpty else { return result }
        for match in matches {
            let index = ReaderLocator.blockIndex(for: match.offset, in: blocks)
            let block = blocks[index]
            let localStart = match.offset - block.start
            guard localStart >= 0, localStart < block.length else { continue }
            let localLength = min(match.length, block.length - localStart)
            guard localLength > 0 else { continue }
            result[block.start, default: []].append(
                NSRange(location: localStart, length: localLength)
            )
        }
        return result
    }

    /// 命中片段：前后各带一点上下文，换行压成空格，列表里一行放得下。
    private static func snippet(in ns: NSString, around range: NSRange) -> String {
        let before = 12
        let after = 18
        let start = max(0, range.location - before)
        let end = min(ns.length, range.location + range.length + after)
        var piece = ns.substring(with: NSRange(location: start, length: end - start))
        piece = piece.replacingOccurrences(of: "\n", with: " ")
        piece = piece.replacingOccurrences(of: "\r", with: " ")
        piece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        if start > 0 { piece = "…" + piece }
        if end < ns.length { piece += "…" }
        return piece
    }
}
