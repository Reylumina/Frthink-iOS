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

        let rendered = coordinator.window.rendered(text).text
        guard coordinator.appliedText != rendered else { return }

        // 先算出「整段应有的排版」，再只替换和屏幕上不同的那一段。
        //
        // 原来靠「原始文本前缀相等」判断能不能追加：屏幕上放的其实是归一化后的
        // 文本（段落合并、去掉标记），两者对不上，下一批就接错位置。现在按显示串
        // 求公共前缀，公共部分不动，只重排尾部——通常只有最后一段。
        let newAttributed = Self.attributed(
            rendered,
            fontSize: fontSize,
            lineSpacing: lineSpacing
        )
        let oldString = uiView.attributedText?.string ?? "" as String
        let newString = newAttributed.string
        if oldString != newString {
            let oldNS = oldString as NSString
            let newNS = newString as NSString
            let maxCommon = min(oldNS.length, newNS.length)
            var common = 0
            while common < maxCommon, oldNS.character(at: common) == newNS.character(at: common) {
                common += 1
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

        let body: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph,
        ]

        // 逐段排版：一到三级标题按字号和字重区分，行首的 # 去掉。
        // 和完成态气泡用同一组缩放（1.45 / 1.26 / 1.12），换气泡时高度不跳。
        let paragraphs = WriterTypography.paragraphs(text)
        let result = NSMutableAttributedString()
        for (index, paragraphText) in paragraphs.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "\n", attributes: body))
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
                for (run, isBold) in Self.inlineRuns(paragraphText) {
                    var attributes = body
                    if isBold {
                        attributes[.font] = UIFont.systemFont(ofSize: fontSize, weight: .bold)
                    }
                    result.append(NSAttributedString(string: run, attributes: attributes))
                }
            }
        }
        return result
    }

    /// 把一段按 `**` 切成普通/加粗两种 run，标记本身不显示。
    ///
    /// 生成中就按这个排版，用户不用等到结束才看到加粗。
    private static func inlineRuns(_ text: String) -> [(String, Bool)] {
        guard text.contains("**") else { return [(text, false)] }
        var runs: [(String, Bool)] = []
        var buffer = ""
        var isBold = false
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("**") {
                if !buffer.isEmpty {
                    runs.append((buffer, isBold))
                    buffer = ""
                }
                isBold.toggle()
                index = text.index(index, offsetBy: 2)
            } else {
                buffer.append(text[index])
                index = text.index(after: index)
            }
        }
        if !buffer.isEmpty {
            runs.append((buffer, isBold))
        }
        // 奇数个标记：最后一个没有配对，按普通文本渲染，别把标记吞掉当加粗。
        if isBold {
            runs.append(("**", false))
        }
        return runs
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
