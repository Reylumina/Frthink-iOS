// 语料搜索结果的高亮：把命中关键词的片段标成强调色。
//
// 在内存里计算命中区间，列表行统一走这一份渲染，保证「搜到的」和「标亮的」一致。

import SwiftUI

enum CorpusHighlight {
    /// 把 `text` 里所有命中 `tokens` 的片段标成强调色。
    ///
    /// 多个词条重叠时按区间合并，避免同一段被拆成碎片。
    static func attributed(_ text: String, tokens: [String]) -> AttributedString {
        let ranges = matchRanges(in: text, tokens: tokens)
        guard !ranges.isEmpty else { return AttributedString(text) }

        var result = AttributedString()
        var cursor = text.startIndex
        for range in ranges {
            if cursor < range.lowerBound {
                result += AttributedString(String(text[cursor..<range.lowerBound]))
            }
            var piece = AttributedString(String(text[range]))
            piece.foregroundColor = Theme.accent
            piece.backgroundColor = Theme.accentSoft
            result += piece
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result += AttributedString(String(text[cursor..<text.endIndex]))
        }
        return result
    }

    static func containsMatch(_ text: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let lowered = text.lowercased()
        return tokens.contains { lowered.contains($0.lowercased()) }
    }

    private static func matchRanges(in text: String, tokens: [String]) -> [Range<String.Index>] {
        guard !text.isEmpty, !tokens.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        for token in tokens where !token.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let found = text.range(
                      of: token,
                      options: [.caseInsensitive, .diacriticInsensitive],
                      range: searchStart..<text.endIndex
                  ) {
                ranges.append(found)
                searchStart = found.upperBound
            }
        }

        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound < last.upperBound {
                if range.upperBound > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<range.upperBound
                }
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
