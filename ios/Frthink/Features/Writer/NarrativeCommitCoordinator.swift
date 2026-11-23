import Foundation
import UIKit

/// 正文采纳落盘回执：绑定本次追加生成的剧情节点与退回基准，支持系统撤销/重做同步回滚分支头与三账本现状。
struct NarrativeCommitReceipt {
    let projectID: String
    let previousHeadNodeID: String
    let committedNodeID: String
    let previousLedgerSnapshot: MaterializedNarrativeState
    let styleLint: StyleLintReport
}

/// 写作台「采纳后落盘」协调器：
/// 确保未采纳气泡与候选变体绝不污染分支剧情图；仅在作者插入或追加正文后执行零延迟本地锚定、
/// 文风检校与节点记账，并在开启睡眠态同步时以低温度在后台补充结构化状态增量。
@MainActor
enum NarrativeCommitCoordinator {

    private static let deltaExtractionTemperature: Double = 0.15
    private static var syncTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    /// 采纳正文后的同步落盘主入口，并在需要时派发后台增量抽取任务。
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

        let lintReport = ProseStyleLinter.lint(
            trimmed,
            pageIndex: startPage,
            baseUTF16Offset: safeOffset
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

        session.noteNarrativeWorkspaceUpdated(
            workspace,
            persistSynchronously: persistSynchronously
        )

        let receipt = NarrativeCommitReceipt(
            projectID: session.project.id,
            previousHeadNodeID: previousHeadID,
            committedNodeID: nodeID,
            previousLedgerSnapshot: stateBeforeCommit,
            styleLint: lintReport
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

    /// 撤销对应采纳提交：中止挂起冷同步任务并把剧情图头指针与三账本现状无损退回提交前快照。
    static func undoCommit(_ receipt: NarrativeCommitReceipt, session: ProjectSession) {
        cancelPendingSync(projectID: receipt.projectID)
        guard var workspace = session.narrativeWorkspace else { return }
        guard workspace.storyGraph.nodes[receipt.previousHeadNodeID] != nil else { return }
        do {
            try workspace.storyGraph.checkout(nodeID: receipt.previousHeadNodeID)
            workspace.restoreLedgerSnapshot(from: receipt.previousLedgerSnapshot)
            session.noteNarrativeWorkspaceUpdated(workspace)
        } catch {
            return
        }
    }

    /// 重做对应采纳提交：将剧情图头指针恢复到该次提交节点并重施该节点记录的三账本增量。
    static func redoCommit(_ receipt: NarrativeCommitReceipt, session: ProjectSession) {
        guard var workspace = session.narrativeWorkspace else { return }
        guard let node = workspace.storyGraph.nodes[receipt.committedNodeID] else { return }
        do {
            try workspace.storyGraph.checkout(nodeID: receipt.committedNodeID)
            workspace.applyLedgerDelta(node.delta, sourceNodeID: node.id)
            session.noteNarrativeWorkspaceUpdated(workspace)
        } catch {
            return
        }
    }

    static func cancelPendingSync(projectID: String) {
        syncTasks[projectID]?.task.cancel()
        syncTasks[projectID] = nil
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

            guard let provider = store.settings.activeProvider,
                  let client = try? store.clientForActiveProvider(),
                  let currentWorkspace = session.narrativeWorkspace,
                  currentWorkspace.storyGraph.nodes[nodeID] != nil
            else {
                return
            }
            let currentState = currentWorkspace.currentState()

            let knownEntities = currentState.entityPages.values.sorted { $0.id < $1.id }
            let activeThreads = currentState.threads.values
                .filter { !$0.state.isTerminal }
                .sorted { $0.id < $1.id }
            let messages = NarrativeDeltaExtractor.buildExtractionMessages(
                excerpt: excerpt,
                knownEntities: knownEntities,
                activeThreads: activeThreads
            )
            let request = LLMRequest(
                model: provider.resolvedModel,
                messages: messages,
                stream: false,
                temperature: deltaExtractionTemperature,
                maxTokens: max(provider.maxTokens, 2_048),
                failOnLength: true
            )

            do {
                let raw = try await client.complete(request)
                guard !Task.isCancelled else { return }
                let extraction = try NarrativeDeltaExtractor.parseDelta(
                    from: raw,
                    excerpt: excerpt,
                    nodeID: nodeID,
                    pageIndex: pageIndex,
                    baseUTF16Offset: baseUTF16Offset
                )

                guard var latestWorkspace = session.narrativeWorkspace,
                      var targetNode = latestWorkspace.storyGraph.nodes[nodeID]
                else {
                    return
                }

                var updatedDelta = extraction.delta
                if updatedDelta.pyramidPatch == nil {
                    updatedDelta.pyramidPatch = targetNode.delta.pyramidPatch
                } else if updatedDelta.pyramidPatch?.anchorIndexVersion == nil {
                    updatedDelta.pyramidPatch?.anchorIndexVersion = targetNode.delta.pyramidPatch?.anchorIndexVersion
                }
                targetNode.delta = updatedDelta
                latestWorkspace.storyGraph.nodes[nodeID] = targetNode
                latestWorkspace.applyLedgerDelta(updatedDelta, sourceNodeID: nodeID)
                session.noteNarrativeWorkspaceUpdated(latestWorkspace)
            } catch {
                guard !Task.isCancelled, !error.isLLMCancellation else { return }
                store.toast = "后台设定同步失败，可稍后在设定核查中重试"
            }
        }
        syncTasks[projectID] = (token: taskToken, task: task)
    }

    private static func compactLineSnippet(_ text: String, limit: Int) -> String {
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
