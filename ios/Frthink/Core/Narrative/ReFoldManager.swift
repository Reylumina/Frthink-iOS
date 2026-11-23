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
            return min(safeBudget, 120_000)
        }
        if modelContextWindow >= 128_000 {
            return min(safeBudget, 32_000)
        }
        return min(safeBudget, 12_000)
    }

    static func apply(
        history: [LLMMessage],
        boundary: ReFoldBoundary,
        modelContextWindow: Int,
        effectiveInputBudget: Int,
        rejectedDraftLimit: Int = 1
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
                    let cost = TokenEstimator.estimate(working[idx].content)
                    return sum + max(0, cost - 48)
                }
                boundaryIdx = nextIdx
                estimatedAfterFold = max(0, estimatedAfterFold - savedTokens)
            }
        }

        nextBoundary.boundaryTurnIndex = boundaryIdx

        // 清理超出当前历史长度或折回边界之外的旧存根，避免撤回/清空对话后键位错配。
        nextBoundary.deduplicatedStubs = nextBoundary.deduplicatedStubs.filter { $0.key < working.count }
        nextBoundary.foldedStepNotes = nextBoundary.foldedStepNotes.filter { $0.key < boundaryIdx }

        guard boundaryIdx > 0 else {
            return ReFoldPlan(
                messages: working,
                updatedBoundary: nextBoundary,
                foldedTurnCount: 0,
                deduplicatedToolCount: deduplicatedToolCount
            )
        }

        // 统计折叠区内连续未采纳草稿位置，仅保留末尾 `rejectedDraftLimit` 份供对比。
        var rejectedDraftIndices: [Int] = []
        for idx in 0..<boundaryIdx where working[idx].role == "assistant" {
            if idx + 1 < boundaryIdx, working[idx + 1].role == "assistant" {
                rejectedDraftIndices.append(idx)
            }
        }
        let retainedRejected = Set(rejectedDraftIndices.suffix(max(0, rejectedDraftLimit)))
        let dropRejectedSet = Set(rejectedDraftIndices).subtracting(retainedRejected)

        var foldedCount = 0
        for idx in 0..<boundaryIdx {
            if dropRejectedSet.contains(idx) {
                let stub = "[已折叠废弃草稿 #\(idx) · 可调用 restore_turn 复原]"
                working[idx].content = stub
                working[idx].toolCalls = nil
                nextBoundary.foldedStepNotes[idx] = stub
                foldedCount += 1
                continue
            }

            let trimmed = working[idx].content.trimmingCharacters(in: .whitespacesAndNewlines)
            if working[idx].role == "tool" {
                if trimmed.count > 120 {
                    let brief = collapsedBrief(trimmed, limit: 48)
                    let stub = "[已折叠步骤 #\(idx)（工具结果）· 可调用 restore_turn 复原] \(brief)"
                    working[idx].content = stub
                    nextBoundary.foldedStepNotes[idx] = stub
                    foldedCount += 1
                }
            } else if trimmed.count > 140 {
                let roleName = working[idx].role == "assistant" ? "助手" : "用户"
                let brief = collapsedBrief(trimmed, limit: 60)
                let stub = "[已折叠步骤 #\(idx)（\(roleName)）· 可调用 restore_turn 复原] \(brief)"
                working[idx].content = stub
                working[idx].toolCalls = nil
                nextBoundary.foldedStepNotes[idx] = stub
                foldedCount += 1
            } else if let existing = nextBoundary.foldedStepNotes[idx], !existing.isEmpty {
                working[idx].content = existing
                foldedCount += 1
            }
        }

        return ReFoldPlan(
            messages: working,
            updatedBoundary: nextBoundary,
            foldedTurnCount: foldedCount,
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

    private static func collapsedBrief(_ text: String, limit: Int) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > limit else { return singleLine }
        return String(singleLine.prefix(limit)) + "…"
    }
}
