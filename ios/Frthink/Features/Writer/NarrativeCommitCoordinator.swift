import Foundation
import UIKit

/// 正文采纳落盘回执：绑定本次追加生成的剧情节点与退回基准，支持系统撤销/重做同步回滚分支头与三账本现状。
struct NarrativeCommitReceipt {
    let projectID: String
    let previousHeadNodeID: String
    let committedNodeID: String
    let committedNode: PlotNode
    let previousLedgerSnapshot: MaterializedNarrativeState
    let styleLint: StyleLintReport
    let previousSceneBoundaryOffset: Int?
}

/// 写作台「采纳后落盘」协调器：
/// 确保未采纳气泡与候选变体绝不污染分支剧情图；仅在作者插入或追加正文后执行零延迟本地锚定、
/// 文风检校与节点记账，维护待补抽队列并在后台补充结构化增量与分层金字塔滚动摘要。
@MainActor
enum NarrativeCommitCoordinator {

    static let deltaExtractionTemperature: Double = 0.15
    private static var syncTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    /// 采纳正文后的同步落盘主入口，并将符合条件的节拍登记至待同步队列按需后台提取。
    @discardableResult
    static func commitAcceptedProse(
        _ text: String,
        sourceMessageID: String?,
        insertionUTF16Offset: Int,
        session: ProjectSession,
        store: AppStore,
        persistSynchronously: Bool = false
    ) -> NarrativeCommitReceipt? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var workspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        let previousHeadID = workspace.storyGraph.headNodeID
        let stateBeforeCommit = workspace.currentState()
        let knownEntities = stateBeforeCommit.entityPages.values.sorted { $0.id < $1.id }

        let pageSize = max(1, FileStore.bodyPageSize)
        let safeOffset = max(0, insertionUTF16Offset)
        let insertedUTF16Length = (text as NSString).length
        let fullBody = session.manuscript
        let nsBody = fullBody as NSString

        let startPage = min(
            max(0, safeOffset / pageSize),
            max(0, max(0, nsBody.length - 1) / pageSize)
        )
        let endUTF16 = min(nsBody.length, safeOffset + max(1, insertedUTF16Length))
        let endPage = max(startPage, max(0, endUTF16 - 1) / pageSize)

        if nsBody.length > 0 {
            for pageIdx in startPage...endPage {
                let pageStart = pageIdx * pageSize
                guard pageStart < nsBody.length else { break }
                let pageLength = min(pageSize, nsBody.length - pageStart)
                let pageSlice = nsBody.substring(
                    with: NSRange(location: pageStart, length: pageLength)
                )
                MechanicalAnchorExtractor.appendPage(
                    pageSlice,
                    pageIndex: pageIdx,
                    baseUTF16Offset: pageStart,
                    knownEntities: knownEntities,
                    to: &workspace.anchorIndex
                )
            }
        } else {
            MechanicalAnchorExtractor.appendPage(
                text,
                pageIndex: 0,
                baseUTF16Offset: safeOffset,
                knownEntities: knownEntities,
                to: &workspace.anchorIndex
            )
        }

        let leadingRange = (text as NSString).range(of: trimmed)
        let leadingUTF16 = leadingRange.location == NSNotFound ? 0 : leadingRange.location
        let lintReport = ProseStyleLinter.lint(
            trimmed,
            pageIndex: startPage,
            baseUTF16Offset: safeOffset + leadingUTF16
        )
        workspace.latestStyleLint = lintReport

        let nodeID = "commit_\(UUID().uuidString)"
        let branchLabel = workspace.storyGraph.nodes[previousHeadID]?.branchLabel ?? "主线"
        let anchor = TextSpanAnchor.make(
            pageIndex: startPage,
            utf16Start: safeOffset,
            utf16Length: insertedUTF16Length,
            quote: String(trimmed.prefix(80)),
            paragraphText: trimmed
        )
        let summarySnippet = compactLineSnippet(trimmed, limit: 32)
        let nodeDelta = PlotNodeDelta(
            pyramidPatch: NarrativePyramidPatch(anchorIndexVersion: workspace.anchorIndex.version)
        )
        let node = PlotNode(
            id: nodeID,
            parentID: previousHeadID,
            branchLabel: branchLabel,
            summary: summarySnippet.isEmpty ? "采纳正文" : "采纳正文：\(summarySnippet)",
            manuscriptAnchor: anchor,
            sourceMessageID: sourceMessageID,
            delta: nodeDelta
        )

        do {
            try workspace.storyGraph.appendNode(node)
            workspace.applyLedgerDelta(nodeDelta, sourceNodeID: nodeID)
        } catch {
            return nil
        }

        if trimmed.count >= 40, !workspace.pendingSyncNodeIDs.contains(nodeID) {
            workspace.pendingSyncNodeIDs.append(nodeID)
        }

        session.noteNarrativeWorkspaceUpdated(
            workspace,
            persistSynchronously: persistSynchronously
        )

        let previousSceneBoundaryOffset = session.payload.sceneBoundaryOffset
        if store.settings.autoSceneContextPruning,
           hasExplicitSceneBreakPrefix(trimmed),
           safeOffset > (session.payload.sceneBoundaryOffset ?? 0) {
            session.setSceneBoundaryOffset(safeOffset)
        }

        let receipt = NarrativeCommitReceipt(
            projectID: session.project.id,
            previousHeadNodeID: previousHeadID,
            committedNodeID: nodeID,
            committedNode: node,
            previousLedgerSnapshot: stateBeforeCommit,
            styleLint: lintReport,
            previousSceneBoundaryOffset: previousSceneBoundaryOffset
        )

        if store.settings.sleepTimeStateSync, trimmed.count >= 40 {
            scheduleColdDeltaSync(
                excerpt: trimmed,
                nodeID: nodeID,
                pageIndex: startPage,
                baseUTF16Offset: safeOffset,
                session: session,
                store: store
            )
        }
        return receipt
    }

    /// 撤销对应采纳提交：中止挂起冷同步、从剧情线移除本次提交子树并无损退回三账本现状快照与换场起点。
    static func undoCommit(_ receipt: NarrativeCommitReceipt, session: ProjectSession) {
        cancelPendingSync(projectID: receipt.projectID)
        guard var workspace = session.narrativeWorkspace else { return }
        workspace.pendingSyncNodeIDs.removeAll { $0 == receipt.committedNodeID }
        _ = workspace.storyGraph.pruneSubtree { $0.id == receipt.committedNodeID }
        if workspace.storyGraph.nodes[receipt.previousHeadNodeID] != nil {
            try? workspace.storyGraph.checkout(nodeID: receipt.previousHeadNodeID)
        }
        workspace.restoreLedgerSnapshot(from: receipt.previousLedgerSnapshot)
        session.setSceneBoundaryOffset(receipt.previousSceneBoundaryOffset)
        session.noteNarrativeWorkspaceUpdated(workspace)
    }

    /// 判断采纳正文首行是否带有显式换场或分章标记（零延迟本地边界识别）。
    static func hasExplicitSceneBreakPrefix(_ text: String) -> Bool {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        guard !firstLine.isEmpty else { return false }
        if firstLine == "***" || firstLine == "---" || firstLine == "===" || firstLine == "——" {
            return true
        }
        if firstLine.hasPrefix("# ") {
            return true
        }
        let chapterPattern = #"^(第[零一二三四五六七八九十百千万0-9]+[章节回幕卷部篇]|序章|楔子|尾声)"#
        return firstLine.range(of: chapterPattern, options: .regularExpression) != nil
    }

    /// 重做对应采纳提交：将已撤销的剧情节拍放回图谱并重施其记录的三账本增量。
    static func redoCommit(_ receipt: NarrativeCommitReceipt, session: ProjectSession) {
        guard var workspace = session.narrativeWorkspace else { return }
        do {
            if workspace.storyGraph.nodes[receipt.committedNodeID] == nil {
                var restored = receipt.committedNode
                restored.secondaryCausalParentIDs = restored.secondaryCausalParentIDs.filter {
                    workspace.storyGraph.nodes[$0] != nil
                }
                try workspace.storyGraph.appendNode(restored)
                workspace.applyLedgerDelta(restored.delta, sourceNodeID: restored.id)
            } else if let existing = workspace.storyGraph.nodes[receipt.committedNodeID] {
                try workspace.storyGraph.checkout(nodeID: existing.id)
                workspace.applyLedgerDelta(existing.delta, sourceNodeID: existing.id)
            }
            session.noteNarrativeWorkspaceUpdated(workspace)
        } catch {
            return
        }
    }

    static func cancelPendingSync(projectID: String) {
        syncTasks[projectID]?.task.cancel()
        syncTasks[projectID] = nil
    }

    /// 手动或定期补抽待同步队列中的采纳节拍，成功后自动清理队列并按需滚动合并金字塔摘要。
    @discardableResult
    static func flushPendingSyncs(
        session: ProjectSession,
        store: AppStore,
        maxCount: Int = 5
    ) async throws -> Int {
        guard maxCount > 0 else { return 0 }
        guard let provider = store.narrativeSyncProvider else {
            throw LLMError.notConfigured
        }
        let client = try store.clientForNarrativeSync()

        var workspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        let candidateIDs = Array(workspace.pendingSyncNodeIDs.prefix(maxCount))
        guard !candidateIDs.isEmpty else { return 0 }

        var syncedCount = 0
        for nodeID in candidateIDs {
            try Task.checkCancellation()
            workspace = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            guard let node = workspace.storyGraph.nodes[nodeID] else {
                dequeuePendingNode(nodeID, in: session)
                continue
            }
            guard let slice = resolveExcerptSlice(for: node, session: session) else {
                dequeuePendingNode(nodeID, in: session)
                continue
            }

            try await extractAndApplyDelta(
                nodeID: nodeID,
                excerpt: slice.excerpt,
                pageIndex: slice.pageIndex,
                baseUTF16Offset: slice.baseUTF16Offset,
                client: client,
                provider: provider,
                session: session,
                store: store
            )
            syncedCount += 1
        }

        await consolidatePyramidIfNeeded(
            client: client,
            provider: provider,
            session: session
        )
        return syncedCount
    }

    /// 按需规划下一步 2-3 个剧情分支选项（不修改任何账本，仅返回候选方案供作者抉择）。
    static func suggestNextChoices(
        session: ProjectSession,
        store: AppStore,
        desiredCount: Int = 3
    ) async throws -> [StoryChoice] {
        guard let provider = store.settings.activeProvider else {
            throw LLMError.notConfigured
        }
        let client = try store.clientForActiveProvider()
        let workspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        let state = workspace.currentState()
        let tailSource: String
        if session.canReadByPage, session.bodyPageCount > 0,
           let lastPage = session.bodyPage(session.bodyPageCount - 1) {
            tailSource = lastPage
        } else {
            tailSource = session.manuscript
        }
        let tail = PromptComposer.codePointTail(tailSource, limit: 2_500)
        let messages = StoryChoicePlanner.buildPlanningMessages(
            state: state,
            manuscriptTail: tail,
            desiredCount: desiredCount
        )
        let request = LLMRequest(
            model: provider.resolvedModel,
            messages: messages,
            stream: false,
            temperature: StoryChoicePlanner.recommendedTemperature,
            maxTokens: max(provider.maxTokens, 2_048),
            failOnLength: true
        )
        let raw = try await client.complete(request)
        return try StoryChoicePlanner.parseChoices(from: raw, limit: desiredCount)
    }

    // MARK: - 后台冷同步

    private static func scheduleColdDeltaSync(
        excerpt: String,
        nodeID: String,
        pageIndex: Int,
        baseUTF16Offset: Int,
        session: ProjectSession,
        store: AppStore
    ) {
        let projectID = session.project.id
        cancelPendingSync(projectID: projectID)
        let taskToken = UUID()

        let task = Task { @MainActor in
            var bgTaskID: UIBackgroundTaskIdentifier = .invalid
            bgTaskID = UIApplication.shared.beginBackgroundTask(
                withName: "FrthinkNarrativeCommitSync"
            ) {
                if syncTasks[projectID]?.token == taskToken {
                    cancelPendingSync(projectID: projectID)
                }
                let expired = bgTaskID
                bgTaskID = .invalid
                if expired != .invalid {
                    UIApplication.shared.endBackgroundTask(expired)
                }
            }
            defer {
                let remaining = bgTaskID
                bgTaskID = .invalid
                if remaining != .invalid {
                    UIApplication.shared.endBackgroundTask(remaining)
                }
                if syncTasks[projectID]?.token == taskToken {
                    syncTasks[projectID] = nil
                }
            }

            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }

            guard let provider = store.narrativeSyncProvider,
                  let client = try? store.clientForNarrativeSync(),
                  let currentWorkspace = session.narrativeWorkspace,
                  currentWorkspace.storyGraph.nodes[nodeID] != nil
            else {
                return
            }

            do {
                try await extractAndApplyDelta(
                    nodeID: nodeID,
                    excerpt: excerpt,
                    pageIndex: pageIndex,
                    baseUTF16Offset: baseUTF16Offset,
                    client: client,
                    provider: provider,
                    session: session,
                    store: store
                )
                await consolidatePyramidIfNeeded(
                    client: client,
                    provider: provider,
                    session: session
                )
            } catch {
                guard !Task.isCancelled, !error.isLLMCancellation else { return }
                store.toast = "后台世界更新失败，可稍后在世界核查中重试"
            }
        }
        syncTasks[projectID] = (token: taskToken, task: task)
    }

    private static func extractAndApplyDelta(
        nodeID: String,
        excerpt: String,
        pageIndex: Int,
        baseUTF16Offset: Int,
        client: any LLMClient,
        provider: ProviderSetting,
        session: ProjectSession,
        store: AppStore? = nil
    ) async throws {
        guard let currentWorkspace = session.narrativeWorkspace,
              currentWorkspace.storyGraph.nodes[nodeID] != nil
        else {
            return
        }
        let currentState = currentWorkspace.currentState()
        let knownEntities = currentState.entityPages.values.sorted { $0.id < $1.id }
        let activeThreads = currentState.threads.values
            .filter { !$0.state.isTerminal }
            .sorted { $0.id < $1.id }
        let activeEvents = Array(
            currentState.sortedEpisodicEvents()
                .filter { $0.status == .ongoing }
                .prefix(8)
        )

        let messages = NarrativeDeltaExtractor.buildExtractionMessages(
            excerpt: excerpt,
            knownEntities: knownEntities,
            activeThreads: activeThreads,
            activeEvents: activeEvents
        )
        let request = LLMRequest(
            model: provider.resolvedModel,
            messages: messages,
            stream: false,
            temperature: deltaExtractionTemperature,
            maxTokens: max(provider.maxTokens, 2_048),
            thinking: false,
            failOnLength: true
        )

        let raw = try await client.complete(request)
        try Task.checkCancellation()

        guard var latestWorkspace = session.narrativeWorkspace,
              var targetNode = latestWorkspace.storyGraph.nodes[nodeID]
        else {
            return
        }
        let latestState = latestWorkspace.currentState()
        let latestKnownEntities = latestState.entityPages.values.sorted { $0.id < $1.id }
        let latestActiveEvents = Array(
            latestState.sortedEpisodicEvents()
                .filter { $0.status == .ongoing }
                .prefix(8)
        )
        let extraction = try NarrativeDeltaExtractor.parseDelta(
            from: raw,
            excerpt: excerpt,
            nodeID: nodeID,
            pageIndex: pageIndex,
            baseUTF16Offset: baseUTF16Offset,
            knownEntities: latestKnownEntities,
            activeEvents: latestActiveEvents
        )

        var updatedDelta = extraction.delta
        if updatedDelta.pyramidPatch == nil {
            updatedDelta.pyramidPatch = targetNode.delta.pyramidPatch
        } else if updatedDelta.pyramidPatch?.anchorIndexVersion == nil {
            updatedDelta.pyramidPatch?.anchorIndexVersion = targetNode.delta.pyramidPatch?.anchorIndexVersion
        }
        targetNode.delta = updatedDelta
        latestWorkspace.storyGraph.nodes[nodeID] = targetNode
        latestWorkspace.applyLedgerDelta(updatedDelta, sourceNodeID: nodeID)
        latestWorkspace.pendingSyncNodeIDs.removeAll { $0 == nodeID }
        latestWorkspace.syncedManuscriptUTF16Offset = max(
            latestWorkspace.syncedManuscriptUTF16Offset,
            baseUTF16Offset + (excerpt as NSString).length
        )
        session.noteNarrativeWorkspaceUpdated(latestWorkspace)

        if let store,
           store.settings.autoSceneContextPruning,
           let transition = extraction.sceneTransition,
           transition.shouldAutoPrune {
            var didPrune = false
            if baseUTF16Offset > (session.payload.sceneBoundaryOffset ?? 0) {
                session.setSceneBoundaryOffset(baseUTF16Offset)
                didPrune = true
            }
            if let sourceMessageID = targetNode.sourceMessageID,
               session.autoPruneMessagesBefore(
                   messageID: sourceMessageID,
                   bridgeSummary: transition.formattedBridge
               ) > 0 {
                didPrune = true
            }
            if didPrune {
                store.toast = "检测到换场，已自动收起前场上下文"
            }
        }
    }

    static func consolidatePyramidIfNeeded(
        client: any LLMClient,
        provider: ProviderSetting,
        session: ProjectSession
    ) async {
        guard var workspace = session.narrativeWorkspace else { return }

        let sceneCards = NarrativePyramidConsolidator.pendingSceneCardsForRollup(in: workspace.pyramid)
        if !sceneCards.isEmpty {
            let summary = await rollupSummary(
                items: sceneCards,
                messages: NarrativePyramidConsolidator.buildSceneRollupMessages(cards: sceneCards),
                fallbackMaxChars: 120,
                client: client,
                provider: provider
            )
            guard !Task.isCancelled, var latest = session.narrativeWorkspace else { return }
            NarrativePyramidConsolidator.applySceneRollup(
                summary: summary,
                consumedCount: sceneCards.count,
                to: &latest.pyramid
            )
            session.noteNarrativeWorkspaceUpdated(latest)
            workspace = latest
        }

        let plotlines = NarrativePyramidConsolidator.pendingPlotlinesForRollup(in: workspace.pyramid)
        if !plotlines.isEmpty {
            let summary = await rollupSummary(
                items: plotlines,
                messages: NarrativePyramidConsolidator.buildVolumeRollupMessages(plotlines: plotlines),
                fallbackMaxChars: 150,
                client: client,
                provider: provider
            )
            guard !Task.isCancelled, var latest = session.narrativeWorkspace else { return }
            NarrativePyramidConsolidator.applyVolumeRollup(
                summary: summary,
                consumedCount: plotlines.count,
                to: &latest.pyramid
            )
            session.noteNarrativeWorkspaceUpdated(latest)
        }
    }

    private static func rollupSummary(
        items: [String],
        messages: [LLMMessage],
        fallbackMaxChars: Int,
        client: any LLMClient,
        provider: ProviderSetting
    ) async -> String {
        let request = LLMRequest(
            model: provider.resolvedModel,
            messages: messages,
            stream: false,
            temperature: deltaExtractionTemperature,
            maxTokens: min(max(provider.maxTokens, 512), 1_024),
            thinking: false,
            failOnLength: false
        )
        if let raw = try? await client.complete(request) {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                return clean
            }
        }
        return NarrativePyramidConsolidator.deterministicFallbackSummary(
            items,
            maxChars: fallbackMaxChars
        )
    }

    private static func resolveExcerptSlice(
        for node: PlotNode,
        session: ProjectSession
    ) -> (excerpt: String, pageIndex: Int, baseUTF16Offset: Int)? {
        guard let anchor = node.manuscriptAnchor else { return nil }
        if session.canReadByPage,
           let pageText = session.bodyPage(anchor.pageIndex),
           !pageText.isEmpty {
            let pageBase = session.pageStartOffset(for: anchor.pageIndex)
            let nsPage = pageText as NSString
            let localStart = anchor.utf16Start - pageBase
            if localStart >= 0,
               anchor.utf16Length > 0,
               anchor.utf16Length <= nsPage.length - localStart {
                let span = nsPage.substring(with: NSRange(location: localStart, length: anchor.utf16Length))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if span.count >= 10 {
                    return (String(span.prefix(3_000)), anchor.pageIndex, anchor.utf16Start)
                }
            }
            let cleanPage = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleanPage.count >= 10 {
                return (String(cleanPage.prefix(3_000)), anchor.pageIndex, pageBase)
            }
        }

        let nsFull = session.manuscript as NSString
        if anchor.utf16Start >= 0,
           anchor.utf16Length > 0,
           anchor.utf16Length <= nsFull.length - anchor.utf16Start {
            let span = nsFull.substring(with: NSRange(location: anchor.utf16Start, length: anchor.utf16Length))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if span.count >= 10 {
                return (String(span.prefix(3_000)), anchor.pageIndex, anchor.utf16Start)
            }
        }

        let quote = anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines)
        if quote.count >= 10 {
            return (String(quote.prefix(3_000)), anchor.pageIndex, anchor.utf16Start)
        }
        return nil
    }

    private static func dequeuePendingNode(_ nodeID: String, in session: ProjectSession) {
        guard var workspace = session.narrativeWorkspace else { return }
        let before = workspace.pendingSyncNodeIDs.count
        workspace.pendingSyncNodeIDs.removeAll { $0 == nodeID }
        if workspace.pendingSyncNodeIDs.count != before {
            session.noteNarrativeWorkspaceUpdated(workspace)
        }
    }

    static func compactLineSnippet(_ text: String, limit: Int) -> String {
        let singleLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        if singleLine.count <= limit {
            return singleLine
        }
        return String(singleLine.prefix(limit)) + "…"
    }
}
