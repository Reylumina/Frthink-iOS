import Foundation
import SwiftUI

/// 创作页回复里的行内 Markdown。只处理 `**加粗**` / `__加粗__`，
/// 不做块级解析，避免把小说正文里的星号误当成列表。
enum MarkdownInline {
    static func attributed(_ raw: String) -> AttributedString? {
        guard raw.contains("**") || raw.contains("__") else { return nil }
        return try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }

    static func text(_ raw: String) -> Text {
        if let attributed = attributed(raw) {
            return Text(attributed)
        }
        return Text(raw)
    }
}
