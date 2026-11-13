// 两端对齐的正文渲染。
//
// SwiftUI 的 Text 只有 leading/center/trailing，没有 justify；NSParagraphStyle 的
// .justified 也不被 Text 读取。这里用 UITextView（TextKit）承接排版：对齐、断行策略、
// 中文禁则都由 CoreText 处理，和系统阅读器同一套。

import SwiftUI
import UIKit

/// 一段两端对齐的正文。
///
/// 传入的 `attributed` 只需要带字体与颜色，段落样式在这里统一设置——同一段里
/// 混着两种对齐会很难看。
struct JustifiedText: UIViewRepresentable {
    var attributed: NSAttributedString
    /// 额外行距（字号 × (行高 − 1)）。
    var lineSpacing: CGFloat
    /// 段后间距；0 表示这一段不是最后一段。
    var paragraphSpacing: CGFloat
    var isSelectable = false
    /// 段落结束才对齐：流式最后一段还在变长，先左对齐，避免每帧重排行内字距。
    var alignsLastLine = true

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        configure(view)
        view.attributedText = styled(attributed)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let next = styled(attributed)
        guard !uiView.attributedText.isEqual(to: next) else { return }
        uiView.attributedText = next
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
        let measured = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        return CGSize(width: width, height: max(1, measured.height))
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

    /// 把段落样式整体套到文本上：对齐、断行策略、行距、中文禁则由 CoreText 处理。
    private func styled(_ source: NSAttributedString) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignsLastLine ? .justified : .natural
        // pushOut：断行时尽量把整词推出去，避免靠断词凑长度——这是系统阅读器
        // 让右边看起来整齐而不是「贪心断行」的关键。
        paragraph.lineBreakStrategy = .pushOut
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = paragraphSpacing
        paragraph.hyphenationFactor = 0.85

        let result = NSMutableAttributedString(attributedString: source)
        let whole = NSRange(location: 0, length: result.length)
        result.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        return result
    }
}
