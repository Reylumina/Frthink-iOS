// 本文件负责：阅读页的一个段落 —— 按设置排版，并把搜索命中刷上底色。

import Foundation
import SwiftUI

/// 一段正文。命中区间用 `AttributedString` 的背景色标出来，不必再叠一层视图。
struct ReaderParagraphView: View {
    /// 本段文本。阅读器只在可见段上按 range 切片，块模型不长期持有整段字符串。
    let text: String
    let fontSize: CGFloat
    let lineHeight: Double
    let darkPage: Bool
    /// 本段内的全部命中，坐标是段内的 UTF-16 相对偏移。
    let highlights: [NSRange]
    /// 当前跳到的那一处命中。
    let current: NSRange?

    var body: some View {
        Text(displayText)
            .font(ReaderStyle.bodyFont(size: fontSize))
            .foregroundStyle(ReaderStyle.ink(dark: darkPage))
            .lineSpacing(ReaderStyle.lineSpacing(size: fontSize, lineHeight: lineHeight))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private var displayText: AttributedString {
        guard !highlights.isEmpty else { return AttributedString(text) }
        return Self.highlighted(text, ranges: highlights, current: current)
    }

    /// 按区间把文本切片再拼回去：命中段加背景色，其余原样。
    ///
    /// 不做 `String.Index` → `AttributedString.Index` 的换算 —— 切片本身是
    /// O(命中数) 的，而且偏移一目了然，不会在代理对上算错一格。
    private static func highlighted(
        _ text: String,
        ranges: [NSRange],
        current: NSRange?
    ) -> AttributedString {
        let ns = text as NSString
        var result = AttributedString()
        var cursor = 0
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            let start = max(0, min(range.location, ns.length))
            let end = max(start, min(range.location + range.length, ns.length))
            guard end > start else { continue }
            if start > cursor {
                result = result + AttributedString(
                    ns.substring(with: NSRange(location: cursor, length: start - cursor))
                )
            }
            var piece = AttributedString(
                ns.substring(with: NSRange(location: start, length: end - start))
            )
            piece.backgroundColor = ReaderStyle.highlightColor(current: isCurrent(range, current))
            result = result + piece
            cursor = end
        }
        if cursor < ns.length {
            result = result + AttributedString(ns.substring(from: cursor))
        }
        return result
    }

    private static func isCurrent(_ range: NSRange, _ current: NSRange?) -> Bool {
        guard let current else { return false }
        return current.location == range.location && current.length == range.length
    }
}
