// 两端对齐的正文渲染。
//
// SwiftUI 的 Text 只有 leading/center/trailing，没有 justify；NSParagraphStyle 的
// .justified 也不被 Text 读取。这里用 UITextView（TextKit）承接排版：对齐、断行策略、
// 中文禁则都由 CoreText 处理，和系统阅读器同一套。

import SwiftUI
import UIKit

/// 一段两端对齐的正文。
///
/// 传入的 `attributed` 仅需包含字体与颜色，段落样式在此处统一配置，避免同一段落内
/// 混合多种对齐方式导致视觉不一致。
struct JustifiedText: UIViewRepresentable {
    var attributed: NSAttributedString
    /// 额外行距（字号 × (行高 − 1)）。
    var lineSpacing: CGFloat
    /// 段后间距；0 表示这一段不是最后一段。
    var paragraphSpacing: CGFloat
    var isSelectable = false
    /// 段落结束才对齐：流式最后一段还在变长，先左对齐，避免每帧重排行内字距。
    var alignsLastLine = true
    /// true 时保留调用方逐段设置的 `.paragraphStyle`。
    var preservesParagraphStyles = false
    /// true 时气泡宽度按实际文本内容收缩（上限仍为提案宽度），用于短文本用户气泡。
    var shrinksToFitWidth = false

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        configure(view)
        view.attributedText = styled(attributed)
        context.coordinator.record(
            attributed: attributed,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            alignsLastLine: alignsLastLine,
            preservesParagraphStyles: preservesParagraphStyles
        )
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        guard !coordinator.matches(
            attributed: attributed,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            alignsLastLine: alignsLastLine,
            preservesParagraphStyles: preservesParagraphStyles
        ) else {
            return
        }
        let next = styled(attributed)
        coordinator.record(
            attributed: attributed,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            alignsLastLine: alignsLastLine,
            preservesParagraphStyles: preservesParagraphStyles
        )
        guard !uiView.attributedText.isEqual(to: next) else { return }
        uiView.attributedText = next
        coordinator.revision += 1
        uiView.invalidateIntrinsicContentSize()
    }

    private static let fallbackProposalWidth: CGFloat = 320

    static func resolvedProposalWidth(_ proposal: ProposedViewSize) -> CGFloat {
        if let proposed = proposal.width, proposed.isFinite, proposed > 0 {
            return proposed
        }
        return fallbackProposalWidth
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        let width = Self.resolvedProposalWidth(proposal)
        let coordinator = context.coordinator
        if coordinator.cachedRevision == coordinator.revision,
           abs(coordinator.cachedWidth - width) < 0.5 {
            let finalWidth = shrinksToFitWidth
                ? min(width, coordinator.cachedMeasuredWidth)
                : width
            return CGSize(width: finalWidth, height: coordinator.cachedHeight)
        }
        let measured = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        let height = max(1, measured.height)
        let measuredWidth = max(1, ceil(measured.width))
        coordinator.cachedWidth = width
        coordinator.cachedRevision = coordinator.revision
        coordinator.cachedHeight = height
        coordinator.cachedMeasuredWidth = measuredWidth
        let finalWidth = shrinksToFitWidth ? min(width, measuredWidth) : width
        return CGSize(width: finalWidth, height: height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var lastInput: NSAttributedString?
        private var lastLineSpacing: CGFloat = -1
        private var lastParagraphSpacing: CGFloat = -1
        private var lastAlignsLastLine = true
        private var lastPreservesParagraphStyles = false
        var revision = 0
        var cachedWidth: CGFloat = 0
        var cachedRevision = -1
        var cachedHeight: CGFloat = 0
        var cachedMeasuredWidth: CGFloat = 0

        func matches(
            attributed: NSAttributedString,
            lineSpacing: CGFloat,
            paragraphSpacing: CGFloat,
            alignsLastLine: Bool,
            preservesParagraphStyles: Bool
        ) -> Bool {
            guard lastLineSpacing == lineSpacing,
                  lastParagraphSpacing == paragraphSpacing,
                  lastAlignsLastLine == alignsLastLine,
                  lastPreservesParagraphStyles == preservesParagraphStyles,
                  let lastInput
            else { return false }
            return lastInput.isEqual(to: attributed)
        }

        func record(
            attributed: NSAttributedString,
            lineSpacing: CGFloat,
            paragraphSpacing: CGFloat,
            alignsLastLine: Bool,
            preservesParagraphStyles: Bool
        ) {
            lastInput = attributed
            lastLineSpacing = lineSpacing
            lastParagraphSpacing = paragraphSpacing
            lastAlignsLastLine = alignsLastLine
            lastPreservesParagraphStyles = preservesParagraphStyles
        }
    }

    private func configure(_ view: UITextView) {
        view.isEditable = false
        view.isScrollEnabled = false
        view.isSelectable = isSelectable
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultHigh, for: .vertical)
    }

    static func paragraphStyle(
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        alignsLastLine: Bool = true
    ) -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignsLastLine ? .justified : .natural
        // pushOut：换行时优先将完整词项推入下一行，避免通过过度断词填充行宽，确保右侧边界对齐规整。
        paragraph.lineBreakStrategy = .pushOut
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = paragraphSpacing
        paragraph.hyphenationFactor = 0.85
        return paragraph
    }

    /// 将段落样式应用至文本：对齐方式、换行策略、行距及中文排版禁则由 CoreText 统一处理。
    private func styled(_ source: NSAttributedString) -> NSAttributedString {
        guard !preservesParagraphStyles else { return source }
        let paragraph = Self.paragraphStyle(
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            alignsLastLine: alignsLastLine
        )
        let result = NSMutableAttributedString(attributedString: source)
        let whole = NSRange(location: 0, length: result.length)
        result.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        return result
    }
}
