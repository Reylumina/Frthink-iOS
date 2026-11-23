import Foundation

/// 作者指令废止与可选替换操作。
struct DirectiveSupersede: Codable, Hashable {
    var targetID: String
    var replacement: AuthorDirective?

    init(targetID: String, replacement: AuthorDirective? = nil) {
        self.targetID = targetID
        self.replacement = replacement
    }
}

/// 前瞻伏笔状态迁移的单步事件。
struct ProspectiveThreadEvent: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        case plant
        case promoteReady
        case markEnacted
        case markSatisfied
        case invalidate
        case updateMetadata
    }

    var id: String
    var threadID: String
    var kind: Kind
    var goal: String?
    var activationCue: String?
    var recurrence: RecurrenceKind?
    var relatedEntityIDs: [String]?
    var intendedHorizonNodeOffset: Int?
    var evidenceAnchor: TextSpanAnchor?
    var authority: AuthorityRank
    var nodeID: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        threadID: String,
        kind: Kind,
        goal: String? = nil,
        activationCue: String? = nil,
        recurrence: RecurrenceKind? = nil,
        relatedEntityIDs: [String]? = nil,
        intendedHorizonNodeOffset: Int? = nil,
        evidenceAnchor: TextSpanAnchor? = nil,
        authority: AuthorityRank = .canonProseQuote,
        nodeID: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.threadID = threadID
        self.kind = kind
        self.goal = goal
        self.activationCue = activationCue
        self.recurrence = recurrence
        self.relatedEntityIDs = relatedEntityIDs
        self.intendedHorizonNodeOffset = intendedHorizonNodeOffset
        self.evidenceAnchor = evidenceAnchor
        self.authority = authority
        self.nodeID = nodeID
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        threadID = (try? c.decode(String.self, forKey: .threadID)) ?? ""
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .updateMetadata
        goal = try? c.decodeIfPresent(String.self, forKey: .goal)
        activationCue = try? c.decodeIfPresent(String.self, forKey: .activationCue)
        recurrence = try? c.decodeIfPresent(RecurrenceKind.self, forKey: .recurrence)
        relatedEntityIDs = try? c.decodeIfPresent([String].self, forKey: .relatedEntityIDs)
        intendedHorizonNodeOffset = try? c.decodeIfPresent(Int.self, forKey: .intendedHorizonNodeOffset)
        evidenceAnchor = try? c.decodeIfPresent(TextSpanAnchor.self, forKey: .evidenceAnchor)
        authority = (try? c.decode(AuthorityRank.self, forKey: .authority)) ?? .canonProseQuote
        nodeID = (try? c.decode(String.self, forKey: .nodeID)) ?? "root"
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }
}

/// 绑定在单个剧情节点上的增量变更载荷，交由确定性归约器统一结算覆写与冲突。
struct PlotNodeDelta: Codable, Hashable {
    var directiveAdds: [AuthorDirective]
    var directiveSupersedes: [DirectiveSupersede]
    var entityPageUpserts: [EntityPage]
    /// 整页替换实体档案（用于清理膨胀列表或忽略已审校告警），重放时覆盖同名字段而非追加并集。
    var entityPageReplacements: [EntityPage]
    var factEvents: [WorldFactEvent]
    var epistemicBeliefs: [EpistemicBelief]
    var threadEvents: [ProspectiveThreadEvent]
    var pyramidPatch: NarrativePyramidPatch?

    init(
        directiveAdds: [AuthorDirective] = [],
        directiveSupersedes: [DirectiveSupersede] = [],
        entityPageUpserts: [EntityPage] = [],
        entityPageReplacements: [EntityPage] = [],
        factEvents: [WorldFactEvent] = [],
        epistemicBeliefs: [EpistemicBelief] = [],
        threadEvents: [ProspectiveThreadEvent] = [],
        pyramidPatch: NarrativePyramidPatch? = nil
    ) {
        self.directiveAdds = directiveAdds
        self.directiveSupersedes = directiveSupersedes
        self.entityPageUpserts = entityPageUpserts
        self.entityPageReplacements = entityPageReplacements
        self.factEvents = factEvents
        self.epistemicBeliefs = epistemicBeliefs
        self.threadEvents = threadEvents
        self.pyramidPatch = pyramidPatch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        directiveAdds = (try? c.decode([AuthorDirective].self, forKey: .directiveAdds)) ?? []
        directiveSupersedes = (try? c.decode([DirectiveSupersede].self, forKey: .directiveSupersedes)) ?? []
        entityPageUpserts = (try? c.decode([EntityPage].self, forKey: .entityPageUpserts)) ?? []
        entityPageReplacements = (try? c.decode([EntityPage].self, forKey: .entityPageReplacements)) ?? []
        factEvents = (try? c.decode([WorldFactEvent].self, forKey: .factEvents)) ?? []
        epistemicBeliefs = (try? c.decode([EpistemicBelief].self, forKey: .epistemicBeliefs)) ?? []
        threadEvents = (try? c.decode([ProspectiveThreadEvent].self, forKey: .threadEvents)) ?? []
        pyramidPatch = try? c.decodeIfPresent(NarrativePyramidPatch.self, forKey: .pyramidPatch)
    }
}

/// 被确定性规则拦截的低权威覆写或重复伏笔触发告警，保留供作者确认。
struct StateConflictWarning: Identifiable, Codable, Hashable {
    var id: String
    var entityID: String
    var attribute: String
    var existingEventID: String
    var existingAuthority: AuthorityRank
    var existingValue: String
    var rejectedEventID: String
    var rejectedAuthority: AuthorityRank
    var rejectedValue: String
    var nodeID: String
    var message: String

    init(
        id: String = UUID().uuidString,
        entityID: String,
        attribute: String,
        existingEventID: String,
        existingAuthority: AuthorityRank,
        existingValue: String,
        rejectedEventID: String,
        rejectedAuthority: AuthorityRank,
        rejectedValue: String,
        nodeID: String,
        message: String
    ) {
        self.id = id
        self.entityID = entityID
        self.attribute = attribute
        self.existingEventID = existingEventID
        self.existingAuthority = existingAuthority
        self.existingValue = existingValue
        self.rejectedEventID = rejectedEventID
        self.rejectedAuthority = rejectedAuthority
        self.rejectedValue = rejectedValue
        self.nodeID = nodeID
        self.message = message
    }
}

/// 沿剧情图重放至指定节点后得到的确定性叙事状态快照。
struct MaterializedNarrativeState: Codable, Hashable {
    var atNodeID: String
    var pathNodeIDs: [String]
    var directiveLedger: AuthorDirectiveLedger
    var entityPages: [String: EntityPage]
    var activeFacts: [String: WorldFactEvent]
    var factHistory: [WorldFactEvent]
    var epistemicBeliefs: [String: EpistemicBelief]
    var threads: [String: ProspectiveThread]
    var pyramid: NarrativePyramid
    var conflictWarnings: [StateConflictWarning]

    init(
        atNodeID: String,
        pathNodeIDs: [String] = [],
        directiveLedger: AuthorDirectiveLedger = AuthorDirectiveLedger(),
        entityPages: [String: EntityPage] = [:],
        activeFacts: [String: WorldFactEvent] = [:],
        factHistory: [WorldFactEvent] = [],
        epistemicBeliefs: [String: EpistemicBelief] = [:],
        threads: [String: ProspectiveThread] = [:],
        pyramid: NarrativePyramid = NarrativePyramid(),
        conflictWarnings: [StateConflictWarning] = []
    ) {
        self.atNodeID = atNodeID
        self.pathNodeIDs = pathNodeIDs
        self.directiveLedger = directiveLedger
        self.entityPages = entityPages
        self.activeFacts = activeFacts
        self.factHistory = factHistory
        self.epistemicBeliefs = epistemicBeliefs
        self.threads = threads
        self.pyramid = pyramid
        self.conflictWarnings = conflictWarnings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        atNodeID = (try? c.decode(String.self, forKey: .atNodeID)) ?? "root"
        pathNodeIDs = (try? c.decode([String].self, forKey: .pathNodeIDs)) ?? []
        directiveLedger = (try? c.decode(AuthorDirectiveLedger.self, forKey: .directiveLedger)) ?? AuthorDirectiveLedger()
        entityPages = (try? c.decode([String: EntityPage].self, forKey: .entityPages)) ?? [:]
        activeFacts = (try? c.decode([String: WorldFactEvent].self, forKey: .activeFacts)) ?? [:]
        factHistory = (try? c.decode([WorldFactEvent].self, forKey: .factHistory)) ?? []
        epistemicBeliefs = (try? c.decode([String: EpistemicBelief].self, forKey: .epistemicBeliefs)) ?? [:]
        threads = (try? c.decode([String: ProspectiveThread].self, forKey: .threads)) ?? [:]
        pyramid = (try? c.decode(NarrativePyramid.self, forKey: .pyramid)) ?? NarrativePyramid()
        conflictWarnings = (try? c.decode([StateConflictWarning].self, forKey: .conflictWarnings)) ?? []
    }

    func facts(for entityID: String) -> [WorldFactEvent] {
        activeFacts.values
            .filter { $0.entityID == entityID && !$0.isRetracted }
            .sorted { lhs, rhs in
                if lhs.attribute != rhs.attribute { return lhs.attribute < rhs.attribute }
                return lhs.id < rhs.id
            }
    }

    func beliefs(for characterID: String) -> [EpistemicBelief] {
        epistemicBeliefs.values
            .filter { $0.characterID == characterID }
            .sorted { lhs, rhs in
                if lhs.topic != rhs.topic { return lhs.topic < rhs.topic }
                return lhs.id < rhs.id
            }
    }

    /// 生成轻量顶层目录索引，供模型按需下沉查阅实体独立页，限制最大行数避免前缀膨胀。
    func bookIndexLines(maxLines: Int = 200) -> [String] {
        guard maxLines > 0 else { return [] }
        var lines: [String] = []

        let enabledEntities = entityPages.values
            .filter(\.enabled)
            .sorted { lhs, rhs in
                if lhs.kind.rawValue != rhs.kind.rawValue {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.id < rhs.id
            }

        for page in enabledEntities {
            guard lines.count < maxLines else { return lines }
            let aliasSuffix = page.aliases.isEmpty
                ? ""
                : "（别名：\(page.aliases.joined(separator: "、"))）"
            let brief = page.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if brief.isEmpty {
                lines.append("- [实体:\(page.kind.rawValue)/\(page.id)] \(page.name)\(aliasSuffix)")
            } else {
                lines.append("- [实体:\(page.kind.rawValue)/\(page.id)] \(page.name)\(aliasSuffix)：\(brief)")
            }
        }

        let activeThreads = threads.values
            .filter { !$0.state.isTerminal }
            .sorted { lhs, rhs in
                if lhs.state.rawValue != rhs.state.rawValue {
                    return lhs.state.rawValue < rhs.state.rawValue
                }
                return lhs.id < rhs.id
            }

        for thread in activeThreads {
            guard lines.count < maxLines else { return lines }
            lines.append("- [伏笔:\(thread.state.rawValue)/\(thread.id)] \(thread.goal)")
        }

        for volumeLine in pyramid.volumeOneLiners {
            guard lines.count < maxLines else { return lines }
            let clean = volumeLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            lines.append("- [卷纲] \(clean)")
        }

        return Array(lines.prefix(maxLines))
    }
}

/// 确定性状态归约器：统一仲裁权威等级覆写、分离客观事实与角色认知，并推进伏笔状态机。
enum NarrativeStateReducer {
    static func emptyState(rootNodeID: String) -> MaterializedNarrativeState {
        MaterializedNarrativeState(atNodeID: rootNodeID, pathNodeIDs: [])
    }

    static func apply(
        delta: PlotNodeDelta,
        nodeID: String,
        to state: inout MaterializedNarrativeState
    ) {
        applyDirectives(delta: delta, nodeID: nodeID, to: &state)
        var affectedEntityIDs = mergeEntityPages(delta.entityPageUpserts, into: &state)
        affectedEntityIDs.formUnion(replaceEntityPages(delta.entityPageReplacements, into: &state))
        applyFactEvents(
            delta.factEvents,
            nodeID: nodeID,
            affectedEntityIDs: &affectedEntityIDs,
            to: &state
        )
        recomputeCurrentFactIDs(for: affectedEntityIDs, in: &state)
        applyEpistemicBeliefs(delta.epistemicBeliefs, nodeID: nodeID, to: &state)
        applyThreadEvents(delta.threadEvents, to: &state)
        if let patch = delta.pyramidPatch {
            applyPyramidPatch(patch, to: &state.pyramid)
        }
        state.atNodeID = nodeID
        state.pathNodeIDs.append(nodeID)
    }

    private static func applyDirectives(
        delta: PlotNodeDelta,
        nodeID: String,
        to state: inout MaterializedNarrativeState
    ) {
        for directive in delta.directiveAdds {
            let trimmed = directive.verbatimRule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if directive.status == .active {
                state.directiveLedger.appendVerbatim(
                    trimmed,
                    scope: directive.scope,
                    sourceNodeID: directive.sourceNodeID ?? nodeID,
                    id: directive.id,
                    now: directive.createdAt
                )
            } else if !state.directiveLedger.directives.contains(where: { $0.id == directive.id }) {
                var clean = directive
                clean.verbatimRule = trimmed
                state.directiveLedger.directives.append(clean)
            }
        }

        for item in delta.directiveSupersedes {
            _ = state.directiveLedger.supersede(
                id: item.targetID,
                replacement: item.replacement
            )
        }
    }

    private static func mergeEntityPages(
        _ upserts: [EntityPage],
        into state: inout MaterializedNarrativeState
    ) -> Set<String> {
        var affected = Set<String>()
        for incoming in upserts where !incoming.id.isEmpty {
            affected.insert(incoming.id)
            guard var existing = state.entityPages[incoming.id] else {
                state.entityPages[incoming.id] = incoming
                continue
            }
            if !incoming.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.name = incoming.name
            }
            existing.kind = incoming.kind
            existing.aliases = deduplicatedStrings(existing.aliases + incoming.aliases)
            if !incoming.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.summary = incoming.summary
            }
            if !incoming.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.identity = incoming.identity
            }
            if !incoming.voiceProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.voiceProfile = incoming.voiceProfile
            }
            existing.hardBoundaries = deduplicatedStrings(
                existing.hardBoundaries + incoming.hardBoundaries
            )
            existing.conflictWarnings = deduplicatedStrings(
                existing.conflictWarnings + incoming.conflictWarnings
            )
            existing.enabled = incoming.enabled
            if incoming.updatedAt > existing.updatedAt {
                existing.updatedAt = incoming.updatedAt
            }
            state.entityPages[incoming.id] = existing
        }
        return affected
    }

    private static func replaceEntityPages(
        _ replacements: [EntityPage],
        into state: inout MaterializedNarrativeState
    ) -> Set<String> {
        var affected = Set<String>()
        for incoming in replacements where !incoming.id.isEmpty {
            var clean = incoming
            clean.aliases = deduplicatedStrings(incoming.aliases)
            clean.hardBoundaries = deduplicatedStrings(incoming.hardBoundaries)
            clean.conflictWarnings = deduplicatedStrings(incoming.conflictWarnings)
            state.entityPages[clean.id] = clean
            affected.insert(clean.id)
        }
        return affected
    }

    private static func applyFactEvents(
        _ events: [WorldFactEvent],
        nodeID: String,
        affectedEntityIDs: inout Set<String>,
        to state: inout MaterializedNarrativeState
    ) {
        for event in events where !event.entityID.isEmpty && !event.attribute.isEmpty {
            state.factHistory.append(event)
            affectedEntityIDs.insert(event.entityID)
            ensureEntityPageExists(id: event.entityID, kind: .character, in: &state)

            if let current = state.activeFacts[event.slotKey], event.authority < current.authority {
                if event.isRetracted || event.value != current.value {
                    let attempted = event.isRetracted ? "<撤回>" : event.value
                    let warning = StateConflictWarning(
                        entityID: event.entityID,
                        attribute: event.attribute,
                        existingEventID: current.id,
                        existingAuthority: current.authority,
                        existingValue: current.value,
                        rejectedEventID: event.id,
                        rejectedAuthority: event.authority,
                        rejectedValue: attempted,
                        nodeID: nodeID,
                        message: "「\(event.attribute)」保留高权威设定「\(current.value)」，已拦截低权威变更为「\(attempted)」"
                    )
                    recordWarning(warning, entityID: event.entityID, in: &state)
                }
                continue
            }

            let previousID = state.activeFacts[event.slotKey]?.id
            if event.isRetracted {
                state.activeFacts.removeValue(forKey: event.slotKey)
            } else {
                var accepted = event
                if accepted.supersedesEventID == nil {
                    accepted.supersedesEventID = previousID
                }
                state.activeFacts[event.slotKey] = accepted
            }
        }
    }

    private static func recomputeCurrentFactIDs(
        for entityIDs: Set<String>,
        in state: inout MaterializedNarrativeState
    ) {
        for entityID in entityIDs {
            guard var page = state.entityPages[entityID] else { continue }
            page.currentFactIDs = state.facts(for: entityID).map(\.id)
            state.entityPages[entityID] = page
        }
    }

    private static func applyEpistemicBeliefs(
        _ beliefs: [EpistemicBelief],
        nodeID: String,
        to state: inout MaterializedNarrativeState
    ) {
        for belief in beliefs where !belief.characterID.isEmpty && !belief.topic.isEmpty {
            ensureEntityPageExists(id: belief.characterID, kind: .character, in: &state)
            if let current = state.epistemicBeliefs[belief.slotKey],
               belief.authority < current.authority {
                if belief.believedTruth != current.believedTruth
                    || belief.knowsSecret != current.knowsSecret {
                    let warning = StateConflictWarning(
                        entityID: belief.characterID,
                        attribute: "belief:\(belief.topic)",
                        existingEventID: current.id,
                        existingAuthority: current.authority,
                        existingValue: current.believedTruth,
                        rejectedEventID: belief.id,
                        rejectedAuthority: belief.authority,
                        rejectedValue: belief.believedTruth,
                        nodeID: nodeID,
                        message: "角色认知「\(belief.topic)」保留高权威记录「\(current.believedTruth)」，已拦截低权威修改"
                    )
                    recordWarning(warning, entityID: belief.characterID, in: &state)
                }
                continue
            }
            state.epistemicBeliefs[belief.slotKey] = belief
        }
    }

    private static func applyThreadEvents(
        _ events: [ProspectiveThreadEvent],
        to state: inout MaterializedNarrativeState
    ) {
        for event in events where !event.threadID.isEmpty {
            switch event.kind {
            case .plant:
                guard var existing = state.threads[event.threadID] else {
                    let goalText = (event.goal?.isEmpty == false)
                        ? (event.goal ?? event.threadID)
                        : event.threadID
                    let created = ProspectiveThread(
                        id: event.threadID,
                        goal: goalText,
                        activationCue: event.activationCue ?? "",
                        recurrence: event.recurrence ?? .once,
                        relatedEntityIDs: deduplicatedStrings(event.relatedEntityIDs ?? []),
                        intendedHorizonNodeOffset: event.intendedHorizonNodeOffset,
                        evidenceAnchors: event.evidenceAnchor.map { [$0] } ?? [],
                        state: .pending,
                        authority: event.authority,
                        plantedAtNodeID: event.nodeID,
                        updatedAtNodeID: event.nodeID,
                        updatedAt: event.createdAt
                    )
                    state.threads[event.threadID] = created
                    continue
                }
                guard event.authority >= existing.authority else { continue }
                mergeThreadMetadata(from: event, into: &existing)
                state.threads[event.threadID] = existing

            case .promoteReady:
                guard var existing = state.threads[event.threadID] else { continue }
                if existing.state.isTerminal, event.authority < .authorDirective {
                    continue
                }
                // 一次性伏笔进入 enacted 后加锁，防止被低权威事件重复激活。
                if existing.state == .enacted,
                   existing.recurrence == .once,
                   event.authority < .authorDirective {
                    let warning = StateConflictWarning(
                        entityID: existing.relatedEntityIDs.first ?? existing.id,
                        attribute: "thread:\(existing.id)",
                        existingEventID: existing.id,
                        existingAuthority: existing.authority,
                        existingValue: existing.state.rawValue,
                        rejectedEventID: event.id,
                        rejectedAuthority: event.authority,
                        rejectedValue: ThreadLifecycle.ready.rawValue,
                        nodeID: event.nodeID,
                        message: "一次性伏笔「\(existing.goal)」已处于 enacted 锁定态，已阻止重复激活"
                    )
                    state.conflictWarnings.append(warning)
                    continue
                }
                guard event.authority >= existing.authority else { continue }
                existing.state = .ready
                mergeThreadMetadata(from: event, into: &existing)
                state.threads[event.threadID] = existing

            case .markEnacted:
                guard var existing = state.threads[event.threadID] else { continue }
                if existing.state.isTerminal, event.authority < .authorDirective {
                    continue
                }
                guard event.authority >= existing.authority else { continue }
                existing.state = .enacted
                mergeThreadMetadata(from: event, into: &existing)
                state.threads[event.threadID] = existing

            case .markSatisfied:
                guard var existing = state.threads[event.threadID] else { continue }
                guard event.authority >= existing.authority else { continue }
                existing.state = .satisfied
                mergeThreadMetadata(from: event, into: &existing)
                state.threads[event.threadID] = existing

            case .invalidate:
                guard var existing = state.threads[event.threadID] else { continue }
                guard event.authority >= existing.authority else { continue }
                existing.state = .invalidated
                mergeThreadMetadata(from: event, into: &existing)
                state.threads[event.threadID] = existing

            case .updateMetadata:
                guard var existing = state.threads[event.threadID] else { continue }
                guard event.authority >= existing.authority else { continue }
                mergeThreadMetadata(from: event, into: &existing)
                state.threads[event.threadID] = existing
            }
        }
    }

    private static func mergeThreadMetadata(
        from event: ProspectiveThreadEvent,
        into thread: inout ProspectiveThread
    ) {
        if let goal = event.goal, !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            thread.goal = goal
        }
        if let cue = event.activationCue, !cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            thread.activationCue = cue
        }
        if let recurrence = event.recurrence {
            thread.recurrence = recurrence
        }
        if let related = event.relatedEntityIDs {
            thread.relatedEntityIDs = deduplicatedStrings(thread.relatedEntityIDs + related)
        }
        if let horizon = event.intendedHorizonNodeOffset {
            thread.intendedHorizonNodeOffset = horizon
        }
        if let anchor = event.evidenceAnchor, !thread.evidenceAnchors.contains(anchor) {
            thread.evidenceAnchors.append(anchor)
        }
        if event.authority > thread.authority {
            thread.authority = event.authority
        }
        thread.updatedAtNodeID = event.nodeID
        thread.updatedAt = event.createdAt
    }

    private static func applyPyramidPatch(
        _ patch: NarrativePyramidPatch,
        to pyramid: inout NarrativePyramid
    ) {
        pyramid.volumeOneLiners = deduplicatedStrings(
            pyramid.volumeOneLiners + patch.addedVolumeOneLiners
        )
        pyramid.closedPlotlines = deduplicatedStrings(
            pyramid.closedPlotlines + patch.addedClosedPlotlines
        )
        pyramid.recentSceneCards = deduplicatedStrings(
            pyramid.recentSceneCards + patch.addedRecentSceneCards
        )
        if let version = patch.anchorIndexVersion, version > pyramid.anchorIndexVersion {
            pyramid.anchorIndexVersion = version
        }
    }

    private static func ensureEntityPageExists(
        id: String,
        kind: EntityKind,
        in state: inout MaterializedNarrativeState
    ) {
        guard state.entityPages[id] == nil else { return }
        state.entityPages[id] = EntityPage(id: id, kind: kind, name: id)
    }

    private static func recordWarning(
        _ warning: StateConflictWarning,
        entityID: String,
        in state: inout MaterializedNarrativeState
    ) {
        state.conflictWarnings.append(warning)
        if var page = state.entityPages[entityID],
           !page.conflictWarnings.contains(warning.message) {
            page.conflictWarnings.append(warning.message)
            state.entityPages[entityID] = page
        }
    }

    private static func deduplicatedStrings(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }
}
