// 流式输出的 UITextView：平时只追加尾部增量，窗口攒满后才整体重置一次。

import SwiftUI
import UIKit

struct StreamingTextView: UIViewRepresentable {
    var text: String
    /// 与「外观 → 正文字号」换算后的实际字号（`WriterTypography.fontSize`）。
    var fontSize: CGFloat
    /// 与完成态气泡共用的行距（`WriterTypography.lineSpacing`）。
    ///
    /// 两处不一致时，生成结束换成普通气泡的那一刻整段会突然变高，
    /// 视口还停在旧高度上，底部就露出一片空白。
    var lineSpacing: CGFloat

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isScrollEnabled = false
        view.isSelectable = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
        let rendered = context.coordinator.window.rendered(text).text
        view.attributedText = Self.attributed(
            rendered,
            fontSize: fontSize,
            lineSpacing: lineSpacing
        )
        context.coordinator.appliedText = rendered
        context.coordinator.fontSignature = Self.signature(
            fontSize: fontSize,
            lineSpacing: lineSpacing
        )
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        let signature = Self.signature(fontSize: fontSize, lineSpacing: lineSpacing)
        if coordinator.fontSignature != signature {
            coordinator.fontSignature = signature
            coordinator.window = StreamingTextWindow()
            let rendered = coordinator.window.rendered(text).text
            uiView.attributedText = Self.attributed(
                rendered,
                fontSize: fontSize,
                lineSpacing: lineSpacing
            )
            coordinator.appliedText = rendered
            uiView.invalidateIntrinsicContentSize()
            return
        }

        let rendered = coordinator.window.rendered(text).text
        guard coordinator.appliedText != rendered else { return }

        // 按显示串求公共前缀，只替换尾部差异（通常只有最后一段），避免整段重排。
        let newAttributed = Self.attributed(
            rendered,
            fontSize: fontSize,
            lineSpacing: lineSpacing
        )
        let oldString = uiView.attributedText?.string ?? "" as String
        let newString = newAttributed.string
        let changed = oldString != newString
        if changed {
            let oldNS = oldString as NSString
            let newNS = newString as NSString
            let maxCommon = min(oldNS.length, newNS.length)
            var common = 0
            while common < maxCommon, oldNS.character(at: common) == newNS.character(at: common) {
                common += 1
            }
            // 退回到上一个换行符之后：换行可能刚把前一段从左对齐切到两端对齐，
            // 同时也能避开 UTF-16 代理对边界。
            if common > 0 {
                let searchRange = NSRange(location: 0, length: common)
                let prevNewline = oldNS.range(of: "\n", options: .backwards, range: searchRange)
                common = prevNewline.location == NSNotFound ? 0 : prevNewline.location + 1
            }
            let replaceRange = NSRange(location: common, length: oldNS.length - common)
            let replacement = newAttributed.attributedSubstring(
                from: NSRange(location: common, length: newNS.length - common)
            )
            uiView.textStorage.beginEditing()
            uiView.textStorage.replaceCharacters(in: replaceRange, with: replacement)
            uiView.textStorage.endEditing()
        }
        coordinator.appliedText = rendered
        // 只有真的变了才重新测量：每帧都 invalidate 会让 SwiftUI 反复比对高度，
        // 表现为整块文字轻微抖动。
        if changed {
            uiView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        let width = JustifiedText.resolvedProposalWidth(proposal)
        let measured = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: max(1, measured.height))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var appliedText = ""
        var fontSignature = ""
        var window = StreamingTextWindow()
    }

    // MARK: - 排版

    private static func signature(fontSize: CGFloat, lineSpacing: CGFloat) -> String {
        "\(fontSize)-\(lineSpacing)"
    }

    /// 流式期间的排版：Markdown 照常渲染，最后一段先左对齐、落定后再两端对齐。
    private static func attributed(
        _ text: String,
        fontSize: CGFloat,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let paragraphs = WriterTypography.paragraphs(text)
        let result = NSMutableAttributedString()

        for (index, paragraphText) in paragraphs.enumerated() {
            // 最后一段还在变长：先左对齐，落定后再两端对齐。否则每帧都在给
            // 不断变长的行重新分配字距，观感是行内轻微抖动。
            let isLast = index == paragraphs.count - 1
            let style = paragraphStyle(justified: !isLast, lineSpacing: lineSpacing)
            let body: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: UIColor.label,
                .paragraphStyle: style,
            ]

            if index > 0 {
                var separator = body
                separator[.paragraphStyle] = paragraphStyle(
                    justified: !isLast,
                    lineSpacing: lineSpacing
                )
                result.append(NSAttributedString(string: "\n", attributes: separator))
            }

            if let level = MarkdownInline.headingLevel(paragraphText) {
                var heading = body
                heading[.font] = UIFont.systemFont(
                    ofSize: fontSize * Self.headingScale(level),
                    weight: .semibold
                )
                result.append(NSAttributedString(
                    string: MarkdownInline.strippingHeadingMarker(paragraphText),
                    attributes: heading
                ))
            } else {
                for (run, style) in MarkdownInline.runs(paragraphText) {
                    var attributes = body
                    if style != .normal {
                        attributes[.font] = Self.font(size: fontSize, style: style)
                    }
                    result.append(NSAttributedString(string: run, attributes: attributes))
                }
            }
        }
        return result
    }

    private static func paragraphStyle(
        justified: Bool,
        lineSpacing: CGFloat
    ) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = justified ? .justified : .natural
        // pushOut 让断行把整词推出去，而不是靠断词凑长度。
        style.lineBreakStrategy = .pushOut
        style.hyphenationFactor = 0.85
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = lineSpacing * 1.4
        return style
    }

    /// 行内样式对应的字体。
    private static func font(size: CGFloat, style: MarkdownInline.InlineStyle) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: .regular)
        guard let descriptor = base.fontDescriptor.withSymbolicTraits(
            style == .bold ? .traitBold : (style == .italic ? .traitItalic : [])
        ) else { return UIFont.systemFont(ofSize: size, weight: .bold) }
        return UIFont(descriptor: descriptor, size: size)
    }

    /// 标题相对正文的缩放，和完成态气泡保持同一组数字。
    private static func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 1.45
        case 2: return 1.26
        default: return 1.12
        }
    }
}
