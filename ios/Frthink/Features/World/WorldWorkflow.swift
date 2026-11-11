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
        let totalChunks: Int
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
            if totalChunks == 0 {
                return "当前正文已完成世界刷新。"
            }
            var text = parts.isEmpty
                ? "世界刷新完成：本轮没有新增。"
                : "世界刷新完成：" + parts.joined(separator: "，") + "。"
            if processedChunks < totalChunks {
                text += " 还有 \(totalChunks - processedChunks) 段未整理，再次点击刷新会继续。"
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
    /// 每处理完一段就落一次 `refreshedUpTo`，中途失败不会丢掉已完成的进度。
    static func refreshWorld(
        session: ProjectSession,
        store: AppStore,
        forceFull: Bool,
        progress: @escaping @MainActor (Int, Int) -> Void
    ) async throws -> RefreshOutcome {
        let manuscript = session.manuscript
        guard !manuscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorldRunError(message: "当前正文为空，无法刷新人物卡。")
        }

        let context = try WorldRequestContext.make(store: store)
        let world = session.payload.world
        let hasBaseline = !world.characters.isEmpty
            || !world.styleTemplate.isEmpty
            || !world.styleNotes.isEmpty
            || !world.events.isEmpty
            || world.lastRefreshedAt != nil
        let incremental = hasBaseline && !forceFull

        let sourceHash = await Task.detached(priority: .userInitiated) {
            ContentHash.of(manuscript)
        }.value

        // 大书模式：正文 ≥ 50 万码点，按模型上下文一次分析一个前缀，断点续跑。
        if WorldDigest.usesWholeTextPass(manuscript) {
            return try await refreshWholeText(
                session: session,
                store: store,
                context: context,
                manuscript: manuscript,
                sourceHash: sourceHash,
                incremental: incremental,
                forceFull: forceFull,
                progress: progress
            )
        }

        // 分段续抽：原版 `characterAnalysisCheckpoint` 记录每一段是否做完，
        // 正文没变时只补没做完的段，不整本重抽。
        // 原版：min(4000, 输入预算 × 0.2) token。输入预算过小时保底 256。
        let chunkBudget = min(
            WorldDigest.tokenChunkCap,
            max(256, store.settings.inputBudgetTokens / 5)
        )
        // 56 万字的切段是纯计算，不能占主线程；先丢后台再回主线程改断点。
        let allSegments = await Task.detached(priority: .userInitiated) {
            WorldDigest.chunks(of: manuscript, tokenBudget: chunkBudget)
        }.value
        if session.payload.world.analysisSourceHash != sourceHash {
            // 正文变过，之前的段进度和未落库候选都作废。
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
        let pendingIndexes = Array(
            (0..<allSegments.count)
                .filter { !session.payload.world.completedAnalysisSegments.contains($0) }
                .prefix(WorldDigest.maxChunksPerRun)
        )
        let chunks = pendingIndexes.map { allSegments[$0] }

        guard !chunks.isEmpty else {
            // 上次可能正好跑完最后一段但没来得及去重/落库，这里补完。
            if isAnalysisComplete(
                completed: session.payload.world.completedAnalysisSegments,
                total: allSegments.count
            ), !session.payload.world.analysisMergedCards.isEmpty {
                let finalized = await finalizeAnalysis(session: session, context: context)
                return RefreshOutcome(
                    addedCharacters: finalized.added,
                    updatedCharacters: finalized.updated,
                    processedChunks: 0,
                    totalChunks: allSegments.count,
                    dedupeNote: finalized.note
                )
            }
            return RefreshOutcome(
                addedCharacters: 0,
                updatedCharacters: 0,
                processedChunks: 0,
                totalChunks: 0
            )
        }

        var addedCharacters = 0
        var updatedCharacters = 0
        var dedupeNote: String?

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress(index + 1, chunks.count)

            let messages = PromptComposer.worldRefreshMessages(
                existingCharacters: session.payload.world.characters,
                existingStyleTemplate: session.payload.world.styleTemplate,
                digest: chunk,
                incremental: incremental,
                // 设置里「世界建立」改写过 P18 就用用户的版本。
                worldBuildInstruction: store.settings.worldBuildInstruction.isEmpty
                    ? nil
                    : store.settings.worldBuildInstruction
            )
            let raw: String
            do {
                raw = try await context.complete(
                    messages,
                    failOnLength: true
                )
            } catch {
                throw WorldRunError(message: "世界刷新请求失败：\(error.localizedDescription)")
            }

            let payload: WorldJSON.WorldRefreshPayload
            do {
                payload = try WorldJSON.parseWorldRefresh(raw)
            } catch {
                throw WorldRunError(
                    message: "世界刷新解析失败：\(error.localizedDescription)",
                    rawResponse: raw
                )
            }

            if !payload.characters.isEmpty {
                // P32 的触发时机是「分段抽取完成、准备写库前」。
                // 先按段累积候选；等全部段完成后再统一去重、并入卡片。
                session.payload.world.analysisMergedCards.append(
                    contentsOf: payload.characters
                )
            }

            // 这一段做完了：记进断点，中途失败下次接着跑。
            if let done = chunks.firstIndex(where: { $0 == chunk }) {
                let segmentIndex = pendingIndexes[done]
                if !session.payload.world.completedAnalysisSegments.contains(segmentIndex) {
                    session.payload.world.completedAnalysisSegments.append(segmentIndex)
                }
            }
            session.payload.world.refreshedUpTo =
                session.payload.world.completedAnalysisSegments
                    .reduce(0) { $0 + (allSegments[$1].count) }
            session.payload.world.lastRefreshedAt = Date()
            session.scheduleSave()
        }

        // 全部段都完成才写库；一次刷新只发一次 P32 去重请求。
        if isAnalysisComplete(
            completed: session.payload.world.completedAnalysisSegments,
            total: allSegments.count
        ) {
            let finalized = await finalizeAnalysis(session: session, context: context)
            addedCharacters = finalized.added
            updatedCharacters = finalized.updated
            dedupeNote = finalized.note
        }

        return RefreshOutcome(
            addedCharacters: addedCharacters,
            updatedCharacters: updatedCharacters,
            processedChunks: chunks.count,
            totalChunks: allSegments.count,
            dedupeNote: dedupeNote
        )
    }

    private static func isAnalysisComplete(completed: [Int], total: Int) -> Bool {
        guard total > 0 else { return false }
        let valid = Set(completed.filter { $0 >= 0 && $0 < total })
        return valid.count == total
    }

    /// 正文变过以后，旧段进度、候选和完成标记一起作废。
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
    }

    /// 大书模式：一次只分析上下文放得下的前缀，落盘后等下一次点击继续。
    ///
    /// 阈值与提示词对齐 v0.8.213 的 `W2.B`：正文 ≥ 50 万码点时不切小段，
    /// 而是把能放下的正文整段送进去，再用「已分析正文前 N 字」告诉用户还剩多少。
    private static func refreshWholeText(
        session: ProjectSession,
        store: AppStore,
        context: WorldRequestContext,
        manuscript: String,
        sourceHash: String,
        incremental: Bool,
        forceFull: Bool,
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
                totalChunks: 0
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
        let prefixBudget = max(1_024, store.settings.promptBudgetTokens - overhead)
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
            worldBuildInstruction: store.settings.worldBuildInstruction.isEmpty
                ? nil
                : store.settings.worldBuildInstruction
        )
        let raw: String
        do {
            raw = try await context.complete(messages, failOnLength: true)
        } catch {
            throw WorldRunError(message: "世界刷新请求失败：\(error.localizedDescription)")
        }
        let payload: WorldJSON.WorldRefreshPayload
        do {
            payload = try WorldJSON.parseWorldRefresh(raw)
        } catch {
            throw WorldRunError(
                message: "世界刷新解析失败：\(error.localizedDescription)",
                rawResponse: raw
            )
        }

        if !payload.characters.isEmpty {
            session.payload.world.analysisMergedCards.append(contentsOf: payload.characters)
        }
        let committed = await commitCandidates(session: session, context: context)

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
            totalChunks: 1,
            dedupeNote: committed.note,
            truncationNote: complete
                ? nil
                : "已分析正文前 \(endCodePoint) 字，其余未分析；再次点击刷新会继续。"
        )
    }

    /// 把候选去重后并入人物卡。分段模式等全部段完成再调用，大书模式每前缀调用一次。
    private static func commitCandidates(
        session: ProjectSession,
        context: WorldRequestContext
    ) async -> (added: Int, updated: Int, note: String?) {
        let candidates = session.payload.world.analysisMergedCards
        session.payload.world.analysisMergedCards = []
        guard !candidates.isEmpty else { return (0, 0, nil) }
        let deduped = await WorldDedupe.dedupe(
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
        return (merged.added, merged.updated, deduped.outcome.note)
    }

    /// 全部段抽完后统一去重并写库；候选来自 checkpoint 的 `mergedCards`。
    private static func finalizeAnalysis(
        session: ProjectSession,
        context: WorldRequestContext
    ) async -> (added: Int, updated: Int, note: String?) {
        let result = await commitCandidates(session: session, context: context)
        session.payload.world.analysisWorldRefreshComplete = true
        session.scheduleSave()
        return result
    }

}
