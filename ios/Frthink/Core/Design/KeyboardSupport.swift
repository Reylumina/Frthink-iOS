import SwiftUI

extension View {
    /// 滚动时收起键盘。
    func keyboardDismissOnScroll() -> some View {
        scrollDismissesKeyboard(.interactively)
    }
}
