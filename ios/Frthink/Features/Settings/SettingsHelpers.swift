import SwiftUI

/// 设置页里字段的小标题。
///
/// 全局函数而不是 view struct，是因为调用点是 `fieldLabel("服务地址")` 这种
/// 直接写在 `VStack` 里的形式，用函数最贴合现有写法。
func fieldLabel(_ text: String) -> some View {
    Text(text)
        .font(Font.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
}
