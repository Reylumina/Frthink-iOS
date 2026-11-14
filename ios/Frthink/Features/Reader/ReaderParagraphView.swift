// 阅读页段落视图：两端对齐排版与搜索命中背景高亮。

import Foundation
import SwiftUI
import UIKit

/// 正文段落视图：匹配区间高亮显示，排版通过 `JustifiedText`（TextKit）渲染。
struct ReaderParagraphView: View, Equatable {
    /// 本段文本。阅读器只在可见段上按 range 切片，块模型不长期持有整段字符串。
    let text: String
    let fontSize: CGFloat
    let lineHeight: Double
    let darkPage: Bool
    /// 本段内的全部命中，坐标是段内的 UTF-16 相对偏移。
    let highlights: [NSRange]
    /// 当前选中的搜索命中项。
    let current: NSRange?
    /// 章节标题所在段落标识：采用放大字号与加粗字重。
    var isHeading: Bool = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 设置里的字号是基数，实际尺寸跟随 Dynamic Type。
    private var scaledFontSize: CGFloat {
        DynamicTypeFont.bodySize(Double(fontSize), dynamicTypeSize: dynamicTypeSize)
    }

    var body: some View {
        JustifiedText(
            attributed: attributed,
            lineSpacing: ReaderStyle.lineSpacing(size: scaledFontSize, lineHeight: lineHeight),
            // 段间距由外层 LazyVStack 控制，此处不叠加额外边距。
            paragraphSpacing: 0,
            isSelectable: true
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        // 章节标题上方预留额外间距，避免与上一段末尾视觉粘连。
        .padding(.top, isHeading ? Theme.Spacing.l : 0)
    }

    private var attributed: NSAttributedString {
        let base = NSMutableAttributedString(string: text)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        base.addAttributes(
            [
                .font: font,
                .foregroundColor: UIColor(ReaderStyle.ink(dark: darkPage)),
            ],
            range: whole
        )
        for range in highlights.sorted(by: { $0.location < $1.location }) {
            let start = max(0, min(range.location, whole.length))
            let end = max(start, min(range.location + range.length, whole.length))
            guard end > start else { continue }
            base.addAttribute(
                .backgroundColor,
                value: UIColor(ReaderStyle.highlightColor(current: isCurrent(range))),
                range: NSRange(location: start, length: end - start)
            )
        }
        return base
    }

    private var font: UIFont {
        isHeading
            ? .systemFont(ofSize: scaledFontSize * 1.08, weight: .semibold)
            : .systemFont(ofSize: scaledFontSize, weight: .regular)
    }

    private func isCurrent(_ range: NSRange) -> Bool {
        guard let current else { return false }
        return current.location == range.location && current.length == range.length
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
            && lhs.fontSize == rhs.fontSize
            && lhs.lineHeight == rhs.lineHeight
            && lhs.darkPage == rhs.darkPage
            && lhs.highlights == rhs.highlights
            && lhs.current == rhs.current
            && lhs.isHeading == rhs.isHeading
    }
}
