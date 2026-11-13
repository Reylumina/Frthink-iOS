// 本文件负责：码字机 —— ChatBot 单栏对话 + 全屏正文。
//
// 0.5 秒测试：进创作页先看到一整列对话气泡，输入条在底部，不被正文挤成两半。
// 正文是「对话的上下文」，不是和聊天争空间的第二块面板：点「正文」进全屏页阅读/编辑。
// 这样既接近原版的聊天记录优先，也给 AI 回复足够的横向宽度。

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
    /// 这一页登记的撤销都落在这份栈上：优先窗口栈，没有时用兜底栈，
    /// 所以「插入正文 / 追加到正文」在任何状态下都撤得回来。
    private let undoManager: UndoManager

    @State private var controller = WriterController()
    /// 输入框文本与焦点都在子视图里，打字不触发整页重算。
    @State private var composer = WriterComposerModel()
    /// 应用级撤销动作（`UndoManager` 只保存 unowned target），由这里登记与清理。
    @State private var undoActions: [WriterBodyUndoAction] = []
    /// 撤销栈的菜单状态：栈顶变了，⋯ 里的「撤销 / 重做」跟着变。
    @State private var undoState: WriterUndoState
    /// 页面自带的「已插入正文 · 撤销」提示。
    ///
    /// 全局 toast 只有文字，放不下撤销按钮；这条只服务插入/追加这类可撤销动作，
    /// 几秒后自动消失（§4.3）。
    @State private var undoPrompt: WriterUndoPrompt?
    /// 输入条（含多选条）的高度：撤销提示浮在它上面，不挤动对话内容。
    @State private var bottomBarHeight: CGFloat = 0
    /// 出现次数令牌：区分「切 Tab 又切回来」与「真的离开」。
    @State private var appearanceToken = 0
    /// 对话列的实际宽度，用来算用户气泡 80% 的宽度上限（§5.3）。
    @State private var columnWidth: CGFloat = 0
    /// 对话内容高度与视口高度：内容不满一屏时从顶部排，不把几条消息压在底部。
    @State private var contentHeight: CGFloat = .greatestFiniteMagnitude
    @State private var viewportHeight: CGFloat = 0
    /// 光标的 UTF-16 偏移。负数表示还没拿到（初始状态），插入正文时按末尾处理。
    @State private var cursorOffset = -1
    /// 用户是否亲手在正文里放过插入点；false 时插到末尾，避免旧偏移插到开头。
    @State private var cursorPlaced = false
    /// 对话只渲染最近 N 条；更早的按原版「加载更早的对话」补。
    @State private var visibleMessageCount = 15
    @State private var rollbackTarget: ChatMessage?
    @State private var showRollbackDialog = false
    @State private var budgetPresented = false
    @State private var activeSheet: WriterSheet?
    @State private var isImportingBody = false
    @State private var pendingBodyImport: PendingBodyImport?
    /// 气泡的追加/清理/删除共用一个 alert，避免同一层视图挂多个 alert。
    @State private var messageAction: MessageAction?
    /// 用户是否停在聊天底部；滚上去后暂停自动跟随，避免抢滚动。
    @State private var isAtBottom = true
    /// 生成结束后的落底窗口：这段时间里底部哨兵离开屏幕不算用户滚走。
    @State private var isSettling = false
    /// 删除等让内容突然变矮的操作后，强制回到底部，避免留下大片空白。
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
    fileprivate struct PendingBodyImport: Identifiable, Hashable {
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
        case cleanup(ChatMessage)
        case delete(ChatMessage)
        case deleteMessage(ChatMessage)
        case deleteSelected(Int)
        case clearAll

        var id: String {
            switch self {
            case .append(let message): return "append-\(message.id)"
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
            case .cleanup: return "清理历史版本？"
            case .delete: return "删除当前版本？"
            case .deleteMessage: return "删除这条消息？"
            case .deleteSelected(let count): return "删除 \(count) 条消息？"
            case .clearAll: return "清空聊天记录？"
            }
        }

        var confirmTitle: String {
            switch self {
            case .append: return "追加"
            case .cleanup, .delete, .deleteMessage, .deleteSelected: return "删除"
            case .clearAll: return "清空"
            }
        }

        var confirmRole: ButtonRole? {
            switch self {
            case .append: return nil
            case .cleanup, .delete, .deleteMessage, .deleteSelected, .clearAll:
                return .destructive
            }
        }

        var messageText: String {
            switch self {
            case .append:
                return "把当前展示的版本追加到正文末尾。追加后可撤销。"
            case .cleanup:
                return "只保留当前展示的版本，其余版本会被删除且无法恢复。"
            case .delete(let message):
                if message.variants.count <= 1 {
                    return "这条气泡只有一个版本，删除后整条气泡消失且无法恢复。"
                }
                return "只删除当前展示的第 \(message.selectedVariant + 1) 版，其余 \(message.variants.count - 1) 个版本保留。"
            case .deleteMessage:
                return "删除后，这条消息以及它在会话里的位置都会消失，正文不受影响。"
            case .deleteSelected:
                return "删除后，这些消息以及它们在会话里的位置都会消失，正文不受影响，且无法恢复。"
            case .clearAll:
                return "会删除码字机里的所有用户指令和回复，正文不受影响，且无法撤销。"
            }
        }
    }

    var body: some View {
        chatList
            // 确认用推入页，不用和文件面板同层的 alert：面板收起与弹层抢转场时，
            // 后者会被系统静默丢掉，表现就是「选完文件没反应」。
            .navigationDestination(item: $pendingBodyImport) { pending in
                BodyImportConfirmPage(pending: pending) {
                    performBodyImport(pending)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
                    .background {
                        GeometryReader { proxy in
                            Color.clear
                                .onAppear { updateBottomBarHeight(proxy.size.height) }
                                .onChange(of: proxy.size.height) { _, height in
                                    updateBottomBarHeight(height)
                                }
                        }
                    }
            }
            // 撤销提示浮在输入条上方，不改变对话区高度（§4.3）。
            .overlay(alignment: .bottom) {
                if let prompt = undoPrompt {
                    undoPromptView(prompt)
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
            .themeAnimation(Theme.motionLayout, value: undoPrompt?.id)
            .onChange(of: controller.isGenerating) { _, active in
                if active { exitSelection() }
            }
            .onChange(of: controller.instructionToRestore) { _, _ in
                // 裁剪重试失败不丢指令：控制器把原文交回来，这里放回输入框。
                guard let text = controller.consumeInstructionToRestore() else { return }
                composer.text = text
            }
        .sensoryFeedback(.impact(weight: .light), trigger: controller.isGenerating) { _, _ in store.settings.hapticsEnabled }
        .sensoryFeedback(.success, trigger: session.payload.bodyAppendReceipts.count) { _, _ in store.settings.hapticsEnabled }
        .toolbar {
            ToolbarItem(placement: .principal) {
                modelMenu
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    openSheet(.manuscript)
                } label: {
                    ToolbarCircleIcon(symbol: "doc.text")
                }
                .disabled(controller.isBusy)
                .accessibilityLabel("正文")

                Menu {
                    writerMenu
                } label: {
                    ToolbarCircleIcon(symbol: "ellipsis")
                }
                .accessibilityLabel("更多写作操作")
            }
        }
        .pageBackground()
        .onChange(of: controller.budgetAlert?.id) { _, newValue in
            budgetPresented = newValue != nil
        }
        .confirmationDialog(
            "回退到这条用户指令",
            isPresented: $showRollbackDialog,
            titleVisibility: .visible
        ) {
            Button("把该指令恢复到输入框并删除其后的对话分支", role: .destructive) {
                performRollback()
            }
            Button("取消", role: .cancel) {
                rollbackTarget = nil
            }
        }
        .alert(messageAction?.title ?? "确认操作", isPresented: messageActionBinding) {
            Button("取消", role: .cancel) { messageAction = nil }
            if let action = messageAction {
                Button(action.confirmTitle, role: action.confirmRole) {
                    performMessageAction(action)
                }
            }
        } message: {
            Text(messageAction?.messageText ?? "")
        }
        .sheet(item: $activeSheet, onDismiss: sheetDidDismiss) { sheet in
            sheetContent(for: sheet)
        }
        .fileImporter(
            isPresented: $isImportingBody,
            allowedContentTypes: [.item, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            handleBodyImport(result)
        }
        .onChange(of: scenePhase) { _, phase in
            // 退后台时立刻把已收增量并回会话并落盘；系统随后可能直接杀进程。
            if phase == .background {
                controller.checkpoint(session: session)
            }
        }
        .onAppear {
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
                // 截图流水线要拍「正文单区」：等首帧排版完再拉 sheet，避免 sheet 抢在列表前面。
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
        .onAppear {
            // 每次出现换一个令牌，用来区分「切 Tab 又切回来」和「真的换了书」。
            appearanceToken += 1
        }
        .onDisappear {
            dismissKeyboard()
            controller.checkpoint(session: session)
            discardUndoActions()

            // 切 Tab 也会触发 onDisappear，但生成必须继续：只有离开后没再回来
            // （切书/关页，旧 Pane 被销毁）才停掉旧任务，避免孤儿流继续写旧会话。
            let token = appearanceToken
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                guard appearanceToken == token else { return }
                if controller.isBusy {
                    controller.stop()
                }
            }
        }
    }

    // MARK: - 顶栏

    @ViewBuilder
    private var writerMenu: some View {
        // 插入/追加正文的撤销入口。系统摇一摇和 ⌘Z 在没有聚焦输入框时拿不到
        // 撤销栈，光靠四秒的提示条太容易错过，所以菜单里常驻一条。
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

        Divider()

        Button {
            dismissKeyboard()
            isImportingBody = true
        } label: {
            Label("导入正文…", systemImage: "square.and.arrow.down")
        }
        .disabled(controller.isBusy)

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

    /// 首帧锚点：内容比视口短时从顶部排（不把内容压在底部），长了才锚底。
    private var scrollAnchor: UnitPoint? {
        guard contentHeight >= viewportHeight else { return nil }
        return isAtBottom && !session.payload.messages.isEmpty ? .bottom : nil
    }

    private var chatList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // 用 VStack 而不是 LazyVStack：整列已经按 `visibleMessageCount`
                // 截过，行数有上限；流式那一行可能有上万字，LazyVStack 的估算
                // 行高 + `scrollTo` 会在结束时落到内容之外，正文区留一整屏空白
                // （Stream Check 的第 2 次连跑复现）。全量测量后偏移是精确值。
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
                .background { columnWidthReader }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .task(id: proxy.size.height) { contentHeight = proxy.size.height }
                    }
                }
            }
            // 首帧就落在底部：不再靠 onAppear 里抢在布局前的 scrollTo。
            // 那一次只能按 LazyVStack 的估算行高算偏移，长对话里可能停在半空
            // （历史「正文区空白」的复现路径之一）。
            // 用户手动滚开后锚点撤掉，不会被内容变高拽回去（§5.9）；
            // 空对话不给锚点，空态按默认从顶部排。
            .defaultScrollAnchor(scrollAnchor)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .task(id: proxy.size.height) { viewportHeight = proxy.size.height }
                }
            }
            // 键盘弹起时右侧浮一个圆形 X：点一下收起，和系统搜索的关闭键同形状。
            // 滚动收起由下面的 .scrollDismissesKeyboard 负责（§5.9）。
            .overlay(alignment: .topTrailing) {
                if composer.isEditing {
                    Button {
                        composer.dismissRequest += 1
                    } label: {
                        ToolbarCircleIcon(symbol: "xmark")
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, Theme.Spacing.l)
                    .padding(.top, Theme.Spacing.s)
                    .accessibilityLabel("收起键盘")
                    .transition(.opacity)
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            // iOS 26 的滚动边缘柔化；更早的系统由 Theme 回落成无操作（§5.2）。
            .softScrollEdge()
            .minimizeTabBarOnScroll()
            .simultaneousGesture(
                DragGesture(minimumDistance: 10).onChanged { value in
                    // 手指向下拖 = 回看更早的内容。生成中也让用户停在自己
                    // 看的位置，不要每 60ms 被跟随器拽回底部。
                    if value.translation.height > 10, isAtBottom {
                        isAtBottom = false
                    }
                }
            )
            // 跟随器单独成视图：它只读 60ms 一次的 displayTick，
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
                // 新消息会把窗口外的旧行挤出去：选择集裁回还能看到的那些。
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
            .overlay(alignment: .bottomTrailing) {
                // 只在离开底部时出现；浮在内容上的玻璃按钮（§1.6、§5.4）。
                ZStack {
                    if !isAtBottom {
                        // 带文字的胶囊，不和一个圆形的发送键抢同一种形态（§5.11）。
                        FloatingGlassButton(
                            symbol: "chevron.down",
                            label: "回到最新",
                            title: "最新"
                        ) {
                            isAtBottom = true
                            scrollToBottom(
                                proxy,
                                animation: Theme.motion(
                                    Theme.motionLayout,
                                    reduceMotion: reduceMotion
                                )
                            )
                        }
                        .padding(.trailing, Theme.Spacing.l)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { dismissKeyboard() }
    }

    /// 对话列的实际宽度。用户气泡的 80% 上限按它算（§5.3），不写设备断点。
    private var columnWidthReader: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { updateColumnWidth(proxy.size.width) }
                .onChange(of: proxy.size.width) { _, width in
                    updateColumnWidth(width)
                }
        }
    }

    private func updateColumnWidth(_ width: CGFloat) {
        guard width > 0, width != columnWidth else { return }
        columnWidth = width
    }

    /// 输入条高度：撤销提示按它上浮，不挤动对话区。
    private func updateBottomBarHeight(_ height: CGFloat) {
        guard height > 0, height != bottomBarHeight else { return }
        bottomBarHeight = height
    }

    /// 插入/追加成功后显示带「撤销」的轻提示（§4.3）。
    private func presentUndoPrompt(_ text: String, undo: @escaping () -> Void) {
        undoPrompt = WriterUndoPrompt(text: text, action: undo)
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
        .padding(.top, 64)
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
            rollback: {
                rollbackTarget = message
                showRollbackDialog = true
            },
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

        if message.role == .user {
            row.contextMenu {
                Button {
                    copyToClipboard(message.content)
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                }
                Button {
                    beginSelection(message.id)
                } label: {
                    Label("多选", systemImage: "checklist")
                }
                .disabled(controller.isBusy)
                Button(role: .destructive) {
                    messageAction = .deleteMessage(message)
                } label: {
                    Label("删除这条消息", systemImage: "trash")
                }
                .disabled(controller.isBusy)
            }
        } else {
            row
        }
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
        // 弹窗只决定「怎么发」：用户气泡和挂起的发送都在控制器里保留着，
        // 三条路径各自走 `dismissBudget`，取消才收回气泡、把指令放回输入框（§4.3）。
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
        // 撤销栈只持有 target 的 unowned 引用，页面必须自己保住它，
        // 所以不清空、不丢引用；离开页面时先摘动作再释放。
        undoActions.append(action)
        action.registerInitialUndo()
        undoState.refresh()
        return action
    }

    /// 离开写作台时清掉本页登记的撤销动作：撤销栈挂在窗口上，
    /// 不清就会切到别的书之后撤回旧书正文。撤销栈只持 unowned 引用，
    /// 摘不掉动作时宁可把对象一起留着，也不能让它悬空。
    private func discardUndoActions() {
        for action in undoActions {
            undoManager.removeAllActions(withTarget: action)
        }
        undoActions.removeAll()
    }

    /// 插入块前后补空行，避免和原文粘成一句。
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
        // 插到末尾时只在前面补空行；后面没有正文，不需要再造一个空段。
        return block
    }

    private func openSheet(_ sheet: WriterSheet) {
        dismissKeyboard()
        // 先开窗口再创建 sheet，避免 UITextView 首次取文时把整本正文拼出来。
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
        // 预算弹窗里点了「查看提示词回看」：挂起的发送和用户气泡都还在，
        // 回到创作页再弹一次确认，指令不会丢在半路。
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

    /// 回退：把对话砍到这条助手回复对应的用户指令之前，指令放回输入框。
    private func performRollback() {
        guard let target = rollbackTarget else { return }
        rollbackTarget = nil
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
            ? "已回退到这条指令，指令已放回输入框"
            : "已删除这条气泡及其后的对话"
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
            store.toast = "已删除这条消息"
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
                        let data = try Data(contentsOf: url)
                        guard let text = String(data: data, encoding: .utf8) else {
                            throw BodyImportError.notUTF8
                        }
                        return text
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
}

/// 正文导入的确认页：先给文件名和字数，再让用户决定是否覆盖。
private struct BodyImportConfirmPage: View {
    let pending: WriterPane.PendingBodyImport
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                AppValueRow(title: "文件", value: pending.filename)
                AppValueRow(title: "字数", value: "\(pending.text.count.formatted()) 字")
            } header: {
                AppSectionHeader(title: "导入正文")
            }

            Section {
                Text("导入会覆盖当前正文，且不能撤销。")
                    .font(Font.footnote)
                    .foregroundStyle(.secondary)
                Button("覆盖并导入", role: .destructive) {
                    onConfirm()
                    dismiss()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle("确认导入")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 「导入正文」只认 UTF-8 文本；别的编码报清楚，而不是塞一段乱码进正文。
private enum BodyImportError: LocalizedError {
    case notUTF8

    var errorDescription: String? {
        "文件不是 UTF-8 文本，请另存为 UTF-8 后再导入。"
    }
}
