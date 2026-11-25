import SwiftUI

/// 多行 Markdown 文档只读排版视图。
///
/// 统一支持一至三级标题、无序/有序列表、引用块、代码块、分隔线与行内样式，
/// 用于档案预览、仿写模板、写作资料与说明弹层，避免界面直接露出原始标记。
struct MarkdownDocumentView: View {
    let markdown: String

    enum Block: Identifiable, Equatable {
        case heading(id: Int, level: Int, text: String)
        case bullet(id: Int, text: String)
        case numbered(id: Int, marker: String, text: String)
        case quote(id: Int, lines: [String])
        case codeBlock(id: Int, code: String)
        case divider(id: Int)
        case paragraph(id: Int, text: String)

        var id: Int {
            switch self {
            case .heading(let id, _, _),
                 .bullet(let id, _),
                 .numbered(let id, _, _),
                 .quote(let id, _),
                 .codeBlock(let id, _),
                 .divider(let id),
                 .paragraph(let id, _):
                return id
            }
        }
    }

    var body: some View {
        let blocks = Self.parseBlocks(from: markdown)
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
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                inlineText(text)
                    .font(headingFont(for: level))
                    .foregroundStyle(.primary)
                    .lineSpacing(3)
                if level == 1 {
                    Divider()
                }
            }
            .padding(.top, headingTopPadding(for: level, isFirst: isFirst))

        case .bullet(_, let text):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text("•")
                    .font(Theme.reply)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                inlineText(text)
                    .font(Theme.reply)
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .numbered(_, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text(marker)
                    .font(Theme.numeric)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20, alignment: .leading)
                inlineText(text)
                    .font(Theme.reply)
                    .foregroundStyle(.primary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .quote(_, let lines):
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Capsule()
                    .fill(Theme.separator)
                    .frame(width: 2)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        inlineText(line)
                            .font(Theme.reply)
                            .foregroundStyle(.secondary)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Theme.Spacing.xs)

        case .codeBlock(_, let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.m)
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.field)
            )

        case .divider:
            Divider()
                .padding(.vertical, Theme.Spacing.xs)

        case .paragraph(_, let text):
            inlineText(text)
                .font(Theme.reply)
                .foregroundStyle(.primary)
                .lineSpacing(4)
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

    private func headingTopPadding(for level: Int, isFirst: Bool) -> CGFloat {
        guard !isFirst else { return 0 }
        return level <= 2 ? Theme.Spacing.m : Theme.Spacing.s
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

    static func parseBlocks(from markdown: String) -> [Block] {
        var result: [Block] = []
        let lines = markdown.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("```") {
                let blockID = index
                index += 1
                var codeLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    if candidate.hasPrefix("```") {
                        index += 1
                        break
                    }
                    codeLines.append(String(lines[index]))
                    index += 1
                }
                let code = codeLines.joined(separator: "\n")
                    .trimmingCharacters(in: .newlines)
                if !code.isEmpty {
                    result.append(.codeBlock(id: blockID, code: code))
                }
                continue
            }

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if MarkdownInline.isDivider(trimmed) {
                result.append(.divider(id: index))
                index += 1
                continue
            }

            if let quoteFirst = strippingQuotePrefix(trimmed) {
                let blockID = index
                var quoteLines: [String] = []
                if !quoteFirst.isEmpty { quoteLines.append(quoteFirst) }
                index += 1
                while index < lines.count {
                    let nextTrimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let nextQuote = strippingQuotePrefix(nextTrimmed) else { break }
                    if !nextQuote.isEmpty { quoteLines.append(nextQuote) }
                    index += 1
                }
                if !quoteLines.isEmpty {
                    result.append(.quote(id: blockID, lines: quoteLines))
                }
                continue
            }

            if let level = MarkdownInline.headingLevel(trimmed) {
                let clean = MarkdownInline.strippingHeadingMarker(trimmed)
                if !clean.isEmpty {
                    result.append(.heading(id: index, level: level, text: clean))
                }
            } else if let bulletText = strippingBulletPrefix(trimmed) {
                if !bulletText.isEmpty {
                    result.append(.bullet(id: index, text: bulletText))
                }
            } else if let numbered = parseNumberedLine(trimmed) {
                if !numbered.text.isEmpty {
                    result.append(.numbered(id: index, marker: numbered.marker, text: numbered.text))
                }
            } else {
                result.append(.paragraph(id: index, text: trimmed))
            }
            index += 1
        }
        return result
    }

    private static func strippingQuotePrefix(_ line: String) -> String? {
        guard line.hasPrefix(">") else { return nil }
        return String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingBulletPrefix(_ line: String) -> String? {
        for prefix in ["- ", "* ", "• "] {
            if line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func parseNumberedLine(_ line: String) -> (marker: String, text: String)? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let afterDigits = line.dropFirst(digits.count)
        let separator: String
        let rest: Substring
        if afterDigits.hasPrefix(". ") {
            separator = "."
            rest = afterDigits.dropFirst(2)
        } else if afterDigits.hasPrefix("、") {
            separator = "、"
            rest = afterDigits.dropFirst(1)
        } else if afterDigits.hasPrefix(") ") {
            separator = ")"
            rest = afterDigits.dropFirst(2)
        } else {
            return nil
        }
        let cleanText = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanText.isEmpty else { return nil }
        return ("\(digits)\(separator)", cleanText)
    }
}
