// 本文件负责：创作页应用级动作的系统撤销入口。
//
// DESIGN §5.8：撤销/重做走系统 `UndoManager`，页面不放常驻的「撤销/重做」按钮；
// 「插入正文」「追加到正文」这类应用级动作也登记进同一套撤销栈，
// iPad 键盘的 ⌘Z / ⇧⌘Z、iPhone 的摇一摇和编辑菜单都能撤回。

import UIKit

/// 一次「插入正文」在系统撤销栈上的代表。
///
/// 撤销用 `ProjectSession` 的插入回执；它只保证「删掉上一次插入」，
/// 没有重做入口，所以重做在 Writer 侧用「位置 + 原文」再插一次。
/// 这里只覆盖插入/追加正文：正文编辑器里逐字编辑的撤销与重做由 UITextView
/// 自己登记在同一个窗口 UndoManager 上，不经过这个类。
///
/// 窗口 `UndoManager` 拿不到时动作照样保留：页面上的「撤销」提示会直接调用
/// 这里，不能让插入变成撤不回去的操作。
///
/// `UndoManager` 只保存 target 的 unowned 引用，调用方必须在页面存活期间
/// 持有这个对象；每次插入在撤销栈上是一个独立对象，避免互相串动作。
@MainActor
final class WriterBodyUndoAction {
    private let undoManager: UndoManager?
    private let session: ProjectSession
    private let store: AppStore
    private let actionName: String

    /// 当前仍在正文里的那一次插入。重做成功后会换成新回执。
    private var receipt: BodyAppendReceipt
    /// 上一次撤销掉的段落，重做时照原位置插回。
    private var undoneReceipt: BodyAppendReceipt?

    init(
        receipt: BodyAppendReceipt,
        actionName: String,
        undoManager: UndoManager?,
        session: ProjectSession,
        store: AppStore
    ) {
        self.receipt = receipt
        self.actionName = actionName
        self.undoManager = undoManager
        self.session = session
        self.store = store
    }

    /// 把这次插入的撤销动作登记进系统栈。拿不到 `UndoManager` 时什么都不做，
    /// 由页面上的「撤销」提示兜底。
    func registerInitialUndo() {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { target in
            target.undo()
        }
        undoManager.setActionName(actionName)
    }

    /// 页面上的「撤销」按钮：有系统栈就走栈（和 ⌘Z 同一条路径，撤销/重做一致），
    /// 没有栈时直接撤回这次插入。
    func undoViaButton() {
        // 先确认这次插入还是栈顶的回执：已经撤过/正文被整段替换时不再动系统栈，
        // 否则会把别的动作（例如编辑器的逐字撤销）当成这次插入撤掉。
        guard session.payload.bodyAppendReceipts.last?.id == receipt.id else {
            store.toast = "没有可撤销的插入"
            return
        }
        if let undoManager {
            undoManager.undo()
        } else {
            _ = removeInsertion()
        }
    }

    /// 撤销：删掉这次插入，并把重做登记进同一个撤销栈。
    func undo() {
        guard removeInsertion() != nil else { return }
        // UndoManager 的语义：撤销过程中登记的 registerUndo 进入重做栈。
        undoManager?.registerUndo(withTarget: self) { target in
            target.redo()
        }
        undoManager?.setActionName(actionName)
    }

    /// 重做：把刚才撤掉的段落插回原位置。
    ///
    /// 插入点由 `ProjectSession` 夹紧到当前正文范围内，用户若已改过正文，
    /// 这一次重做仍按原偏移插回；登记到新的回执上，下一次撤销照常可用。
    func redo() {
        guard let undone = undoneReceipt else { return }
        receipt = session.insertIntoManuscript(undone.text, at: undone.location)
        undoneReceipt = nil
        store.toast = "已重做"
        // 重做过程中登记的 registerUndo 回到撤销栈。
        undoManager?.registerUndo(withTarget: self) { target in
            target.undo()
        }
        undoManager?.setActionName(actionName)
    }

    /// 真正删掉这次插入。只有删成功才提示「已撤销」。
    ///
    /// 没有可撤销的回执、或原位置上的文字已经变了（`undoLastBodyAppend()`
    /// 返回 nil）都如实提示，不当成成功。
    @discardableResult
    private func removeInsertion() -> BodyAppendReceipt? {
        guard session.payload.bodyAppendReceipts.last?.id == receipt.id else {
            store.toast = "没有可撤销的插入"
            return nil
        }
        guard let undone = session.undoLastBodyAppend() else {
            store.toast = "插入位置已被改动，无法撤销"
            return nil
        }
        undoneReceipt = undone
        store.toast = "已撤销"
        return undone
    }
}

enum WriterUndo {
    /// 没有窗口栈时用的兜底栈。
    ///
    /// `UIWindow.undoManager` 只在响应链上有能提供撤销栈的响应者时才非 nil：
    /// 输入框没聚焦（例如刚在气泡上点「插入正文」）、或者页面里没有正在编辑的
    /// 文本视图时，它返回 nil。以前这里直接返回 nil，插入动作于是根本没登记进
    /// 任何栈，页面上的提示四秒后一消失，这件事就再也撤不回来了。
    @MainActor private static let fallback = UndoManager()

    /// 撤销栈：优先窗口栈（和正文编辑器的逐字撤销共用一个），否则用兜底栈。
    @MainActor
    static func manager() -> UndoManager {
        windowManager() ?? fallback
    }

    @MainActor
    private static func windowManager() -> UndoManager? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return (windows.first(where: \.isKeyWindow) ?? windows.first)?.undoManager
    }
}

/// 撤销栈的可观察状态：菜单里的「撤销 / 重做」要跟着栈顶变化刷新。
@MainActor
@Observable
final class WriterUndoState {
    private(set) var canUndo = false
    private(set) var canRedo = false
    private(set) var undoTitle = "撤销"
    private(set) var redoTitle = "重做"

    private let manager: UndoManager
    private var observers: [NSObjectProtocol] = []

    init(manager: UndoManager) {
        self.manager = manager
        let center = NotificationCenter.default
        for name in [
            Notification.Name.NSUndoManagerDidUndoChange,
            Notification.Name.NSUndoManagerDidRedoChange,
            Notification.Name.NSUndoManagerDidCloseUndoGroup,
            Notification.Name.NSUndoManagerWillCloseUndoGroup,
        ] {
            observers.append(center.addObserver(forName: name, object: manager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func refresh() {
        canUndo = manager.canUndo
        canRedo = manager.canRedo
        undoTitle = manager.undoMenuItemTitle
        redoTitle = manager.redoMenuItemTitle
    }

    func undo() {
        manager.undo()
        refresh()
    }

    func redo() {
        manager.redo()
        refresh()
    }
}
