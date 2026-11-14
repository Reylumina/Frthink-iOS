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
    /// 调用方显式指定的正文范围（预算重试的末尾片段）；`.full` 表示按设置推导。
    var explicitBodyRange: PromptLibrary.BodyRange
    /// 历史裁剪与预算检查共用的有效输入预算。
    var inputBudget: Int
}

/// 组装结果。
struct WriterPreparedPrompt {
    var messages: [LLMMessage]
    var sourceIds: [String]
    var omittedHistoryMessages: Int
    var estimatedInputTokens: Int
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
        try checkpoint()

        let history: [LLMMessage]
        let built: [LLMMessage]
        switch snapshot.action {
        case .send(let instruction):
            history = PromptComposer.llmMessages(from: snapshot.messages)
            built = PromptComposer.writingMessages(
                assembly: assembly,
                history: history,
                userInstruction: instruction
            )
        case .continueWriting:
            history = PromptComposer.llmMessages(from: snapshot.messages)
            let lastAssistant = snapshot.messages.last(where: { $0.role == .assistant })?.content ?? ""
            built = PromptComposer.continueFragmentMessages(
                assembly: assembly,
                history: history,
                fragment: lastAssistant
            )
        case .regenerate(let index):
            let prefix = index > 0
                ? Array(snapshot.messages[..<min(index, snapshot.messages.count)])
                : []
            history = PromptComposer.llmMessages(from: prefix)
            if let last = history.last, last.role == "assistant" {
                built = PromptComposer.continueFragmentMessages(
                    assembly: assembly,
                    history: history,
                    fragment: last.content
                )
            } else {
                built = PromptComposer.writingMessages(
                    assembly: assembly,
                    history: history,
                    userInstruction: nil
                )
            }
        }
        try checkpoint()

        let trimmed = try trimHistory(
            built,
            budget: snapshot.inputBudget,
            checkpoint: checkpoint
        )
        try checkpoint()
        return WriterPreparedPrompt(
            messages: trimmed.messages,
            sourceIds: assembly.sourceIds,
            omittedHistoryMessages: trimmed.omitted,
            estimatedInputTokens: TokenEstimator.estimate(messages: trimmed.messages)
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
        let body = effectiveBody(snapshot)
        let excess = preparedFull.estimatedInputTokens - snapshot.inputBudget
        let manuscriptBudget = max(
            512,
            TokenEstimator.estimate(body.text) - max(excess, 0)
        )
        let trimmed = try WriterBudgeting.trimTail(
            body.text,
            toTokens: manuscriptBudget
        )
        try Task.checkCancellation()
        guard !trimmed.isEmpty, trimmed != body.text else {
            return .cannotTrim
        }

        var next = snapshot
        next.manuscript = trimmed
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
        if let anchor = snapshot.continuationAnchor,
           anchor > 0, anchor <= (whole as NSString).length {
            let prefix = (whole as NSString).substring(to: anchor)
            return (prefix, .anchorPrefix(count: prefix.count))
        }
        if snapshot.bodyPromptSendWhole {
            return (whole, .full)
        }
        let limit = max(256, snapshot.bodyPromptTailCodePoints)
        return (PromptComposer.codePointTail(whole, limit: limit), .tail(count: limit))
    }

    // MARK: - 历史

    /// 历史裁剪（原版 `L1/e3.java:172-198`）：按「用户轮」从末尾整轮加入，
    /// 超预算就停；不拆散用户指令与助手回复。system 块和本轮用户指令永远保留。
    private static func trimHistory(
        _ messages: [LLMMessage],
        budget: Int,
        checkpoint: () throws -> Void
    ) rethrows -> (messages: [LLMMessage], omitted: Int) {
        guard messages.count > 1 else { return (messages, 0) }
        var system: LLMMessage?
        var tailMessages: [LLMMessage] = []
        var history = messages
        if history.first?.role == "system" {
            system = history.removeFirst()
        }
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

        var used = (system.map { TokenEstimator.estimate($0.content) } ?? 0)
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

        var result: [LLMMessage] = []
        if let system { result.append(system) }
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
            // 循环内校验任务取消状态。
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
