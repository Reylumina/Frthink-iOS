// 流式输出的 UITextView：按段落增量更新，平时只重排最后一个未落定段落，窗口切换时才整体重置。

import SwiftUI
import UIKit

struct StreamingTextView: UIViewRepresentable {
    var text: String
    /// 已增量统计的正文字数，避免流式每帧全串执行 `String.count`。
    var characterCount: Int? = nil
    /// 与「外观 → 正文字号」换算后的实际字号（`WriterTypography.fontSize`）。
    var fontSize: CGFloat
    /// 与完成态气泡共用的行距（`WriterTypography.lineSpacing`）。
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

        let coordinator = context.coordinator
        coordinator.fontSignature = Self.signature(fontSize: fontSize, lineSpacing: lineSpacing)
        let rendered = coordinator.window.rendered(text, characterCount: characterCount).text
        applyFullReset(rendered, to: view, coordinator: coordinator)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        let coordinator = context.coordinator
        let signature = Self.signature(fontSize: fontSize, lineSpacing: lineSpacing)
        if coordinator.fontSignature != signature {
            coordinator.fontSignature = signature
            coordinator.window = StreamingTextWindow()
            let rendered = coordinator.window.rendered(text, characterCount: characterCount).text
            applyFullReset(rendered, to: view(uiView), coordinator: coordinator)
            return
        }

        let rendered = coordinator.window.rendered(text, characterCount: characterCount).text
        guard coordinator.appliedText != rendered else { return }

        let paragraphs = WriterTypography.paragraphs(rendered)
        let completed = paragraphs.count > 1 ? Array(paragraphs.dropLast()) : []
        let trailing = paragraphs.last ?? ""

        let spacing = WriterTypography.paragraphSpacing(size: fontSize, lineHeight: WriterTypography.lineHeight)

        // 快路径：已落定段落前缀完全未变，只替换最后一个正在流式增长的段落，O(末段) 而非 O(全窗口)。
        if completed.count == coordinator.completedParagraphs.count,
           completed == coordinator.completedParagraphs,
           coordinator.completedUTF16Length <= uiView.textStorage.length {
            let replaceRange = NSRange(
                location: coordinator.completedUTF16Length,
                length: uiView.textStorage.length - coordinator.completedUTF16Length
            )
            let tailAttr = WriterTypography.attributedParagraph(
                trailing,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                paragraphSpacing: 0,
                justified: false
            )
            uiView.textStorage.beginEditing()
            uiView.textStorage.replaceCharacters(in: replaceRange, with: tailAttr)
            uiView.textStorage.endEditing()

            coordinator.appliedText = rendered
            coordinator.textRevision += 1
            uiView.invalidateIntrinsicContentSize()
            return
        }

        // 次快路径：新增了已落定段落（刚跨过换行），从公共已落定段落之后增量追加。
        var commonCompleted = 0
        let maxCommon = min(completed.count, coordinator.completedParagraphs.count)
        while commonCompleted < maxCommon,
              completed[commonCompleted] == coordinator.completedParagraphs[commonCompleted] {
            commonCompleted += 1
        }

        if commonCompleted > 0, commonCompleted == coordinator.completedUTF16PrefixEnds.count {
            let prefixEnd = coordinator.completedUTF16PrefixEnds[commonCompleted - 1]
            if prefixEnd <= uiView.textStorage.length {
                let tailBuild = NSMutableAttributedString()
                var newPrefixEnds = coordinator.completedUTF16PrefixEnds
                var runningEnd = prefixEnd

                for idx in commonCompleted..<completed.count {
                    let paraAttr = WriterTypography.attributedParagraph(
                        completed[idx],
                        fontSize: fontSize,
                        lineSpacing: lineSpacing,
                        paragraphSpacing: spacing,
                        justified: true
                    )
                    let sepAttr = WriterTypography.newlineSeparator(
                        fontSize: fontSize,
                        lineSpacing: lineSpacing,
                        paragraphSpacing: spacing,
                        justified: true
                    )
                    tailBuild.append(paraAttr)
                    tailBuild.append(sepAttr)
                    runningEnd += paraAttr.length + sepAttr.length
                    newPrefixEnds.append(runningEnd)
                }

                if !trailing.isEmpty {
                    tailBuild.append(WriterTypography.attributedParagraph(
                        trailing,
                        fontSize: fontSize,
                        lineSpacing: lineSpacing,
                        paragraphSpacing: 0,
                        justified: false
                    ))
                }

                let replaceRange = NSRange(
                    location: prefixEnd,
                    length: uiView.textStorage.length - prefixEnd
                )
                uiView.textStorage.beginEditing()
                uiView.textStorage.replaceCharacters(in: replaceRange, with: tailBuild)
                uiView.textStorage.endEditing()

                coordinator.completedParagraphs = completed
                coordinator.completedUTF16PrefixEnds = newPrefixEnds
                coordinator.completedUTF16Length = runningEnd
                coordinator.appliedText = rendered
                coordinator.textRevision += 1
                uiView.invalidateIntrinsicContentSize()
                return
            }
        }

        // 兜底：窗口截断/重置时全量重建一次。
        applyFullReset(rendered, to: uiView, coordinator: coordinator)
    }

    private func view(_ uiView: UITextView) -> UITextView { uiView }

    private func applyFullReset(
        _ rendered: String,
        to uiView: UITextView,
        coordinator: Coordinator
    ) {
        let paragraphs = WriterTypography.paragraphs(rendered)
        let completed = paragraphs.count > 1 ? Array(paragraphs.dropLast()) : []
        let trailing = paragraphs.last ?? ""
        let spacing = WriterTypography.paragraphSpacing(size: fontSize, lineHeight: WriterTypography.lineHeight)

        let full = NSMutableAttributedString()
        var prefixEnds: [Int] = []
        prefixEnds.reserveCapacity(completed.count)

        for paragraph in completed {
            let paraAttr = WriterTypography.attributedParagraph(
                paragraph,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                paragraphSpacing: spacing,
                justified: true
            )
            let sepAttr = WriterTypography.newlineSeparator(
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                paragraphSpacing: spacing,
                justified: true
            )
            full.append(paraAttr)
            full.append(sepAttr)
            prefixEnds.append(full.length)
        }

        let completedEnd = full.length
        if !trailing.isEmpty {
            full.append(WriterTypography.attributedParagraph(
                trailing,
                fontSize: fontSize,
                lineSpacing: lineSpacing,
                paragraphSpacing: 0,
                justified: false
            ))
        }

        uiView.attributedText = full
        coordinator.completedParagraphs = completed
        coordinator.completedUTF16PrefixEnds = prefixEnds
        coordinator.completedUTF16Length = completedEnd
        coordinator.appliedText = rendered
        coordinator.textRevision += 1
        uiView.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: UITextView,
        context: Context
    ) -> CGSize? {
        let width = JustifiedText.resolvedProposalWidth(proposal)
        let coordinator = context.coordinator
        if coordinator.cachedRevision == coordinator.textRevision,
           abs(coordinator.cachedWidth - width) < 0.5 {
            return CGSize(width: width, height: coordinator.cachedHeight)
        }
        let measured = uiView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        )
        let height = max(1, measured.height)
        coordinator.cachedWidth = width
        coordinator.cachedRevision = coordinator.textRevision
        coordinator.cachedHeight = height
        return CGSize(width: width, height: height)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var appliedText = ""
        var fontSignature = ""
        var window = StreamingTextWindow()
        var completedParagraphs: [String] = []
        var completedUTF16PrefixEnds: [Int] = []
        var completedUTF16Length = 0
        var textRevision = 0
        var cachedWidth: CGFloat = 0
        var cachedRevision = -1
        var cachedHeight: CGFloat = 0
    }

    private static func signature(fontSize: CGFloat, lineSpacing: CGFloat) -> String {
        "\(fontSize)-\(lineSpacing)"
    }
}
