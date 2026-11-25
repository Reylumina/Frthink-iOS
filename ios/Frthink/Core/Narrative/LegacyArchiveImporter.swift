import Foundation

/// 一次性旧存档迁移统计摘要。
struct LegacyImportReport: Codable, Hashable {
    var projectID: String
    var title: String
    var bodyCharacterCount: Int
    var importedEntityCount: Int
    var importedDirectiveCount: Int
    var importedFactCount: Int
    var importedThreadCount: Int
    var preservedStyleTemplate: Bool
    var preservedExemplarCount: Int
}

/// 单本书迁移并持久化后的结果组合。
struct LegacyImportedProject {
    var project: Project
    var workspace: NarrativeWorkspace
    var report: LegacyImportReport
}

/// 一次性旧存档迁移器：提取正文、人物设定、世界书、长期写作规则、伏笔与深度蒸馏仿写资产，
/// 并初始化分支剧情图与独立实体页；中间分析断点与历史摘要修订等遗留字段不再带入新工作区。
enum LegacyArchiveImporter {

    static func importFromPayload(
        _ payload: ProjectPayload,
        projectID: String = "",
        projectTitle: String,
        settingsCorpusLibraries: [CorpusLibrary] = [],
        now: Date = Date()
    ) -> (workspace: NarrativeWorkspace, report: LegacyImportReport) {
        let rootID = "root"
        let cleanTitle = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        // 原封保留既有深度蒸馏仿写模板、文风笔记及代表性语料样本。
        let exemplars = collectExemplars(
            from: payload.world,
            projectID: projectID,
            projectTitle: cleanTitle,
            settingsCorpusLibraries: settingsCorpusLibraries
        )
        let preservedStyle = PreservedStyleDistillation(
            styleTemplate: payload.world.styleTemplate,
            styleNotes: payload.world.styleNotes,
            centroidExemplar: exemplars.first,
            exemplars: exemplars
        )

        var directivesAdds: [AuthorDirective] = []
        let trimmedRules = normalizedLongTermRules(from: payload.world)
        if !trimmedRules.isEmpty {
            directivesAdds.append(
                AuthorDirective(
                    id: "import_long_term_rules",
                    verbatimRule: trimmedRules,
                    scope: .global,
                    sourceNodeID: rootID,
                    status: .active,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }
        let trimmedSupplement = payload.assistantSupplement.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSupplement.isEmpty {
            directivesAdds.append(
                AuthorDirective(
                    id: "import_assistant_supplement",
                    verbatimRule: trimmedSupplement,
                    scope: .global,
                    sourceNodeID: rootID,
                    status: .active,
                    createdAt: now,
                    updatedAt: now
                )
            )
        }

        var entityPages: [EntityPage] = []
        var factEvents: [WorldFactEvent] = []
        var epistemicBeliefs: [EpistemicBelief] = []
        var entityNameToID: [String: String] = [:]
        var usedEntityIDs = Set<String>()

        for card in payload.world.characters {
            let name = card.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            var entityID = card.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if entityID.isEmpty || !usedEntityIDs.insert(entityID).inserted {
                entityID = "char_\(SummaryKey.sha256Hex(name + "_\(entityPages.count)").prefix(12))"
                usedEntityIDs.insert(entityID)
            }
            entityNameToID[name] = entityID
            for alias in card.aliases {
                let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanAlias.isEmpty, entityNameToID[cleanAlias] == nil {
                    entityNameToID[cleanAlias] = entityID
                }
            }

            let boundaries = normalizedBoundaries(from: card.boundaries)

            let page = EntityPage(
                id: entityID,
                kind: .character,
                name: name,
                aliases: card.aliases,
                summary: "",
                identity: card.identity,
                voiceProfile: card.voice,
                hardBoundaries: boundaries,
                currentFactIDs: [],
                conflictWarnings: card.snapshotConflicts ?? [],
                enabled: card.enabled ?? true,
                updatedAt: card.updatedAt
            )
            entityPages.append(page)

            let cleanGoal = card.goals.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanGoal.isEmpty {
                factEvents.append(
                    WorldFactEvent(
                        id: "import_\(entityID)_goal",
                        entityID: entityID,
                        attribute: WorldFactEvent.StandardAttribute.goal,
                        value: cleanGoal,
                        nodeID: rootID,
                        authority: .authorDirective,
                        createdAt: now
                    )
                )
            }

            let cleanPersonality = card.personality.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanPersonality.isEmpty {
                factEvents.append(
                    WorldFactEvent(
                        id: "import_\(entityID)_personality",
                        entityID: entityID,
                        attribute: WorldFactEvent.StandardAttribute.personality,
                        value: cleanPersonality,
                        nodeID: rootID,
                        authority: .authorDirective,
                        createdAt: now
                    )
                )
            }

            let cleanRelations = card.relationshipAttitudes.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanRelations.isEmpty {
                let splitRelations = parseRelationshipLines(
                    cleanRelations,
                    entityID: entityID,
                    nodeID: rootID,
                    createdAt: now
                )
                factEvents.append(contentsOf: splitRelations)
            }

            for entry in card.customEntries {
                let cleanEntryTitle = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanEntryBody = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanEntryTitle.isEmpty, !cleanEntryBody.isEmpty else { continue }
                factEvents.append(
                    WorldFactEvent(
                        id: "import_\(entityID)_custom_\(entry.id)",
                        entityID: entityID,
                        attribute: "custom:\(cleanEntryTitle)",
                        value: cleanEntryBody,
                        nodeID: rootID,
                        authority: .authorDirective,
                        createdAt: card.updatedAt
                    )
                )
            }

            for (memIdx, memory) in (card.memories ?? []).enumerated() {
                let cleanContent = memory.content.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanContent.isEmpty else { continue }
                let cleanEvidence = memory.evidence.trimmingCharacters(in: .whitespacesAndNewlines)
                let combined = cleanEvidence.isEmpty
                    ? cleanContent
                    : "\(cleanContent)（依据：\(cleanEvidence)）"
                let anchor: TextSpanAnchor? = cleanEvidence.isEmpty
                    ? nil
                    : TextSpanAnchor.make(
                        pageIndex: 0,
                        utf16Start: 0,
                        utf16Length: (cleanEvidence as NSString).length,
                        quote: cleanEvidence
                    )
                factEvents.append(
                    WorldFactEvent(
                        id: "import_\(entityID)_memory_\(memIdx + 1)",
                        entityID: entityID,
                        attribute: "memory:\(memIdx + 1)",
                        value: combined,
                        nodeID: rootID,
                        authority: .authorDirective,
                        quoteAnchor: anchor,
                        createdAt: memory.createdAt > 0
                            ? Date(timeIntervalSince1970: TimeInterval(memory.createdAt) / 1000)
                            : card.updatedAt
                    )
                )
            }

            if let snap = card.dynamicSnapshot {
                let loc = snap.location.trimmingCharacters(in: .whitespacesAndNewlines)
                if !loc.isEmpty {
                    factEvents.append(
                        WorldFactEvent(
                            id: "import_\(entityID)_loc",
                            entityID: entityID,
                            attribute: WorldFactEvent.StandardAttribute.location,
                            value: loc,
                            nodeID: rootID,
                            authority: .canonProseQuote,
                            createdAt: snap.updatedAt
                        )
                    )
                }
                let cond = snap.condition.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cond.isEmpty {
                    factEvents.append(
                        WorldFactEvent(
                            id: "import_\(entityID)_cond",
                            entityID: entityID,
                            attribute: WorldFactEvent.StandardAttribute.condition,
                            value: cond,
                            nodeID: rootID,
                            authority: .canonProseQuote,
                            createdAt: snap.updatedAt
                        )
                    )
                }
                if !snap.possessions.isEmpty {
                    factEvents.append(
                        WorldFactEvent(
                            id: "import_\(entityID)_poss",
                            entityID: entityID,
                            attribute: WorldFactEvent.StandardAttribute.possession,
                            value: snap.possessions.joined(separator: "、"),
                            nodeID: rootID,
                            authority: .canonProseQuote,
                            createdAt: snap.updatedAt
                        )
                    )
                }
            }

            let personalMemory = card.personalMemory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !personalMemory.isEmpty {
                epistemicBeliefs.append(
                    EpistemicBelief(
                        id: "import_\(entityID)_memory",
                        characterID: entityID,
                        topic: "个人记忆",
                        believedTruth: personalMemory,
                        knowsSecret: true,
                        authority: .authorDirective,
                        updatedAtNodeID: rootID,
                        updatedAt: card.updatedAt
                    )
                )
            }
        }

        for entry in payload.world.worldbookEntries where entry.enabled {
            let body = entry.body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            var entityID = entry.id.trimmingCharacters(in: .whitespacesAndNewlines)
            if entityID.isEmpty || !usedEntityIDs.insert(entityID).inserted {
                entityID = "lore_\(SummaryKey.sha256Hex(entry.title + "_\(entityPages.count)").prefix(12))"
                usedEntityIDs.insert(entityID)
            }
            let title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
            entityPages.append(
                EntityPage(
                    id: entityID,
                    kind: .lore,
                    name: title.isEmpty ? "未命名设定" : title,
                    aliases: entry.resolvedKeys,
                    summary: entry.summary,
                    identity: body,
                    enabled: entry.enabled,
                    updatedAt: entry.updatedAt
                )
            )
        }

        var threadEvents: [ProspectiveThreadEvent] = []
        for thread in payload.world.openThreads {
            let goalText = thread.obligation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? thread.title
                : "\(thread.title)：\(thread.obligation)"
            let relatedIDs = thread.relatedCharacters.map { name -> String in
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return entityNameToID[trimmed] ?? trimmed
            }
            let cleanContext = thread.plantedContext.trimmingCharacters(in: .whitespacesAndNewlines)
            let anchor: TextSpanAnchor? = cleanContext.isEmpty
                ? nil
                : TextSpanAnchor.make(
                    pageIndex: 0,
                    utf16Start: 0,
                    utf16Length: (cleanContext as NSString).length,
                    quote: cleanContext
                )

            threadEvents.append(
                ProspectiveThreadEvent(
                    id: "import_plant_\(thread.id)",
                    threadID: thread.id,
                    kind: .plant,
                    goal: goalText,
                    activationCue: cleanContext,
                    recurrence: .once,
                    relatedEntityIDs: relatedIDs,
                    evidenceAnchor: anchor,
                    authority: .canonProseQuote,
                    nodeID: rootID,
                    createdAt: thread.updatedAt
                )
            )
            if thread.status == .resolved {
                threadEvents.append(
                    ProspectiveThreadEvent(
                        id: "import_sat_\(thread.id)",
                        threadID: thread.id,
                        kind: .markSatisfied,
                        authority: .canonProseQuote,
                        nodeID: rootID,
                        createdAt: thread.updatedAt
                    )
                )
            }
        }

        var episodicEvents: [EpisodicEvent] = []
        for eventCard in payload.world.events {
            let cleanTitle = eventCard.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanTitle.isEmpty else { continue }
            let cleanScene = eventCard.scene.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanCause = eventCard.cause.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanDev = eventCard.development.trimmingCharacters(in: .whitespacesAndNewlines)
            let cleanConsequence = eventCard.consequence.trimmingCharacters(in: .whitespacesAndNewlines)
            let participants = eventCard.characters.compactMap { rawName -> String? in
                let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return entityNameToID[trimmed]
            }
            episodicEvents.append(
                EpisodicEvent(
                    id: "legacy_evt_\(eventCard.id)",
                    title: cleanTitle,
                    arcTitle: "",
                    scene: cleanScene,
                    participantEntityIDs: participants,
                    cause: cleanCause,
                    development: cleanDev,
                    outcome: cleanConsequence,
                    status: cleanConsequence.isEmpty ? .ongoing : .resolved,
                    authority: .authorDirective,
                    nodeID: rootID,
                    updatedAt: eventCard.updatedAt
                )
            )
        }

        let delta = PlotNodeDelta(
            directiveAdds: directivesAdds,
            entityPageUpserts: entityPages,
            factEvents: factEvents,
            epistemicBeliefs: epistemicBeliefs,
            threadEvents: threadEvents,
            episodicEvents: episodicEvents
        )

        let bodyAnchor: TextSpanAnchor? = payload.manuscript.isEmpty
            ? nil
            : TextSpanAnchor.make(
                pageIndex: 0,
                utf16Start: 0,
                utf16Length: (payload.manuscript as NSString).length,
                quote: String(payload.manuscript.prefix(120))
            )

        var graph = StoryGraph.makeInitial(
            rootID: rootID,
            branchLabel: "主线",
            summary: "存档导入基线",
            initialDelta: delta,
            manuscriptAnchor: bodyAnchor,
            now: now
        )
        _ = try? graph.recordCheckpoint(at: rootID, now: now)

        var workspace = NarrativeWorkspace(
            schemaVersion: NarrativeWorkspace.currentSchemaVersion,
            storyGraph: graph,
            preservedStyle: preservedStyle,
            migratedFromLegacyAt: now
        )
        try? workspace.synchronizeMaterializedHead()

        let report = LegacyImportReport(
            projectID: projectID,
            title: cleanTitle.isEmpty ? Project.untitledTitle : cleanTitle,
            bodyCharacterCount: payload.manuscript.count,
            importedEntityCount: workspace.entityPages.count,
            importedDirectiveCount: workspace.directives.activeDirectives().count,
            importedFactCount: factEvents.count,
            importedThreadCount: payload.world.openThreads.count,
            preservedStyleTemplate: !preservedStyle.styleTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            preservedExemplarCount: preservedStyle.exemplars.count
        )
        return (workspace, report)
    }

    /// 打开 `.frthink` 备份并通过临时暂存目录原子写入全部项目数据与分文件叙事工作区。
    @discardableResult
    static func importFromArchiveData(
        _ data: Data,
        into files: FileStore,
        ownerID: String,
        now: Date = Date()
    ) throws -> [LegacyImportedProject] {
        let archive = try FrthinkArchive.openAny(data)
        let settingsCorpusLibraries: [CorpusLibrary]
        switch archive {
        case .full(let full):
            settingsCorpusLibraries = full.settings.corpusLibraries
        case .projects:
            settingsCorpusLibraries = []
        }

        let stagingRoot: URL
        do {
            stagingRoot = try files.makeImportStagingRoot()
        } catch {
            throw FrthinkArchiveError.writeFailed(error.localizedDescription)
        }
        defer { files.discardImportStagingRoot(stagingRoot) }

        let stagedFiles = FileStore(root: stagingRoot)
        var imported: [LegacyImportedProject] = []

        for backup in archive.projects {
            let resolvedTitle = backup.title.isEmpty ? Project.untitledTitle : backup.title
            var payload = backup.snapshot.projectPayload
            if let anchor = payload.continuationAnchor,
               anchor < 0 || anchor > payload.manuscript.utf16.count {
                payload.continuationAnchor = nil
            }
            if payload.chapters.isEmpty, !payload.manuscript.isEmpty {
                payload.chapters = ChapterScanner.scan(payload.manuscript)
            }

            let project = Project(
                id: backup.projectId,
                title: resolvedTitle,
                synopsis: backup.synopsis,
                updatedAt: now,
                revision: 0,
                coverImagePayload: backup.coverImageBase64.isEmpty ? nil : backup.coverImageBase64,
                branchRootId: backup.branchRootId,
                branchOrder: backup.branchOrder,
                trashedAt: backup.trashedAt > 0
                    ? Date(timeIntervalSince1970: TimeInterval(backup.trashedAt) / 1000)
                    : nil,
                bodyCharacterCount: payload.manuscript.count,
                bodyUTF16Length: (payload.manuscript as NSString).length
            )

            let translations = backup.translations.map { segment -> TranslationSegment in
                var copy = segment
                copy.owner = ownerID
                copy.project = project.id
                return copy
            }

            let (workspace, report) = importFromPayload(
                payload,
                projectID: project.id,
                projectTitle: resolvedTitle,
                settingsCorpusLibraries: settingsCorpusLibraries,
                now: now
            )

            do {
                try stagedFiles.saveProject(project)
                try stagedFiles.savePayload(payload, projectID: project.id)
                try stagedFiles.saveBody(
                    payload.manuscript,
                    chapters: payload.chapters,
                    projectID: project.id
                )
                try stagedFiles.saveSource(backup.sourceText, projectID: project.id)
                try stagedFiles.saveTranslations(translations, projectID: project.id)
                try stagedFiles.narrative.saveWorkspace(workspace, projectID: project.id)
                try files.commitStagedProject(projectID: project.id, stagingRoot: stagingRoot)
            } catch {
                throw FrthinkArchiveError.writeFailed(error.localizedDescription)
            }

            imported.append(
                LegacyImportedProject(
                    project: project,
                    workspace: workspace,
                    report: report
                )
            )
        }

        return imported
    }

    /// 将世界书流程更新后的文风、人物与长期规则增量合并进已挂载工作区，避免与新账本分裂。
    static func syncWorldChanges(
        from payload: ProjectPayload,
        projectID: String,
        projectTitle: String,
        settingsCorpusLibraries: [CorpusLibrary] = [],
        syncLegacyCharacters: Bool = false,
        syncLongTermRules: Bool = false,
        into workspace: inout NarrativeWorkspace,
        now: Date = Date()
    ) -> Bool {
        var changed = false

        let exemplars = collectExemplars(
            from: payload.world,
            projectID: projectID,
            projectTitle: projectTitle,
            settingsCorpusLibraries: settingsCorpusLibraries
        )
        var nextStyle = workspace.preservedStyle
        if nextStyle.styleTemplate != payload.world.styleTemplate {
            nextStyle.styleTemplate = payload.world.styleTemplate
        }
        if nextStyle.styleNotes != payload.world.styleNotes {
            nextStyle.styleNotes = payload.world.styleNotes
        }
        if nextStyle.exemplars != exemplars {
            nextStyle.exemplars = exemplars
            nextStyle.centroidExemplar = exemplars.first
        }
        if nextStyle != workspace.preservedStyle {
            workspace.preservedStyle = nextStyle
            changed = true
        }

        let currentState = workspace.currentState()
        var delta = PlotNodeDelta()
        var hasDelta = false
        let rootID = workspace.storyGraph.rootNodeID

        if syncLegacyCharacters {
            for card in payload.world.characters {
                let cleanName = card.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanName.isEmpty else { continue }
                let existing = currentState.entityPages[card.id]
                    ?? currentState.entityPages.values.first { $0.name == cleanName }
                let cardBoundaries = normalizedBoundaries(from: card.boundaries)
                let candidate = EntityPage(
                    id: existing?.id ?? card.id,
                    kind: existing?.kind ?? .character,
                    name: cleanName,
                    aliases: card.aliases,
                    triggerKeywords: existing?.triggerKeywords ?? [],
                    activationMode: existing?.activationMode ?? .mentioned,
                    summary: existing?.summary ?? "",
                    identity: card.identity,
                    voiceProfile: card.voice,
                    hardBoundaries: cardBoundaries.isEmpty ? (existing?.hardBoundaries ?? []) : cardBoundaries,
                    currentFactIDs: existing?.currentFactIDs ?? [],
                    conflictWarnings: existing?.conflictWarnings ?? (card.snapshotConflicts ?? []),
                    enabled: card.enabled ?? true,
                    updatedAt: card.updatedAt
                )
                let semanticUnchanged = existing.map {
                    $0.name == candidate.name
                        && $0.aliases == candidate.aliases
                        && $0.triggerKeywords == candidate.triggerKeywords
                        && $0.activationMode == candidate.activationMode
                        && $0.identity == candidate.identity
                        && $0.voiceProfile == candidate.voiceProfile
                        && $0.hardBoundaries == candidate.hardBoundaries
                        && $0.enabled == candidate.enabled
                        && $0.conflictWarnings == candidate.conflictWarnings
                } ?? false
                if !semanticUnchanged {
                    delta.entityPageUpserts.append(candidate)
                    hasDelta = true
                }
            }
        }

        if syncLongTermRules {
            let effectiveRules = normalizedLongTermRules(from: payload.world)
            let activeImportedRule = currentState.directiveLedger.directives.first {
                $0.status == .active
                    && ($0.id == "import_long_term_rules" || $0.id.hasPrefix("import_long_term_rules_"))
            }
            if let existingRule = activeImportedRule {
                if existingRule.verbatimRule != effectiveRules {
                    let replacement: AuthorDirective? = effectiveRules.isEmpty
                        ? nil
                        : AuthorDirective(
                            id: "import_long_term_rules_\(UUID().uuidString.prefix(8))",
                            verbatimRule: effectiveRules,
                            scope: .global,
                            sourceNodeID: rootID,
                            createdAt: now,
                            updatedAt: now
                        )
                    delta.directiveSupersedes.append(
                        DirectiveSupersede(targetID: existingRule.id, replacement: replacement)
                    )
                    hasDelta = true
                }
            } else if !effectiveRules.isEmpty {
                delta.directiveAdds.append(
                    AuthorDirective(
                        id: "import_long_term_rules",
                        verbatimRule: effectiveRules,
                        scope: .global,
                        sourceNodeID: rootID,
                        createdAt: now,
                        updatedAt: now
                    )
                )
                hasDelta = true
            }
        }

        if hasDelta {
            workspace.applyLedgerDelta(delta, sourceNodeID: workspace.storyGraph.headNodeID)
            changed = true
        }
        return changed
    }

    private static func collectExemplars(
        from world: WorldBook,
        projectID: String,
        projectTitle: String,
        settingsCorpusLibraries: [CorpusLibrary]
    ) -> [CorpusEntry] {
        let cleanTitle = projectTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookLibraryName = cleanTitle.isEmpty ? "" : "本书节选 · \(cleanTitle)"
        var rawExemplars: [CorpusEntry] = []
        rawExemplars.append(contentsOf: world.corpus)
        for lib in settingsCorpusLibraries {
            guard lib.enabled else { continue }
            let matchesProjectID = !projectID.isEmpty && lib.projectID == projectID
            let matchesBookTitle = !bookLibraryName.isEmpty && lib.name == bookLibraryName
            if matchesProjectID || matchesBookTitle {
                rawExemplars.append(contentsOf: lib.entries)
            }
        }
        var seen = Set<String>()
        var exemplars: [CorpusEntry] = []
        for entry in rawExemplars {
            let trimmedText = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else { continue }
            let key = "\(entry.title)\u{1F}\(trimmedText)"
            guard seen.insert(key).inserted else { continue }
            exemplars.append(entry)
        }
        return exemplars
    }

    private static func normalizedLongTermRules(from world: WorldBook) -> String {
        let trimmed = world.longTermRules.trimmingCharacters(in: .whitespacesAndNewlines)
        guard world.summaryEnabled, !trimmed.isEmpty, trimmed != "暂无长期规则。" else {
            return ""
        }
        return trimmed
    }

    private static func normalizedBoundaries(from raw: String) -> [String] {
        raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parseRelationshipLines(
        _ raw: String,
        entityID: String,
        nodeID: String,
        createdAt: Date
    ) -> [WorldFactEvent] {
        let disallowedTargetChars = CharacterSet(charactersIn: "，。、；;！？!?（）()【】「」\"'")
        var results: [WorldFactEvent] = []
        var fallbackLines: [String] = []

        for (idx, rawLine) in raw.split(whereSeparator: \.isNewline).enumerated() {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            for prefix in ["- ", "• ", "* "] {
                if line.hasPrefix(prefix) {
                    line = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    break
                }
            }
            if let colonRange = line.range(of: "：") ?? line.range(of: ":") {
                let target = String(line[..<colonRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let attitude = String(line[colonRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !target.isEmpty,
                   target.count <= 16,
                   target.rangeOfCharacter(from: disallowedTargetChars) == nil,
                   !attitude.isEmpty {
                    results.append(
                        WorldFactEvent(
                            id: "import_\(entityID)_rel_\(idx)_\(SummaryKey.sha256Hex(target).prefix(6))",
                            entityID: entityID,
                            attribute: "relation:\(target)",
                            value: attitude,
                            nodeID: nodeID,
                            authority: .authorDirective,
                            createdAt: createdAt
                        )
                    )
                    continue
                }
            }
            fallbackLines.append(line)
        }

        if !fallbackLines.isEmpty {
            results.append(
                WorldFactEvent(
                    id: "import_\(entityID)_relation",
                    entityID: entityID,
                    attribute: WorldFactEvent.StandardAttribute.relation,
                    value: fallbackLines.joined(separator: "\n"),
                    nodeID: nodeID,
                    authority: .authorDirective,
                    createdAt: createdAt
                )
            )
        }
        return results
    }
}
