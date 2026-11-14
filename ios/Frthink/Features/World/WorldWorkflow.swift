// 世界刷新：把正文分段送模型，抽取/合并人物卡。

import Foundation

/// 世界流程里需要把原始响应交给 UI 展示时用的错误。
struct WorldRunError: LocalizedError {
    let message: String
    var rawResponse: String? = nil

    var errorDescription: String? { message }
}

/// 世界刷新流程。事件/文风/长期规则分别在 `WorldMaterialWorkflow`
/// 和 `WorldRulesWorkflow`，这里只处理正文 → 人物卡。
@MainActor
enum WorldWorkflow {

    // MARK: - 结果

    struct RefreshOutcome {
        let addedCharacters: Int
        let updatedCharacters: Int
        let processedChunks: Int
        /// 本次执行后尚未完成分析的分段数。
        let remainingChunks: Int
        /// 人物去重是可选步骤，失败时的提示挂在这里。
        var dedupeNote: String? = nil
        /// 大书模式只分析了上下文放得下的前缀，剩余部分留给下一次点击。
        var truncationNote: String? = nil

        var summary: String {
            var parts: [String] = []
            if addedCharacters > 0 { parts.append("新增 \(addedCharacters) 张人物卡") }
            if updatedCharacters > 0 { parts.append("补充 \(updatedCharacters) 张人物卡") }
            if let truncationNote {
                var text = parts.isEmpty
                    ? "世界刷新已保存"
                    : "世界刷新已保存：" + parts.joined(separator: "，")
                text += "。" + truncationNote
                if let dedupeNote { text += " " + dedupeNote }
                return text
            }
            if processedChunks == 0, remainingChunks == 0 {
                return "当前正文已完成世界刷新。"
            }
            var text = parts.isEmpty
                ? "世界刷新完成：本轮没有新增。"
                : "世界刷新完成：" + parts.joined(separator: "，") + "。"
            if remainingChunks > 0 {
                text += " 还有 \(remainingChunks) 段未整理，再次点击刷新会继续。"
            }
            if let dedupeNote { text += " " + dedupeNote }
            return text
        }
    }

    // MARK: - 世界刷新

    /// 把正文切成片段逐段整理。
    ///
    /// - 已有世界资料时是增量模式：从 `refreshedUpTo` 之后继续，只提取新事实。
    /// - `forceFull` 为 true 时忽略断点，从正文开头重新整理（合并仍然只增不减）。
    /// 每段处理完毕即持久化更新 `refreshedUpTo` 断点进度。
    static func refreshWorld(
        session: ProjectSession,
        store: AppStore,
        forceFull: Bool,
        targetCharacter: String? = nil,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> RefreshOutcome {
        let manuscript = session.manuscript
        guard !manuscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorldRunError(message: "当前正文为空，无法刷新人物卡。")
        }

        let context = try WorldRequestContext.make(store: store)
        let incremental = !session.payload.world.characters.isEmpty

        let sourceHash = await Task.detached(priority: .userInitiated) {
            ContentHash.of(manuscript)
        }.value

        // 超长文本模式：正文 ≥ 50 万码点时截取最大上下文前缀进行分析并支持断点续跑。
        if WorldDigest.usesWholeTextPass(manuscript) {
            return try await refreshWholeText(
                session: session,
                store: store,
                context: context,
                manuscript: manuscript,
                sourceHash: sourceHash,
                incremental: incremental,
                forceFull: forceFull,
                targetCharacter: targetCharacter,
                progress: progress
            )
        }

        // 分段续抽：`characterAnalysisCheckpoint` 记录已完成段，正文未变时仅补未完成段。
        // 单段预算：min(4000, 输入预算 × 0.2) token，保底 256 token。
        let chunkBudget = min(
            WorldDigest.tokenChunkCap,
            max(256, store.settings.inputBudgetTokens / 5)
        )
        // 正文分段计算由后台任务执行，避免阻塞主线程。
        let allSegments = await Task.detached(priority: .userInitiated) {
            WorldDigest.chunks(of: manuscript, tokenBudget: chunkBudget)
        }.value
        if session.payload.world.analysisSourceHash != sourceHash {
            // 正文内容发生变动，重置历史分段进度与临时候选数据。
            resetAnalysisCheckpoint(session: session, sourceHash: sourceHash)
            session.payload.world.analysisSegmentCount = allSegments.count
        } else if session.payload.world.analysisSegmentCount != allSegments.count {
            session.payload.world.analysisSegmentCount = allSegments.count
            session.payload.world.completedAnalysisSegments =
                session.payload.world.completedAnalysisSegments.filter {
                    $0 >= 0 && $0 < allSegments.count
                }
        }
        if forceFull {
            session.payload.world.completedAnalysisSegments = []
            session.payload.world.analysisMergedCards = []
            session.payload.world.analysisWorldRefreshComplete = false
        }
        let pendingIndexes = (0..<allSegments.count)
            .filter { !session.payload.world.completedAnalysisSegments.contains($0) }
        // 每轮最多处理 256 段（与 APK `L1/K0.smali:5774-5776` 对齐），剩余段留到下次点击继续。
        let batchIndexes = Array(pendingIndexes.prefix(256))
        let chunks = batchIndexes.map { allSegments[$0] }

        guard !chunks.isEmpty else {
            // 若所有分段已完成但尚未执行最终合并，在此触发结算落库。
            if isAnalysisComplete(
                completed: session.payload.world.completedAnalysisSegments,
                total: allSegments.count
            ), !session.payload.world.analysisMergedCards.isEmpty {
                let finalized = try await finalizeAnalysis(session: session, context: context)
                return RefreshOutcome(
                    addedCharacters: finalized.added,
                    updatedCharacters: finalized.updated,
                    processedChunks: 0,
                    remainingChunks: 0,
                    dedupeNote: finalized.note
                )
            }
            return RefreshOutcome(
                addedCharacters: 0,
                updatedCharacters: 0,
                processedChunks: 0,
                remainingChunks: 0
            )
        }

        var addedCharacters = 0
        var updatedCharacters = 0
        var dedupeNote: String?

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(index + 1, chunks.count)
            let segmentIndex = batchIndexes[index]

            let messages = PromptComposer.worldRefreshMessages(
                existingCharacters: session.payload.world.characters,
                existingStyleTemplate: session.payload.world.styleTemplate,
                digest: chunk.text,
                incremental: incremental,
                // P27/P28/P29 都要带段序号与码点范围；大书模式没有分段。
                segment: PromptLibrary.Segment(
                    index: segmentIndex + 1,
                    total: allSegments.count,
                    start: chunk.startCodePoint + 1,
                    end: chunk.endCodePoint
                ),
                targetCharacter: targetCharacter,
                // 设置里「世界建立」改写过 P18 就用用户的版本。
                worldBuildInstruction: store.settings.worldBuildInstruction.isEmpty
                    ? nil
                    : store.settings.worldBuildInstruction
            )
            let payload = try await context.completeAndParse(
                messages,
                failOnLength: true,
                requestErrorPrefix: "世界刷新请求失败",
                parseErrorPrefix: "世界刷新解析失败",
                parse: WorldJSON.parseWorldRefresh
            )

            let filtered = Self.filterTargetCharacter(payload.characters, target: targetCharacter)
            if !filtered.isEmpty {
                // P32 的触发时机是「分段抽取完成、准备写库前」。
                // 先按段累积候选；等全部段完成后再统一去重、并入卡片。
                session.payload.world.analysisMergedCards.append(
                    contentsOf: filtered
                )
            }

            // 当前分段处理完成：更新断点记录以支持断点续跑。
            if !session.payload.world.completedAnalysisSegments.contains(segmentIndex) {
                session.payload.world.completedAnalysisSegments.append(segmentIndex)
            }
            session.payload.world.refreshedUpTo =
                session.payload.world.completedAnalysisSegments
                    .reduce(0) { sum, done in
                        // 校验分段索引有效性，防止越界异常中断流程。
                        guard allSegments.indices.contains(done) else { return sum }
                        return sum + allSegments[done].text.unicodeScalars.count
                    }
            session.payload.world.lastRefreshedAt = Date()
            session.scheduleSave()
        }

        // 所有分段全部完成后统一执行去重并持久化落库。
        if isAnalysisComplete(
            completed: session.payload.world.completedAnalysisSegments,
            total: allSegments.count
        ) {
            let finalized = try await finalizeAnalysis(session: session, context: context)
            addedCharacters = finalized.added
            updatedCharacters = finalized.updated
            dedupeNote = finalized.note
        }

        let validCompleted = Set(
            session.payload.world.completedAnalysisSegments
                .filter { $0 >= 0 && $0 < allSegments.count }
        )
        return RefreshOutcome(
            addedCharacters: addedCharacters,
            updatedCharacters: updatedCharacters,
            processedChunks: chunks.count,
            remainingChunks: max(0, allSegments.count - validCompleted.count),
            dedupeNote: dedupeNote
        )
    }

    private static func isAnalysisComplete(completed: [Int], total: Int) -> Bool {
        guard total > 0 else { return false }
        let valid = Set(completed.filter { $0 >= 0 && $0 < total })
        return valid.count == total
    }

    /// 正文内容变更时重置分段分析断点状态与候选集。
    private static func resetAnalysisCheckpoint(
        session: ProjectSession,
        sourceHash: String
    ) {
        session.payload.world.analysisSourceHash = sourceHash
        session.payload.world.analysisSegmentCount = 0
        session.payload.world.completedAnalysisSegments = []
        session.payload.world.analysisSegments = []
        session.payload.world.analysisMergedDraft = nil
        session.payload.world.analysisMergedCards = []
        session.payload.world.analysisWorldRefreshComplete = false
        session.payload.world.refreshedUpTo = 0
        // 重置源码码点计数，避免历史数值影响进度展示。
        session.payload.world.analysisSourceCodePointCount = 0
    }

    /// 超长文本模式：单次分析上下文容量允许的最大前缀，完成后持久化并支持后续继续处理。
    private static func refreshWholeText(
        session: ProjectSession,
        store: AppStore,
        context: WorldRequestContext,
        manuscript: String,
        sourceHash: String,
        incremental: Bool,
        forceFull: Bool,
        targetCharacter: String?,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> RefreshOutcome {
        let totalCodePoints = manuscript.unicodeScalars.count
        if session.payload.world.analysisSourceHash != sourceHash {
            resetAnalysisCheckpoint(session: session, sourceHash: sourceHash)
        }
        if forceFull {
            session.payload.world.completedAnalysisSegments = []
            session.payload.world.analysisSegments = []
            session.payload.world.analysisMergedCards = []
            session.payload.world.analysisWorldRefreshComplete = false
            session.payload.world.refreshedUpTo = 0
        }
        session.payload.world.analysisSourceCodePointCount = totalCodePoints

        let consumed = min(
            max(session.payload.world.analysisSegments.map(\.endCodePoint).max() ?? 0, 0),
            totalCodePoints
        )
        guard consumed < totalCodePoints else {
            return RefreshOutcome(
                addedCharacters: 0,
                updatedCharacters: 0,
                processedChunks: 0,
                remainingChunks: 0
            )
        }

        let scalars = manuscript.unicodeScalars
        let start = scalars.index(scalars.startIndex, offsetBy: consumed)
        let remaining = String(scalars[start...])

        let instruction = PromptLibrary.wholeTextWorldRefreshInstruction
            + (incremental ? PromptLibrary.incrementalRefreshClause : "")
        let baselineTokens = TokenEstimator.estimate(
            session.payload.world.characters
                .map(PromptLibrary.characterBaseline)
                .joined(separator: "\n")
        )
        let overhead = TokenEstimator.estimate(instruction) + baselineTokens + 4_096
        let prefixBudget = store.settings.promptBudgetTokens - overhead
        guard prefixBudget >= 256 else {
            throw WorldRunError(message: "当前模型可用上下文不足，请调整输入或预算。")
        }
        let prefix = await Task.detached(priority: .userInitiated) {
            WorldDigest.prefixChunk(of: remaining, tokenBudget: prefixBudget)
        }.value
        guard !prefix.isEmpty else {
            throw WorldRunError(message: "当前模型可用上下文不足，请调整输入或预算。")
        }

        progress(1, 1)
        let messages = PromptComposer.worldRefreshMessages(
            existingCharacters: session.payload.world.characters,
            existingStyleTemplate: session.payload.world.styleTemplate,
            digest: prefix,
            incremental: incremental,
            wholeText: true,
            targetCharacter: targetCharacter,
            worldBuildInstruction: store.settings.worldBuildInstruction.isEmpty
                ? nil
                : store.settings.worldBuildInstruction
        )
        let payload = try await context.completeAndParse(
            messages,
            failOnLength: true,
            requestErrorPrefix: "世界刷新请求失败",
            parseErrorPrefix: "世界刷新解析失败",
            parse: WorldJSON.parseWorldRefresh
        )

        let filtered = Self.filterTargetCharacter(payload.characters, target: targetCharacter)
        if !filtered.isEmpty {
            session.payload.world.analysisMergedCards.append(contentsOf: filtered)
        }
        let committed = try await commitCandidates(session: session, context: context)

        let endCodePoint = min(consumed + prefix.unicodeScalars.count, totalCodePoints)
        let segment = CharacterAnalysisSegment(
            index: session.payload.world.analysisSegments.count,
            startCodePoint: consumed,
            endCodePoint: endCodePoint,
            extractedFields: ""
        )
        session.payload.world.analysisSegments.append(segment)
        session.payload.world.completedAnalysisSegments.append(segment.index)
        session.payload.world.analysisSegmentCount =
            session.payload.world.analysisSegments.count
        session.payload.world.refreshedUpTo = endCodePoint
        session.payload.world.lastRefreshedAt = Date()
        let complete = endCodePoint >= totalCodePoints
        session.payload.world.analysisWorldRefreshComplete = complete
        session.scheduleSave()

        return RefreshOutcome(
            addedCharacters: committed.added,
            updatedCharacters: committed.updated,
            processedChunks: 1,
            remainingChunks: 0,
            dedupeNote: committed.note,
            truncationNote: complete
                ? nil
                : "已分析正文前 \(endCodePoint) 字，其余未分析；再次点击刷新会继续。"
        )
    }

    /// 把候选去重后并入人物卡。分段模式等全部段完成再调用，大书模式每前缀调用一次。
    ///
    /// 候选数据仅在落库成功后清空；请求失败或中断时保留候选集，以便重试恢复。
    private static func commitCandidates(
        session: ProjectSession,
        context: WorldRequestContext
    ) async throws -> (added: Int, updated: Int, note: String?) {
        let rawCandidates = session.payload.world.analysisMergedCards
        guard !rawCandidates.isEmpty else { return (0, 0, nil) }
        let candidates = WorldMerge.consolidateConnected(rawCandidates)
        let deduped = try await WorldDedupe.dedupe(
            candidates: candidates,
            existing: session.payload.world.characters,
            client: context.client,
            provider: context.provider
        )
        let merged = WorldMerge.mergeCharacters(
            existing: session.payload.world.characters,
            incoming: deduped.cards
        )
        session.payload.world.characters = merged.cards
        session.payload.world.analysisMergedCards = []
        return (merged.added, merged.updated, deduped.outcome.note)
    }

    /// 单条码字机气泡 → 一张人物卡（使用 `create_character_card` function calling）。
    static func ingestCharacterFromBubble(
        _ bubble: String,
        session: ProjectSession,
        store: AppStore
    ) async throws -> (cardName: String, isNew: Bool) {
        let trimmed = bubble.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorldRunError(message: "气泡内容为空，无法提取人物卡。")
        }
        let context = try WorldRequestContext.make(store: store)
        let request = LLMRequest(
            model: context.provider.resolvedModel,
            messages: PromptComposer.characterIngestMessages(bubble: trimmed),
            stream: false,
            temperature: context.provider.temperature,
            maxTokens: 8_192,
            attemptId: UUID().uuidString,
            failOnLength: true,
            tools: [PromptComposer.createCharacterCardTool],
            toolChoiceName: "create_character_card",
            parallelToolCalls: false,
            omitThinking: true
        )
        let calls: [LLMToolCall]
        do {
            calls = try await context.client.completeToolCall(request)
        } catch {
            if error.isLLMCancellation { throw CancellationError() }
            throw WorldRunError(message: "人物卡提取失败：\(error.localizedDescription)")
        }
        guard let target = calls.first(where: { $0.functionName == "create_character_card" }) ?? calls.first,
              let data = target.arguments.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let card = WorldJSON.character(from: object) else {
            throw WorldRunError(message: "未能从气泡中识别出有效的人物卡内容。")
        }

        let merged = WorldMerge.mergeCharacters(
            existing: session.payload.world.characters,
            incoming: [card]
        )
        session.payload.world.characters = merged.cards
        session.scheduleSave()
        return (card.name, merged.added > 0)
    }

    private static func filterTargetCharacter(
        _ cards: [CharacterCard],
        target: String?
    ) -> [CharacterCard] {
        guard let target, !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return cards
        }
        let targetKey = WorldMerge.normalize(target)
        return cards.filter { card in
            if WorldMerge.normalize(card.name) == targetKey { return true }
            return card.aliases.contains { WorldMerge.normalize($0) == targetKey }
        }
    }

    /// 全部段抽完后统一去重并写库；候选来自 checkpoint 的 `mergedCards`。
    private static func finalizeAnalysis(
        session: ProjectSession,
        context: WorldRequestContext
    ) async throws -> (added: Int, updated: Int, note: String?) {
        let result = try await commitCandidates(session: session, context: context)
        session.payload.world.analysisWorldRefreshComplete = true
        session.scheduleSave()
        return result
    }

}
