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
        return try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
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

    static func text(_ raw: String) -> Text {
        if let attributed = attributed(raw) {
            return Text(attributed)
        }
        return Text(raw)
    }
}
