// 流式输出的 UITextView：平时只追加尾部增量，窗口攒满后才整体重置一次。

import SwiftUI
import UIKit

struct StreamingTextView: UIViewRepresentable {
    var text: String
    /// 与「外观 → 正文字号」一致。
    var fontSize: CGFloat = 18


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
        view.attributedText = Self.attributed(rendered, fontSize: fontSize)
        context.coordinator.appliedText = rendered
        context.coordinator.fontSignature = Self.signature(fontSize: fontSize)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        let signature = Self.signature(fontSize: fontSize)
        if coordinator.fontSignature != signature {
            coordinator.fontSignature = signature
            coordinator.window = StreamingTextWindow()
            let rendered = coordinator.window.rendered(text).text
            uiView.attributedText = Self.attributed(rendered, fontSize: fontSize)
            coordinator.appliedText = rendered
            uiView.invalidateIntrinsicContentSize()
            return
        }

        let result = coordinator.window.rendered(text)
        let rendered = result.text
        guard coordinator.appliedText != rendered else { return }

        let old = coordinator.appliedText
        if !result.reset, rendered.hasPrefix(old) {
            let suffix = String(rendered.dropFirst(old.count))
            if !suffix.isEmpty {
                uiView.textStorage.append(Self.attributed(suffix, fontSize: fontSize))
            }
        } else {
            uiView.attributedText = Self.attributed(rendered, fontSize: fontSize)
        }
        coordinator.appliedText = rendered
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

    private static func signature(fontSize: CGFloat) -> String {
        "\(fontSize)"
    }

    private static func attributed(_ text: String, fontSize: CGFloat) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
                .foregroundColor: UIColor.label,
            ]
        )
    }
}
