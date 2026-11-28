import Foundation

/// 历史交互流分块可逆折叠的计算结果。
struct ReFoldPlan: Equatable {
    var messages: [LLMMessage]
    var updatedBoundary: ReFoldBoundary
    var foldedTurnCount: Int
    var deduplicatedToolCount: Int
}

/// 确定性对话流可逆折叠器：通过固定边界步长折叠早期冗余交互与重复工具输出，
/// 保持前部上下文结构稳定以保护前缀缓存，并支持在尾部通过 `restore_turn` 无损复原原文。
enum ReFoldManager {

    static func adaptiveHorizonTokens(
        modelContextWindow: Int,
        effectiveInputBudget: Int
    ) -> Int {
        let safeBudget = max(1_024, effectiveInputBudget)
        if modelContextWindow >= 500_000 {
            return min(safeBudget, 16_000)
        }
        if modelContextWindow >= 128_000 {
            return min(safeBudget, 12_000)
        }
        return min(safeBudget, 6_000)
    }

    static func apply(
        history: [LLMMessage],
        boundary: ReFoldBoundary,
        modelContextWindow: Int,
        effectiveInputBudget: Int,
        rejectedDraftLimit: Int = 1,
        allowRestoreTool: Bool = true
    ) -> ReFoldPlan {
        guard !history.isEmpty else {
            return ReFoldPlan(
                messages: [],
                updatedBoundary: boundary,
                foldedTurnCount: 0,
                deduplicatedToolCount: 0
            )
        }

        var nextBoundary = boundary
        let stride = max(1, boundary.stride)
        var working = history
        var deduplicatedToolCount = 0

        // 对重复出现的工具返回内容仅保留首次原文，其余替换为指向首次步骤的存根。
        nextBoundary.deduplicatedStubs = [:]
        var seenToolOutputs: [String: Int] = [:]
        for idx in working.indices where working[idx].role == "tool" {
            let normalized = working[idx].content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            if let firstIdx = seenToolOutputs[normalized] {
                working[idx].content = "[重复工具结果，内容同步骤 #\(firstIdx)]"
                nextBoundary.deduplicatedStubs[idx] = "step:\(firstIdx)"
                deduplicatedToolCount += 1
            } else {
                seenToolOutputs[normalized] = idx
            }
        }

        let recentProtectedCount = min(6, working.count)
        let maxFoldableEnd = max(0, working.count - recentProtectedCount)
        let horizon = adaptiveHorizonTokens(
            modelContextWindow: modelContextWindow,
            effectiveInputBudget: effectiveInputBudget
        )

        var boundaryIdx = min(max(0, (boundary.boundaryTurnIndex / stride) * stride), maxFoldableEnd)
        boundaryIdx = (boundaryIdx / stride) * stride

        let currentTokens = TokenEstimator.estimate(messages: working)
        if currentTokens > horizon {
            var estimatedAfterFold = currentTokens
            while boundaryIdx + stride <= maxFoldableEnd, estimatedAfterFold > horizon {
                let nextIdx = boundaryIdx + stride
                let savedTokens = (boundaryIdx..<nextIdx).reduce(0) { sum, idx in
                    sum + TokenEstimator.estimate(working[idx].content)
                }
                boundaryIdx = nextIdx
                estimatedAfterFold = max(0, estimatedAfterFold - savedTokens)
            }
        }

        // 确保滑窗边界不会落在 orphan tool 结果中间，避免破坏 assistant(toolCalls) -> tool 配对。
        while boundaryIdx > 0 && boundaryIdx < working.count && working[boundaryIdx].role == "tool" {
            boundaryIdx += 1
        }

        nextBoundary.boundaryTurnIndex = boundaryIdx

        // 清理超出当前历史长度或折回边界之外的旧存根，避免撤回/清空对话后键位错配。
        nextBoundary.deduplicatedStubs = nextBoundary.deduplicatedStubs.filter { $0.key < working.count && $0.key >= boundaryIdx }
        nextBoundary.foldedStepNotes = [:]

        guard boundaryIdx > 0 else {
            return ReFoldPlan(
                messages: working,
                updatedBoundary: nextBoundary,
                foldedTurnCount: 0,
                deduplicatedToolCount: deduplicatedToolCount
            )
        }

        // 采用非破坏性滑窗：整段折叠 0..<boundaryIdx 为单条紧凑区间提示，不再把用户/助手消息硬截断为 60 字碎片。
        let restoreHint = allowRestoreTool ? " · 可调用 restore_turn 复原" : ""
        let rangeStub = "[已滑出窗口步骤 #0-\(boundaryIdx - 1)（共 \(boundaryIdx) 条早期交互）\(restoreHint)]"
        nextBoundary.foldedStepNotes[0] = rangeStub

        var remaining = Array(working[boundaryIdx...])
        // 清理紧接边界之后的孤立连续冗余旧草稿，同时保留其余交互完整原文。
        if rejectedDraftLimit == 0 {
            remaining.removeAll { $0.role == "tool" && $0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        let resultMessages = [.user(rangeStub)] + remaining

        return ReFoldPlan(
            messages: resultMessages,
            updatedBoundary: nextBoundary,
            foldedTurnCount: boundaryIdx,
            deduplicatedToolCount: deduplicatedToolCount
        )
    }

    /// 按步骤编号或闭区间从无损原始历史中恢复完整交互文本，供尾部追加发送而不破坏前部缓存。
    static func restoreTurns(
        stepRange: String,
        from losslessHistory: [LLMMessage]
    ) -> String {
        guard !losslessHistory.isEmpty else {
            return "当前没有可供恢复的历史交互步骤。"
        }
        let clean = stepRange
            .replacingOccurrences(of: "..", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = clean
            .split(separator: "-")
            .map { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }

        let lower: Int
        let upper: Int
        if parts.count == 1, let single = parts[0] {
            lower = single
            upper = single
        } else if parts.count >= 2, let start = parts[0], let end = parts[1] {
            lower = min(start, end)
            upper = max(start, end)
        } else {
            return "无法解析步骤范围「\(stepRange)」，请传入如 \"2\" 或 \"1-3\" 的步骤编号。"
        }

        let clampedStart = max(0, min(lower, losslessHistory.count - 1))
        let clampedEnd = max(clampedStart, min(upper, losslessHistory.count - 1))
        var lines = ["【恢复的历史步骤 \(clampedStart)-\(clampedEnd)（按需追加于上下文末尾）】"]
        for idx in clampedStart...clampedEnd {
            let msg = losslessHistory[idx]
            lines.append("[步骤 #\(idx) · \(msg.role)]\n\(msg.content)")
        }
        return lines.joined(separator: "\n\n")
    }
}
