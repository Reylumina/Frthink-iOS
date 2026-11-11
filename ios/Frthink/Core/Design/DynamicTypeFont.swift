// 正文与气泡的字号缩放。
//
// 「外观」里的字号是基数（默认 18pt，13–28 可调），实际显示尺寸还要跟随系统
// Dynamic Type。固定 `.system(size:)` 在辅助功能大字号下不会变大，正文和气泡
// 就永远停在用户选的基数上。

import SwiftUI
import UIKit

enum DynamicTypeFont {
    /// 把设置里的字号基数按指定 Dynamic Type 档位缩放。
    static func bodySize(_ base: Double, dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(
            preferredContentSizeCategory: dynamicTypeSize.contentSizeCategory
        )
        return UIFontMetrics(forTextStyle: .body).scaledValue(
            for: CGFloat(max(1, base)),
            compatibleWith: traits
        )
    }
}

extension DynamicTypeSize {
    /// SwiftUI 的档位和 UIKit 的内容尺寸分类没有公开的双向映射。
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

extension View {
    /// 正文/气泡字号：设置值是基数，再按 Dynamic Type 放大。
    func dynamicBodyFont(_ baseSize: Double) -> some View {
        modifier(DynamicBodyFontModifier(baseSize: baseSize))
    }
}

struct DynamicBodyFontModifier: ViewModifier {
    let baseSize: Double

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.font(.system(size: DynamicTypeFont.bodySize(
            baseSize,
            dynamicTypeSize: dynamicTypeSize
        )))
    }
}
