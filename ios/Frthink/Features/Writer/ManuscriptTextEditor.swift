// 本文件负责：正文编辑区 —— 一个拿到真实光标位置、能按字符偏移滚动的 UITextView 包装。

import SwiftUI
import UIKit

/// 章节跳转请求。
///
/// 用 UUID 而不是裸的偏移量：同一章节连点两次，偏移没变，SwiftUI 不会重画，
/// 滚动就不会发生。每次请求都是一个新的 id。
struct ManuscriptScrollRequest: Equatable {
    let id = UUID()
    let location: Int
}

/// 正文编辑器。
///
/// 用 UITextView 而不是 SwiftUI 的 `TextEditor`，是为了拿到真实光标偏移（「插入正文」
/// 的落点）和按 UTF-16 偏移滚动（章节跳转）。文本通过窗口编辑页的 `session.updateEditorText`
/// 双向同步，只写光标所在的那一段。
struct ManuscriptTextEditor: UIViewRepresentable {

    /// 当前窗口的正文文本（由外部接到 `session.updateEditorText`）。
    @Binding var text: String

    /// 光标的 UTF-16 偏移。负数表示还没拿到（初始状态），此时按末尾处理。
    @Binding var cursor: Int

    /// 非 nil 时滚到指定偏移，并把光标放在那里。
    var scrollRequest: ManuscriptScrollRequest?

    /// 正文字号，来自「外观」设置（`AppSettings.bodyFontSize`）。
    var fontSize: CGFloat = 18

    /// 正文被外部改动过的次数（`ProjectSession.manuscriptRevision`）。
    ///
    /// 只有这个数字变了才把整段文字回灌给 UITextView。逐字编辑时数字不变，
    /// 免掉每次重绘都拿 56 万字做一次 `String ==`、还顺手重置光标。
    var revision: Int = 0

    /// 阅读模式传 false：不弹键盘、不触发编辑回调，但仍可滚动与选择插入位置。
    var isEditable: Bool = true

    /// 用户亲手点过正文/挪过光标时回调；用来区分「默认文末」和「明确插入点」。
    var onCursorInteraction: (() -> Void)? = nil

    /// 选区变化（读写都回调）。改写条在选区非空时出现。
    var onSelectionChange: ((NSRange) -> Void)? = nil

    /// 把 UITextView 自己的撤销栈交出去：编辑页的 ⋯ 菜单要用它显示「撤销 / 重做」。
    /// 逐字编辑的撤销本来就登记在这份栈上，不需要再造一个。
    var onUndoManagerReady: ((UndoManager?) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = Self.manuscriptFont(ofSize: fontSize)
        view.backgroundColor = .clear
        view.textColor = UIColor.label
        view.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 20, right: 8)
        view.textContainer.lineFragmentPadding = 4
        view.alwaysBounceVertical = true
        view.keyboardDismissMode = .interactive
        view.isEditable = isEditable
        view.isSelectable = true
        view.text = text
        // 打开书稿时光标落在末尾：写作时继续往下写的概率最高。
        let end = (text as NSString).length
        view.selectedRange = NSRange(location: end, length: 0)
        context.coordinator.appliedRevision = revision
        // 委托最后挂：上面这些初始设置不该回调进 SwiftUI 的状态。
        view.delegate = context.coordinator
        context.coordinator.reportUndoManagerIfNeeded(view.undoManager)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        // 视图重建后委托手里还握着旧的 Binding，每次都换新。
        context.coordinator.parent = self
        context.coordinator.reportUndoManagerIfNeeded(uiView.undoManager)

        if uiView.isEditable != isEditable {
            uiView.isEditable = isEditable
            if !isEditable {
                uiView.resignFirstResponder()
            } else {
                // 从阅读切到编辑时直接弹键盘，少一次“再点一下正文”的动作。
                // 放到下一轮 runloop，等 isEditable 生效后再成为 first responder。
                DispatchQueue.main.async {
                    guard uiView.isEditable, uiView.window != nil else { return }
                    uiView.becomeFirstResponder()
                }
            }
        }

        // 「外观」里的字号改了就跟着改，不用重进页面。
        if uiView.font?.pointSize != fontSize {
            uiView.font = Self.manuscriptFont(ofSize: fontSize)
        }

        // 只有外部改动（插入正文 / 撤销 / 导入正文）才回灌文字。
        if context.coordinator.appliedRevision != revision {
            // 外部替换会覆盖编辑器里的内容，挂起的旧文本提交必须先取消。
            context.coordinator.cancelPendingWrites()
            // 这里改文字/选区会同步回调 delegate，回调里不能反过来改 SwiftUI 状态。
            context.coordinator.isUpdating = true
            context.coordinator.appliedRevision = revision
            uiView.text = text
            let length = (text as NSString).length
            let safe = cursor < 0 ? length : min(cursor, length)
            uiView.selectedRange = NSRange(location: safe, length: 0)
            context.coordinator.isUpdating = false
        }

        // 章节跳转只滚位置，不动文字，所以放在 revision 判断之外。
        if let request = scrollRequest, request.id != context.coordinator.lastScrollID {
            context.coordinator.lastScrollID = request.id
            context.coordinator.scroll(uiView, to: request.location)
        }
    }

    private static func manuscriptFont(ofSize size: CGFloat) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: .regular)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ManuscriptTextEditor
        var lastScrollID: UUID?
        /// `updateUIView` 正在改控件：这段时间内的选区回调不能写回 SwiftUI 状态。
        var isUpdating = false
        /// 已经回灌给 UITextView 的外部改动版本。
        var appliedRevision = -1
        /// 上一次回调过的选区长度；用来区分「光标移动」和「选区变化」。
        var lastSelectionLength = 0
        /// 正文提交防抖：停止输入 400ms 才把整串交给 session。
        ///
        /// 56 万字的书，每敲一个键都 `textView.text` 取一次整串 + 让 SwiftUI
        /// 重算整页，输入法必然掉帧。这里只让 UITextView 自己刷新，停手再提交。
        private var pendingCommit: Task<Void, Never>?
        /// 光标同步防抖。章节高亮/插入位置的精度 120ms 足够。
        private var pendingCursor: Task<Void, Never>?
        /// 是否有还没提交给 session 的输入。没有就不必重复提交同一份文本。
        private var hasPendingText = false
        private weak var lastReportedUndoManager: UndoManager?

        init(_ parent: ManuscriptTextEditor) {
            self.parent = parent
            super.init()
        }

        func reportUndoManagerIfNeeded(_ manager: UndoManager?) {
            guard let manager, manager !== lastReportedUndoManager else { return }
            lastReportedUndoManager = manager
            parent.onUndoManagerReady?(manager)
        }

        /// 外部替换文字前取消挂起的提交，免得把旧文字又写回去。
        func cancelPendingWrites() {
            pendingCommit?.cancel()
            pendingCommit = nil
            pendingCursor?.cancel()
            pendingCursor = nil
            hasPendingText = false
        }

        private func commitText(from textView: UITextView) {
            guard hasPendingText else { return }
            hasPendingText = false
            // 不做整串比较：这里是 56 万字的正文，比较本身就要遍历一遍。
            parent.text = textView.text ?? ""
        }

        private func commitCursor(from textView: UITextView) {
            let location = textView.selectedRange.location
            if parent.cursor != location {
                parent.cursor = location
            }
        }

        func textViewDidChange(_ textView: UITextView) {
            hasPendingText = true
            pendingCommit?.cancel()
            let delay = Duration.milliseconds(400)
            pendingCommit = Task { @MainActor [weak self, weak textView] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, let textView else { return }
                self.commitText(from: textView)
                self.pendingCommit = nil
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            // 收起键盘/离开页面时立刻提交，绝不把最后 400ms 的输入丢掉。
            pendingCommit?.cancel()
            pendingCommit = nil
            commitText(from: textView)
            pendingCursor?.cancel()
            pendingCursor = nil
            commitCursor(from: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isUpdating else { return }
            // 只在有选区（或刚从有选区变为无选区）时回调，避免每敲一个字
            // 都把阅读页重建一次。
            let range = textView.selectedRange
            if range.length > 0 || lastSelectionLength > 0 {
                parent.onSelectionChange?(range)
            }
            lastSelectionLength = range.length
            // 只读正文没有输入成本，光标必须立刻写回；否则「点正文再点插入」
            // 会拿到 120ms 前的旧位置。编辑态仍保留防抖，避免每挪一下光标
            // 都让写作台重算。
            parent.onCursorInteraction?()
            if !parent.isEditable {
                let location = textView.selectedRange.location
                if parent.cursor != location {
                    parent.cursor = location
                }
                return
            }
            pendingCursor?.cancel()
            let delay = Duration.milliseconds(120)
            pendingCursor = Task { @MainActor [weak self, weak textView] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, let textView else { return }
                self.commitCursor(from: textView)
                self.pendingCursor = nil
            }
        }

        func scroll(_ textView: UITextView, to location: Int) {
            let length = (textView.text as NSString).length
            let safe = min(max(location, 0), length)
            // 程序性滚动/章节跳转也会改选区，别让它被当成“用户亲手放置光标”。
            isUpdating = true
            textView.selectedRange = NSRange(location: safe, length: 0)
            isUpdating = false
            textView.scrollRangeToVisible(NSRange(location: safe, length: 0))
        }
    }
}


