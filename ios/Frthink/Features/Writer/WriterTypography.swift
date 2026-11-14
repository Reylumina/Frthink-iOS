// 本文件负责：创作页正文与气泡的排版换算（DESIGN §2.3、§5.3）。
//
// 流式视图、正式气泡、行宽上限各写一套常量时，只要字号、行距或宽度差一点，
// 生成结束换成正式气泡的那一刻整段高度就会突变，视口按旧高度落点就露出空白。
// 换算只留这一份，三处共用。

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
    /// `lineHeight` 默认取阅读页那档 1.5；调用方传用户调过的值，创作页就和
    /// 阅读页完全同节奏。
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

    /// 把正文拆成段落：按行拆、丢掉空行、去掉首尾空白。
    ///
    /// 模型输出用空行分段，段落本身不保留缩进和空行。
    static func paragraphs(_ text: String) -> [String] {
        // 按任意换行符切（\r\n 也算一次），再连空白一起剪掉：
        // 只切 "\n" 会把 \r 留在段尾，完成态那段会多出一行，和流式对不上。
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
        justified: Bool
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
                    .foregroundColor: UIColor.label,
                    .paragraphStyle: style,
                ]
            ))
        } else {
            for (run, inlineStyle) in MarkdownInline.runs(plain) {
                result.append(NSAttributedString(
                    string: run,
                    attributes: [
                        .font: inlineFont(size: size, baseWeight: baseWeight, style: inlineStyle),
                        .foregroundColor: UIColor.label,
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
        alignsLastLine: Bool
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
                justified: justified
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
                        .foregroundColor: UIColor.label,
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

    private static func makeParagraphStyle(
        justified: Bool,
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = justified ? .justified : .natural
        style.lineBreakStrategy = .pushOut
        style.hyphenationFactor = 0.85
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        return style
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
