import Foundation

struct ManuscriptSyncChunk: Equatable {
    let text: String
    let utf16Start: Int
    let utf16End: Int
    let leadingContext: String

    init(text: String, utf16Start: Int, utf16End: Int, leadingContext: String = "") {
        self.text = text
        self.utf16Start = utf16Start
        self.utf16End = utf16End
        self.leadingContext = leadingContext
    }
}

struct ManuscriptSyncProgress: Equatable {
    let completedChunks: Int
    let totalChunks: Int
    let entitiesAdded: Int
    let eventsUpdated: Int
    let threadsUpdated: Int
    let stageLabel: String

    init(
        completedChunks: Int,
        totalChunks: Int,
        entitiesAdded: Int,
        eventsUpdated: Int,
        threadsUpdated: Int,
        stageLabel: String = ""
    ) {
        self.completedChunks = completedChunks
        self.totalChunks = totalChunks
        self.entitiesAdded = entitiesAdded
        self.eventsUpdated = eventsUpdated
        self.threadsUpdated = threadsUpdated
        self.stageLabel = stageLabel
    }
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

    /// 按自然段或换行边界切分未同步的正文区间（UTF-16 安全，不截断代理对），并为续段附带只读前情参考。
    static func splitIntoSyncChunks(
        fullText: String,
        startUTF16: Int,
        targetChunkUTF16: Int = 3_500,
        contextOverlapUTF16: Int = 250
    ) -> [ManuscriptSyncChunk] {
        let ns = fullText as NSString
        let length = ns.length
        guard length > 0 else { return [] }

        var cursor = max(0, startUTF16)
        guard cursor < length else { return [] }
        cursor = ns.rangeOfComposedCharacterSequence(at: cursor).location

        let safeTarget = max(1, targetChunkUTF16)
        let safeOverlap = max(0, contextOverlapUTF16)
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
                let leadingContext: String
                if cursor > 0 && safeOverlap > 0 {
                    let rawLeadStart = max(0, cursor - safeOverlap)
                    let safeLeadStart = ns.rangeOfComposedCharacterSequence(at: rawLeadStart).location
                    leadingContext = ns.substring(
                        with: NSRange(location: safeLeadStart, length: cursor - safeLeadStart)
                    ).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    leadingContext = ""
                }
                chunks.append(
                    ManuscriptSyncChunk(
                        text: slice,
                        utf16Start: cursor,
                        utf16End: safeEnd,
                        leadingContext: leadingContext
                    )
                )
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
        targetChunkUTF16: Int = 3_500,
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
            // 仅清理未挂接非同步子节点的老旧 sync_* 节点，防止重扫全书时重复堆叠剧情线。
            let prunableSyncIDs = Set(
                workspace.storyGraph.nodes.values
                    .filter { node in
                        node.id.hasPrefix("sync_")
                            && !workspace.storyGraph.downstreamImpactedNodes(of: node.id).contains {
                                !$0.id.hasPrefix("sync_")
                            }
                    }
                    .map(\.id)
            )
            if !prunableSyncIDs.isEmpty {
                _ = workspace.storyGraph.pruneSubtree { prunableSyncIDs.contains($0.id) }
            }
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
        var newlyCreatedEntityIDs: [String] = []
        let pageSize = max(1, FileStore.bodyPageSize)

        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()

            workspace = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            let stateBefore = workspace.currentState()
            let knownEntitiesBefore = stateBefore.entityPages.values.sorted { $0.id < $1.id }
            let existingEntityIDs = Set(knownEntitiesBefore.map(\.id))

            let nodeID = "sync_\(UUID().uuidString)"
            let pageIndex = max(0, chunk.utf16Start / pageSize)

            // 阶段 1：抽取四类档案与精确动态事实
            onProgress?(
                ManuscriptSyncProgress(
                    completedChunks: index,
                    totalChunks: chunks.count,
                    entitiesAdded: totalEntitiesAdded,
                    eventsUpdated: totalEventsUpdated,
                    threadsUpdated: totalThreadsUpdated,
                    stageLabel: "提取档案"
                )
            )
            let stage1Payload = NarrativeEntityExtractor.buildExtractionPayload(
                manuscriptTail: chunk.text,
                leadingContext: chunk.leadingContext,
                existingPages: knownEntitiesBefore,
                includeFacts: true
            )
            let stage1Request = LLMRequest(
                model: provider.resolvedModel,
                messages: stage1Payload.messages,
                stream: false,
                temperature: NarrativeCommitCoordinator.deltaExtractionTemperature,
                maxTokens: max(provider.maxTokens, 4_096),
                thinking: false,
                failOnLength: true
            )
            let rawStage1 = try await client.complete(stage1Request)
            try Task.checkCancellation()

            var workingWorkspace = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            let latestKnownBeforeStage1 = workingWorkspace.currentState().entityPages.values
                .sorted { $0.id < $1.id }
            let stage1Result = try NarrativeEntityExtractor.parseEntitiesAndFacts(
                from: rawStage1,
                excerpt: chunk.text,
                nodeID: nodeID,
                pageIndex: pageIndex,
                baseUTF16Offset: chunk.utf16Start,
                existingPages: latestKnownBeforeStage1,
                idMapping: stage1Payload.mapping
            )
            let stage1Delta = PlotNodeDelta(
                entityPageUpserts: stage1Result.upserts,
                factEvents: stage1Result.factEvents
            )
            if !stage1Delta.isEmpty {
                // 仅在内存工作区演进供阶段 2 读取，待两阶段均成功后随 PlotNode 原子落盘。
                workingWorkspace.applyLedgerDelta(stage1Delta, sourceNodeID: nodeID)
            }

            // 阶段 2：基于已定型实体抽取剧情事件、伏笔与角色认知盲区
            onProgress?(
                ManuscriptSyncProgress(
                    completedChunks: index,
                    totalChunks: chunks.count,
                    entitiesAdded: totalEntitiesAdded,
                    eventsUpdated: totalEventsUpdated,
                    threadsUpdated: totalThreadsUpdated,
                    stageLabel: "提取剧情"
                )
            )
            let stage2State = workingWorkspace.currentState()
            let stage2Entities = stage2State.entityPages.values.sorted { $0.id < $1.id }
            let stage2Threads = stage2State.threads.values
                .filter { !$0.state.isTerminal }
                .sorted { $0.id < $1.id }
            let stage2Events = stage2State.sortedEpisodicEvents()
                .filter { $0.status == .ongoing }
            let stage2Payload = NarrativeDeltaExtractor.buildPlotExtractionPayload(
                excerpt: chunk.text,
                leadingContext: chunk.leadingContext,
                knownEntities: stage2Entities,
                activeThreads: stage2Threads,
                activeEvents: stage2Events
            )
            let stage2Request = LLMRequest(
                model: provider.resolvedModel,
                messages: stage2Payload.messages,
                stream: false,
                temperature: NarrativeCommitCoordinator.deltaExtractionTemperature,
                maxTokens: max(provider.maxTokens, 4_096),
                thinking: false,
                failOnLength: true
            )
            let rawStage2 = try await client.complete(stage2Request)
            try Task.checkCancellation()

            var finalWorkspace = workingWorkspace
            let finalState = finalWorkspace.currentState()
            let finalEntities = finalState.entityPages.values.sorted { $0.id < $1.id }
            let finalActiveEvents = finalState.sortedEpisodicEvents()
                .filter { $0.status == .ongoing }
            let stage2Result = try NarrativeDeltaExtractor.parsePlotDelta(
                from: rawStage2,
                excerpt: chunk.text,
                nodeID: nodeID,
                pageIndex: pageIndex,
                baseUTF16Offset: chunk.utf16Start,
                knownEntities: finalEntities,
                activeEvents: finalActiveEvents,
                idMapping: stage2Payload.mapping
            )

            MechanicalAnchorExtractor.appendPage(
                chunk.text,
                pageIndex: pageIndex,
                baseUTF16Offset: chunk.utf16Start,
                knownEntities: finalEntities,
                to: &finalWorkspace.anchorIndex
            )

            var combinedDelta = PlotNodeDelta(
                entityPageUpserts: stage1Result.upserts,
                factEvents: stage1Result.factEvents,
                epistemicBeliefs: stage2Result.delta.epistemicBeliefs,
                threadEvents: stage2Result.delta.threadEvents,
                episodicEvents: stage2Result.delta.episodicEvents,
                pyramidPatch: stage2Result.delta.pyramidPatch
            )
            if combinedDelta.pyramidPatch == nil {
                combinedDelta.pyramidPatch = NarrativePyramidPatch(
                    anchorIndexVersion: finalWorkspace.anchorIndex.version
                )
            } else if combinedDelta.pyramidPatch?.anchorIndexVersion == nil {
                combinedDelta.pyramidPatch?.anchorIndexVersion = finalWorkspace.anchorIndex.version
            }

            let trimmedChunk = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let headID = finalWorkspace.storyGraph.headNodeID
            let branchLabel = finalWorkspace.storyGraph.nodes[headID]?.branchLabel ?? "主线"
            let anchor = TextSpanAnchor.make(
                pageIndex: pageIndex,
                utf16Start: chunk.utf16Start,
                utf16Length: max(0, chunk.utf16End - chunk.utf16Start),
                quote: String(trimmedChunk.prefix(80)),
                paragraphText: trimmedChunk
            )
            let sceneSummary = combinedDelta.pyramidPatch?.addedRecentSceneCards.first?
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
                delta: combinedDelta
            )

            try? finalWorkspace.storyGraph.appendNode(node)
            var stage2ApplyDelta = stage2Result.delta
            stage2ApplyDelta.pyramidPatch = combinedDelta.pyramidPatch
            finalWorkspace.applyLedgerDelta(stage2ApplyDelta, sourceNodeID: nodeID)
            finalWorkspace.syncedManuscriptUTF16Offset = max(
                finalWorkspace.syncedManuscriptUTF16Offset,
                chunk.utf16End
            )
            session.noteNarrativeWorkspaceUpdated(finalWorkspace)

            let newIDsThisChunk = stage1Result.upserts
                .filter { !existingEntityIDs.contains($0.id) }
                .map(\.id)
            newlyCreatedEntityIDs.append(contentsOf: newIDsThisChunk)
            totalEntitiesAdded += newIDsThisChunk.count
            totalFactsAdded += stage1Result.factEvents.count
            totalEventsUpdated += stage2Result.delta.episodicEvents.count
            totalThreadsUpdated += stage2Result.delta.threadEvents.count

            onProgress?(
                ManuscriptSyncProgress(
                    completedChunks: index + 1,
                    totalChunks: chunks.count,
                    entitiesAdded: totalEntitiesAdded,
                    eventsUpdated: totalEventsUpdated,
                    threadsUpdated: totalThreadsUpdated,
                    stageLabel: ""
                )
            )
        }

        if !newlyCreatedEntityIDs.isEmpty {
            onProgress?(
                ManuscriptSyncProgress(
                    completedChunks: chunks.count,
                    totalChunks: chunks.count,
                    entitiesAdded: totalEntitiesAdded,
                    eventsUpdated: totalEventsUpdated,
                    threadsUpdated: totalThreadsUpdated,
                    stageLabel: "实体去重"
                )
            )
        }
        let removedDuplicates = await deduplicateNewlyCreatedEntities(
            candidateIDs: newlyCreatedEntityIDs,
            client: client,
            provider: provider,
            session: session,
            store: store
        )
        totalEntitiesAdded = max(0, totalEntitiesAdded - removedDuplicates)

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

    private static func deduplicateNewlyCreatedEntities(
        candidateIDs: [String],
        client: any LLMClient,
        provider: ProviderSetting,
        session: ProjectSession,
        store: AppStore
    ) async -> Int {
        let uniqueCandidateIDs = NarrativeEntityResolver.deduplicatedNonEmptyStrings(candidateIDs)
        guard !uniqueCandidateIDs.isEmpty else { return 0 }
        let candidateIDSet = Set(uniqueCandidateIDs)
        var removedCount = 0

        for kind in [EntityKind.character, .location, .artifact, .lore] {
            if Task.isCancelled { break }
            let workspaceSnapshot = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            let allPages = workspaceSnapshot.entityPages
            let candidatesForKind = uniqueCandidateIDs.compactMap { id -> EntityPage? in
                guard let page = allPages[id], page.kind == kind else { return nil }
                return page
            }
            let existingForKind = allPages.values.filter {
                $0.kind == kind && !candidateIDSet.contains($0.id)
            }
            guard let payload = NarrativeEntityResolver.buildDedupeMessages(
                kind: kind,
                candidates: candidatesForKind,
                existing: existingForKind
            ) else {
                continue
            }

            let request = LLMRequest(
                model: provider.resolvedModel,
                messages: payload.messages,
                stream: false,
                temperature: 0.1,
                maxTokens: max(provider.maxTokens, 2_048),
                thinking: false,
                failOnLength: true
            )
            guard let raw = try? await client.complete(request),
                  let suggestions = NarrativeEntityResolver.parseDedupeResponse(
                      from: raw,
                      candidateIDs: payload.candidateIDs,
                      existingIDs: payload.existingIDs
                  ),
                  !suggestions.isEmpty else {
                continue
            }

            var latestWorkspace = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            var didMutate = false
            for suggestion in suggestions {
                if mergeDuplicateEntity(
                    sourceID: suggestion.sourceID,
                    targetID: suggestion.targetID,
                    canonicalName: suggestion.canonicalName,
                    extraAliases: suggestion.extraAliases,
                    in: &latestWorkspace
                ) {
                    removedCount += 1
                    didMutate = true
                }
            }
            if didMutate {
                session.noteNarrativeWorkspaceUpdated(latestWorkspace)
            }
        }
        return removedCount
    }

    private static func mergeDuplicateEntity(
        sourceID: String,
        targetID: String,
        canonicalName: String,
        extraAliases: [String],
        in workspace: inout NarrativeWorkspace
    ) -> Bool {
        guard sourceID != targetID,
              let sourcePage = workspace.entityPages[sourceID],
              let targetPage = workspace.entityPages[targetID],
              sourcePage.kind == targetPage.kind else {
            return false
        }

        let mergedTarget = NarrativeEntityResolver.mergeEntityPage(
            into: targetPage,
            from: sourcePage,
            preferredName: canonicalName,
            extraAliases: extraAliases
        )
        workspace.entityPages[targetID] = mergedTarget
        workspace.entityPages.removeValue(forKey: sourceID)

        for (oldKey, fact) in Array(workspace.activeFacts) where fact.entityID == sourceID {
            workspace.activeFacts.removeValue(forKey: oldKey)
            var migrated = fact
            migrated.entityID = targetID
            let targetSlot = migrated.slotKey
            if let existing = workspace.activeFacts[targetSlot], existing.authority > migrated.authority {
                continue
            }
            workspace.activeFacts[targetSlot] = migrated
        }

        for (oldKey, belief) in Array(workspace.epistemicBeliefs) where belief.characterID == sourceID {
            workspace.epistemicBeliefs.removeValue(forKey: oldKey)
            var migrated = belief
            migrated.characterID = targetID
            let targetSlot = migrated.slotKey
            if let existing = workspace.epistemicBeliefs[targetSlot], existing.authority > migrated.authority {
                continue
            }
            workspace.epistemicBeliefs[targetSlot] = migrated
        }

        for eventID in Array(workspace.episodicEvents.keys) {
            guard var event = workspace.episodicEvents[eventID],
                  event.participantEntityIDs.contains(sourceID) else { continue }
            event.participantEntityIDs = NarrativeEntityResolver.deduplicatedNonEmptyStrings(
                event.participantEntityIDs.map { $0 == sourceID ? targetID : $0 }
            )
            workspace.episodicEvents[eventID] = event
        }

        for threadID in Array(workspace.threads.keys) {
            guard var thread = workspace.threads[threadID],
                  thread.relatedEntityIDs.contains(sourceID) else { continue }
            thread.relatedEntityIDs = NarrativeEntityResolver.deduplicatedNonEmptyStrings(
                thread.relatedEntityIDs.map { $0 == sourceID ? targetID : $0 }
            )
            workspace.threads[threadID] = thread
        }

        workspace.entityPages[targetID]?.currentFactIDs = workspace.activeFacts.values
            .filter { $0.entityID == targetID && !$0.isRetracted }
            .map(\.id)
            .sorted()
        if workspace.activePOVCharacterID == sourceID {
            workspace.activePOVCharacterID = targetID
        }
        workspace.hasLiveLedgers = true
        return true
    }
}
