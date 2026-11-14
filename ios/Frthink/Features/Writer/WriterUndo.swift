// 本文件负责：创作页应用级动作的系统撤销入口。
//
// DESIGN §5.8：撤销/重做走系统 `UndoManager`，页面不放常驻的「撤销/重做」按钮；
// 「插入正文」「追加到正文」这类应用级动作也登记进同一套撤销栈。
//
// 撤销栈有两处来源，优先级不同：
// - 窗口栈：摇一摇、⌘Z、编辑菜单走的就是它。它只在响应链上有能提供栈的响应者
//   （正在编辑的文本视图）时存在，输入框没聚焦时取不到。
// - 兜底栈：无窗口栈时采用私有实例，并在菜单栏提供显式撤销操作入口。

import UIKit

/// 一次「插入正文」在系统撤销栈上的代表。
///
/// 撤销操作通过 `ProjectSession` 插入回执移除文本，重做时基于原位置与内容重新插入。
/// 文本编辑器内部的逐字符编辑撤销由 UITextView 自行管理。
///
/// 兜底栈下同样完整保留撤销动作，确保正文插入操作始终可逆。
///
/// UndoManager 仅持有 target 的 unowned 引用，生命周期内需维持强引用，且每次插入对应独立动作实例。
@MainActor
final class WriterBodyUndoAction {
    private let undoManager: UndoManager
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
        undoManager: UndoManager,
        session: ProjectSession,
        store: AppStore
    ) {
        self.receipt = receipt
        self.actionName = actionName
        self.undoManager = undoManager
        self.session = session
        self.store = store
    }

    /// 把这次插入的撤销动作登记进系统栈（窗口栈或兜底栈，一定有）。
    func registerInitialUndo() {
        undoManager.registerUndo(withTarget: self) { target in
            target.undo()
        }
        undoManager.setActionName(actionName)
    }

    /// 页面上的「撤销」按钮：栈顶正好是这次插入时走系统栈，否则只撤回这次插入。
    func undoViaButton() {
        guard session.payload.bodyAppendReceipts.last?.id == receipt.id else {
            store.toast = "没有可撤销的插入"
            return
        }
        if undoManager.canUndo, undoManager.undoActionName == actionName {
            undoManager.undo()
        } else {
            undoManager.removeAllActions(withTarget: self)
            removeInsertion()
        }
    }

    /// 撤销：删掉这次插入，并把重做登记进同一个撤销栈。
    func undo() {
        guard removeInsertion() != nil else { return }
        // UndoManager 的语义：撤销过程中登记的 registerUndo 进入重做栈。
        undoManager.registerUndo(withTarget: self) { target in
            target.redo()
        }
        undoManager.setActionName(actionName)
    }

    /// 重做：把刚才撤掉的段落插回原位置。
    ///
    /// 插入位置限制在当前正文有效长度内，重做生成新回执以保持后续撤销链条。
    func redo() {
        guard let undone = undoneReceipt else { return }
        receipt = session.insertIntoManuscript(undone.text, at: undone.location)
        undoneReceipt = nil
        store.toast = "已重做"
        // 重做过程中登记的 registerUndo 回到撤销栈。
        undoManager.registerUndo(withTarget: self) { target in
            target.undo()
        }
        undoManager.setActionName(actionName)
    }

    /// 真正删掉这次插入。只有删成功才提示「已撤销」。
    ///
    /// 若无有效回执或原插入位置文本已发生变更，提示对应原因。
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
    /// 响应链无活跃输入响应者时采用兜底撤销栈。
    @MainActor private static let fallback = UndoManager()

    /// 优先获取当前窗口撤销栈，无可用窗口栈时返回兜底栈。
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
    /// 通知令牌。deinit 是非隔离上下文，读这个属性不能让编译器报隔离错误；
    /// 令牌只在主线程写入，removeObserver 本身线程安全。
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
