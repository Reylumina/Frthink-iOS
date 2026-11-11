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

    /// 界面刷新间隔：默认 60ms（约 16 帧/秒），低电量/机身过热时自动降频。
    ///
    /// 社区实践（Tanay Shah《Why Your iOS Streaming Chat Is Cooking the GPU》）
    /// 与 Apple 的省电/热管理建议一致：设备状态差时少做无谓的排版，
    /// 把 GPU/CPU 留给真正的前台交互。
    private var displayInterval: Duration {
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return .milliseconds(100) }
        switch info.thermalState {
        case .serious, .critical:
            return .milliseconds(90)
        case .fair:
            return .milliseconds(70)
        default:
            return .milliseconds(60)
        }
    }
    /// 本次请求所属的 store。组消息时要读全局设置（预设 / 技能 / 去 AI 味规则 / 语料库），
    /// 这几个值在 `AppSettings` 里，而消息组装函数拿不到 store，所以在这里存一份。
    private weak var activeStore: AppStore?

    /// 预算不足时挂起、等用户确认的操作。
    private var pending: PendingAction?

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
    /// 视图据此把输入框里的文字放回去。
    @discardableResult
    func send(_ text: String, session: ProjectSession, store: AppStore) -> Bool {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !isGenerating else { return false }
        activeStore = store
        return performSend(
            instruction: instruction,
            session: session,
            store: store,
            manuscript: session.manuscript
        )
    }

    /// 续写：不带用户输入，从正文末尾接着写（正文末尾片段作为 assistant 回灌）。
    func continueWriting(session: ProjectSession, store: AppStore) {
        guard !isGenerating else { return }
        activeStore = store
        performContinue(
            session: session,
            store: store,
            manuscript: session.manuscript
        )
    }

    /// 重新生成某条助手回复：旧内容留作上一个版本，新内容写进新版本。
    func regenerate(messageID: String, session: ProjectSession, store: AppStore) {
        guard !isGenerating else { return }
        activeStore = store
        performRegenerate(
            messageID: messageID,
            session: session,
            store: store,
            manuscript: session.manuscript
        )
    }

    /// 停止生成。取消发给 Task，流会在 `onTermination` 里中断网络请求，
    /// 已经收到的部分内容保留。
    func stop() {
        guard isGenerating else { return }
        stopRequested = true
        task?.cancel()
    }

    /// 预算弹窗里点「取消」：把挂起的指令还给输入框，返回 nil 表示没有可恢复的输入。
    func takePendingInstruction() -> String? {
        defer { pending = nil }
        if case .send(let text)? = pending {
            return text
        }
        return nil
    }

    func dismissBudgetAlert() {
        budgetAlert = nil
    }

    /// 预算弹窗里点「裁剪正文后重试」。
    ///
    /// 只裁发给模型的那份正文，`session.manuscript` 保持不变。
    func retryAfterTrimming(session: ProjectSession, store: AppStore) {
        guard let action = pending, let provider = store.settings.activeProvider else {
            budgetAlert = nil
            pending = nil
            return
        }

        let limit = budget(for: provider).effectiveInputBudget
        let manuscript = session.manuscript
        guard let fullMessages = messages(
            for: action,
            session: session,
            manuscript: manuscript,
            bodyRange: .full
        ) else {
            budgetAlert = nil
            restoreFailedRetry(action, store: store)
            store.errorMessage = "上下文预算信息已过期，请重新发送。"
            return
        }

        // 超出的量从正文的 token 预算里扣掉，剩下的才是正文能占的空间。
        let excess = TokenEstimator.estimate(messages: fullMessages) - limit
        let manuscriptBudget = max(512, TokenEstimator.estimate(manuscript) - max(excess, 0))
        let trimmed = WriterBudgeting.trimTail(manuscript, toTokens: manuscriptBudget)

        guard !trimmed.isEmpty, trimmed != manuscript else {
            budgetAlert = nil
            restoreFailedRetry(action, store: store)
            store.errorMessage = "上下文放不下：裁剪正文后仍然超出模型上下文窗。可以先回退几轮对话、精简正文，或在设置里调小输出上限。"
            return
        }

        // 只发了正文末尾一段，提示词里的正文范围标注也要跟着改成「末尾 N 字」。
        let trimmedRange = PromptLibrary.BodyRange.tail(
            count: trimmed.unicodeScalars.count
        )
        guard let nextMessages = messages(
            for: action,
            session: session,
            manuscript: trimmed,
            bodyRange: trimmedRange
        ),
            TokenEstimator.estimate(messages: nextMessages) <= limit else {
            budgetAlert = nil
            restoreFailedRetry(action, store: store)
            store.errorMessage = "上下文放不下：只保留正文末尾 \(trimmed.count) 字仍然超出模型上下文窗，请在设置里调小输出上限。"
            return
        }

        budgetAlert = nil
        pending = nil

        switch action {
        case .send(let instruction):
            _ = performSend(
                instruction: instruction,
                session: session,
                store: store,
                manuscript: trimmed,
                bodyRange: trimmedRange
            )
        case .regenerate(let messageID):
            performRegenerate(
                messageID: messageID,
                session: session,
                store: store,
                manuscript: trimmed,
                bodyRange: trimmedRange
            )
        case .continuation:
            performContinue(
                session: session,
                store: store,
                manuscript: trimmed,
                bodyRange: trimmedRange
            )
        }
    }

    /// 重试失败时把指令还给输入框（只有「发送」有可恢复的文本）。
    private func restoreFailedRetry(_ action: PendingAction, store: AppStore) {
        if case .send(let text) = action {
            instructionToRestore = text
        }
        pending = nil
    }

    // MARK: - 三个入口的实现

    private func performSend(
        instruction: String,
        session: ProjectSession,
        store: AppStore,
        manuscript: String,
        bodyRange: PromptLibrary.BodyRange = .full
    ) -> Bool {
        do {
            let (client, provider) = try activeClient(store: store)
            let prepared = chatMessages(
                instruction: instruction,
                session: session,
                manuscript: manuscript,
                bodyRange: bodyRange
            )
            if let issue = budgetIssue(messages: prepared.messages, provider: provider) {
                pending = .send(instruction)
                budgetAlert = issue
                return true
            }
            session.addUserMessage(instruction)
            let assistant = session.beginAssistantMessage(model: provider.resolvedModel)
            run(
                client: client,
                provider: provider,
                prepared: prepared,
                session: session,
                store: store,
                messageID: assistant.id,
                isNewMessage: true,
                fallbackVariant: nil
            )
            return true
        } catch {
            store.errorMessage = error.localizedDescription
            return false
        }
    }

    private func performContinue(
        session: ProjectSession,
        store: AppStore,
        manuscript: String,
        bodyRange: PromptLibrary.BodyRange = .full
    ) {
        do {
            let (client, provider) = try activeClient(store: store)
            // 续写不新增用户气泡，直接接在现有对话后面。
            let prepared = continueMessages(
                session: session,
                manuscript: manuscript,
                bodyRange: bodyRange
            )
            if let issue = budgetIssue(messages: prepared.messages, provider: provider) {
                pending = .continuation
                budgetAlert = issue
                return
            }
            let assistant = session.beginAssistantMessage(model: provider.resolvedModel)
            run(
                client: client,
                provider: provider,
                prepared: prepared,
                session: session,
                store: store,
                messageID: assistant.id,
                isNewMessage: true,
                fallbackVariant: nil
            )
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    private func performRegenerate(
        messageID: String,
        session: ProjectSession,
        store: AppStore,
        manuscript: String,
        bodyRange: PromptLibrary.BodyRange = .full
    ) {
        guard let index = session.payload.messages.firstIndex(where: { $0.id == messageID }),
              session.payload.messages[index].role == .assistant else {
            store.toast = "这条助手消息已经不存在了"
            return
        }
        session.clearInterrupted(messageID)

        do {
            let (client, provider) = try activeClient(store: store)
            let prepared = regenerateMessages(
                beforeIndex: index,
                session: session,
                manuscript: manuscript,
                bodyRange: bodyRange
            )
            if let issue = budgetIssue(messages: prepared.messages, provider: provider) {
                pending = .regenerate(messageID)
                budgetAlert = issue
                return
            }
            let previousVariant = session.payload.messages[index].selectedVariant
            // 新版本是空的并被选中，后面的 appendDelta 会写进它。
            session.addVariant(to: messageID)
            run(
                client: client,
                provider: provider,
                prepared: prepared,
                session: session,
                store: store,
                messageID: messageID,
                isNewMessage: false,
                fallbackVariant: previousVariant
            )
        } catch {
            store.errorMessage = error.localizedDescription
        }
    }

    // MARK: - 请求组装

    /// 组装结果：发给模型的消息、来源块、被裁掉的历史条数。
    private struct PreparedPrompt {
        let messages: [LLMMessage]
        let sourceIds: [String]
        let omittedHistoryMessages: Int
    }

    /// 把全局设置（预设 / 技能 / 去 AI 味规则 / 语料库）与项目负载装配成
    /// 规格 §1 的 14 个块。
    /// 按原版 `bodyPrompt*` 决定这次请求发哪一段正文。
    ///
    /// 原版实测 `bodyPromptSendWhole = false`、`bodyPromptTailCodePoints = 5000`：
    /// **续写只把正文末尾 5000 码点发过去**，不是全文。之前一律发全文，
    /// 提示词和原版不一致，长书还会把上下文撑爆。
    private func effectiveBody(
        _ session: ProjectSession,
        manuscript: String,
        fallbackRange: PromptLibrary.BodyRange
    ) -> (text: String, range: PromptLibrary.BodyRange) {
        // 调用方显式给了裁剪范围（预算重试）就尊重它，正文也用调用方传进来的
        // 那一份；这里再读 session.manuscript 会把裁剪结果丢掉。
        if fallbackRange != .full {
            return (manuscript, fallbackRange)
        }
        let whole = manuscript
        if let anchor = session.payload.continuationAnchor,
           anchor > 0, anchor <= (whole as NSString).length {
            let prefix = (whole as NSString).substring(to: anchor)
            return (prefix, .anchorPrefix(count: prefix.count))
        }
        if session.payload.bodyPromptSendWhole {
            return (whole, .full)
        }
        let limit = max(256, session.payload.bodyPromptTailCodePoints)
        return (PromptComposer.codePointTail(whole, limit: limit), .tail(count: limit))
    }
    private func assembly(
        session: ProjectSession,
        manuscript: String,
        bodyRange: PromptLibrary.BodyRange
    ) -> PromptAssembly {
        // 真正发出去的正文按原版 bodyPrompt* 收口，不是调用方传进来的整篇。
        let effective = effectiveBody(
            session,
            manuscript: manuscript,
            fallbackRange: bodyRange
        )
        return PromptAssembly.from(
            world: session.payload.world,
            manuscript: effective.text,
            assistantSupplement: session.payload.assistantSupplement,
            settings: activeStore?.settings ?? AppSettings(),
            projectID: session.project.id,
            enabledUniverseEntryIDs: session.payload.enabledUniverseEntryIDs,
            bodyRange: effective.range
        )
    }

    private func chatMessages(
        instruction: String,
        session: ProjectSession,
        manuscript: String,
        bodyRange: PromptLibrary.BodyRange
    ) -> PreparedPrompt {
        let assembly = assembly(session: session, manuscript: manuscript, bodyRange: bodyRange)
        let built = PromptComposer.writingMessages(
            assembly: assembly,
            history: llmMessages(session.payload.messages),
            userInstruction: instruction
        )
        let trimmed = trimHistory(built, budget: budgetLimit())
        return PreparedPrompt(
            messages: trimmed.messages,
            sourceIds: assembly.sourceIds,
            omittedHistoryMessages: trimmed.omitted
        )
    }

    /// 续写：不带用户输入，把正文末尾当作「已生成的末尾片段」喂回去，让模型从它
    /// 后面接着写。Core 的 `continueFragmentMessages` 会自己取片段的最后 2000 个
    /// 码点（对齐 Android 端 `b3/l.java:1963-1975`），这里传整份正文即可。
    private func continueMessages(
        session: ProjectSession,
        manuscript: String,
        bodyRange: PromptLibrary.BodyRange
    ) -> PreparedPrompt {
        let assembly = assembly(session: session, manuscript: manuscript, bodyRange: bodyRange)
        let built = PromptComposer.continueFragmentMessages(
            assembly: assembly,
            history: llmMessages(session.payload.messages),
            fragment: manuscript
        )
        let trimmed = trimHistory(built, budget: budgetLimit())
        return PreparedPrompt(
            messages: trimmed.messages,
            sourceIds: assembly.sourceIds,
            omittedHistoryMessages: trimmed.omitted
        )
    }

    /// 重新生成时上下文只到这条回复之前。前一条如果是用户指令，它已经在
    /// history 里，不再重复传 userInstruction；如果前面已经是助手回复
    /// （比如这条本身就是「续写」生成的），就重跑同一条续写路径。
    private func regenerateMessages(
        beforeIndex index: Int,
        session: ProjectSession,
        manuscript: String,
        bodyRange: PromptLibrary.BodyRange
    ) -> PreparedPrompt {
        let conversation = session.payload.messages
        let prefix = index > 0 ? Array(conversation[..<index]) : []
        let history = llmMessages(prefix)
        let assembly = assembly(session: session, manuscript: manuscript, bodyRange: bodyRange)

        let built: [LLMMessage]
        if let last = history.last, last.role == "assistant" {
            built = PromptComposer.continueFragmentMessages(
                assembly: assembly,
                history: history,
                fragment: manuscript
            )
        } else {
            built = PromptComposer.writingMessages(
                assembly: assembly,
                history: history,
                userInstruction: nil
            )
        }
        let trimmed = trimHistory(built, budget: budgetLimit())
        return PreparedPrompt(
            messages: trimmed.messages,
            sourceIds: assembly.sourceIds,
            omittedHistoryMessages: trimmed.omitted
        )
    }

    private func llmMessages(_ messages: [ChatMessage]) -> [LLMMessage] {
        messages.compactMap { message -> LLMMessage? in
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            switch message.role {
            case .user: return LLMMessage.user(content)
            case .assistant: return LLMMessage.assistant(content)
            case .system: return LLMMessage.system(content)
            }
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
    private func budget(for provider: ProviderSetting) -> PromptBudget {
        let settings = activeStore?.settings ?? AppSettings()
        let window = settings.contextWindowTokens > 0
            ? settings.contextWindowTokens
            : TokenEstimator.contextWindow(for: provider.resolvedModel)
        if let made = try? PromptBudget.make(
            settings: settings,
            model: provider.resolvedModel,
            contextWindowOverride: window
        ) {
            return made
        }
        // 窗口连输出都放不下：退化成「输入预算为准」，后续 budgetIssue 会拦住。
        return PromptBudget(
            inputBudget: settings.inputBudgetTokens,
            outputBudget: settings.reservedOutputTokens,
            effectiveInputBudget: settings.inputBudgetTokens,
            contextWindow: window
        )
    }

    /// 当前供应方的有效输入预算。
    private func budgetLimit() -> Int {
        guard let provider = activeStore?.settings.activeProvider else {
            return (activeStore?.settings ?? AppSettings()).inputBudgetTokens
        }
        return budget(for: provider).effectiveInputBudget
    }

    private func budgetIssue(messages: [LLMMessage], provider: ProviderSetting) -> BudgetAlert? {
        let plan = budget(for: provider)
        let estimated = TokenEstimator.estimate(messages: messages)
        guard estimated > plan.effectiveInputBudget else { return nil }
        return BudgetAlert(
            estimated: estimated,
            limit: plan.effectiveInputBudget,
            window: plan.contextWindow ?? 0,
            reserve: plan.outputBudget
        )
    }

    /// 历史裁剪（原版 `L1/e3.java:172-198`）：按「用户轮」从末尾整轮加入，
    /// 超预算就停；不拆散用户指令与助手回复。system 块和本轮用户指令永远保留。
    private func trimHistory(
        _ messages: [LLMMessage],
        budget: Int
    ) -> (messages: [LLMMessage], omitted: Int) {
        guard messages.count > 1 else { return (messages, 0) }
        var system: LLMMessage?
        var tail: LLMMessage?
        var history = messages
        if history.first?.role == "system" {
            system = history.removeFirst()
        }
        if history.last?.role == "user" {
            tail = history.removeLast()
        }

        // 每个 turn 从 user 开始，带上其后的 assistant/system，直到下一个 user。
        var turns: [[LLMMessage]] = []
        for message in history {
            if message.role == "user" || turns.isEmpty {
                turns.append([message])
            } else {
                turns[turns.count - 1].append(message)
            }
        }

        var used = (system.map { TokenEstimator.estimate($0.content) } ?? 0)
            + (tail.map { TokenEstimator.estimate($0.content) } ?? 0)
        var keptTurns: [[LLMMessage]] = []
        for turn in turns.reversed() {
            let cost = turn.reduce(0) { $0 + TokenEstimator.estimate($1.content) }
            if used + cost > budget { break }
            used += cost
            keptTurns.append(turn)
        }
        let kept = keptTurns.reversed().flatMap { $0 }
        let omitted = history.count - kept.count

        var result: [LLMMessage] = []
        if let system { result.append(system) }
        result.append(contentsOf: kept)
        if let tail { result.append(tail) }
        return (result, omitted)
    }

    // MARK: - 流式

    private func run(
        client: any LLMClient,
        provider: ProviderSetting,
        prepared: PreparedPrompt,
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

        let plan = budget(for: provider)
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
                ?? TokenEstimator.contextWindow(for: model)
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
        session.scheduleSave()
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
        persistPendingDelta(session: session, messageID: messageID)
        flushStreaming(session: session, messageID: messageID)
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
                    session.removeMessage(messageID)
                } else if let fallbackVariant {
                    session.selectVariant(fallbackVariant, for: messageID)
                }
                store.toast = "生成已停止"
            }
            return
        }

        if let failure {
            if isNewMessage {
                session.removeMessage(messageID)
            } else if let fallbackVariant {
                session.selectVariant(fallbackVariant, for: messageID)
            }
            store.errorMessage = failure.localizedDescription
            return
        }

        // 只有思考过程、没有正文：空气泡没有意义，按失败处理。
        guard !produced.isEmpty else {
            if isNewMessage {
                session.removeMessage(messageID)
            } else if let fallbackVariant {
                session.selectVariant(fallbackVariant, for: messageID)
            }
            store.errorMessage = "模型没有返回正文内容，请检查模型是否支持流式输出。"
            return
        }

        session.finishAssistantMessage(messageID, model: model)
        maybeAutoSummarize(session: session, store: store)
    }

    /// 上下文占用达到阈值时，自动把未摘要的用户轮次并进长期规则。
    private func maybeAutoSummarize(session: ProjectSession, store: AppStore) {
        let settings = store.settings
        guard settings.autoConversationSummary, !autoSummarizing,
              let provider = settings.activeProvider else { return }
        let threshold = min(max(settings.conversationSummaryThresholdPercent, 1), 100)
        let limit = budget(for: provider).effectiveInputBudget
        let used = TokenEstimator.estimate(messages: llmMessages(session.payload.messages))
        guard used * 100 >= limit * threshold else { return }

        let summarized = Set(session.payload.world.summarizedMessageIDs)
        let pending = session.payload.messages
            .filter { $0.role == .user && !summarized.contains($0.id) }
            .suffix(12)
        guard !pending.isEmpty else { return }

        let pendingMessages = Array(pending).filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !pendingMessages.isEmpty else { return }
        let ids = pendingMessages.map(\.id)

        autoSummarizing = true
        Task { @MainActor in
            defer { autoSummarizing = false }
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
        if error is CancellationError { return true }
        if let llmError = error as? LLMError, llmError == .cancelled { return true }
        return false
    }

    // MARK: - 预算操作

    private func messages(
        for action: PendingAction,
        session: ProjectSession,
        manuscript: String,
        bodyRange: PromptLibrary.BodyRange
    ) -> [LLMMessage]? {
        switch action {
        case .send(let instruction):
            return chatMessages(
                instruction: instruction,
                session: session,
                manuscript: manuscript,
                bodyRange: bodyRange
            ).messages
        case .regenerate(let messageID):
            guard let index = session.payload.messages.firstIndex(where: { $0.id == messageID })
            else { return nil }
            return regenerateMessages(
                beforeIndex: index,
                session: session,
                manuscript: manuscript,
                bodyRange: bodyRange
            ).messages
        case .continuation:
            return continueMessages(
                session: session,
                manuscript: manuscript,
                bodyRange: bodyRange
            ).messages
        }
    }
}

// MARK: - 正文裁剪

/// 把正文裁到 token 预算内，保留末尾。
///
/// `TokenEstimator.trimTail` 的字符数是从预算出发向上收敛（`chars * 3 / 2`），
/// 中文差不多 1 字 1 token，起点就等于预算，估算永远超一点，于是一路放大到原文，
/// 等于没裁。这里改从「预算字符数的九成」起手、放不下再折半，能放下的尾部再交给
/// `trimTail` 收口。Core 那边改之前，写作台的「裁剪正文」走这一条。
private enum WriterBudgeting {
    static func trimTail(_ text: String, toTokens budget: Int) -> String {
        guard budget > 0 else { return "" }
        guard TokenEstimator.estimate(text) > budget else { return text }

        var chars = min(text.count, max(64, budget * 9 / 10))
        while chars >= 64 {
            let start = text.index(text.endIndex, offsetBy: -chars)
            let slice = String(text[start...])
            let trimmed = TokenEstimator.trimTail(slice, toTokens: budget)
            if TokenEstimator.estimate(trimmed) <= budget {
                return trimmed
            }
            chars /= 2
        }
        return ""
    }
}
