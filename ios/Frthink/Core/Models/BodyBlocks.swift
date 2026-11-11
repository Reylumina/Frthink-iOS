import Foundation

/// 正文块索引。保存正文时算一次，阅读页按块取文时直接复用。
///
/// `start` 是全文 UTF-16 偏移，也是滚动锚点的稳定 id；块本身不存文字，
/// 避免把整本书再复制一份。
struct BodyBlock: Codable, Hashable, Sendable {
    var start: Int
    var length: Int

    var range: NSRange { NSRange(location: start, length: length) }
}

/// 按空行切块，超长段落再按句末切。切法必须稳定，否则旧块锚点会漂。
enum BodyBlockIndex {
    static let maxBlockLength = 1200

    /// 空行：一个换行 + 行内空白 + 再一个换行（兼容 CRLF）。
    private static let blankLine = try? NSRegularExpression(pattern: "\\n[ \\t\\r]*\\n")

    static func blocks(from text: String) -> [BodyBlock] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        guard whole.length > 0 else { return [] }

        var result: [BodyBlock] = []
        var paragraphStart = 0
        let separators = blankLine?.matches(in: text, options: [], range: whole) ?? []
        for separator in separators {
            let range = NSRange(
                location: paragraphStart,
                length: separator.range.location - paragraphStart
            )
            emit(ns, range: range, into: &result)
            paragraphStart = separator.range.location + separator.range.length
        }
        emit(
            ns,
            range: NSRange(location: paragraphStart, length: ns.length - paragraphStart),
            into: &result
        )
        return result
    }

    private static func emit(
        _ ns: NSString,
        range: NSRange,
        into result: inout [BodyBlock]
    ) {
        var start = range.location
        var end = range.location + range.length
        while start < end, isBlank(ns.character(at: start)) { start += 1 }
        while end > start, isBlank(ns.character(at: end - 1)) { end -= 1 }
        guard start < end else { return }

        var cursor = start
        while cursor < end {
            let limit = min(cursor + maxBlockLength, end)
            let cut = limit < end ? breakPoint(ns, from: cursor, limit: limit) : limit
            let length = cut - cursor
            guard length > 0 else { break }
            result.append(BodyBlock(start: cursor, length: length))
            cursor = cut
            while cursor < end, isBlank(ns.character(at: cursor)) { cursor += 1 }
        }
    }

    /// 在 `limit` 之前找一个标点后的断点，找不到就硬切。
    private static func breakPoint(_ ns: NSString, from start: Int, limit: Int) -> Int {
        let floor = start + maxBlockLength / 2
        var probe = limit
        while probe > floor {
            if isBreak(ns.character(at: probe - 1)) { break }
            probe -= 1
        }
        var cut = probe > floor ? probe : limit
        if cut > start + 1, isHighSurrogate(ns.character(at: cut - 1)) {
            cut -= 1
        }
        return max(cut, start + 1)
    }

    private static func isBlank(_ ch: unichar) -> Bool {
        ch == 9 || ch == 10 || ch == 13 || ch == 32 || ch == 0x3000
    }

    private static func isBreak(_ ch: unichar) -> Bool {
        switch ch {
        case 10, 13, 0x3002, 0xFF01, 0xFF1F, 0xFF1B, 0x21, 0x3F, 0x3B, 0x2E:
            return true
        default:
            return false
        }
    }

    private static func isHighSurrogate(_ ch: unichar) -> Bool {
        ch >= 0xD800 && ch <= 0xDBFF
    }
}
