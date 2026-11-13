// 本文件负责：创作页正文与气泡的排版换算（DESIGN §2.3、§5.3）。
//
// 流式视图、正式气泡、行宽上限各写一套常量时，只要字号、行距或宽度差一点，
// 生成结束换成正式气泡的那一刻整段高度就会突变，视口按旧高度落点就露出空白。
// 换算只留这一份，三处共用。

import SwiftUI

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

    /// 气泡里的段落间距（§2.3）。
    ///
    /// 原来正文用 `\n\n` 表示分段，空行按整行排版，段间实际有 37pt 左右，
    /// 比阅读页的 12pt 松一倍。现在两处统一：气泡按段拆开、段间留这一个距离，
    /// 流式气泡把同样的间距放进段落样式里，换气泡时高度不变。
    /// 段距跟着字号走：行距是 0.6 倍字号，段距要比它明显大一截，
    /// 否则段落和折行看起来一样（0.9 倍在默认字号下约 16pt）。
    static func paragraphSpacing(size: CGFloat) -> CGFloat {
        // 和阅读页同一个 token，不按字号缩放。
        Theme.Layout.paragraphSpacing
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
}
