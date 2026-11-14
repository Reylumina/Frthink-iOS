// 本文件负责：创作页正文与气泡的排版换算（DESIGN §2.3、§5.3）。
//
// 集中管理正文与气泡排版换算，确保流式视图与静态气泡具有一致的高度与行距。

import SwiftUI
import UIKit

enum WriterTypography {
    /// 正文行高倍数。§2.3：流式气泡、正文编辑器、阅读页统一 1.5。
    static let lineHeight: Double = 1.5

    /// 用户气泡最多占对话列宽的 80%（§5.3）。
    static let userBubbleWidthRatio: CGFloat = 0.8

    /// 正文字号：外观设置里的基数字号，再按 Dynamic Type 放大。
    static func fontSize(_ baseSize: Double, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        DynamicTypeFont.bodySize(baseSize, dynamicTypeSize: dynamicTypeSize)
    }

    /// 行距换算与阅读页共用 `ReaderStyle`，不另写数值。
    ///
    /// `lineHeight` 默认取 1.5，亦可接收自定义行高以与阅读器对齐。
    static func lineSpacing(size: CGFloat, lineHeight: Double = lineHeight) -> CGFloat {
        ReaderStyle.lineSpacing(size: size, lineHeight: lineHeight)
    }

    /// 正文栏最大宽度 = 字号 × 36，超出时居中（§2.3、§5.3）。
    static func bodyMaxWidth(size: CGFloat) -> CGFloat {
        ReaderStyle.bodyMaxWidth(size: size)
    }

    /// 气泡里的段落间距（§2.3），与阅读页统一由 `Theme.Layout` 换算。
    static func paragraphSpacing(size: CGFloat, lineHeight: Double = lineHeight) -> CGFloat {
        Theme.Layout.paragraphSpacing(fontSize: size, lineHeight: lineHeight)
    }

    /// 将正文拆分为独立段落，过滤空行并去除首尾空白字符。
    static func paragraphs(_ text: String) -> [String] {
        // 识别各类换行符并修剪多余空白，确保跨平台换行格式一致。
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !MarkdownInline.isDivider($0) }
    }

    // MARK: - 统一富文本构建（流式视图与完成态气泡共用同一套排版）

    /// 生成单段富文本；流式视图与完成态气泡共用，保证段距、标题缩放与行内字体完全一致。
    static func attributedParagraph(
        _ paragraphText: String,
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        justified: Bool,
        foregroundColor: UIColor = .label
    ) -> NSAttributedString {
        let style = makeParagraphStyle(
            justified: justified,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing
        )
        let level = MarkdownInline.headingLevel(paragraphText)
        let plain = level == nil
            ? paragraphText
            : MarkdownInline.strippingHeadingMarker(paragraphText)
        let size = level.map { fontSize * headingScale($0) } ?? fontSize
        let baseWeight: UIFont.Weight = level == nil ? .regular : .semibold

        let result = NSMutableAttributedString()
        if level != nil {
            result.append(NSAttributedString(
                string: plain,
                attributes: [
                    .font: UIFont.systemFont(ofSize: size, weight: baseWeight),
                    .foregroundColor: foregroundColor,
                    .paragraphStyle: style,
                ]
            ))
        } else {
            for (run, inlineStyle) in MarkdownInline.runs(plain) {
                result.append(NSAttributedString(
                    string: run,
                    attributes: [
                        .font: inlineFont(size: size, baseWeight: baseWeight, style: inlineStyle),
                        .foregroundColor: foregroundColor,
                        .paragraphStyle: style,
                    ]
                ))
            }
        }
        return result
    }

    /// 生成整段文档的富文本；`alignsLastLine == false` 用于流式尾段先左对齐防抖。
    static func attributedDocument(
        _ text: String,
        fontSize: CGFloat,
        lineHeight: Double,
        alignsLastLine: Bool,
        foregroundColor: UIColor = .label
    ) -> NSAttributedString {
        let paragraphs = paragraphs(text)
        let lineSpacing = lineSpacing(size: fontSize, lineHeight: lineHeight)
        let spacing = paragraphSpacing(size: fontSize, lineHeight: lineHeight)
        let result = NSMutableAttributedString()

        for (index, paragraphText) in paragraphs.enumerated() {
            let isLast = index == paragraphs.count - 1
            let paraSpacing = isLast ? 0 : spacing
            let justified = alignsLastLine || !isLast
            result.append(attributedParagraph(
                paragraphText,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                paragraphSpacing: paraSpacing,
                justified: justified,
                foregroundColor: foregroundColor
            ))
            if !isLast {
                let sepStyle = makeParagraphStyle(
                    justified: justified,
                    lineSpacing: lineSpacing,
                    paragraphSpacing: paraSpacing
                )
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
                        .foregroundColor: foregroundColor,
                        .paragraphStyle: sepStyle,
                    ]
                ))
            }
        }
        return result
    }

    static func newlineSeparator(
        fontSize: CGFloat,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        justified: Bool
    ) -> NSAttributedString {
        let style = makeParagraphStyle(
            justified: justified,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing
        )
        return NSAttributedString(
            string: "\n",
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: UIColor.label,
                .paragraphStyle: style,
            ]
        )
    }

    static func makeParagraphStyle(
        justified: Bool,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat
    ) -> NSParagraphStyle {
        JustifiedText.paragraphStyle(
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            alignsLastLine: justified
        )
    }

    /// 正文编辑器输入态默认属性：复用阅读页与气泡的同款两端对齐与行距。
    static func manuscriptTypingAttributes(
        fontSize: CGFloat,
        lineHeight: Double
    ) -> [NSAttributedString.Key: Any] {
        let line = lineSpacing(size: fontSize, lineHeight: lineHeight)
        let para = paragraphSpacing(size: fontSize, lineHeight: lineHeight)
        return [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: UIColor.label,
            .paragraphStyle: makeParagraphStyle(
                justified: true,
                lineSpacing: line,
                paragraphSpacing: para
            ),
        ]
    }

    /// 将阅读页同款两端对齐、行距与段落间距应用至正文 `UITextView`（不改变底层 UTF-16 字符偏移）。
    ///
    /// 正文段间若存在 `\n\n` 空行（如插入正文或常见小说格式），将前一段的 `paragraphSpacing` 置 0，
    /// 并把空行高度约束为 `paragraphSpacing`，使视觉段距与阅读页完全一致且光标偏移零误差。
    static func applyManuscriptTypography(
        to textView: UITextView,
        fontSize: CGFloat,
        lineHeight: Double
    ) {
        let storage = textView.textStorage
        let totalLength = storage.length
        let line = lineSpacing(size: fontSize, lineHeight: lineHeight)
        let spacing = paragraphSpacing(size: fontSize, lineHeight: lineHeight)
        let font = UIFont.systemFont(ofSize: fontSize, weight: .regular)

        let standardStyle = makeParagraphStyle(
            justified: true,
            lineSpacing: line,
            paragraphSpacing: spacing
        )
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: standardStyle,
        ]
        guard totalLength > 0 else { return }

        let beforeBlankStyle = makeParagraphStyle(
            justified: true,
            lineSpacing: line,
            paragraphSpacing: 0
        )
        let blankLineStyle = NSMutableParagraphStyle()
        blankLineStyle.alignment = .justified
        blankLineStyle.lineBreakStrategy = .pushOut
        blankLineStyle.hyphenationFactor = 0.85
        blankLineStyle.minimumLineHeight = spacing
        blankLineStyle.maximumLineHeight = spacing
        blankLineStyle.lineSpacing = 0
        blankLineStyle.paragraphSpacing = 0

        let ns = storage.string as NSString
        let fullRange = NSRange(location: 0, length: totalLength)
        storage.beginEditing()
        storage.addAttributes(
            [
                .font: font,
                .foregroundColor: UIColor.label,
                .paragraphStyle: standardStyle,
            ],
            range: fullRange
        )
        var index = 0
        while index < totalLength {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let contentEnd = NSMaxRange(lineRange)
            let trimmedLen = lineRange.length
            let isBlankLine = trimmedLen == 0
                || (trimmedLen == 1 && ns.character(at: lineRange.location) == 10)
                || (trimmedLen == 2
                    && ns.character(at: lineRange.location) == 13
                    && ns.character(at: lineRange.location + 1) == 10)
            if isBlankLine {
                storage.addAttribute(.paragraphStyle, value: blankLineStyle, range: lineRange)
            } else if contentEnd < totalLength {
                let nextChar = ns.character(at: contentEnd)
                if nextChar == 10 || nextChar == 13 {
                    storage.addAttribute(.paragraphStyle, value: beforeBlankStyle, range: lineRange)
                }
            }
            guard contentEnd > index else { break }
            index = contentEnd
        }
        storage.endEditing()
    }

    private static func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 1.45
        case 2: return 1.26
        default: return 1.12
        }
    }

    private static func inlineFont(
        size: CGFloat,
        baseWeight: UIFont.Weight,
        style: MarkdownInline.InlineStyle
    ) -> UIFont {
        switch style {
        case .normal:
            return .systemFont(ofSize: size, weight: baseWeight)
        case .bold:
            return .systemFont(ofSize: size, weight: .bold)
        case .italic:
            let base = UIFont.systemFont(ofSize: size, weight: baseWeight)
            return base.fontDescriptor.withSymbolicTraits(.traitItalic)
                .map { UIFont(descriptor: $0, size: size) } ?? base
        }
    }
}
