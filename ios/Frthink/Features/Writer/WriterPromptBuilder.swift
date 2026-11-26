// 本文件负责：写作台请求组装 —— 把值类型快照变成要发给模型的消息。
//
// 提示词组装基于不可变快照在后台执行，避免长篇正文与历史记录处理阻塞主线程。

import Foundation

/// 一次写作请求的动作。
enum WriterPromptAction: Equatable {
    case send(instruction: String)
    case continueWriting
    case regenerate(beforeIndex: Int)
}

/// 组装一次请求所需的全部输入。全部是值类型，可安全跨线程。
struct WriterPromptSnapshot {
    var action: WriterPromptAction
    var manuscript: String
    var messages: [ChatMessage]
    var world: WorldBook
    var assistantSupplement: String
    var settings: AppSettings
    var projectID: String
    var enabledUniverseEntryIDs: [String]
    var bodyPromptSendWhole: Bool
    var bodyPromptTailCodePoints: Int
    var continuationAnchor: Int?
    /// 本场正文起始位置（UTF-16 偏移）；非 nil 时仅将本场起点之后的正文放入活跃正文窗口。
    var sceneBoundaryOffset: Int? = nil
    /// 调用方显式指定的正文范围（预算重试的末尾片段）；`.full` 表示按设置推导。
    var explicitBodyRange: PromptLibrary.BodyRange
    /// 历史裁剪与预算检查共用的有效输入预算。
    var inputBudget: Int
    /// 上几轮激活、仍处于 Sticky 黏性窗口内的人物卡/事件卡/世界书词条 id。
    var stickyCharacterIDs: Set<String> = []
    var stickyEventIDs: Set<String> = []
    var stickyWorldbookIDs: Set<String> = []
    /// 叙事工作区；非 nil 时优先走缓存优先与按需状态装配管线。
    var narrativeWorkspace: NarrativeWorkspace? = nil
    /// 显式覆写只读工具开关；nil 时依据当前服务商协议自动决定。
    var enableReadOnlyTools: Bool? = nil
    /// 增量分页 BM25 索引快照，供无工具通道复用按页缓存检索。
    var bm25Index: ManuscriptIndex.IncrementalBM25Index? = nil
}

struct WriterPreparedPrompt {
    var messages: [LLMMessage]
    var sourceIds: [String]
    var omittedHistoryMessages: Int
    var estimatedInputTokens: Int
    var matchedCharacterIDs: Set<String> = []
    var matchedEventIDs: Set<String> = []
    var matchedWorldbookIDs: Set<String> = []
    var tools: [LLMToolDefinition] = []
    var updatedReFoldBoundary: ReFoldBoundary? = nil
    /// 与 `ReFoldManager` 折叠序号严格对齐的完整历史快照，供流式 `restore_turn` 工具无失真回查。
    var toolHistory: [LLMMessage] = []
}

/// 预算重试的三种结果。
enum WriterPromptRetryResult {
    case prepared(WriterPreparedPrompt)
    /// 正文已经剪无可剪，仍放不下。
    case cannotTrim
    /// 剪到末尾后还是超预算。
    case stillTooLarge(characters: Int)
}

enum WriterPromptBuilder {

    /// 一次组装。纯函数，不碰会话与磁盘；不做取消检查（自检这类纯逻辑调用用）。
    static func prepare(_ snapshot: WriterPromptSnapshot) -> WriterPreparedPrompt {
        build(snapshot, checkpoint: {})
    }

    /// 可取消的组装：每个耗时阶段前检查任务取消。
    ///
    /// 阶段间执行取消检查，确保在任务取消时及时中断计算。
    static func prepareCancellable(_ snapshot: WriterPromptSnapshot) throws -> WriterPreparedPrompt {
        try build(snapshot) {
            try Task.checkCancellation()
        }
    }

    /// 组装本体。`checkpoint` 在每个阶段前调用，调用方决定要不要检查取消。
    private static func build(
        _ snapshot: WriterPromptSnapshot,
        checkpoint: () throws -> Void
    ) rethrows -> WriterPreparedPrompt {
        try checkpoint()
        if let workspace = snapshot.narrativeWorkspace {
            return try buildWithNarrativeOrchestrator(
                snapshot,
                workspace: workspace,
                checkpoint: checkpoint
            )
        }
        let effective = effectiveBody(snapshot)
        try checkpoint()
        var assembly = PromptAssembly.from(
            world: snapshot.world,
            manuscript: effective.text,
            assistantSupplement: snapshot.assistantSupplement,
            settings: snapshot.settings,
            projectID: snapshot.projectID,
            enabledUniverseEntryIDs: snapshot.enabledUniverseEntryIDs,
            bodyRange: effective.range
        )
        if case .anchorPrefix = effective.range, !effective.text.isEmpty {
            let anchorTail = PromptComposer.codePointTail(effective.text, limit: 200)
            assembly.appendedBlocks.append(PromptBlock(
                key: "task:continuation-anchor",
                category: .userInput,
                title: "指定续写锚点",
                body: PromptLibrary.render(PromptLibrary.continuationAnchorTemplate, [
                    "锚点文本": anchorTail,
                ]),
                locked: true
            ))
        }
        let currentInstruction: String?
        if case .send(let instruction) = snapshot.action {
            currentInstruction = instruction
        } else {
            currentInstruction = nil
        }
        let scanText = DynamicContextSelector.makeScanText(
            instruction: currentInstruction,
            messages: snapshot.messages,
            bodyWindow: effective.text
        )
        let dynamicSelection = DynamicContextSelector.select(
            world: snapshot.world,
            assemblyWorldbooks: assembly.worldbooks,
            scanText: scanText,
            inputBudget: snapshot.inputBudget,
            stickyCharacterIDs: snapshot.stickyCharacterIDs,
            stickyEventIDs: snapshot.stickyEventIDs,
            stickyWorldbookIDs: snapshot.stickyWorldbookIDs,
            enabled: snapshot.settings.dynamicContextActivation
        )
        assembly.characters = dynamicSelection.characters
        assembly.plotOutline = dynamicSelection.renderedEvents
        assembly.worldbooks = dynamicSelection.worldbooks

        if let sceneMemory = SceneMemoryBuilder.composeSceneMemoryBlock(
            snapshot: snapshot,
            effectiveBodyText: effective.text,
            activeCharacters: dynamicSelection.characters,
            offStageSummary: dynamicSelection.offStageSummary,
            activatedWorldbookKeys: dynamicSelection.activatedWorldbookKeys,
            currentInstruction: currentInstruction
        ) {
            assembly.appendedBlocks.append(sceneMemory)
        }
        let styleRef = StyleDistiller.styleReferenceBlock(
            from: assembly.corpus,
            maxSamples: 2,
            tokenBudget: max(1, snapshot.inputBudget / 4),
            instructionText: currentInstruction,
            queryText: PromptComposer.codePointTail(effective.text, limit: 800)
        )
        if let block = styleRef.block {
            assembly.appendedBlocks.append(block)
        }
        if !styleRef.injectedEntryIDs.isEmpty {
            assembly.corpus.removeAll { styleRef.injectedEntryIDs.contains($0.entryID) }
        }
        if snapshot.settings.dynamicContextActivation {
            assembly.corpus = DynamicContextSelector.selectCorpus(
                assembly.corpus,
                scanText: scanText,
                budget: max(1, snapshot.inputBudget / 4)
            )
        }
        try checkpoint()

        let prefixMessages = PromptComposer.writingPrefixMessages(
            assembly: assembly
        )
        let reasoningPolicy = snapshot.settings.reasoningContextPolicy
        let history: [LLMMessage]
        let built: [LLMMessage]
        switch snapshot.action {
        case .send(let instruction):
            history = PromptComposer.llmMessages(from: snapshot.messages, reasoningPolicy: reasoningPolicy)
            built = PromptComposer.writingMessages(
                assembly: assembly,
                history: history,
                userInstruction: instruction
            )
        case .continueWriting:
            // 若最后一条就是助手消息，将其从历史中剥离并作为续接片段，避免同一内容重复发送两遍。
            if let last = snapshot.messages.last, last.role == .assistant {
                let fragment = last.content
                history = PromptComposer.llmMessages(
                    from: snapshot.messages.dropLast(),
                    reasoningPolicy: reasoningPolicy
                )
                built = PromptComposer.continueFragmentMessages(
                    assembly: assembly,
                    history: history,
                    fragment: fragment
                )
            } else {
                history = PromptComposer.llmMessages(
                    from: snapshot.messages,
                    reasoningPolicy: reasoningPolicy
                )
                built = PromptComposer.writingMessages(
                    assembly: assembly,
                    history: history,
                    userInstruction: PromptLibrary.continueLatestBubbleInstruction
                )
            }
        case .regenerate(let index):
            let prefix = index > 0
                ? Array(snapshot.messages[..<min(index, snapshot.messages.count)])
                : []
            var regenHistory = PromptComposer.llmMessages(
                from: prefix,
                reasoningPolicy: reasoningPolicy
            )
            if let last = regenHistory.last, last.role == "assistant" {
                regenHistory.removeLast()
                built = PromptComposer.continueFragmentMessages(
                    assembly: assembly,
                    history: regenHistory,
                    fragment: last.content
                )
            } else {
                built = PromptComposer.writingMessages(
                    assembly: assembly,
                    history: regenHistory,
                    userInstruction: nil
                )
            }
        }
        try checkpoint()

        let trimmed = try trimHistory(
            built,
            protectedPrefixCount: prefixMessages.count,
            budget: snapshot.inputBudget,
            checkpoint: checkpoint
        )
        try checkpoint()
        let finalMessages = trimmed.messages
        return WriterPreparedPrompt(
            messages: finalMessages,
            sourceIds: assembly.sourceIds,
            omittedHistoryMessages: trimmed.omitted,
            estimatedInputTokens: TokenEstimator.estimate(messages: finalMessages),
            matchedCharacterIDs: dynamicSelection.matchedCharacterIDs,
            matchedEventIDs: dynamicSelection.matchedEventIDs,
            matchedWorldbookIDs: dynamicSelection.matchedWorldbookIDs
        )
    }

    private static func buildWithNarrativeOrchestrator(
        _ snapshot: WriterPromptSnapshot,
        workspace: NarrativeWorkspace,
        checkpoint: () throws -> Void
    ) rethrows -> WriterPreparedPrompt {
        try checkpoint()
        let reasoningPolicy = snapshot.settings.reasoningContextPolicy
        let tailTier: ManuscriptTailTier = snapshot.bodyPromptSendWhole
            ? .long
            : ManuscriptTailTier.from(codePoints: snapshot.bodyPromptTailCodePoints)
        let tailCodePointOverride: Int?
        if case .tail(let explicitCount) = snapshot.explicitBodyRange {
            tailCodePointOverride = max(256, explicitCount)
        } else {
            tailCodePointOverride = nil
        }
        let enableTools = snapshot.enableReadOnlyTools
            ?? NarrativeReadTools.supportsNativeTools(provider: snapshot.settings.activeProvider)

        var history: [LLMMessage]
        let userInstruction: String?
        var continuationFragment: String?

        switch snapshot.action {
        case .send(let instruction):
            history = PromptComposer.llmMessages(
                from: snapshot.messages,
                reasoningPolicy: reasoningPolicy
            )
            userInstruction = instruction
        case .continueWriting:
            if let last = snapshot.messages.last,
               last.role == .assistant,
               last.contextMode == .normal {
                history = PromptComposer.llmMessages(
                    from: snapshot.messages.dropLast(),
                    reasoningPolicy: reasoningPolicy
                )
                continuationFragment = last.content
                userInstruction = nil
            } else {
                history = PromptComposer.llmMessages(
                    from: snapshot.messages,
                    reasoningPolicy: reasoningPolicy
                )
                userInstruction = PromptLibrary.continueLatestBubbleInstruction
            }
        case .regenerate(let index):
            let prefix = index > 0
                ? Array(snapshot.messages[..<min(index, snapshot.messages.count)])
                : []
            var regenHistory = PromptComposer.llmMessages(
                from: prefix,
                reasoningPolicy: reasoningPolicy
            )
            if let last = regenHistory.last, last.role == "assistant" {
                regenHistory.removeLast()
                continuationFragment = last.content
            }
            history = regenHistory
            userInstruction = nil
        }

        try checkpoint()
        let orchestrated = NarrativeContextOrchestrator.compose(
            workspace: workspace,
            manuscript: snapshot.manuscript,
            history: history,
            userInstruction: userInstruction,
            settings: snapshot.settings,
            enabledUniverseEntryIDs: snapshot.enabledUniverseEntryIDs,
            continuationAnchor: snapshot.continuationAnchor,
            sceneBoundaryOffset: snapshot.sceneBoundaryOffset,
            tailTier: tailTier,
            tailCodePointLimitOverride: tailCodePointOverride,
            inputBudget: snapshot.inputBudget,
            enableTools: enableTools,
            povCharacterID: workspace.activePOVCharacterID,
            bm25Index: snapshot.bm25Index
        )
        try checkpoint()

        var finalMessages = orchestrated.messages
        if let fragment = continuationFragment, !fragment.isEmpty {
            finalMessages.append(.assistant(PromptComposer.codePointTail(fragment, limit: 2_000)))
            finalMessages.append(.user(PromptLibrary.continueLastFragmentInstruction))
        }

        var sourceIDs = ["narrative:frozen-prefix", "narrative:query-cone"]
        if orchestrated.usedFallbackBM25 {
            sourceIDs.append("narrative:fallback-bm25")
        }
        return WriterPreparedPrompt(
            messages: finalMessages,
            sourceIds: sourceIDs,
            omittedHistoryMessages: 0,
            estimatedInputTokens: TokenEstimator.estimate(messages: finalMessages),
            matchedCharacterIDs: orchestrated.onStageEntityIDs,
            matchedEventIDs: [],
            matchedWorldbookIDs: [],
            tools: orchestrated.tools,
            updatedReFoldBoundary: orchestrated.updatedReFoldBoundary,
            toolHistory: orchestrated.tools.isEmpty ? [] : history
        )
    }

    /// 预算超限时裁剪正文尾部并重新组装，支持异步取消。
    static func retryAfterTrimming(_ snapshot: WriterPromptSnapshot) throws -> WriterPromptRetryResult {
        try Task.checkCancellation()
        var full = snapshot
        full.explicitBodyRange = .full
        let preparedFull = try prepareCancellable(full)
        try Task.checkCancellation()

        // 预算基数基于实际待发送正文片段计算，避免全量正文干扰裁剪口径。
        let baselineTailText: String
        if snapshot.narrativeWorkspace != nil {
            let tailTier: ManuscriptTailTier = snapshot.bodyPromptSendWhole
                ? .long
                : ManuscriptTailTier.from(codePoints: snapshot.bodyPromptTailCodePoints)
            let overrideCount: Int?
            if case .tail(let explicitCount) = snapshot.explicitBodyRange {
                overrideCount = max(256, explicitCount)
            } else {
                overrideCount = nil
            }
            baselineTailText = NarrativeContextOrchestrator.effectiveTailText(
                manuscript: snapshot.manuscript,
                continuationAnchor: snapshot.continuationAnchor,
                sceneBoundaryOffset: snapshot.sceneBoundaryOffset,
                tailTier: tailTier,
                tailCodePointLimitOverride: overrideCount
            ).tailText
        } else {
            baselineTailText = effectiveBody(snapshot).text
        }

        let excess = preparedFull.estimatedInputTokens - snapshot.inputBudget
        let manuscriptBudget = max(
            256,
            TokenEstimator.estimate(baselineTailText) - max(excess, 0)
        )
        let trimmed = try WriterBudgeting.trimTail(
            baselineTailText,
            toTokens: manuscriptBudget
        )
        try Task.checkCancellation()
        guard !trimmed.isEmpty, trimmed != baselineTailText else {
            return .cannotTrim
        }

        var next = snapshot
        next.manuscript = trimmed
        if next.narrativeWorkspace != nil {
            next.continuationAnchor = nil
            next.sceneBoundaryOffset = nil
        }
        next.explicitBodyRange = .tail(count: trimmed.unicodeScalars.count)
        let prepared = try prepareCancellable(next)
        try Task.checkCancellation()
        guard prepared.estimatedInputTokens <= snapshot.inputBudget else {
            return .stillTooLarge(characters: trimmed.count)
        }
        return .prepared(prepared)
    }

    // MARK: - 正文范围

    /// 按原版 `bodyPrompt*` 决定这次发哪一段正文。
    ///
    /// 默认采用局部截取策略，发送末尾预设码点数的正文片段。
    private static func effectiveBody(
        _ snapshot: WriterPromptSnapshot
    ) -> (text: String, range: PromptLibrary.BodyRange) {
        if snapshot.explicitBodyRange != .full {
            return (snapshot.manuscript, snapshot.explicitBodyRange)
        }
        let whole = snapshot.manuscript
        let prefix: String
        let baseRange: PromptLibrary.BodyRange
        if let anchor = snapshot.continuationAnchor,
           anchor > 0, anchor <= (whole as NSString).length {
            prefix = (whole as NSString).substring(to: anchor)
            baseRange = .anchorPrefix(count: prefix.count)
        } else {
            prefix = whole
            baseRange = .full
        }

        let nsPrefix = prefix as NSString
        let scopedText: String
        if let boundary = snapshot.sceneBoundaryOffset, boundary > 0 {
            if boundary >= nsPrefix.length {
                return ("", .tail(count: 0))
            }
            let safeStart = nsPrefix.rangeOfComposedCharacterSequence(at: boundary).location
            scopedText = nsPrefix.substring(from: safeStart)
        } else {
            scopedText = prefix
        }

        if snapshot.bodyPromptSendWhole || baseRange != .full {
            let finalRange: PromptLibrary.BodyRange = (scopedText == prefix)
                ? baseRange
                : .tail(count: scopedText.count)
            return (scopedText, finalRange)
        }
        let limit = max(256, snapshot.bodyPromptTailCodePoints)
        return (PromptComposer.codePointTail(scopedText, limit: limit), .tail(count: limit))
    }

    // MARK: - 历史

    /// 历史裁剪（原版 `L1/e3.java:172-198`）：按「用户轮」从末尾整轮加入，
    /// 超预算就停；不拆散用户指令与助手回复。system 块、只读上下文块（正文/长期规则/锚点）
    /// 和本轮用户指令永远保留，仅裁剪对话历史。
    private static func trimHistory(
        _ messages: [LLMMessage],
        protectedPrefixCount: Int,
        budget: Int,
        checkpoint: () throws -> Void
    ) rethrows -> (messages: [LLMMessage], omitted: Int) {
        guard messages.count > 1 else { return (messages, 0) }
        var history = messages
        let prefixCount = min(max(protectedPrefixCount, 0), history.count)
        let protectedPrefix = Array(history.prefix(prefixCount))
        history.removeFirst(prefixCount)

        var tailMessages: [LLMMessage] = []
        if history.last?.role == "user" {
            let lastUser = history.removeLast()
            if lastUser.content == PromptLibrary.continueLastFragmentInstruction,
               history.last?.role == "assistant" {
                let fragment = history.removeLast()
                tailMessages = [fragment, lastUser]
            } else {
                tailMessages = [lastUser]
            }
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

        var used = protectedPrefix.reduce(0) { $0 + TokenEstimator.estimate($1.content) }
            + tailMessages.reduce(0) { $0 + TokenEstimator.estimate($1.content) }
        var keptTurns: [[LLMMessage]] = []
        for turn in turns.reversed() {
            try checkpoint()
            let cost = turn.reduce(0) { $0 + TokenEstimator.estimate($1.content) }
            if used + cost > budget { break }
            used += cost
            keptTurns.append(turn)
        }
        let kept = keptTurns.reversed().flatMap { $0 }
        let omitted = history.count - kept.count

        var result = protectedPrefix
        result.append(contentsOf: kept)
        result.append(contentsOf: tailMessages)
        return (result, omitted)
    }
}

/// 把正文裁到 token 预算内，保留末尾。
///
/// 基于预算九成字符量初始化探测窗口并二分折半，最后由 `TokenEstimator.trimTail` 进行精确收口截断。
enum WriterBudgeting {
    static func trimTail(_ text: String, toTokens budget: Int) throws -> String {
        guard budget > 0 else { return "" }
        guard TokenEstimator.estimate(text) > budget else { return text }

        var chars = min(text.count, max(64, budget * 9 / 10))
        while chars >= 64 {
            try Task.checkCancellation()
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
