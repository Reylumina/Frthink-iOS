// 流式输出的 UITextView：平时只追加尾部增量，窗口攒满后才整体重置一次。

import SwiftUI
import UIKit

struct StreamingTextView: UIViewRepresentable {
    var text: String
    /// 与「外观 → 正文字号」换算后的实际字号（`WriterTypography.fontSize`）。
    var fontSize: CGFloat
    /// 与完成态 `Text` 共用的行距（`WriterTypography.lineSpacing`）。
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

        let result = coordinator.window.rendered(text)
        let rendered = result.text
        guard coordinator.appliedText != rendered else { return }

        if !result.reset, rendered.hasPrefix(coordinator.appliedText) {
            let suffix = String(rendered.dropFirst(coordinator.appliedText.count))
            if !suffix.isEmpty {
                uiView.textStorage.append(Self.attributed(
                    suffix,
                    fontSize: fontSize,
                    lineSpacing: lineSpacing
                ))
            }
        } else {
            uiView.attributedText = Self.attributed(
                rendered,
                fontSize: fontSize,
                lineSpacing: lineSpacing
            )
        }
        coordinator.appliedText = rendered
        // 先让下一次测量拿到新高度，再由 SwiftUI 收这一帧。
        uiView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        let width = proposal.width ?? 320
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

    /// 与完成态气泡同一套段落度量：WriterTypography.paragraphs 拆段、
    /// paragraphSpacing 留白。段落之间用单换行，不再让空行占一整行行高；
    /// 两处用同一份换算，生成结束换成正式气泡时整段高度不变，视口不会跳。
    private static func attributed(
        _ text: String,
        fontSize: CGFloat,
        lineSpacing: CGFloat
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacing = WriterTypography.paragraphSpacing(size: fontSize)
        let normalized = WriterTypography.paragraphs(text).joined(separator: "\n")
        return NSAttributedString(
            string: normalized,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: UIColor.label,
                .paragraphStyle: paragraph,
            ]
        )
    }
}
