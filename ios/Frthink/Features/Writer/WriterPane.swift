// 本文件负责：码字机 —— ChatBot 单栏对话 + 全屏正文。
//
// 界面采用对话优先布局，底部常驻输入条；正文承载于独立全屏页面，保障移动端横向展示空间。

import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct WriterPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 减弱动态效果：位移/缩放退化成直接落位（§4.1、§5.6）。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let session: ProjectSession
    /// 页面撤销栈：优先采用窗口编辑撤销栈，回退至全局栈，确保插入与追加操作可逆。
    private let undoManager: UndoManager

    @State private var controller = WriterController()
    /// 输入框文本与焦点都在子视图里，打字不触发整页重算。
    @State private var composer = WriterComposerModel()
    /// 应用级撤销动作（`UndoManager` 只保存 unowned target），由这里登记与清理。
    @State private var undoActions: [WriterBodyUndoAction] = []
    /// 撤销栈的菜单状态：栈顶变了，⋯ 里的「撤销 / 重做」跟着变。
    @State private var undoState: WriterUndoState
    /// 针对正文插入与追加等可撤销操作展示的专用操作反馈条。
    @State private var undoPrompt: WriterUndoPrompt?
    /// 底部控制条（输入栏或多选栏）的测量高度。
    @State private var bottomBarHeight: CGFloat = 0
    /// 对话列的实际宽度，用来算用户气泡 80% 的宽度上限（§5.3）。
    @State private var columnWidth: CGFloat = 0
    /// 标记对话内容高度是否超出可视区域，用于切换对齐布局策略。
    @State private var contentOverflowsViewport = true
    @State private var scrollAnchorMetrics = ScrollAnchorMetrics()
    /// 光标的 UTF-16 偏移。负数表示还没拿到（初始状态），插入正文时按末尾处理。
    @State private var cursorOffset = -1
    /// 记录用户是否明确指定过正文插入位置。
    @State private var cursorPlaced = false
    /// 对话只渲染最近 N 条；更早的按原版「加载更早的对话」补。
    @State private var visibleMessageCount = 15
    @State private var budgetPresented = false
    @State private var activeSheet: WriterSheet?
    @State private var isImportingBody = false
    @State private var isExportingBody = false
    @State private var bodyExportDocument = PlainTextFileDocument()
    @State private var bodyExportFilename = "正文.txt"
    @State private var pendingBodyImport: PendingBodyImport?
    /// 消息气泡追加、清理与删除复用单一确认弹窗容器。
    @State private var messageAction: MessageAction?
    /// 视口是否处于列表底部；上滑查看历史时暂停自动跟随滚动。
    @State private var isAtBottom = true
    /// 生成完成后的布局稳定过渡窗口。
    @State private var isSettling = false
    /// 列表内容高度缩减时触发强制回滚到底部。
    @State private var forceScrollToBottom = false
    /// 多选删除：条目选择态、选中的消息 id。
    @State private var selectionMode = false
    @State private var selectedMessageIDs: Set<String> = []
    #if DEBUG
    @State private var didMockSend = false
    #endif

    @MainActor
    init(session: ProjectSession) {
        self.session = session
        let manager = WriterUndo.manager()
        self.undoManager = manager
        _undoState = State(initialValue: WriterUndoState(manager: manager))
    }

    private enum WriterSheet: String, Identifiable {
        case manuscript
        case materials
        case snapshots
        case bodyRange

        var id: String { rawValue }
    }

    /// 已经读进内存、等着确认替换正文的文件。
    struct PendingBodyImport: Identifiable, Hashable {
        let id = UUID()
        let filename: String
        let text: String

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// 带「撤销」的轻提示。一次只显示一条，几秒后自动消失。
    fileprivate struct WriterUndoPrompt: Identifiable {
        let id = UUID()
        let text: String
        let action: () -> Void
    }

    private enum MessageAction: Identifiable {
        case append(ChatMessage)
        case rollback(ChatMessage)
        case cleanup(ChatMessage)
        case delete(ChatMessage)
        case deleteMessage(ChatMessage)
        case deleteSelected(Int)
        case clearAll

        var id: String {
            switch self {
            case .append(let message): return "append-\(message.id)"
            case .rollback(let message): return "rollback-\(message.id)"
            case .cleanup(let message): return "cleanup-\(message.id)"
            case .delete(let message): return "delete-\(message.id)"
            case .deleteMessage(let message): return "delete-message-\(message.id)"
            case .deleteSelected(let count): return "delete-selected-\(count)"
            case .clearAll: return "clear-all"
            }
        }

        var title: String {
            switch self {
            case .append: return "追加到正文？"
            case .rollback: return "回退到此指令"
            case .cleanup: return "清理历史版本？"
            case .delete: return "删除当前版本？"
            case .deleteMessage: return "删除消息？"
            case .deleteSelected(let count): return "删除 \(count) 条消息？"
            case .clearAll: return "清空聊天记录？"
            }
        }

        var confirmTitle: String {
            switch self {
            case .append: return "追加"
            case .rollback: return "回退"
            case .cleanup, .delete, .deleteMessage, .deleteSelected: return "删除"
            case .clearAll: return "清空"
            }
        }

        var confirmRole: ButtonRole? {
            switch self {
            case .append: return nil
            case .rollback, .cleanup, .delete, .deleteMessage, .deleteSelected, .clearAll:
                return .destructive
            }
        }

        var messageText: String {
            switch self {
            case .append:
                return "把当前展示的版本追加到正文末尾。追加后可撤销。"
            case .rollback:
                return "把该指令恢复到输入框并删除其后的对话分支。"
            case .cleanup:
                return "只保留当前展示的版本，其余版本会被删除且无法恢复。"
            case .delete(let message):
                if message.variants.count <= 1 {
                    return "当前气泡仅有一个版本，删除后将彻底移除且无法恢复。"
                }
                return "只删除当前展示的第 \(message.selectedVariant + 1) 版，其余 \(message.variants.count - 1) 个版本保留。"
            case .deleteMessage:
                return "删除后，此消息及其在会话中的记录将被移除，正文不受影响。"
            case .deleteSelected:
                return "删除后，这些消息以及它们在会话里的位置都会消失，正文不受影响，且无法恢复。"
            case .clearAll:
                return "会删除码字机里的所有用户指令和回复，正文不受影响，且无法撤销。"
            }
        }
    }

    var body: some View {
        chatList
            // 采用导航推入页进行确认，避免与系统文件选取器收起时的模态转场冲突。
            .navigationDestination(item: $pendingBodyImport) { pending in
                BodyImportConfirmPage(pending: pending) {
                    performBodyImport(pending)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        updateBottomBarHeight(height)
                    }
            }
            // 撤销提示条以浮层展示于输入条上方，不影响对话内容高度。
            .overlay(alignment: .bottom) {
                undoPromptOverlay
            }
            .themeAnimation(Theme.motionLayout, value: undoPrompt?.id)
            .onChange(of: controller.isGenerating) { _, active in
                if active { exitSelection() }
            }
            .onChange(of: controller.instructionToRestore) { _, _ in
                // 裁剪重试未成功时，将原指令还原至输入框。
                guard let text = controller.consumeInstructionToRestore() else { return }
                composer.text = text
            }
            .sensoryFeedback(.impact(weight: .light), trigger: controller.isGenerating) { _, _ in store.settings.hapticsEnabled }
            .sensoryFeedback(.success, trigger: session.payload.bodyAppendReceipts.count) { _, _ in store.settings.hapticsEnabled }
            .toolbar { writerToolbar }
            .pageBackground()
            .onChange(of: controller.budgetAlert?.id) { _, newValue in
                budgetPresented = newValue != nil
            }
            .alert(
                messageAction?.title ?? "确认操作",
                isPresented: messageActionBinding
            ) {
                if let action = messageAction {
                    Button(action.confirmTitle, role: action.confirmRole) {
                        performMessageAction(action)
                    }
                }
                Button("取消", role: .cancel) { messageAction = nil }
            }
            .sheet(item: $activeSheet, onDismiss: sheetDidDismiss) { sheet in
                sheetContent(for: sheet)
            }
            .fileImporter(
                isPresented: $isImportingBody,
                allowedContentTypes: [.plainText, .text],
                allowsMultipleSelection: false
            ) { result in
                handleBodyImport(result)
            }
            .fileExporter(
                isPresented: $isExportingBody,
                document: bodyExportDocument,
                contentType: .plainText,
                defaultFilename: bodyExportFilename
            ) { result in
                switch result {
                case .success:
                    store.toast = "已导出正文"
                case .failure(let error):
                    guard !settingsIsUserCancelled(error) else { return }
                    store.errorMessage = "导出正文失败：\(error.localizedDescription)"
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // 切换至后台时立即持久化增量文本检查点。
                if phase == .background {
                    controller.checkpoint(session: session)
                }
            }
            .onAppear(perform: handleAppear)
            .onDisappear(perform: handleDisappear)
    }

    @ToolbarContentBuilder
    private var writerToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            modelMenu
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                openSheet(.manuscript)
            } label: {
                Image(systemName: "doc.text")
            }
            .disabled(controller.isBusy)
            .accessibilityLabel("正文")

            Menu {
                writerMenu
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("更多写作操作")
        }
    }

    private func handleAppear() {
        if composer.text.isEmpty, !session.payload.composerDraft.isEmpty {
            composer.text = session.payload.composerDraft
        }
        session.refreshDerivedValues()
        if cursorOffset < 0 {
            cursorOffset = session.manuscriptLength
            cursorPlaced = false
        }

        #if DEBUG
        if LaunchArguments.writerFocus == "manuscript" {
            // 延迟呈现正文视图，等待首帧布局渲染完毕。
            Task { @MainActor in
                await Task.yield()
                openSheet(.manuscript)
            }
        }
        if LaunchArguments.streamPreview {
            let message = session.beginAssistantMessage(model: "stream-preview")
            let preview = """
            林昭把梯子挪到最里侧的书架前。灰尘在手电的光柱里浮着，像静止的雪。

            ninety-two 年的那批书堆在最底层，纸页边缘已经发脆。她抽出第三本的时候，有什么东西从书页间滑了出来，轻飘飘地落在她脚边。

            是一封信。信封上写着地址，邮票还在，却从来没有盖过邮戳。

            「这个……」她把信捡起来，指尖有点抖。窗外的雨声突然变得很远，整间书店像是被谁按下了静音键。
            """
            controller.debugStartPreview(text: preview, messageID: message.id)
        }
        if LaunchArguments.mockStream, LaunchArguments.mockAutoSend, !didMockSend {
            didMockSend = true
            Task { @MainActor in
                await Task.yield()
                _ = controller.send(
                    "写一段雨夜旧书店的正文，让林昭发现一封信。",
                    session: session,
                    store: store
                )
            }
        }
        #endif
    }

    private func handleDisappear() {
        dismissKeyboard()
        controller.checkpoint(session: session)

        // 校验活跃项目标识：仅在切换书稿时释放旧任务与撤销栈，Tab 切换与内存警告均保留活跃状态。
        let projectID = session.project.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let stillActive = UserDefaults.standard.string(forKey: RootView.activeProjectKey) == projectID
            guard !stillActive else { return }
            discardUndoActions()
            if controller.isBusy {
                controller.stop()
            }
        }
    }

    // MARK: - 顶栏

    @ViewBuilder
    private var writerMenu: some View {
        // 菜单内常驻撤销与重做操作入口。
        Button {
            undoState.undo()
        } label: {
            Label(undoState.undoTitle, systemImage: "arrow.uturn.backward")
        }
        .disabled(!undoState.canUndo)

        Button {
            undoState.redo()
        } label: {
            Label(undoState.redoTitle, systemImage: "arrow.uturn.forward")
        }
        .disabled(!undoState.canRedo)

        Divider()

        Button {
            openSheet(.snapshots)
        } label: {
            Label("提示词回看", systemImage: "text.magnifyingglass")
        }
        Button {
            openSheet(.materials)
        } label: {
            Label("写作资料", systemImage: "book.closed")
        }
        Button {
            openSheet(.bodyRange)
        } label: {
            Label("正文发送范围…", systemImage: "text.alignleft")
        }
        // 多选操作模式入口。
        Button {
            if let last = windowedMessages.last {
                beginSelection(last.id)
            }
        } label: {
            Label("多选消息", systemImage: "checklist")
        }
        .disabled(controller.isBusy || session.payload.messages.isEmpty)

        Divider()

        Button {
            dismissKeyboard()
            // 延迟调用文件选择器，确保当前菜单收起转场完毕。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(350))
                isImportingBody = true
            }
        } label: {
            Label("导入正文…", systemImage: "square.and.arrow.down")
        }
        .disabled(controller.isBusy)

        Button {
            prepareBodyExport()
        } label: {
            Label("导出正文…", systemImage: "square.and.arrow.up")
        }
        .disabled(controller.isBusy || session.manuscriptCharacterCount == 0)

        Divider()

        if session.payload.continuationAnchor == nil {
            Button {
                setAnchor()
            } label: {
                Label("放置续写锚", systemImage: "bookmark")
            }
            .disabled(controller.isBusy || cursorOffset < 0)
        } else {
            Button {
                clearAnchor()
            } label: {
                Label("取消续写锚点", systemImage: "bookmark.slash")
            }
            .disabled(controller.isBusy)
        }
    }

    // MARK: - 对话

    private var windowedMessages: [ChatMessage] {
        Array(session.payload.messages.suffix(visibleMessageCount))
    }

    /// 已经加载出来的消息 id。多选只作用于这一批，隐藏的历史不进选择集。
    private var selectableMessageIDs: Set<String> {
        Set(windowedMessages.map(\.id))
    }

    private final class ScrollAnchorMetrics {
        var contentHeight: CGFloat = .greatestFiniteMagnitude
        var viewportHeight: CGFloat = 0
    }

    /// 首帧锚点：内容比视口短时从顶部排（不把内容压在底部），长了才锚底。
    private var scrollAnchor: UnitPoint? {
        guard contentOverflowsViewport else { return nil }
        return isAtBottom && !session.payload.messages.isEmpty ? .bottom : nil
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 采用 VStack 承载已按窗口截断的消息列表，确保动态高度计算精确。
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    if session.payload.messages.count > visibleMessageCount {
                        Button("加载更早的对话") {
                            visibleMessageCount += 30
                        }
                        .font(Font.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.s)
                    }

                    if session.payload.messages.isEmpty {
                        chatEmptyState
                    } else {
                        ForEach(windowedMessages) { message in
                            messageRow(for: message)
                        }
                    }

                    bottomAnchor
                }
                // 对话列宽上限 720（§5.3）；正文栏在行内再按「字号 × 36」收窄。
                .frame(maxWidth: Theme.Layout.chatMaxWidth)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    updateColumnWidth(width)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    scrollAnchorMetrics.contentHeight = height
                    let overflows = height >= scrollAnchorMetrics.viewportHeight
                    if overflows != contentOverflowsViewport {
                        contentOverflowsViewport = overflows
                    }
                }
            }
            // 初始通过 defaultScrollAnchor 对齐底部，手动滚动后移除锚点以避免干扰用户浏览。
            .defaultScrollAnchor(scrollAnchor)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                scrollAnchorMetrics.viewportHeight = height
                let overflows = scrollAnchorMetrics.contentHeight >= height
                if overflows != contentOverflowsViewport {
                    contentOverflowsViewport = overflows
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            // iOS 26 的滚动边缘柔化；更早的系统由 Theme 回落成无操作（§5.2）。
            .softScrollEdge()
            .minimizeTabBarOnScroll()
            .simultaneousGesture(
                DragGesture(minimumDistance: 10).onChanged { value in
                    // 检测到下拉手势时取消底部跟随状态，保持当前浏览位置。
                    if value.translation.height > 10, isAtBottom {
                        isAtBottom = false
                    }
                }
            )
            // 跟随器单独成视图：它只读合帧后的 displayTick，
            // 不会让整列气泡跟着高频重算（PERFORMANCE.md §2.1）。
            .background {
                WriterStreamingFollower(
                    controller: controller,
                    proxy: proxy,
                    isAtBottom: isAtBottom
                )
            }
            .onAppear {
                // 进页落底：首帧位置由 defaultScrollAnchor(.bottom) 给出，
                // 这里等一轮布局后再对齐一次，不在布局前按估算行高算偏移。
                // 动画统一走 motionLayout；减弱动态效果时直接落位。
                Task { @MainActor in
                    await Task.yield()
                    scrollToBottom(
                        proxy,
                        animation: Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)
                    )
                }
            }
            .onChange(of: session.payload.messages.count) { oldCount, newCount in
                // 消息列表窗口滚动时裁剪已选择集合，保持与可见行一致。
                if !selectedMessageIDs.isEmpty {
                    selectedMessageIDs = WriterSelection.pruning(
                        selectedMessageIDs,
                        visible: selectableMessageIDs
                    )
                }
                // 删除/回退会让内容变短，停在原偏移就会露出大片空白；变短时一律回到底部。
                let shouldFollow = forceScrollToBottom || isAtBottom || newCount < oldCount
                forceScrollToBottom = false
                guard shouldFollow else { return }
                isAtBottom = true
                // 用户发出消息是直接操作的结果（emphasis）；助手占位、删除等
                // 属于列表布局变化（layout）。一屏只留一个 emphasis（§4.1）。
                let sentByUser = newCount > oldCount
                    && session.payload.messages.last?.role == .user
                let animation = sentByUser ? Theme.motionEmphasis : Theme.motionLayout
                scrollToBottom(
                    proxy,
                    animation: Theme.motion(animation, reduceMotion: reduceMotion)
                )
            }
            .onChange(of: controller.isGenerating) { _, active in
                guard active else { return }
                isAtBottom = true
                scrollToBottom(
                    proxy,
                    animation: Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)
                )
            }
            .onChange(of: controller.streamingMessageID) { _, messageID in
                // 生成结束：流式气泡换成正式气泡，整段按全文重新排版。
                // 只跟着还在底部的用户落底；已经上滑看历史时保持位置，
                // 让「回到最新」按钮出现就行（§5.9）。
                guard messageID == nil else { return }
                guard isAtBottom else { return }
                settleAtBottom(proxy)
            }
            .overlay(alignment: .bottom) {
                jumpToLatestOverlay(proxy)
                    .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func jumpToLatestOverlay(_ proxy: ScrollViewProxy) -> some View {
        // 只在离开底部时出现；水平居中悬浮的玻璃圆形按钮，不与右下角发送键同列撞形。
        ZStack {
            if !isAtBottom {
                FloatingGlassButton(
                    symbol: "chevron.down",
                    label: "回到最新"
                ) {
                    isAtBottom = true
                    forceJumpToBottom(proxy)
                }
                .padding(.bottom, Theme.Spacing.s)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
            }
        }
        .themeAnimation(Theme.motionLayout, value: isAtBottom)
    }

    private func updateColumnWidth(_ width: CGFloat) {
        guard width > 0, width != columnWidth else { return }
        columnWidth = width
    }

    /// 测量并更新底部输入条高度。
    private func updateBottomBarHeight(_ height: CGFloat) {
        guard height > 0, height != bottomBarHeight else { return }
        bottomBarHeight = height
    }

    /// 插入/追加成功后显示带「撤销」的轻提示（§4.3）。
    private func presentUndoPrompt(_ text: String, undo: @escaping () -> Void) {
        undoPrompt = WriterUndoPrompt(text: text, action: undo)
    }

    @ViewBuilder
    private var undoPromptOverlay: some View {
        if let prompt = undoPrompt {
            undoPromptView(prompt)
                .glassStack()
                .padding(.bottom, bottomBarHeight + Theme.Spacing.s)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
                .task(id: prompt.id) {
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled else { return }
                    undoPrompt = nil
                }
        }
    }

    private func undoPromptView(_ prompt: WriterUndoPrompt) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(prompt.text)
                .font(Theme.label)
                .foregroundStyle(.primary)
            Button("撤销") {
                undoPrompt = nil
                prompt.action()
            }
            .font(Font.subheadline.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .buttonStyle(.plain)
            .frame(
                minWidth: Theme.Layout.hitTarget,
                minHeight: Theme.Layout.hitTarget
            )
            .contentShape(Rectangle())
        }
        .padding(.leading, Theme.Spacing.l)
        .padding(.trailing, Theme.Spacing.xs)
        .glassSurface(Capsule())
        .accessibilityElement(children: .contain)
    }

    /// 正文栏宽度上限：字号 × 36，宽屏居中（§2.3、§5.3）。
    private var bodyMaxWidth: CGFloat {
        let size = WriterTypography.fontSize(
            store.settings.bodyFontSize,
            dynamicTypeSize: dynamicTypeSize
        )
        return WriterTypography.bodyMaxWidth(size: size)
    }

    /// 用户气泡最多占对话列宽的 80%（§5.3）；还没量到列宽时先不限制。
    private var userBubbleMaxWidth: CGFloat? {
        columnWidth > 0 ? columnWidth * WriterTypography.userBubbleWidthRatio : nil
    }

    /// 显式回底：进页、消息发出、生成结束、删除后都走这里，动画只取动效 token。
    private func scrollToBottom(_ proxy: ScrollViewProxy, animation: Animation?) {
        withAnimation(animation) {
            proxy.scrollTo(WriterChatLayout.bottomAnchor, anchor: .bottom)
        }
    }

    /// 「回到最新」专用回底：先让出一步停下惯性滚动，再补一次对齐，避免惯性减速期间 scrollTo 失效。
    private func forceJumpToBottom(_ proxy: ScrollViewProxy) {
        let animation = Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)
        scrollToBottom(proxy, animation: animation)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            scrollToBottom(proxy, animation: animation)
        }
    }

    /// 结束/删除后回底：先让本轮排版落地，滚动才按新高度落点；
    /// 正式气泡还要再排一次版（行内 Markdown、动态字体），下一轮再补一次。
    private func settleAtBottom(_ proxy: ScrollViewProxy) {
        isSettling = true
        Task { @MainActor in
            defer { isSettling = false }
            await Task.yield()
            scrollToBottom(
                proxy,
                animation: Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)
            )
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            scrollToBottom(
                proxy,
                animation: Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)
            )
        }
    }

    private var chatEmptyState: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: "text.bubble")
                .font(Font.title2)
                .foregroundStyle(.tertiary)
            Text("从这里开始写")
                .font(Font.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.xxl * 2)
    }

    /// 每项只产出一个视图：流式气泡和普通气泡在 row 内部二选一。
    /// 身份由 `ChatMessage.id` 提供，不用再挂 `.id()`。
    ///
    /// 两种状态共用同一个正文栏宽度，生成结束换气泡时折行位置不变（§2.3）。
    @ViewBuilder
    private func messageRow(for message: ChatMessage) -> some View {
        if controller.isStreaming(message.id) {
            WriterStreamingBubble(controller: controller, bodyMaxWidth: bodyMaxWidth)
        } else {
            bubble(for: message)
        }
    }

    /// 底部哨兵可见 = 用户看着最新内容。只在这里恢复跟随，
    /// 流式内容变高把哨兵推出屏幕时不会被误判成“用户滚上去了”。
    private var bottomAnchor: some View {
        Color.clear
            .frame(height: 1)
            .id(WriterChatLayout.bottomAnchor)
            .onAppear {
                isAtBottom = true
            }
            .onDisappear {
                // 生成中内容变高、生成结束换气泡时，哨兵会先离开屏幕；
                // 那不算用户滚走，不能因此暂停跟随。
                if !controller.isBusy, !isSettling {
                    isAtBottom = false
                }
            }
    }

    @ViewBuilder
    private func bubble(for message: ChatMessage) -> some View {
        let actions = WriterMessageActions(
            copy: { copyToClipboard(message.content) },
            insert: { insertIntoManuscript(message.content) },
            append: { messageAction = .append(message) },
            regenerate: {
                controller.regenerate(messageID: message.id, session: session, store: store)
            },
            rollback: { messageAction = .rollback(message) },
            selectVariant: { index in
                session.selectVariant(index, for: message.id)
            },
            cleanupVersions: { messageAction = .cleanup(message) },
            deleteVariant: { messageAction = .delete(message) },
            toggleSelection: { toggleSelection(message.id) },
            beginSelection: { beginSelection(message.id) }
        )
        let row = WriterMessageBubble(
            message: message,
            isBusy: controller.isBusy,
            isSelecting: selectionMode,
            isSelected: selectedMessageIDs.contains(message.id),
            isInterrupted: session.isInterrupted(message.id),
            bodyMaxWidth: bodyMaxWidth,
            userBubbleMaxWidth: userBubbleMaxWidth,
            actions: actions
        )

        // 操作都收进长按菜单：气泡下面不再挂一排常驻图标（占位置、每条都重复一遍）。
        menuAnchor(row, message: message)
    }

    /// 长按弹出无预览卡片、无空白玻璃的原生液态玻璃 UIMenu（原地就近弹出）。
    @ViewBuilder
    private func menuAnchor<Row: View>(_ row: Row, message: ChatMessage) -> some View {
        if selectionMode {
            row
        } else {
            NoPreviewContextMenu(sections: contextMenuSections(for: message)) {
                row
            }
        }
    }

    private func contextMenuSections(for message: ChatMessage) -> [[UIMenuElement]] {
        let isBusy = controller.isBusy

        if message.role == .user {
            let primaryGroup: [UIMenuElement] = [
                UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { _ in
                    copyToClipboard(message.content)
                }
            ]
            let withdraw = UIAction(
                title: "撤回",
                image: UIImage(systemName: "arrow.uturn.backward"),
                attributes: .destructive
            ) { _ in
                if controller.isBusy {
                    controller.stop()
                }
                let index = session.payload.messages.firstIndex { $0.id == message.id }
                let removed = session.withdraw(from: message.id)
                presentUndoPrompt("已撤销指令") {
                    session.restore(removed, at: index)
                }
            }
            let delete = UIAction(
                title: "删除消息",
                image: UIImage(systemName: "trash"),
                attributes: isBusy ? [.destructive, .disabled] : .destructive
            ) { _ in
                messageAction = .deleteMessage(message)
            }
            return [primaryGroup, [withdraw, delete]]
        }

        var group1: [UIMenuElement] = [
            UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { _ in
                copyToClipboard(message.content)
            },
            UIAction(title: "插入到光标处", image: UIImage(systemName: "text.insert")) { _ in
                insertIntoManuscript(message.content)
            },
            UIAction(title: "追加到正文末尾", image: UIImage(systemName: "text.append")) { _ in
                messageAction = .append(message)
            },
        ]
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            group1.append(
                UIAction(
                    title: "提取为人物卡",
                    image: UIImage(systemName: "person.crop.rectangle.badge.plus"),
                    attributes: isBusy ? .disabled : []
                ) { _ in
                    let text = message.content
                    Task { @MainActor in
                        do {
                            let result = try await WorldWorkflow.ingestCharacterFromBubble(
                                text,
                                session: session,
                                store: store
                            )
                            store.toast = result.isNew
                                ? "已新建人物卡：\(result.cardName)"
                                : "已更新人物卡：\(result.cardName)"
                        } catch {
                            if !error.isLLMCancellation {
                                store.errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
            )
        }

        var group2: [UIMenuElement] = [
            UIAction(
                title: "重新生成",
                image: UIImage(systemName: "arrow.clockwise"),
                attributes: isBusy ? .disabled : []
            ) { _ in
                controller.regenerate(messageID: message.id, session: session, store: store)
            },
            UIAction(
                title: "回退到此",
                image: UIImage(systemName: "arrow.uturn.backward"),
                attributes: isBusy ? .disabled : []
            ) { _ in
                messageAction = .rollback(message)
            },
        ]
        if message.variants.count > 1 {
            group2.append(
                UIAction(title: "清理历史版本", image: UIImage(systemName: "archivebox")) { _ in
                    messageAction = .cleanup(message)
                }
            )
        }

        let deleteAction = UIAction(
            title: message.variants.count > 1 ? "删除当前版本" : "删除气泡",
            image: UIImage(systemName: "trash"),
            attributes: isBusy ? [.destructive, .disabled] : .destructive
        ) { _ in
            messageAction = .delete(message)
        }
        return [group1, group2, [deleteAction]]
    }

    // MARK: - 输入区

    /// 顶栏标题：书名 + 当前模型；点开在启用的服务商之间切换。
    private var modelMenu: some View {
        Menu {
            if enabledProviders.isEmpty {
                Text("还没有AI服务商")
            } else {
                Picker(selection: activeProviderBinding) {
                    ForEach(enabledProviders) { provider in
                        Text(providerModelLabel(provider)).tag(provider.id)
                    }
                } label: {
                    EmptyView()
                }
            }
        } label: {
            titleLabel
        }
        .accessibilityLabel("当前模型 \(modelLabel)，点按切换")
        .disabled(controller.isBusy)
    }

    private var titleLabel: some View {
        VStack(spacing: 1) {
            Text(session.project.title)
                .font(Font.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(modelLabel)
                .font(Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: Theme.Layout.navTitleMaxWidth)
    }

    private var activeProviderBinding: Binding<String> {
        Binding(
            get: { store.settings.activeProvider?.id ?? "" },
            set: { id in
                store.settings.activeProviderID = id
                store.saveSettings()
            }
        )
    }

    private var enabledProviders: [ProviderSetting] {
        store.settings.providers.filter(\.enabled)
    }

    private func providerModelLabel(_ provider: ProviderSetting) -> String {
        let model = provider.resolvedModel
        return model.isEmpty ? provider.kind.displayName : model
    }

    private var modelLabel: String {
        guard let provider = store.settings.activeProvider else { return "选择模型" }
        return providerModelLabel(provider)
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 0) {
            if selectionMode {
                WriterSelectionBar(
                    totalCount: selectableMessageIDs.count,
                    selectedCount: selectedMessageIDs.count,
                    isBusy: controller.isBusy,
                    onToggleAll: {
                        selectedMessageIDs = WriterSelection.togglingAll(
                            current: selectedMessageIDs,
                            visible: selectableMessageIDs
                        )
                    },
                    onDelete: {
                        messageAction = .deleteSelected(selectedMessageIDs.count)
                    },
                    onDone: {
                        exitSelection()
                    }
                )
            } else {
                composerView
            }
        }
    }

    private var composerView: some View {
        WriterComposerBar(
            session: session,
            controller: controller,
            model: composer,
            onSend: { text in
                return controller.send(text, session: session, store: store)
            },
            onContinue: {
                startContinuation()
            },
            autoFocus: LaunchArguments.focusComposer
        )
        .sensoryFeedback(.impact(weight: .light), trigger: session.payload.messages.count) { _, _ in store.settings.hapticsEnabled }
        // 预算弹窗确认逻辑：用户指令与挂起状态由控制器统一管理调度。
        .alert("上下文预算不足", isPresented: $budgetPresented) {
            Button("裁剪正文末尾后重试") {
                controller.retryAfterTrimming(session: session, store: store)
            }
            Button("查看提示词回看") {
                controller.dismissBudget(.inspectPrompt, session: session)
                activeSheet = .snapshots
            }
            Button("取消", role: .cancel) {
                controller.dismissBudget(.cancel, session: session)
            }
        } message: {
            Text(controller.budgetAlert?.message ?? "模型上下文窗不足以同时预留输出和安全空间。")
        }
    }

    // MARK: - 操作

    private func startContinuation() {
        dismissKeyboard()
        controller.continueWriting(session: session, store: store)
    }

    private func copyToClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        WriterClipboard.copy(text)
        store.toast = "已复制"
    }

    private func insertIntoManuscript(_ text: String) {
        guard !text.isEmpty else { return }
        dismissKeyboard()
        let length = session.manuscriptLength
        let base = cursorPlaced ? min(max(cursorOffset, 0), length) : length
        let block = paragraphSeparated(text, at: base)
        guard !block.isEmpty else { return }
        let receipt = session.insertIntoManuscript(block, at: base)
        cursorOffset = base + (block as NSString).length
        cursorPlaced = true
        let action = registerBodyUndo(receipt, actionName: "插入正文")
        presentUndoPrompt("已插入正文") {
            action.undoViaButton()
        }
    }

    /// 应用级动作登记进窗口的 UndoManager（§5.8）。
    ///
    /// 撤销/重做是两个独立方法：撤销用插入回执删掉原文，重做按「位置 + 原文」
    /// 插回去。撤销走系统栈：⌘Z / ⇧⌘Z、摇一摇和编辑菜单都能用上。
    /// 窗口拿不到 `UndoManager` 时动作照样保留，页面的「撤销」提示直接调它。
    private func registerBodyUndo(
        _ receipt: BodyAppendReceipt,
        actionName: String
    ) -> WriterBodyUndoAction {
        let action = WriterBodyUndoAction(
            receipt: receipt,
            actionName: actionName,
            undoManager: undoManager,
            session: session,
            store: store
        )
        // 持有撤销动作强引用，防止 UndoManager 的 unowned 引用失效。
        undoActions.append(action)
        action.registerInitialUndo()
        undoState.refresh()
        return action
    }

    /// 页面离开时注销所有撤销动作，避免跨项目误触发与悬挂引用。
    private func discardUndoActions() {
        for action in undoActions {
            undoManager.removeAllActions(withTarget: action)
        }
        undoActions.removeAll()
    }

    /// 为插入文本补充段落分隔换行符。
    private func paragraphSeparated(_ text: String, at offset: Int) -> String {
        let ns = session.manuscript as NSString
        var block = text.trimmingCharacters(in: .newlines)
        if offset > 0 {
            let start = max(0, offset - 2)
            let before = ns.substring(with: NSRange(
                location: start,
                length: offset - start
            ))
            if !before.hasSuffix("\n\n") {
                block = (before.hasSuffix("\n") ? "\n" : "\n\n") + block
            }
        }
        let afterLength = min(2, ns.length - offset)
        if afterLength > 0 {
            let after = ns.substring(with: NSRange(location: offset, length: afterLength))
            if !after.hasPrefix("\n\n") {
                block += after.hasPrefix("\n") ? "\n" : "\n\n"
            }
        }
        // 末尾插入仅前置补齐换行。
        return block
    }

    private func openSheet(_ sheet: WriterSheet) {
        dismissKeyboard()
        // 呈现全屏正文前初始化窗口编辑状态，避免全量正文提前加载。
        if sheet == .manuscript {
            session.beginWindowedEditing()
        }
        activeSheet = sheet
    }

    @ViewBuilder
    private func sheetContent(for sheet: WriterSheet) -> some View {
        switch sheet {
        case .manuscript:
            ManuscriptReaderSheet(
                session: session,
                cursor: $cursorOffset,
                onCursorInteraction: { cursorPlaced = true }
            )
        case .materials:
            WriterMaterialsSheet(session: session)
        case .snapshots:
            RequestSnapshotsSheet(session: session)
        case .bodyRange:
            WriterBodyRangeSheet(session: session)
        }
    }

    /// 浮层关闭后的收尾。
    private func sheetDidDismiss() {
        resolveCursorAfterSheet()
        // 提示词查看弹窗关闭后重新展示预算确认提示。
        controller.republishBudgetAlert()
    }

    /// 浮层关闭后补上光标：负数表示阅读页没有放过插入点，按末尾处理。
    private func resolveCursorAfterSheet() {
        if cursorOffset < 0 {
            cursorOffset = session.manuscriptLength
            cursorPlaced = false
        }
    }

    private func setAnchor() {
        let length = session.manuscriptLength
        let anchor = cursorPlaced ? min(max(cursorOffset, 0), length) : length
        dismissKeyboard()
        session.setContinuationAnchor(anchor)
        store.toast = "已在光标处放置续写锚"
    }

    private func clearAnchor() {
        dismissKeyboard()
        session.setContinuationAnchor(nil)
        store.toast = "已恢复从正文末尾续写"
    }

    private func dismissKeyboard() {
        composer.dismissRequest += 1
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    /// 回退操作：回滚当前助手回复及其前置用户指令，并将指令文本恢复至输入框。
    private func performRollback(to target: ChatMessage) {
        let messages = session.payload.messages
        guard let index = messages.firstIndex(where: { $0.id == target.id }) else { return }

        var cutIndex = index
        var restoredInstruction = false
        if let userIndex = messages[..<index].lastIndex(where: { $0.role == .user }) {
            composer.text = messages[userIndex].content
            cutIndex = userIndex
            restoredInstruction = true
        }
        session.rollbackToMessage(messages[cutIndex].id)
        store.toast = restoredInstruction
            ? "已回退指令，指令已放回输入框"
            : "已删除此气泡及后续对话"
    }

    // MARK: - 追加 / 清理 / 删除

    private var messageActionBinding: Binding<Bool> {
        Binding(
            get: { messageAction != nil },
            set: { if !$0 { messageAction = nil } }
        )
    }

    private func beginSelection(_ messageID: String) {
        guard !controller.isBusy else { return }
        dismissKeyboard()
        selectionMode = true
        selectedMessageIDs.insert(messageID)
    }

    private func toggleSelection(_ messageID: String) {
        if selectedMessageIDs.contains(messageID) {
            selectedMessageIDs.remove(messageID)
        } else {
            selectedMessageIDs.insert(messageID)
        }
    }

    private func exitSelection() {
        selectionMode = false
        selectedMessageIDs.removeAll()
    }

    private func performMessageAction(_ action: MessageAction) {
        messageAction = nil
        switch action {
        case .append(let message):
            dismissKeyboard()
            let receipt = session.appendToManuscript(message.content)
            cursorOffset = session.manuscriptLength
            cursorPlaced = true
            let action = registerBodyUndo(receipt, actionName: "追加到正文")
            presentUndoPrompt("已追加到正文") {
                action.undoViaButton()
            }
        case .rollback(let message):
            performRollback(to: message)
        case .cleanup(let message):
            session.keepOnlySelectedVariant(for: message.id)
            store.toast = "已清理历史版本"
        case .delete(let message):
            forceScrollToBottom = message.variants.count <= 1
            withAnimation(Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)) {
                session.deleteSelectedVariant(for: message.id)
            }
            store.toast = "已删除当前版本"
        case .deleteMessage(let message):
            forceScrollToBottom = true
            withAnimation(Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)) {
                session.deleteMessage(message.id)
            }
            store.toast = "已删除消息"
        case .deleteSelected:
            let ids = selectedMessageIDs
            guard !ids.isEmpty else { return }
            forceScrollToBottom = true
            exitSelection()
            withAnimation(Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)) {
                session.deleteMessages(ids)
            }
            store.toast = "已删除 \(ids.count) 条消息"
        case .clearAll:
            forceScrollToBottom = true
            withAnimation(Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)) {
                session.clearConversation()
            }
            store.toast = "已清空聊天记录"
        }
    }

    // MARK: - 导入正文

    private func handleBodyImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            guard !settingsIsUserCancelled(error) else { return }
            store.errorMessage = "读取正文失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { @MainActor in
                do {
                    let text = try await Task.detached(priority: .userInitiated) {
                        let accessed = url.startAccessingSecurityScopedResource()
                        defer {
                            if accessed { url.stopAccessingSecurityScopedResource() }
                        }
                        try TextFileCodec.validateExtension(url)
                        let data = try SecurityScopedFileReader.read(
                            url,
                            maxBytes: TextFileCodec.maxImportBytes
                        ) { _ in
                            NSError(
                                domain: "Frthink.BodyImport",
                                code: 1,
                                userInfo: [NSLocalizedDescriptionKey: "正文文件过大（超过 12 MB），无法导入。"]
                            )
                        }
                        return try TextFileCodec.decode(data)
                    }.value
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        store.errorMessage = "这个文件没有正文内容。"
                        return
                    }
                    pendingBodyImport = PendingBodyImport(
                        filename: url.lastPathComponent,
                        text: text
                    )
                } catch {
                    store.errorMessage = "读取正文失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func performBodyImport(_ pending: PendingBodyImport) {
        dismissKeyboard()
        session.replaceManuscript(pending.text)
        cursorOffset = 0
        cursorPlaced = false
        store.toast = "已导入正文，共 \(pending.text.count.formatted()) 字"
    }

    @MainActor
    private func prepareBodyExport() {
        let title = session.project.title
        let files = store.fileStore
        Task { @MainActor in
            let plain = await TextFileCodec.loadPlainExport(session: session, files: files)
            guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                store.errorMessage = "当前作品暂无可导出的正文。"
                return
            }
            bodyExportDocument = PlainTextFileDocument(text: plain)
            bodyExportFilename = TextFileCodec.exportFilename(title: title)
            isExportingBody = true
        }
    }
}
