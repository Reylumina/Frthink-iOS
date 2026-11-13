// 本文件负责：写作台的生成状态机 —— 组装请求、检查上下文预算、流式写入消息、取消与重跑。

import Foundation
import Observation
import UIKit

/// 码字机一次生成的完整流程。
///
/// 生成状态放在 `@Observable` 类里而不是视图的局部状态：一次流式响应要挂起很久，
/// 视图在挂起期间可能被重建，只有类能保证「同一时刻只有一个请求在跑」且取消按钮
/// 拿得到那个 Task。
///
/// 流式循环直接跑在 MainActor 上（`Task {}` 继承当前 actor），不碰 `Task.detached`：
/// `ProjectSession` 是 `@MainActor` 的，增量写入必须在主线程。
@MainActor
@Observable
final class WriterController {

    // MARK: - 对外状态

    /// 正在生成：从发起请求到最后一个增量落盘。
    private(set) var isGenerating = false

    /// 正在流式写入的助手消息 id。气泡据此显示「正在生成」。
    private(set) var streamingMessageID: String?

    /// 正在生成的正文（控制器侧缓冲）。流式期间气泡只读这里。
    private(set) var streamingText = ""

    /// 已生成字符数；增量累加，避免气泡每帧对全文做一次 `count`。
    private(set) var streamingCharacterCount = 0

    /// 落盘刷新的次数。
    private(set) var streamFlushTick = 0

    /// 气泡显示刷新的次数（约 60ms 一次）。
    private(set) var displayTick = 0

    /// 本次请求的思考过程。
    private(set) var streamingReasoning: String?
    /// 已收到的思考字符数。流式期间只靠它判断要不要刷新思考区，
    /// 不必每 60ms 比较一次长字符串。
    private(set) var streamingReasoningCharacterCount = 0

    /// 自动摘要进行中，避免并发重复请求。
    private var autoSummarizing = false

    /// 正在后台组装提示词。此时还没有开始生成，界面显示「整理提示词…」。
    private(set) var isPreparing = false

    /// 准备阶段的 Task；点停止或切页时取消。
    private var prepareTask: Task<Void, Never>?
    /// 后台组装本身。`Task.detached` 不继承调用方取消，取消必须打到这个句柄上，
    /// 否则停止后旧组装还在跑，立刻重发就会有两份 56 万字组装并发。
    private var prepareAssemblyTask: Task<WriterPromptRetryResult, Error>?
    /// 每次开始准备 +1。旧任务晚一步收尾时靠它认出自己已经过期，
    /// 不去改新一轮的 `isPreparing` / `prepareTask`。
    private var prepareGeneration = 0

    /// 非 nil 时弹上下文预算提示；由视图观察后弹 alert。
    private(set) var budgetAlert: BudgetAlert?

    /// 「裁剪后重试」失败时把用户指令放回输入框，不要求重打。
    private(set) var instructionToRestore: String?

    /// 视图取走指令后清空，避免重复回填。
    func consumeInstructionToRestore() -> String? {
        defer { instructionToRestore = nil }
        return instructionToRestore
    }

    // MARK: - 内部状态

    private var task: Task<Void, Never>?
    /// 还没写进 session 的增量。攒着，按 `flushInterval` 批量落。
    private var pendingDelta = ""
    /// 自动摘要的后台任务；停止或切书时要能取消。
    private var summaryTask: Task<Void, Never>?
    private var reasoningBuffer = ""
    private var reasoningBufferCharacterCount = 0
    private var flushTask: Task<Void, Never>?
    /// 还没显示到气泡上的增量。按 `displayInterval` 刷新，避免一个 token 一帧。
    private var displayBuffer = ""
    /// `displayBuffer` 的字符数，增量维护。
    private var displayCharacterCount = 0
    private var displayTask: Task<Void, Never>?
    /// 切后台后向系统申请的额外执行时间；生成结束或过期时归还。
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    /// 系统收回后台时间：收尾时把消息标成中断。
    private var backgroundExpired = false
    /// 落盘间隔：只为防崩溃丢字，不驱动界面。
    private let flushInterval: Duration = .seconds(3)

    /// 界面刷新间隔：默认 33ms（约 30 帧/秒），低电量/机身过热时自动降频。
    ///
    /// 60ms 时一个字块一次跳三四个字，看起来是一跳一跳的；33ms 接近一次刷新
    /// 补两三个字，观感接近逐字。设备状态差时少做无谓的排版——社区实践
    /// （Tanay Shah《Why Your iOS Streaming Chat Is Cooking the GPU》）与 Apple 的
    /// 省电/热管理建议一致。
    private var displayInterval: Duration {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return .milliseconds(100) }
        switch info.thermalState {
        case .serious, .critical:
            return .milliseconds(80)
        case .fair:
            return .milliseconds(50)
        default:
            return .milliseconds(33)
        }
    }

    /// 预算不足时挂起的发送。
    ///
    /// 用户气泡在弹窗期间一直保留在会话里——只有「取消」和重试失败才收回，
    /// 「查看提示词回看」只是离开弹窗，挂起状态原样保留，回来后再弹一次确认。
    private struct SuspendedSend {
        let action: PendingAction
        /// 已经落盘的用户气泡；重试时复用它，不再加第二条。
        let userMessageID: String?
        /// 弹窗内容，回看结束后重新弹出时用同一份。
        let alert: BudgetAlert
    }

    private var suspended: SuspendedSend?

    /// 预算弹窗的关闭方式。
    enum BudgetDismissal {
        /// 先去看提示词回看：挂起的发送和用户气泡都保留。
        case inspectPrompt
        /// 用户明确取消：收回用户气泡，把指令还给输入框。
        case cancel

        /// 是否收回已经落盘的用户气泡。只有明确取消才收。
        var retractsUserMessage: Bool { self == .cancel }

        /// 是否把用户指令还给输入框。
        var restoresInstruction: Bool { self == .cancel }
    }

    /// 用户按过停止。流正常结束（没抛错）时也要按取消处理。
    private var stopRequested = false

    /// 上下文预算提示的内容。字段都在弹窗前算好，避免视图里再读供应方。
    struct BudgetAlert: Identifiable, Equatable {
        let id = UUID()
        let estimated: Int
        let limit: Int
        let window: Int
        let reserve: Int

        var message: String {
            """
            模型上下文窗不足以同时预留输出和安全空间。
            本轮提示词与正文估算约 \(estimated) tokens，安全输入上限约 \(limit) tokens（上下文窗 \(window) tokens，为输出预留 \(reserve) tokens）。
            可以只把正文末尾的部分发给模型后重试，正文本身不会被改动。
            """
        }
    }

    private enum PendingAction {
        case send(String)
        case regenerate(String)
        case continuation
    }

    /// 某条消息是否正在被流式写入。
    func isStreaming(_ messageID: String) -> Bool {
        isGenerating && streamingMessageID == messageID
    }

    #if DEBUG
    /// 截图流水线用：把控制器置成“正在流式”的静态状态，不发起网络请求。
    ///
    /// 这样 CI 能真的渲染一次 `StreamingTextView`，验证增量文本的排版与高度，
    /// 而不是只验证普通气泡。
    func debugStartPreview(text: String, messageID: String) {
        isGenerating = true
        streamingMessageID = messageID
        streamingText = text
        streamingCharacterCount = text.count
        streamingReasoning = nil
    }
    #endif

    // MARK: - 入口

    /// 发送一条指令。返回 false 表示请求根本没发出去（没配置供应方等），
    /// 视图据此把输入框里的文字还回去。
    @discardableResult
    func send(_ text: String, session: ProjectSession, store: AppStore) -> Bool {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !isGenerating, !isPreparing else { return false }
        return start(
            action: .send(instruction: instruction),
            session: session,
            store: store,
            manuscript: session.manuscript,
            bodyRange: .full
        )
    }

    /// 续写：不带用户输入，从正文末尾接着写（正文末尾片段作为 assistant 回灌）。
    func continueWriting(session: ProjectSession, store: AppStore) {
        guard !isGenerating, !isPreparing else { return }
        _ = start(
            action: .continueWriting,
            session: session,
            store: store,
            manuscript: session.manuscript,
            bodyRange: .full
        )
    }

    /// 重新生成某条助手回复：旧内容留作上一个版本，新内容写进新版本。
    func regenerate(messageID: String, session: ProjectSession, store: AppStore) {
        guard !isGenerating, !isPreparing else { return }
        guard let index = session.payload.messages.firstIndex(where: { $0.id == messageID }),
              session.payload.messages[index].role == .assistant else {
            store.toast = "这条助手消息已经不存在了"
            return
        }
        session.clearInterrupted(messageID)
        let previousVariant = session.payload.messages[index].selectedVariant
        _ = start(
            action: .regenerate(beforeIndex: index),
            session: session,
            store: store,
            manuscript: session.manuscript,
            bodyRange: .full,
            regenerateFallbackVariant: previousVariant
        )
    }

    /// 生成或准备中：界面上的编辑/删除动作都要禁用。
    var isBusy: Bool { isGenerating || isPreparing }

    /// 停止：准备阶段取消组装，生成阶段取消流。
    func stop() {
        if isPreparing {
            prepareGeneration &+= 1
            prepareTask?.cancel()
            prepareTask = nil
            // detached 组装不继承取消，必须显式取消，否则停完立刻重发会并排跑两份。
            prepareAssemblyTask?.cancel()
            prepareAssemblyTask = nil
            isPreparing = false
            // 指令在准备开始时已经作为用户气泡落盘，这里不再把它吐回输入框，
            // 否则会和气泡里的同一句话重复。
            return
        }
        summaryTask?.cancel()
        guard isGenerating else { return }
        stopRequested = true
        task?.cancel()
    }

    /// 预算弹窗的所有关闭路径都走这里，避免视图和控制器各改一半状态。
    ///
    /// - `.inspectPrompt`：只是先去看提示词回看，挂起的发送和用户气泡都保留；
    /// - `.cancel`：用户明确取消，收回用户气泡并把指令还给输入框。
    func dismissBudget(_ intent: BudgetDismissal, session: ProjectSession) {
        if intent.retractsUserMessage, let suspended {
            retractSend(
                suspended.action,
                userMessageID: suspended.userMessageID,
                session: session
            )
            self.suspended = nil
        }
        budgetAlert = nil
    }

    /// 看完提示词回看回到创作页：挂起的发送还在，重新弹一次预算确认。
    func republishBudgetAlert() {
        guard let suspended else { return }
        budgetAlert = suspended.alert
    }

    /// 预算弹窗里点「裁剪正文后重试」。
    ///
    /// 裁剪与重新组装都放后台；用户气泡沿用弹窗前那一条，不再新增，
    /// 失败时才收回并把指令还给输入框。
    func retryAfterTrimming(session: ProjectSession, store: AppStore) {
        guard let suspended else {
            budgetAlert = nil
            return
        }
        guard let builderAction = builderAction(for: suspended.action, session: session) else {
            budgetAlert = nil
            self.suspended = nil
            retractSend(
                suspended.action,
                userMessageID: suspended.userMessageID,
                session: session
            )
            store.errorMessage = "上下文预算信息已过期，请重新发送。"
            return
        }
        let started = start(
            action: builderAction,
            session: session,
            store: store,
            manuscript: session.manuscript,
            bodyRange: .full,
            retry: suspended.action,
            preparedUserMessageID: suspended.userMessageID
        )
        if started {
            // 重试接管了那条用户气泡：挂起状态到此为止，后面的失败由
            // `finishPreparation` 用 `Preparation` 里的回执处理。
            budgetAlert = nil
            self.suspended = nil
        } else {
            // 连请求都没开始：收回挂起的用户气泡，把指令还给输入框。
            budgetAlert = nil
            self.suspended = nil
            retractSend(
                suspended.action,
                userMessageID: suspended.userMessageID,
                session: session
            )
        }
    }

    /// 这次发送没成：收回提前落盘的用户气泡，把指令还给输入框（只有「发送」有文本）。
    private func retractSend(
        _ action: PendingAction,
        userMessageID: String?,
        session: ProjectSession
    ) {
        if let userMessageID {
            session.deleteMessage(userMessageID)
        }
        if case .send(let text) = action {
            instructionToRestore = text
        }
    }

    // MARK: - 准备与提交

    private struct Preparation {
        /// 预算弹窗挂起的动作；提交成功前不清。
        let action: PendingAction
        /// 重新生成时旧版本的下标；生成成功后才加新版本。
        let regenerateFallbackVariant: Int?
        /// 发送时提前落盘的用户气泡。预算弹窗取消或准备失败时删掉它。
        let userMessageID: String?
        let client: any LLMClient
        let provider: ProviderSetting
    }

    /// 拍快照、后台组装、回主线程提交。返回 false 表示连请求都没开始。
    private func start(
        action: WriterPromptAction,
        session: ProjectSession,
        store: AppStore,
        manuscript: String,
        bodyRange: PromptLibrary.BodyRange,
        retry: PendingAction? = nil,
        regenerateFallbackVariant: Int? = nil,
        preparedUserMessageID: String? = nil
    ) -> Bool {
        do {
            let (client, provider) = try activeClient(store: store)
            let snapshot = try promptSnapshot(
                action: action,
                session: session,
                store: store,
                manuscript: manuscript,
                bodyRange: bodyRange,
                provider: provider,
                excludingMessageID: preparedUserMessageID
            )
            // 先把用户气泡落盘：组装在 56 万字书上要几秒，这期间被杀掉不能让
            // 指令只活在一个 Task 里。历史快照已经取过，不会把这条重复带进去。
            // 预算重试复用弹窗前已经落盘的那一条，不再加第二遍。
            var userMessageID = preparedUserMessageID
            if userMessageID == nil, case .send(let instruction) = action {
                userMessageID = session.addUserMessage(instruction).id
                session.saveNow()
            }
            let preparation = Preparation(
                action: pendingAction(for: snapshot.action, messages: snapshot.messages),
                regenerateFallbackVariant: regenerateFallbackVariant
                    ?? fallbackVariant(for: snapshot.action, session: session),
                userMessageID: userMessageID,
                client: client,
                provider: provider
            )
            isPreparing = true
            prepareGeneration &+= 1
            let generation = prepareGeneration
            prepareTask?.cancel()
            prepareAssemblyTask?.cancel()
            // 组装是同步重活，放后台；取消必须显式打到这个任务的句柄上。
            let assembly = Task.detached(priority: .userInitiated) { () throws in
                if retry == nil {
                    return WriterPromptRetryResult.prepared(
                        try WriterPromptBuilder.prepareCancellable(snapshot)
                    )
                }
                return try WriterPromptBuilder.retryAfterTrimming(snapshot)
            }
            prepareAssemblyTask = assembly
            prepareTask = Task { @MainActor [weak self] in
                let result: WriterPromptRetryResult
                do {
                    result = try await assembly.value
                } catch {
                    // 旧一轮的准备晚一步收尾时不要碰新一轮的状态。
                    guard let self, self.prepareGeneration == generation else { return }
                    self.prepareAssemblyTask = nil
                    self.isPreparing = false
                    self.prepareTask = nil
                    // 取消来自 stop()/重发：状态已经复位，不提交半成品、不弹错。
                    guard !Task.isCancelled, !(error is CancellationError) else { return }
                    self.retractSend(
                        preparation.action,
                        userMessageID: preparation.userMessageID,
                        session: session
                    )
                    store.errorMessage = error.localizedDescription
                    return
                }
                guard let self,
                      self.prepareGeneration == generation,
                      !Task.isCancelled else { return }
                self.prepareAssemblyTask = nil
                self.isPreparing = false
                self.prepareTask = nil
                self.finishPreparation(
                    result,
                    preparation: preparation,
                    session: session,
                    store: store
                )
            }
            return true
        } catch {
            store.errorMessage = error.localizedDescription
            return false
        }
    }

    /// 主线程拍值类型快照；组装工作不碰会话对象。
    ///
    /// 预算推导也在这里做完：窗口连输出都放不下时直接抛错，`start` 的 catch
    /// 按原版文案报错并返回 false，不会带着一个假预算把请求发出去。
    private func promptSnapshot(
        action: WriterPromptAction,
        session: ProjectSession,
        store: AppStore,
        manuscript: String,
        bodyRange: PromptLibrary.BodyRange,
        provider: ProviderSetting,
        excludingMessageID: String? = nil
    ) throws -> WriterPromptSnapshot {
        let plan = try budget(for: provider, settings: store.settings)
        return WriterPromptSnapshot(
            action: action,
            manuscript: manuscript,
            // 预算重试时用户气泡已经在历史里了：再把它当历史带进去，指令会被
            // 追加第二遍，同一句话发两次、token 虚高，还可能误判「仍然过大」。
            messages: session.payload.messages.filter { $0.id != excludingMessageID },
            world: session.payload.world,
            assistantSupplement: session.payload.assistantSupplement,
            settings: store.settings,
            projectID: session.project.id,
            enabledUniverseEntryIDs: session.payload.enabledUniverseEntryIDs,
            bodyPromptSendWhole: session.payload.bodyPromptSendWhole,
            bodyPromptTailCodePoints: session.payload.bodyPromptTailCodePoints,
            continuationAnchor: session.payload.continuationAnchor,
            explicitBodyRange: bodyRange,
            inputBudget: plan.effectiveInputBudget
        )
    }

    private func finishPreparation(
        _ result: WriterPromptRetryResult,
        preparation: Preparation,
        session: ProjectSession,
        store: AppStore
    ) {
        let plan: PromptBudget
        do {
            plan = try budget(for: preparation.provider, settings: store.settings)
        } catch {
            // 预算算不出来就不能发：收回用户气泡和挂起状态，按原版文案报错。
            budgetAlert = nil
            suspended = nil
            retractSend(
                preparation.action,
                userMessageID: preparation.userMessageID,
                session: session
            )
            store.errorMessage = error.localizedDescription
            return
        }
        switch result {
        case .cannotTrim:
            budgetAlert = nil
            suspended = nil
            retractSend(
                preparation.action,
                userMessageID: preparation.userMessageID,
                session: session
            )
            store.errorMessage = "上下文放不下：裁剪正文后仍然超出模型上下文窗。可以先回退几轮对话、精简正文，或在设置里调小输出上限。"
        case .stillTooLarge(let characters):
            budgetAlert = nil
            suspended = nil
            retractSend(
                preparation.action,
                userMessageID: preparation.userMessageID,
                session: session
            )
            store.errorMessage = "上下文放不下：只保留正文末尾 \(characters) 字仍然超出模型上下文窗，请在设置里调小输出上限。"
        case .prepared(let prepared):
            if prepared.estimatedInputTokens > plan.effectiveInputBudget {
                // 气泡保留：弹窗只决定「怎么发」，用户点取消才收回（§4.3）。
                let alert = BudgetAlert(
                    estimated: prepared.estimatedInputTokens,
                    limit: plan.effectiveInputBudget,
                    window: plan.contextWindow ?? 0,
                    reserve: plan.outputBudget
                )
                suspended = SuspendedSend(
                    action: preparation.action,
                    userMessageID: preparation.userMessageID,
                    alert: alert
                )
                budgetAlert = alert
                return
            }
            budgetAlert = nil
            suspended = nil
            commit(
                prepared,
                plan: plan,
                preparation: preparation,
                session: session,
                store: store
            )
        }
    }

    private func commit(
        _ prepared: WriterPreparedPrompt,
        plan: PromptBudget,
        preparation: Preparation,
        session: ProjectSession,
        store: AppStore
    ) {
        switch preparation.action {
        case .send:
            // 用户气泡在准备阶段已经落盘，这里只接助手回复。
            let assistant = session.beginAssistantMessage(
                model: preparation.provider.resolvedModel
            )
            run(
                client: preparation.client,
                provider: preparation.provider,
                plan: plan,
                prepared: prepared,
                session: session,
                store: store,
                messageID: assistant.id,
                isNewMessage: true,
                fallbackVariant: nil
            )
        case .continuation:
            let assistant = session.beginAssistantMessage(
                model: preparation.provider.resolvedModel
            )
            run(
                client: preparation.client,
                provider: preparation.provider,
                plan: plan,
                prepared: prepared,
                session: session,
                store: store,
                messageID: assistant.id,
                isNewMessage: true,
                fallbackVariant: nil
            )
        case .regenerate(let messageID):
            guard let index = session.payload.messages.firstIndex(where: {
                $0.id == messageID
            }), session.payload.messages[index].role == .assistant else {
                store.toast = "这条助手消息已经不存在了"
                return
            }
            // 新版本是空的并被选中，后面的 appendDelta 会写进它。
            session.addVariant(to: messageID)
            run(
                client: preparation.client,
                provider: preparation.provider,
                plan: plan,
                prepared: prepared,
                session: session,
                store: store,
                messageID: messageID,
                isNewMessage: false,
                fallbackVariant: preparation.regenerateFallbackVariant
            )
        }
    }

    /// 快照里的动作 ↔ 预算弹窗挂起的动作。
    private func pendingAction(
        for action: WriterPromptAction,
        messages: [ChatMessage]
    ) -> PendingAction {
        switch action {
        case .send(let instruction):
            return .send(instruction)
        case .continueWriting:
            return .continuation
        case .regenerate(let index):
            let id = messages.indices.contains(index) ? messages[index].id : ""
            return .regenerate(id)
        }
    }

    /// 重新生成失败时要回退到的旧版本下标。
    private func fallbackVariant(
        for action: WriterPromptAction,
        session: ProjectSession
    ) -> Int? {
        guard case .regenerate(let index) = action,
              session.payload.messages.indices.contains(index)
        else { return nil }
        return session.payload.messages[index].selectedVariant
    }

    private func builderAction(
        for action: PendingAction,
        session: ProjectSession
    ) -> WriterPromptAction? {
        switch action {
        case .send(let text):
            return .send(instruction: text)
        case .continuation:
            return .continueWriting
        case .regenerate(let messageID):
            guard let index = session.payload.messages.firstIndex(where: {
                $0.id == messageID
            }) else { return nil }
            return .regenerate(beforeIndex: index)
        }
    }

    // MARK: - 上下文预算

    private func activeClient(store: AppStore) throws -> (any LLMClient, ProviderSetting) {
        guard let provider = store.settings.activeProvider else {
            throw LLMError.notConfigured
        }
        let client = try store.clientForActiveProvider()
        return (client, provider)
    }

    /// 预算推导，照抄原版 `L1/e3.java:22-55`：
    /// `effectiveInputBudget = min(inputBudget, contextWindow - outputBudget - 1024)`。
    ///
    /// 窗口连输出都放不下时 `PromptBudget.make` 抛 `BudgetError`；这里直接往上传，
    /// 由 `start` 按原版文案报错并停下，不再退化成「输入预算为准」继续发超窗请求。
    private func budget(for provider: ProviderSetting, settings: AppSettings) throws -> PromptBudget {
        let window = settings.contextWindowTokens > 0
            ? settings.contextWindowTokens
            : TokenEstimator.contextWindow(for: provider.resolvedModel)
        return try PromptBudget.make(
            settings: settings,
            model: provider.resolvedModel,
            contextWindowOverride: window
        )
    }

    // MARK: - 流式

    private func run(
        client: any LLMClient,
        provider: ProviderSetting,
        plan: PromptBudget,
        prepared: WriterPreparedPrompt,
        session: ProjectSession,
        store: AppStore,
        messageID: String,
        isNewMessage: Bool,
        fallbackVariant: Int?
    ) {
        let messages = prepared.messages
        isGenerating = true
        streamingMessageID = messageID
        streamingText = ""
        streamingCharacterCount = 0
        streamingReasoning = nil
        streamingReasoningCharacterCount = 0
        streamFlushTick = 0
        displayTick = 0
        pendingDelta = ""
        reasoningBuffer = ""
        reasoningBufferCharacterCount = 0
        displayBuffer = ""
        displayCharacterCount = 0
        flushTask?.cancel()
        flushTask = nil
        displayTask?.cancel()
        displayTask = nil
        stopRequested = false
        backgroundExpired = false
        beginBackgroundTask()
        session.beginGeneration(messageID: messageID)
        // 先落一次盘，保证进程在首个 3 秒窗口内被杀也能看到“生成中”。
        session.saveNow()

        let request = LLMRequest(
            model: provider.resolvedModel,
            messages: messages,
            stream: provider.stream,
            temperature: 0.2,
            maxTokens: plan.outputBudget,
            // 思考档位由供应方设置统一决定。
            attemptId: UUID().uuidString
        )
        let model = provider.resolvedModel
        let useStreaming = provider.stream

        // 记录这次实际发出去的提示词，供「提示词回看」。
        session.recordRequestSnapshot(
            model: model,
            messages: messages,
            sourceIds: prepared.sourceIds,
            omittedHistoryMessages: prepared.omittedHistoryMessages,
            maxTokens: request.maxTokens,
            inputBudgetTokens: plan.effectiveInputBudget,
            contextWindow: plan.contextWindow
                ?? TokenEstimator.contextWindow(for: model),
            estimatedInputTokens: prepared.estimatedInputTokens
        )

        task = Task { @MainActor in
            var failure: Error?
            do {
                if useStreaming {
                    for try await event in client.stream(request) {
                        switch event {
                        case .delta(let text):
                            // 只更新控制器里的缓冲；气泡按「换行或时间」合并显示，
                            // 不去碰整份 payload（那是整页重算的源头）。
                            self.pendingDelta += text
                            self.displayBuffer += text
                            self.displayCharacterCount += text.count
                            self.scheduleStreamingFlush(session: session, messageID: messageID)
                            if text.contains("\n") {
                                // 段落边界立刻上屏，避免时间片把一句话切在中间。
                                self.flushStreamingDisplay()
                            } else {
                                self.scheduleStreamingDisplay()
                            }
                        case .reasoning(let text):
                            self.reasoningBuffer += text
                            self.reasoningBufferCharacterCount += text.count
                            self.scheduleStreamingDisplay()
                        case .finished:
                            break
                        }
                        if Task.isCancelled { break }
                    }
                } else {
                    // 用户在设置里关掉了流式：一次性拿完整段再落盘。
                    let text = try await client.complete(request)
                    if !text.isEmpty {
                        self.streamingText = text
                        self.streamingCharacterCount = text.count
                        self.pendingDelta += text
                        self.flushStreaming(session: session, messageID: messageID)
                    }                }
            } catch {
                failure = error
            }
            self.finish(
                failure: failure,
                session: session,
                store: store,
                messageID: messageID,
                isNewMessage: isNewMessage,
                fallbackVariant: fallbackVariant,
                model: model
            )
        }
    }

    /// 安排一次批量落盘。已有任务在等就不重复排，保证最多 1/1.2s 一次。
    private func scheduleStreamingFlush(session: ProjectSession, messageID: String) {
        guard flushTask == nil else { return }
        let interval = flushInterval
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            self.flushStreaming(session: session, messageID: messageID)
            self.flushTask = nil
        }
    }

    /// 安排一次气泡刷新。按设备状态合并到 60–160ms 一次。
    ///
    /// 思考过程也在这里上屏：DeepSeek 开启思考时，正文可能几十秒为空，
    /// 只在 3 秒落盘时更新思考区会让界面看起来卡住。
    private func scheduleStreamingDisplay() {
        guard displayTask == nil else { return }
        let interval = displayInterval
        displayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            self.displayTask = nil
            self.syncStreamingDisplay()
        }
    }

    /// 立即把缓冲刷到气泡（段落边界用）。
    private func flushStreamingDisplay() {
        displayTask?.cancel()
        displayTask = nil
        syncStreamingDisplay()
    }

    /// 文本与思考过程共用一次显示刷新。
    private func syncStreamingDisplay() {
        let textChanged = streamingText != displayBuffer
        let reasoningChanged =
            streamingReasoningCharacterCount != reasoningBufferCharacterCount
        guard textChanged || reasoningChanged else { return }
        if reasoningChanged {
            streamingReasoning = reasoningBuffer
            streamingReasoningCharacterCount = reasoningBufferCharacterCount
        }
        if textChanged {
            streamingText = displayBuffer
            streamingCharacterCount = displayCharacterCount
        }
        displayTick &+= 1
    }

    /// 把缓冲里的增量写进 session。这个操作会让写作页重算一次，所以降频。
    private func flushStreaming(session: ProjectSession, messageID: String) {
        // 生成期间**不**把增量写进 session：appendDelta 不会落盘，却会让
        // `payload` 变化、整个写作台（正文 + 15 条气泡）重算。写回只在
        // finish(...) 里做一次，既少整页刷新，也少一次 JSON 编码前的状态抖动。
        if !reasoningBuffer.isEmpty,
           streamingReasoningCharacterCount != reasoningBufferCharacterCount {
            streamingReasoning = reasoningBuffer
            streamingReasoningCharacterCount = reasoningBufferCharacterCount
        }
        streamFlushTick += 1
        // 每次落盘（约 3 秒）都把已收内容并回会话；进程被杀最多丢这一段。
        checkpoint(session: session)
    }

    /// 页面离开时做一次安全检查点。
    ///
    /// 生成期间不写 session 是为了少整页刷新；但切 Tab/退到后台时把已收到的
    /// 文本并回会话并落盘，避免视图销毁后这段时间的输出全丢。
    func checkpoint(session: ProjectSession) {
        guard isGenerating, let messageID = streamingMessageID else { return }
        persistPendingDelta(session: session, messageID: messageID)
        // 检查点只重写 payload；正文页没有变化，不必整份重编码。
        session.scheduleGenerationCheckpoint()
    }

    /// 把最后一段增量并回会话。只在生成结束/停止时调用，随后 finishAssistantMessage
    /// 会安排一次落盘。
    private func persistPendingDelta(session: ProjectSession, messageID: String) {
        guard !pendingDelta.isEmpty else { return }
        session.appendDelta(pendingDelta, to: messageID)
        pendingDelta = ""
    }

    // MARK: - 后台执行

    /// 进入后台后向系统申请约 30 秒的额外执行时间；生成结束或过期时归还。
    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Frthink.Generate"
        ) { [weak self] in
            Task { @MainActor in
                guard let self, self.isGenerating else { return }
                // 系统要收回时间：先停流，finish 会保留已收内容并标中断。
                self.backgroundExpired = true
                self.stop()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func finish(
        failure: Error?,
        session: ProjectSession,
        store: AppStore,
        messageID: String,
        isNewMessage: Bool,
        fallbackVariant: Int?,
        model: String
    ) {
        defer {
            endBackgroundTask()
            if backgroundExpired,
               session.payload.messages.contains(where: { $0.id == messageID }) {
                session.markInterrupted(messageID)
            }
        }
        // 收尾先落掉最后一段缓冲，再判断内容是否为空。
        flushTask?.cancel()
        flushTask = nil
        displayTask?.cancel()
        displayTask = nil
        if !displayBuffer.isEmpty {
            streamingText = displayBuffer
            streamingCharacterCount = displayCharacterCount
        }
        if reasoningBufferCharacterCount != streamingReasoningCharacterCount {
            streamingReasoning = reasoningBuffer
            streamingReasoningCharacterCount = reasoningBufferCharacterCount
        }
        // 生成期间没有写 session，结束前必须把最后一段增量并回去。
        // 消息可能已经被撤回/删除：此时不能再写回内容，否则删掉的回复会复活。
        if session.payload.messages.contains(where: { $0.id == messageID }) {
            persistPendingDelta(session: session, messageID: messageID)
            flushStreaming(session: session, messageID: messageID)
        }
        session.finishGeneration()

        let wasStopped = stopRequested
        isGenerating = false
        streamingMessageID = nil
        streamingReasoning = nil
        streamingReasoningCharacterCount = 0
        streamingText = ""
        streamingCharacterCount = 0
        pendingDelta = ""
        reasoningBuffer = ""
        reasoningBufferCharacterCount = 0
        displayBuffer = ""
        displayCharacterCount = 0
        stopRequested = false
        task = nil

        let produced = session.payload.messages.first(where: { $0.id == messageID })?.content ?? ""
        let cancelled = wasStopped || isCancellation(failure)

        if cancelled {
            if !produced.isEmpty {
                session.finishAssistantMessage(messageID, model: model)
                store.toast = "生成已停止，已收到的部分内容保存在原气泡"
            } else {
                if isNewMessage {
                    session.deleteMessage(messageID)
                } else if fallbackVariant != nil {
                    session.deleteSelectedVariant(for: messageID)
                }
                store.toast = "生成已停止"
            }
            return
        }

        if let failure {
            if isNewMessage {
                session.deleteMessage(messageID)
            } else if fallbackVariant != nil {
                session.deleteSelectedVariant(for: messageID)
            }
            store.errorMessage = failure.localizedDescription
            return
        }

        // 只有思考过程、没有正文：空气泡没有意义，按失败处理。
        guard !produced.isEmpty else {
            if isNewMessage {
                session.deleteMessage(messageID)
            } else if fallbackVariant != nil {
                session.deleteSelectedVariant(for: messageID)
            }
            store.errorMessage = "模型没有返回正文内容，请检查模型是否支持流式输出。"
            return
        }

        session.finishAssistantMessage(messageID, model: model)
        #if DEBUG
        if LaunchArguments.mockStream {
            print("[MOCK STREAM DONE] chars=\(produced.count)")
        }
        #endif
        maybeAutoSummarize(session: session, store: store)
    }

    /// 上下文占用达到阈值时，自动把未摘要的用户轮次并进长期规则。
    private func maybeAutoSummarize(session: ProjectSession, store: AppStore) {
        let settings = store.settings
        guard settings.autoConversationSummary, !autoSummarizing,
              let provider = settings.activeProvider else { return }
        let threshold = min(max(settings.conversationSummaryThresholdPercent, 1), 100)
        let limit: Int
        do {
            limit = try budget(for: provider, settings: settings).effectiveInputBudget
        } catch {
            // 自动摘要只是后台维护：预算本身不成立时跳过，不额外弹错。
            return
        }
        let used = TokenEstimator.estimate(
            messages: PromptComposer.llmMessages(from: session.payload.messages)
        )
        guard used * 100 >= limit * threshold else { return }

        let summarized = Set(session.payload.world.summarizedMessageIDs)
        let unsummarized = session.payload.messages
            .filter { $0.role == .user && !summarized.contains($0.id) }
            .suffix(12)
        guard !unsummarized.isEmpty else { return }

        let pendingMessages = Array(unsummarized).filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !pendingMessages.isEmpty else { return }
        let ids = pendingMessages.map(\.id)

        autoSummarizing = true
        // 挂句柄：停止生成、切书时能取消，不然它会继续对已被驱逐的会话写盘。
        summaryTask?.cancel()
        summaryTask = Task { @MainActor in
            defer {
                autoSummarizing = false
                summaryTask = nil
            }
            do {
                _ = try await WorldRulesWorkflow.updateLongTermRules(
                    session: session,
                    store: store,
                    sourceMessages: pendingMessages
                )
                for id in ids where !session.payload.world.summarizedMessageIDs.contains(id) {
                    session.payload.world.summarizedMessageIDs.append(id)
                }
                session.scheduleSave()
            } catch {
                // 自动摘要是后台维护，不弹警报；失败原因用轻提示说清楚。
                guard !isCancellation(error) else { return }
                store.toast = error.localizedDescription
            }
        }
    }

    private func isCancellation(_ error: Error?) -> Bool {
        guard let error else { return false }
        return error.isLLMCancellation
    }
}
