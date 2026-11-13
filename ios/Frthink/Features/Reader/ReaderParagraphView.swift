// 本文件负责：阅读页的一个段落 —— 两端对齐排版，并把搜索命中刷上底色。

import Foundation
import SwiftUI
import UIKit

/// 一段正文。命中区间用背景色标出来，排版交给 `JustifiedText`（TextKit）。
struct ReaderParagraphView: View {
    /// 本段文本。阅读器只在可见段上按 range 切片，块模型不长期持有整段字符串。
    let text: String
    let fontSize: CGFloat
    let lineHeight: Double
    let darkPage: Bool
    /// 本段内的全部命中，坐标是段内的 UTF-16 相对偏移。
    let highlights: [NSRange]
    /// 当前跳到的那一处命中。
    let current: NSRange?
    /// 这一段就是章节标题所在的那一块：字号略大、字重更重。
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
            // 段与段之间的距离由外层 LazyVStack 给，这里不再叠段距。
            paragraphSpacing: 0,
            isSelectable: true
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        // 章节标题上方多留一段：段间距对所有块一样时，标题会贴在上一段末尾。
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
}
