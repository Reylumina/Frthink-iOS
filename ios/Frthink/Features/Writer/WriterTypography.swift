// 本文件负责：创作页正文与气泡的排版换算（DESIGN §2.3、§5.3）。
//
// 流式视图、正式气泡、行宽上限各写一套常量时，只要字号、行距或宽度差一点，
// 生成结束换成正式气泡的那一刻整段高度就会突变，视口按旧高度落点就露出空白。
// 换算只留这一份，三处共用。

import SwiftUI

enum WriterTypography {
    /// 正文行高倍数。§2.3：流式气泡、正文编辑器、阅读页统一 1.6。
    static let lineHeight: Double = 1.6

    /// 用户气泡最多占对话列宽的 80%（§5.3）。
    static let userBubbleWidthRatio: CGFloat = 0.8

    /// 正文字号：外观设置里的基数字号，再按 Dynamic Type 放大。
    static func fontSize(_ baseSize: Double, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        DynamicTypeFont.bodySize(baseSize, dynamicTypeSize: dynamicTypeSize)
    }

    /// 行距换算与阅读页共用 `ReaderStyle`，不另写数值。
    static func lineSpacing(size: CGFloat) -> CGFloat {
        ReaderStyle.lineSpacing(size: size, lineHeight: lineHeight)
    }

    /// 正文栏最大宽度 = 字号 × 36，超出时居中（§2.3、§5.3）。
    static func bodyMaxWidth(size: CGFloat) -> CGFloat {
        ReaderStyle.bodyMaxWidth(size: size)
    }
}
