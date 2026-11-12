// 本文件负责：创作页应用级动作的系统撤销入口。
//
// DESIGN §5.8：撤销/重做走系统 `UndoManager`，页面不放常驻的「撤销/重做」按钮；
// 「插入正文」「追加到正文」这类应用级动作也登记进同一套撤销栈，
// iPad 键盘的 ⌘Z / ⇧⌘Z、iPhone 的摇一摇和编辑菜单都能撤回。

import UIKit

/// `registerUndo(withTarget:handler:)` 的 target 必须是引用类型。
/// 每次登记一个盒子，盒子自己带着那次操作的回滚动作；撤销栈按后进先出取用。
@MainActor
final class WriterUndoTarget {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func perform() {
        action()
    }
}

enum WriterUndo {
    /// 撤销栈挂在窗口上：响应链向上查到 `UIWindow`，它返回可用的实例；
    /// 正文编辑器里 UITextView 的逐字编辑也落在同一份栈上。
    @MainActor
    static func manager() -> UndoManager? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.undoManager
    }
}
