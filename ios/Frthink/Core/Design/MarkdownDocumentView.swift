import SwiftUI

/// 多行 Markdown 文档只读排版视图。
///
/// 复用 `MarkdownInline` 的标题、分隔线与行内格式解析，
/// 避免在设定档案预览与仿写模板页直接露出 `#`、`**`、`-` 等原始标记。
struct MarkdownDocumentView: View {
    let markdown: String

    private enum Block: Identifiable {
        case heading(id: Int, level: Int, text: String)
        case bullet(id: Int, text: String)
        case paragraph(id: Int, text: String)

        var id: Int {
            switch self {
            case .heading(let id, _, _),
                 .bullet(let id, _),
                 .paragraph(let id, _):
                return id
            }
        }
    }

    var body: some View {
        let blocks = parsedBlocks
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                blockView(block, isFirst: index == 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: Block, isFirst: Bool) -> some View {
        switch block {
        case .heading(_, let level, let text):
            inlineText(text)
                .font(headingFont(for: level))
                .foregroundStyle(.primary)
                .padding(.top, isFirst ? 0 : Theme.Spacing.xs)
        case .bullet(_, let text):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text("•")
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                inlineText(text)
                    .font(Theme.labelSmall)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .paragraph(_, let text):
            inlineText(text)
                .font(Theme.labelSmall)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1: return Theme.heading
        case 2: return Theme.labelEmphasis
        default: return Theme.label.weight(.semibold)
        }
    }

    private func inlineText(_ raw: String) -> Text {
        if let attributed = MarkdownInline.attributed(raw) {
            return Text(attributed)
        }
        if !raw.contains("["),
           raw.contains("`") || raw.contains("*") || raw.contains("_"),
           let attributed = try? AttributedString(
               markdown: raw,
               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
           ) {
            return Text(attributed)
        }
        if raw.contains("*") {
            var combined = AttributedString()
            for (segment, style) in MarkdownInline.runs(raw) {
                var part = AttributedString(segment)
                switch style {
                case .normal:
                    break
                case .bold:
                    part.inlinePresentationIntent = .stronglyEmphasized
                case .italic:
                    part.inlinePresentationIntent = .emphasized
                }
                combined.append(part)
            }
            return Text(combined)
        }
        return MarkdownInline.text(raw)
    }

    private var parsedBlocks: [Block] {
        var result: [Block] = []
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (idx, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !MarkdownInline.isDivider(trimmed) else { continue }
            if let level = MarkdownInline.headingLevel(trimmed) {
                let clean = MarkdownInline.strippingHeadingMarker(trimmed)
                if !clean.isEmpty {
                    result.append(.heading(id: idx, level: level, text: clean))
                }
            } else if let bulletText = strippingBulletPrefix(trimmed) {
                if !bulletText.isEmpty {
                    result.append(.bullet(id: idx, text: bulletText))
                }
            } else {
                result.append(.paragraph(id: idx, text: trimmed))
            }
        }
        return result
    }

    private func strippingBulletPrefix(_ line: String) -> String? {
        for prefix in ["- ", "* ", "• "] {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}
