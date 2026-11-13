import Foundation
import SwiftUI

/// 创作页回复里的 Markdown。
///
/// 行内（`**加粗**`、`*斜体*`）交给 `AttributedString(markdown:)`；块级只认
/// 一到三级标题（行首 `#`、`##`、`###`），其余一律按正文排版——小说正文里的
/// 星号、短横线很常见，全量块级解析会把它们误读成列表和分隔线。
enum MarkdownInline {
    static func attributed(_ raw: String) -> AttributedString? {
        // 加粗、斜体都交给系统解析；解析失败就退回纯文本，不会出现半截标记。
        guard raw.contains("*") || raw.contains("__") else { return nil }
        // 带方括号或反引号时保持原文：行内解析会把 [注](url) 的方括号和反引号吃掉，
        // 小说正文里这两个符号比 Markdown 结构更常见。
        guard !raw.contains("["), !raw.contains("`") else { return nil }
        return try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }

    /// 整行只有分隔线标记（`---`、`***`、`___`）时返回 true。
    ///
    /// 模型很爱在段与段之间插一条横线；小说正文里它们只是噪音，两处渲染都跳过。
    static func isDivider(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return false }
        let markers = Set(trimmed)
        return markers == ["-"] || markers == ["*"] || markers == ["_"]
    }

    /// 行首的标题层级（1…3）。不是标题返回 nil。
    static func headingLevel(_ raw: String) -> Int? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let level = trimmed.prefix(while: { $0 == "#" }).count
        guard (1...3).contains(level) else { return nil }
        // 必须跟一个空格才是标题；"#标签" 这种不算。
        let rest = trimmed.dropFirst(level)
        guard rest.hasPrefix(" ") || rest.hasPrefix("　") else { return nil }
        return level
    }

    /// 去掉行首的 `#` 和空格，留下标题文字。
    static func strippingHeadingMarker(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let level = trimmed.prefix(while: { $0 == "#" }).count
        return String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
    }

    /// 行内样式。
    enum InlineStyle { case normal, bold, italic }

    /// 把一段按 `**` 和 `*` 切成带样式的 run，标记本身不显示。
    ///
    /// 流式气泡和完成态气泡共用这一份解析：两边各写一套时，生成结束换气泡那一刻
    /// 会出现「多一个星号 / 少一层加粗」的跳变。
    static func runs(_ raw: String) -> [(String, InlineStyle)] {
        guard raw.contains("*") else { return [(raw, .normal)] }
        var runs: [(String, InlineStyle)] = []
        var buffer = ""
        var isBold = false
        var isItalic = false

        func flush() {
            guard !buffer.isEmpty else { return }
            let style: InlineStyle = isBold ? .bold : (isItalic ? .italic : .normal)
            runs.append((buffer, style))
            buffer = ""
        }

        var index = raw.startIndex
        while index < raw.endIndex {
            if raw[index...].hasPrefix("**") {
                flush()
                isBold.toggle()
                index = raw.index(index, offsetBy: 2)
            } else if raw[index] == "*" {
                flush()
                isItalic.toggle()
                index = raw.index(after: index)
            } else {
                buffer.append(raw[index])
                index = raw.index(after: index)
            }
        }
        flush()
        return runs
    }

    static func text(_ raw: String) -> Text {
        if let attributed = attributed(raw) {
            return Text(attributed)
        }
        return Text(raw)
    }
}
