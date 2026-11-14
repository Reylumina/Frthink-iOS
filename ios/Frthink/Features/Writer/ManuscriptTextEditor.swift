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
    /// 仅在版本号递增时全量同步文本至 UITextView，避免常规输入引发频繁文本比较与光标重置。
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
        // 延迟绑定代理，防止初始化设置触发状态同步回调。
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
                // 切换至编辑模式时自动激活键盘；延迟至下一事件循环以确保编辑属性生效。
                Task { @MainActor in
                    await Task.yield()
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
        /// 输入停止后统一提交文本，避免逐字读取长文本造成主线程卡顿。
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

        /// 外部内容更新前取消挂起的防抖写入任务，避免旧数据回写。
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
            // 仅在选区存在或状态改变时触发回调，降低视图刷新频次。
            let range = textView.selectedRange
            if range.length > 0 || lastSelectionLength > 0 {
                parent.onSelectionChange?(range)
            }
            lastSelectionLength = range.length
            // 只读模式下即时同步光标位置；编辑模式采用 120ms 防抖同步。
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
            // 程序化滚动跳过用户交互标记，避免误识别为手动点击。
            isUpdating = true
            textView.selectedRange = NSRange(location: safe, length: 0)
            isUpdating = false
            textView.scrollRangeToVisible(NSRange(location: safe, length: 0))
        }
    }
}


