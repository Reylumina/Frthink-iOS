// 本文件负责：写作台请求组装 —— 把值类型快照变成要发给模型的消息。
//
// 组装要读整本正文、世界资料与全部历史。56 万字时这些工作在 2–5 秒的
// 主线程任务里跑，发送按钮会像卡住一样。这里只接收快照，可在后台执行；
// 控制器负责拍快照、显示「正在整理提示词」并提交结果。

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

    /// 一次组装。纯函数，不碰会话与磁盘。
    static func prepare(_ snapshot: WriterPromptSnapshot) -> WriterPreparedPrompt {
        let effective = effectiveBody(snapshot)
        let assembly = PromptAssembly.from(
            world: snapshot.world,
            manuscript: effective.text,
            assistantSupplement: snapshot.assistantSupplement,
            settings: snapshot.settings,
            projectID: snapshot.projectID,
            enabledUniverseEntryIDs: snapshot.enabledUniverseEntryIDs,
            bodyRange: effective.range
        )

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
            built = PromptComposer.continueFragmentMessages(
                assembly: assembly,
                history: history,
                fragment: snapshot.manuscript
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
                    fragment: snapshot.manuscript
                )
            } else {
                built = PromptComposer.writingMessages(
                    assembly: assembly,
                    history: history,
                    userInstruction: nil
                )
            }
        }

        let trimmed = trimHistory(built, budget: snapshot.inputBudget)
        return WriterPreparedPrompt(
            messages: trimmed.messages,
            sourceIds: assembly.sourceIds,
            omittedHistoryMessages: trimmed.omitted,
            estimatedInputTokens: TokenEstimator.estimate(messages: trimmed.messages)
        )
    }

    /// 预算不足时把正文裁到末尾再组装。原逻辑在控制器里同步跑两遍组装，
    /// 长书上点一次「裁剪后重试」会冻住界面；这里整体放后台。
    static func retryAfterTrimming(_ snapshot: WriterPromptSnapshot) -> WriterPromptRetryResult {
        var full = snapshot
        full.explicitBodyRange = .full
        let preparedFull = prepare(full)

        let excess = preparedFull.estimatedInputTokens - snapshot.inputBudget
        let manuscriptBudget = max(
            512,
            TokenEstimator.estimate(snapshot.manuscript) - max(excess, 0)
        )
        let trimmed = WriterBudgeting.trimTail(
            snapshot.manuscript,
            toTokens: manuscriptBudget
        )
        guard !trimmed.isEmpty, trimmed != snapshot.manuscript else {
            return .cannotTrim
        }

        var next = snapshot
        next.manuscript = trimmed
        next.explicitBodyRange = .tail(count: trimmed.unicodeScalars.count)
        let prepared = prepare(next)
        guard prepared.estimatedInputTokens <= snapshot.inputBudget else {
            return .stillTooLarge(characters: trimmed.count)
        }
        return .prepared(prepared)
    }

    // MARK: - 正文范围

    /// 按原版 `bodyPrompt*` 决定这次发哪一段正文。
    ///
    /// 原版实测 `bodyPromptSendWhole = false`、`bodyPromptTailCodePoints = 5000`：
    /// **续写只把正文末尾 5000 码点发过去**，不是全文。
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
}

/// 把正文裁到 token 预算内，保留末尾。
///
/// `TokenEstimator.trimTail` 的字符数是从预算出发向上收敛（`chars * 3 / 2`），
/// 中文差不多 1 字 1 token，起点就等于预算，估算永远超一点，于是一路放大到原文，
/// 等于没裁。这里改从「预算字符数的九成」起手、放不下再折半，能放下的尾部再交给
/// `trimTail` 收口。
enum WriterBudgeting {
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
