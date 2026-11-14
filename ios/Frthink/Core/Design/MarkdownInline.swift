import Foundation
import SwiftUI

/// 创作页回复里的 Markdown。
///
/// 行内（`**加粗**`、`*斜体*`）统一走 `runs(_:)`，把文本切成带样式的片段——
/// 流式生成与完成态统一使用该实现，避免状态切换时出现符号吞吐或格式跳变。用户气泡仍采用
/// `AttributedString(markdown:)` 处理。块级只认
/// 一到三级标题（行首 `#`、`##`、`###`），其余一律按正文排版——小说正文里的
/// 星号、短横线很常见，全量块级解析会把它们误读成列表和分隔线。
enum MarkdownInline {
    static func attributed(_ raw: String) -> AttributedString? {
        // 加粗与斜体均委托系统解析；解析失败则回退至纯文本，防止残留不完整的格式标记。
        guard raw.contains("*") || raw.contains("__") else { return nil }
        // 包含方括号或反引号时保留原始内容：标准行内解析会剥离括号或反引号，
        // 而在小说文本中此类符号多为标点或引用，而非 Markdown 语法结构。
        guard !raw.contains("["), !raw.contains("`") else { return nil }
        return try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
    }

    /// 整行只有分隔线标记（`---`、`***`、`___`）时返回 true。
    ///
    /// 模型生成时常在段落间插入水平分割线；在小说正文中此类符号多属冗余噪点，渲染时予以忽略。
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
        // 需后跟空格方判定为标题；类似 "#标签" 的内容不视为标题。
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
    /// 流式气泡与完成态气泡共享此解析逻辑，避免两套解析差异导致生成结束切换视图时
    /// 出现格式跳变或标记残留。
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
