// 阅读页数据层：处理原文/译文获取、分段切块、偏移定位与全文搜索。

import Foundation

/// 阅读页显示的正文来源：包含书稿原文与按序拼接的译文。
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

    /// 搜索框占位符，跟随当前阅读模式动态变化。
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
    /// 同一段号可能存在多条历史记录，选取 `updatedAt` 最新的记录并保留段落间距拼接。
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

/// 正文分块：优先按空行分割，超长段落按句末标点细分。
///
/// `start` 为块在全文中的 UTF-16 偏移，兼作稳定滚动锚点；
/// 章节、搜索命中与书签均映射至对应块起点进行定位。
struct ReaderBlock: Identifiable, Equatable {
    let start: Int
    let length: Int

    var id: Int { start }
    var range: NSRange { NSRange(location: start, length: length) }
}

/// 已分块正文数据：分块索引读取自 `body.meta`，阅读模式无需拼接全文。
///
/// `fullText` 仅在导出等需全量文本场景调用；搜索采用分页扫描，滚动时按块读取对应页。
struct ReaderDocument {
    let blocks: [ReaderBlock]
    /// 全文 UTF-16 长度，用于边界约束。
    let length: Int
    /// 全文可见字符数，用于页脚字数统计。
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

    /// 全量正文文本。仅供导出等必要场景调用，搜索应避免使用。
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

    /// 全文检索：分页文档逐页扫描并维持窗口缓存，避免全量载入内存。
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

    /// 逐页扫描，跨页匹配通过保留前一页末尾 256 字符窗口衔接。
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
                // 排除完全落在前一页末尾的重复匹配项，仅收集覆盖当前页的结果。
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
    /// 单次检索的最大匹配数限制，防止大结果集影响检索性能。
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

    /// 将匹配项按块分组，段落渲染时仅检索当前段落区间。
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

    /// 匹配片段：提取前后上下文并将换行符转换为空格，适配列表单行展示。
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
