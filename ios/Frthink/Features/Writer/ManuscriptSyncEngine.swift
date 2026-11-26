import Foundation

struct ManuscriptSyncChunk: Equatable {
    let text: String
    let utf16Start: Int
    let utf16End: Int
}

struct ManuscriptSyncProgress: Equatable {
    let completedChunks: Int
    let totalChunks: Int
    let entitiesAdded: Int
    let eventsUpdated: Int
    let threadsUpdated: Int
}

struct ManuscriptSyncResult: Equatable {
    let processedChunks: Int
    let entitiesAdded: Int
    let factsAdded: Int
    let eventsUpdated: Int
    let threadsUpdated: Int
}

/// 分段全书同步器：按记录的同步位置顺序扫描正文，单次调用更新档案、事实、关键事件、伏笔与剧情节点。
@MainActor
enum ManuscriptSyncEngine {

    /// 按自然段或换行边界切分未同步的正文区间（UTF-16 安全，不截断代理对）。
    static func splitIntoSyncChunks(
        fullText: String,
        startUTF16: Int,
        targetChunkUTF16: Int = 6_500
    ) -> [ManuscriptSyncChunk] {
        let ns = fullText as NSString
        let length = ns.length
        guard length > 0 else { return [] }

        var cursor = max(0, startUTF16)
        guard cursor < length else { return [] }
        cursor = ns.rangeOfComposedCharacterSequence(at: cursor).location

        let safeTarget = max(1, targetChunkUTF16)
        var chunks: [ManuscriptSyncChunk] = []

        while cursor < length {
            let end: Int
            if length - cursor <= safeTarget {
                end = length
            } else {
                let rawMaxEnd = min(length, cursor + safeTarget)
                let composed = ns.rangeOfComposedCharacterSequence(at: max(cursor, rawMaxEnd - 1))
                let safeMaxEnd = min(length, max(cursor + 1, composed.location + composed.length))
                let minBoundary = min(safeMaxEnd, cursor + Int(Double(safeTarget) * 0.65))
                let searchRange = NSRange(location: minBoundary, length: max(0, safeMaxEnd - minBoundary))

                let doubleNewline = ns.range(of: "\n\n", options: .backwards, range: searchRange)
                if doubleNewline.location != NSNotFound {
                    end = doubleNewline.location + doubleNewline.length
                } else {
                    let singleNewline = ns.range(of: "\n", options: .backwards, range: searchRange)
                    if singleNewline.location != NSNotFound {
                        end = singleNewline.location + singleNewline.length
                    } else {
                        end = safeMaxEnd
                    }
                }
            }

            let safeEnd = max(cursor + 1, min(length, end))
            let slice = ns.substring(with: NSRange(location: cursor, length: safeEnd - cursor))
            if !slice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                chunks.append(ManuscriptSyncChunk(text: slice, utf16Start: cursor, utf16End: safeEnd))
            }
            cursor = safeEnd
        }

        return chunks
    }

    /// 沿上次同步位置分段抽取出档案、事实、关键事件、伏笔与剧情节点，每段即时落盘以支持断点续跑。
    @discardableResult
    static func syncManuscript(
        session: ProjectSession,
        store: AppStore,
        rescanFromStart: Bool = false,
        targetChunkUTF16: Int = 6_500,
        onProgress: (@MainActor (ManuscriptSyncProgress) -> Void)? = nil
    ) async throws -> ManuscriptSyncResult {
        guard let provider = store.narrativeSyncProvider else {
            throw LLMError.notConfigured
        }
        let client = try store.clientForNarrativeSync()

        let projectID = session.project.id
        let canReadByPage = session.canReadByPage
        let pageCount = session.bodyPageCount
        let fileStore = store.fileStore
        let fallbackManuscript = (canReadByPage && pageCount > 0) ? nil : session.manuscript

        let fullText = await Task.detached(priority: .userInitiated) {
            let pages = ProjectSession.loadManuscriptPages(
                projectID: projectID,
                canReadByPage: canReadByPage,
                bodyPageCount: pageCount,
                fileStore: fileStore,
                fallbackManuscript: fallbackManuscript
            )
            return pages.joined()
        }.value

        var workspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        if rescanFromStart {
            workspace.syncedManuscriptUTF16Offset = 0
            session.noteNarrativeWorkspaceUpdated(workspace)
        }

        let chunks = splitIntoSyncChunks(
            fullText: fullText,
            startUTF16: workspace.syncedManuscriptUTF16Offset,
            targetChunkUTF16: targetChunkUTF16
        )
        let fullUTF16Length = (fullText as NSString).length

        guard !chunks.isEmpty else {
            if workspace.syncedManuscriptUTF16Offset < fullUTF16Length {
                workspace.syncedManuscriptUTF16Offset = fullUTF16Length
                session.noteNarrativeWorkspaceUpdated(workspace)
            }
            return ManuscriptSyncResult(
                processedChunks: 0,
                entitiesAdded: 0,
                factsAdded: 0,
                eventsUpdated: 0,
                threadsUpdated: 0
            )
        }

        var totalEntitiesAdded = 0
        var totalFactsAdded = 0
        var totalEventsUpdated = 0
        var totalThreadsUpdated = 0
        let pageSize = max(1, FileStore.bodyPageSize)

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()

            workspace = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            let stateBefore = workspace.currentState()
            let knownEntities = stateBefore.entityPages.values.sorted { $0.id < $1.id }
            let activeThreads = stateBefore.threads.values
                .filter { !$0.state.isTerminal }
                .sorted { $0.id < $1.id }
            let activeEvents = Array(
                stateBefore.sortedEpisodicEvents()
                    .filter { $0.status == .ongoing }
                    .prefix(8)
            )

            let messages = NarrativeDeltaExtractor.buildExtractionMessages(
                excerpt: chunk.text,
                knownEntities: knownEntities,
                activeThreads: activeThreads,
                activeEvents: activeEvents
            )
            let request = LLMRequest(
                model: provider.resolvedModel,
                messages: messages,
                stream: false,
                temperature: NarrativeCommitCoordinator.deltaExtractionTemperature,
                maxTokens: max(provider.maxTokens, 2_048),
                thinking: false,
                failOnLength: true
            )

            let raw = try await client.complete(request)
            try Task.checkCancellation()

            var latestWorkspace = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            let latestState = latestWorkspace.currentState()
            let latestKnownEntities = latestState.entityPages.values.sorted { $0.id < $1.id }
            let latestActiveEvents = Array(
                latestState.sortedEpisodicEvents()
                    .filter { $0.status == .ongoing }
                    .prefix(8)
            )

            let nodeID = "sync_\(UUID().uuidString)"
            let pageIndex = max(0, chunk.utf16Start / pageSize)
            let extraction = try NarrativeDeltaExtractor.parseDelta(
                from: raw,
                excerpt: chunk.text,
                nodeID: nodeID,
                pageIndex: pageIndex,
                baseUTF16Offset: chunk.utf16Start,
                knownEntities: latestKnownEntities,
                activeEvents: latestActiveEvents
            )

            MechanicalAnchorExtractor.appendPage(
                chunk.text,
                pageIndex: pageIndex,
                baseUTF16Offset: chunk.utf16Start,
                knownEntities: latestKnownEntities,
                to: &latestWorkspace.anchorIndex
            )

            var updatedDelta = extraction.delta
            if updatedDelta.pyramidPatch == nil {
                updatedDelta.pyramidPatch = NarrativePyramidPatch(
                    anchorIndexVersion: latestWorkspace.anchorIndex.version
                )
            } else if updatedDelta.pyramidPatch?.anchorIndexVersion == nil {
                updatedDelta.pyramidPatch?.anchorIndexVersion = latestWorkspace.anchorIndex.version
            }

            let trimmedChunk = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let headID = latestWorkspace.storyGraph.headNodeID
            let branchLabel = latestWorkspace.storyGraph.nodes[headID]?.branchLabel ?? "主线"
            let anchor = TextSpanAnchor.make(
                pageIndex: pageIndex,
                utf16Start: chunk.utf16Start,
                utf16Length: max(0, chunk.utf16End - chunk.utf16Start),
                quote: String(trimmedChunk.prefix(80)),
                paragraphText: trimmedChunk
            )
            let sceneSummary = updatedDelta.pyramidPatch?.appendedSceneCards.first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let snippet = NarrativeCommitCoordinator.compactLineSnippet(chunk.text, limit: 28)
            let summaryText = !sceneSummary.isEmpty ? sceneSummary : (snippet.isEmpty ? "同步正文片段" : snippet)
            let node = PlotNode(
                id: nodeID,
                parentID: headID,
                branchLabel: branchLabel,
                summary: summaryText,
                manuscriptAnchor: anchor,
                sourceMessageID: nil,
                delta: updatedDelta
            )

            try? latestWorkspace.storyGraph.appendNode(node)
            latestWorkspace.applyLedgerDelta(updatedDelta, sourceNodeID: nodeID)
            latestWorkspace.syncedManuscriptUTF16Offset = max(
                latestWorkspace.syncedManuscriptUTF16Offset,
                chunk.utf16End
            )
            session.noteNarrativeWorkspaceUpdated(latestWorkspace)

            let existingEntityIDs = Set(latestKnownEntities.map(\.id))
            totalEntitiesAdded += updatedDelta.entityPageUpserts.filter { !existingEntityIDs.contains($0.id) }.count
            totalFactsAdded += updatedDelta.factEvents.count
            totalEventsUpdated += updatedDelta.episodicEvents.count
            totalThreadsUpdated += updatedDelta.threadEvents.count

            onProgress?(
                ManuscriptSyncProgress(
                    completedChunks: index + 1,
                    totalChunks: chunks.count,
                    entitiesAdded: totalEntitiesAdded,
                    eventsUpdated: totalEventsUpdated,
                    threadsUpdated: totalThreadsUpdated
                )
            )
        }

        var tailWorkspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        if tailWorkspace.syncedManuscriptUTF16Offset < fullUTF16Length {
            tailWorkspace.syncedManuscriptUTF16Offset = fullUTF16Length
            session.noteNarrativeWorkspaceUpdated(tailWorkspace)
        }

        await NarrativeCommitCoordinator.consolidatePyramidIfNeeded(
            client: client,
            provider: provider,
            session: session
        )

        return ManuscriptSyncResult(
            processedChunks: chunks.count,
            entitiesAdded: totalEntitiesAdded,
            factsAdded: totalFactsAdded,
            eventsUpdated: totalEventsUpdated,
            threadsUpdated: totalThreadsUpdated
        )
    }
}
