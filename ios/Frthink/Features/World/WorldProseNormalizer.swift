// 事件卡叙述文本与标题清洗：剥离列表编号、并句断句、统一中文全角标点与省略号。

import Foundation

enum WorldProseNormalizer {

    private static let clauseClosingChars = "。！？…，、；：」』”’）"
    private static let sentenceClosingChars = "。！？…」』”’）"
    private static let trailingClauseChars = "，、；："

    /// 事件卡叙述文本段落规范化：合并换行、转换全半角标点并补齐句读；
    /// 保留空行作为自然段落分隔符，英文文本采用空格合并。
    static func normalizeProse(_ rawText: String) -> String {
        let lines = rawText
            .components(separatedBy: .newlines)
            .map { stripListMarker($0.trimmingCharacters(in: .whitespaces)) }

        var paragraphs: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.isEmpty {
                if !current.isEmpty {
                    paragraphs.append(current)
                    current = []
                }
                continue
            }
            current.append(line)
        }
        if !current.isEmpty { paragraphs.append(current) }

        return paragraphs
            .map(mergeParagraph)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// 规范化事件标题：去除首尾多余标点与列表编号标记。
    static func normalizeEventTitle(_ raw: String) -> String {
        stripListMarker(raw)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。！？；，、："))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 段落与标点

    /// 段内并句：行间缺分隔补「，」，段末补「。」，半角转全角。
    private static func mergeParagraph(_ lines: [String]) -> String {
        guard !lines.isEmpty else { return "" }
        guard lines.contains(where: containsHan) else {
            return lines.joined(separator: " ")
        }

        var result = ""
        for line in lines {
            let normalized = normalizePunctuation(line)
            guard !result.isEmpty else {
                result = normalized
                continue
            }
            if !endsWithAny(result, in: clauseClosingChars) {
                result += "，"
            }
            result += normalized
        }
        result = collapsePunctuation(result)
        if !endsWithAny(result, in: sentenceClosingChars) {
            while let last = result.last, trailingClauseChars.contains(last) {
                result.removeLast()
            }
            result += "。"
        }
        return result
    }

    private static func containsHan(_ text: String) -> Bool {
        text.contains { isHan($0) }
    }

    private static func stripListMarker(_ line: String) -> String {
        line
            .replacingOccurrences(of: #"^\s*[-–—•·]\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*\d+[.、)]\s*"#, with: "", options: .regularExpression)
    }

    /// 中文行里的半角标点转全角；数字小数、英文缩写不动。
    private static func normalizePunctuation(_ text: String) -> String {
        let prepared = text.replacingOccurrences(of: "...", with: "……")
        let chars = Array(prepared)
        var result = ""
        result.reserveCapacity(chars.count)

        for (index, ch) in chars.enumerated() {
            guard let fullwidth = fullwidthPunctuation(ch) else {
                result.append(ch)
                continue
            }
            let previous = index > 0 ? chars[index - 1] : nil
            let next = index + 1 < chars.count ? chars[index + 1] : nil
            result.append((isHan(previous) || isHan(next)) ? fullwidth : ch)
        }

        return result
            .replacingOccurrences(of: #"\s+([，。！？；：、」』”’）])"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([「『“‘（])\s+"#, with: "$1", options: .regularExpression)
    }

    private static func fullwidthPunctuation(_ ch: Character) -> Character? {
        guard ",;:!?.".contains(ch) else { return nil }
        if ch == "." { return "。" }
        return String(ch)
            .applyingTransform(.fullwidthToHalfwidth, reverse: true)?
            .first
    }

    private static func isHan(_ ch: Character?) -> Bool {
        guard let ch,
              ch.unicodeScalars.count == 1,
              let scalar = ch.unicodeScalars.first else {
            return false
        }
        return (0x4E00...0x9FFF).contains(scalar.value)
    }

    private static func endsWithAny(_ text: String, in set: String) -> Bool {
        guard let last = text.last else { return false }
        return set.contains(last)
    }

    /// 并段后清掉「，。」「。。」「，，」这类重复标点，并去掉标点前空格。
    private static func collapsePunctuation(_ text: String) -> String {
        let rules: [(String, String)] = [
            (#"\s+([，。！？；：、])"#, "$1"),
            (#"[，、；：]+(?=[。！？…])"#, ""),
            (#"。{2,}"#, "。"),
            (#"([。！？…])[，、；：]+"#, "$1"),
            (#"[，、；：]{2,}"#, "，"),
        ]
        return rules.reduce(text) { partial, rule in
            partial.replacingOccurrences(of: rule.0, with: rule.1, options: .regularExpression)
        }
    }
}
