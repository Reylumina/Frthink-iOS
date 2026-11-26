import Foundation

/// 工作区六大持久化子域的单调修订号，支持 `O(1)` 变更检测与精准脏文件落盘。
struct NarrativeSectionRevisions: Hashable {
    var lineageID: UUID = UUID()
    var storyGraph: UInt64 = 0
    var directives: UInt64 = 0
    var entities: UInt64 = 0
    var ledgers: UInt64 = 0
    var pyramid: UInt64 = 0
    var manifest: UInt64 = 0
}

/// 单个书项目的叙事状态工作区：
/// 统一维护「可直接 O(1) 读写的现状三账本（写作规则、实体独立页、客观事实/私有认知、五态伏笔、文风与折叠状态）」
/// 与「仅记录剧情节拍及因果分叉汇合关系的纯情节因果图（StoryGraph）」。
struct NarrativeWorkspace: Codable, Hashable {
    static let currentSchemaVersion = 1

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case storyGraph
        case directives
        case entityPages
        case activeFacts
        case epistemicBeliefs
        case threads
        case episodicEvents
        case conflictWarnings
        case pyramid
        case anchorIndex
        case reFoldBoundary
        case preservedStyle
        case latestStyleLint
        case migratedFromLegacyAt
        case hasLiveLedgers
        case pendingSyncNodeIDs
        case syncedManuscriptUTF16Offset
        case activePOVCharacterID
    }

    var schemaVersion: Int {
        didSet { sectionRevisions.manifest &+= 1 }
    }
    var storyGraph: StoryGraph {
        didSet { sectionRevisions.storyGraph &+= 1 }
    }
    var directives: AuthorDirectiveLedger {
        didSet { sectionRevisions.directives &+= 1 }
    }
    var entityPages: [String: EntityPage] {
        didSet { sectionRevisions.entities &+= 1 }
    }
    var activeFacts: [String: WorldFactEvent] {
        didSet { sectionRevisions.ledgers &+= 1 }
    }
    var epistemicBeliefs: [String: EpistemicBelief] {
        didSet { sectionRevisions.ledgers &+= 1 }
    }
    var threads: [String: ProspectiveThread] {
        didSet { sectionRevisions.ledgers &+= 1 }
    }
    var episodicEvents: [String: EpisodicEvent] {
        didSet { sectionRevisions.ledgers &+= 1 }
    }
    var conflictWarnings: [StateConflictWarning] {
        didSet { sectionRevisions.ledgers &+= 1 }
    }
    var pyramid: NarrativePyramid {
        didSet { sectionRevisions.pyramid &+= 1 }
    }
    var anchorIndex: AnchorIndex {
        didSet { sectionRevisions.pyramid &+= 1 }
    }
    var reFoldBoundary: ReFoldBoundary {
        didSet { sectionRevisions.manifest &+= 1 }
    }
    var preservedStyle: PreservedStyleDistillation {
        didSet { sectionRevisions.manifest &+= 1 }
    }
    var latestStyleLint: StyleLintReport? {
        didSet { sectionRevisions.manifest &+= 1 }
    }
    var migratedFromLegacyAt: Date? {
        didSet { sectionRevisions.manifest &+= 1 }
    }
    var hasLiveLedgers: Bool {
        didSet { sectionRevisions.ledgers &+= 1 }
    }
    var pendingSyncNodeIDs: [String] {
        didSet { sectionRevisions.manifest &+= 1 }
    }
    var syncedManuscriptUTF16Offset: Int {
        didSet { sectionRevisions.manifest &+= 1 }
    }
    var activePOVCharacterID: String? {
        didSet { sectionRevisions.manifest &+= 1 }
    }

    private(set) var sectionRevisions = NarrativeSectionRevisions()

    init(
        schemaVersion: Int = NarrativeWorkspace.currentSchemaVersion,
        storyGraph: StoryGraph = StoryGraph.makeInitial(),
        directives: AuthorDirectiveLedger = AuthorDirectiveLedger(),
        entityPages: [String: EntityPage] = [:],
        activeFacts: [String: WorldFactEvent] = [:],
        epistemicBeliefs: [String: EpistemicBelief] = [:],
        threads: [String: ProspectiveThread] = [:],
        episodicEvents: [String: EpisodicEvent] = [:],
        conflictWarnings: [StateConflictWarning] = [],
        pyramid: NarrativePyramid = NarrativePyramid(),
        anchorIndex: AnchorIndex = AnchorIndex(),
        reFoldBoundary: ReFoldBoundary = ReFoldBoundary(),
        preservedStyle: PreservedStyleDistillation = PreservedStyleDistillation(),
        latestStyleLint: StyleLintReport? = nil,
        migratedFromLegacyAt: Date? = nil,
        hasLiveLedgers: Bool = false,
        pendingSyncNodeIDs: [String] = [],
        syncedManuscriptUTF16Offset: Int = 0,
        activePOVCharacterID: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.storyGraph = storyGraph
        self.directives = directives
        self.entityPages = entityPages
        self.activeFacts = activeFacts
        self.epistemicBeliefs = epistemicBeliefs
        self.threads = threads
        self.episodicEvents = episodicEvents
        self.conflictWarnings = conflictWarnings
        self.pyramid = pyramid
        self.anchorIndex = anchorIndex
        self.reFoldBoundary = reFoldBoundary
        self.preservedStyle = preservedStyle
        self.latestStyleLint = latestStyleLint
        self.migratedFromLegacyAt = migratedFromLegacyAt
        self.hasLiveLedgers = hasLiveLedgers
        self.pendingSyncNodeIDs = pendingSyncNodeIDs
        self.syncedManuscriptUTF16Offset = syncedManuscriptUTF16Offset
        self.activePOVCharacterID = activePOVCharacterID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion =
            (try? c.decode(Int.self, forKey: .schemaVersion))
                ?? NarrativeWorkspace.currentSchemaVersion
        storyGraph = (try? c.decode(StoryGraph.self, forKey: .storyGraph)) ?? StoryGraph.makeInitial()
        directives = (try? c.decode(AuthorDirectiveLedger.self, forKey: .directives)) ?? AuthorDirectiveLedger()
        entityPages = (try? c.decode([String: EntityPage].self, forKey: .entityPages)) ?? [:]
        activeFacts = (try? c.decode([String: WorldFactEvent].self, forKey: .activeFacts)) ?? [:]
        epistemicBeliefs = (try? c.decode([String: EpistemicBelief].self, forKey: .epistemicBeliefs)) ?? [:]
        threads = (try? c.decode([String: ProspectiveThread].self, forKey: .threads)) ?? [:]
        episodicEvents = (try? c.decode([String: EpisodicEvent].self, forKey: .episodicEvents)) ?? [:]
        conflictWarnings = (try? c.decode([StateConflictWarning].self, forKey: .conflictWarnings)) ?? []
        pyramid = (try? c.decode(NarrativePyramid.self, forKey: .pyramid)) ?? NarrativePyramid()
        anchorIndex = (try? c.decode(AnchorIndex.self, forKey: .anchorIndex)) ?? AnchorIndex()
        reFoldBoundary = (try? c.decode(ReFoldBoundary.self, forKey: .reFoldBoundary)) ?? ReFoldBoundary()
        preservedStyle =
            (try? c.decode(PreservedStyleDistillation.self, forKey: .preservedStyle))
                ?? PreservedStyleDistillation()
        latestStyleLint = try? c.decodeIfPresent(StyleLintReport.self, forKey: .latestStyleLint)
        migratedFromLegacyAt = try? c.decodeIfPresent(Date.self, forKey: .migratedFromLegacyAt)
        hasLiveLedgers = (try? c.decode(Bool.self, forKey: .hasLiveLedgers)) ?? false
        pendingSyncNodeIDs = (try? c.decode([String].self, forKey: .pendingSyncNodeIDs)) ?? []
        syncedManuscriptUTF16Offset =
            (try? c.decode(Int.self, forKey: .syncedManuscriptUTF16Offset)) ?? 0
        activePOVCharacterID = try? c.decodeIfPresent(String.self, forKey: .activePOVCharacterID)
    }

    static func == (lhs: NarrativeWorkspace, rhs: NarrativeWorkspace) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.storyGraph == rhs.storyGraph
            && lhs.directives == rhs.directives
            && lhs.entityPages == rhs.entityPages
            && lhs.activeFacts == rhs.activeFacts
            && lhs.epistemicBeliefs == rhs.epistemicBeliefs
            && lhs.threads == rhs.threads
            && lhs.episodicEvents == rhs.episodicEvents
            && lhs.conflictWarnings == rhs.conflictWarnings
            && lhs.pyramid == rhs.pyramid
            && lhs.anchorIndex == rhs.anchorIndex
            && lhs.reFoldBoundary == rhs.reFoldBoundary
            && lhs.preservedStyle == rhs.preservedStyle
            && lhs.latestStyleLint == rhs.latestStyleLint
            && lhs.migratedFromLegacyAt == rhs.migratedFromLegacyAt
            && lhs.hasLiveLedgers == rhs.hasLiveLedgers
            && lhs.pendingSyncNodeIDs == rhs.pendingSyncNodeIDs
            && lhs.syncedManuscriptUTF16Offset == rhs.syncedManuscriptUTF16Offset
            && lhs.activePOVCharacterID == rhs.activePOVCharacterID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(schemaVersion)
        hasher.combine(storyGraph)
        hasher.combine(directives)
        hasher.combine(entityPages)
        hasher.combine(activeFacts)
        hasher.combine(epistemicBeliefs)
        hasher.combine(threads)
        hasher.combine(episodicEvents)
        hasher.combine(conflictWarnings)
        hasher.combine(pyramid)
        hasher.combine(anchorIndex)
        hasher.combine(reFoldBoundary)
        hasher.combine(preservedStyle)
        hasher.combine(latestStyleLint)
        hasher.combine(migratedFromLegacyAt)
        hasher.combine(hasLiveLedgers)
        hasher.combine(pendingSyncNodeIDs)
        hasher.combine(syncedManuscriptUTF16Offset)
        hasher.combine(activePOVCharacterID)
    }

    /// 同一派生链内基于递增修订号的 `O(1)` 判等；跨独立实例回退为值语义比较。
    func hasSameRevision(as other: NarrativeWorkspace?) -> Bool {
        guard let other else { return false }
        if sectionRevisions.lineageID == other.sectionRevisions.lineageID {
            return sectionRevisions == other.sectionRevisions
                && storyGraph.lineageID == other.storyGraph.lineageID
                && storyGraph.topologyRevision == other.storyGraph.topologyRevision
                && storyGraph.checkpointsRevision == other.storyGraph.checkpointsRevision
        }
        return self == other
    }

    /// O(1) 读取当前活跃三账本快照；尚未初始化实时账本且图中存在增量时回退重放。
    func currentState() -> MaterializedNarrativeState {
        if hasLiveLedgers {
            return MaterializedNarrativeState(
                atNodeID: storyGraph.headNodeID,
                pathNodeIDs: [storyGraph.headNodeID],
                directiveLedger: directives,
                entityPages: entityPages,
                activeFacts: activeFacts,
                factHistory: [],
                epistemicBeliefs: epistemicBeliefs,
                threads: threads,
                episodicEvents: episodicEvents,
                pyramid: pyramid,
                conflictWarnings: conflictWarnings
            )
        }
        if let replayed = try? storyGraph.replay(to: storyGraph.headNodeID) {
            return replayed
        }
        return MaterializedNarrativeState(
            atNodeID: storyGraph.headNodeID,
            pathNodeIDs: [storyGraph.headNodeID],
            directiveLedger: directives,
            entityPages: entityPages,
            activeFacts: activeFacts,
            factHistory: [],
            epistemicBeliefs: epistemicBeliefs,
            threads: threads,
            episodicEvents: episodicEvents,
            pyramid: pyramid,
            conflictWarnings: conflictWarnings
        )
    }

    func materializedState(at nodeID: String? = nil) throws -> MaterializedNarrativeState {
        if nodeID == nil || nodeID == storyGraph.headNodeID, hasLiveLedgers {
            return currentState()
        }
        return try storyGraph.replay(to: nodeID ?? storyGraph.headNodeID)
    }

    /// 直接对现状三账本执行确定性单步归约，不向情节因果图写入设定管理节点。
    @discardableResult
    mutating func applyLedgerDelta(
        _ delta: PlotNodeDelta,
        sourceNodeID: String = "direct"
    ) -> MaterializedNarrativeState {
        var state = currentState()
        NarrativeStateReducer.apply(delta: delta, nodeID: sourceNodeID, to: &state)
        applyMaterializedState(state)
        return state
    }

    /// 还原此前保存的三账本现状快照（用于撤销正文采纳时无损恢复状态）。
    mutating func restoreLedgerSnapshot(from state: MaterializedNarrativeState) {
        applyMaterializedState(state)
    }

    /// 删除指定设定实体，并级联清理绑定到该实体的客观事实与私有认知。
    @discardableResult
    mutating func deleteEntityPage(id: String) -> Bool {
        guard entityPages.removeValue(forKey: id) != nil else { return false }
        activeFacts = activeFacts.filter { $0.value.entityID != id }
        epistemicBeliefs = epistemicBeliefs.filter { $0.value.characterID != id }
        for key in Array(episodicEvents.keys) {
            episodicEvents[key]?.participantEntityIDs.removeAll { $0 == id }
        }
        if activePOVCharacterID == id {
            activePOVCharacterID = nil
        }
        hasLiveLedgers = true
        return true
    }

    /// 沿指定节点重放情节图谱，并将结果同步至工作区现状账本。
    @discardableResult
    mutating func synchronizeMaterializedHead() throws -> MaterializedNarrativeState {
        let state = try storyGraph.replay(to: storyGraph.headNodeID)
        applyMaterializedState(state)
        return state
    }

    /// 在剧情图谱剪枝或回滚后，按当前头节点重放并重对齐支线账本，并保留全书实体档案与全局规则。
    mutating func realignBranchLedgersToHead() {
        let live = currentState()
        storyGraph.pruneCheckpoints()
        guard let replayed = try? storyGraph.replay(to: storyGraph.headNodeID) else { return }
        _ = applyBranchScopedState(replayed, preservingGlobalFrom: live)
    }

    /// 安全切换分支节点：保存旧头节点实时快照供回切恢复，按目标节点重放隔离支线三账本，并保留全书设定真源。
    @discardableResult
    mutating func checkoutBranch(
        to targetNodeID: String,
        now: Date = Date()
    ) throws -> MaterializedNarrativeState {
        let oldHeadID = storyGraph.headNodeID
        if targetNodeID == oldHeadID {
            return currentState()
        }
        guard storyGraph.nodes[targetNodeID] != nil else {
            throw StoryGraphError.nodeNotFound(targetNodeID)
        }

        let liveBeforeCheckout = currentState()
        if storyGraph.nodes[oldHeadID] != nil {
            var oldSnapshot = liveBeforeCheckout
            oldSnapshot.atNodeID = oldHeadID
            oldSnapshot.pathNodeIDs = (try? storyGraph.lineage(to: oldHeadID).map(\.id)) ?? [oldHeadID]
            storyGraph.checkpoints[oldHeadID] = ReplayCheckpoint(
                nodeID: oldHeadID,
                state: oldSnapshot,
                createdAt: now
            )
            storyGraph.pruneCheckpoints()
        }

        try storyGraph.checkout(nodeID: targetNodeID)
        let branchState = try storyGraph.replay(to: targetNodeID)
        return applyBranchScopedState(branchState, preservingGlobalFrom: liveBeforeCheckout)
    }

    /// 合并支线重放状态与全书唯一真源：
    /// `entityPages` 与 `.global` 指令作为全书真源跨分支持久生效，
    /// 其余支线账本与非全局指令严格随当前分支节点重放隔离，并过滤已全局删除实体的残留状态。
    @discardableResult
    private mutating func applyBranchScopedState(
        _ branchState: MaterializedNarrativeState,
        preservingGlobalFrom live: MaterializedNarrativeState
    ) -> MaterializedNarrativeState {
        var merged = branchState
        merged.entityPages = live.entityPages

        let nonGlobalDirectives = branchState.directiveLedger.directives.filter { $0.scope != .global }
        var seenGlobalIDs: Set<String> = []
        let globalDirectives = live.directiveLedger.directives.filter { directive in
            guard directive.scope == .global else { return false }
            return seenGlobalIDs.insert(directive.id).inserted
        }
        merged.directiveLedger = AuthorDirectiveLedger(directives: globalDirectives + nonGlobalDirectives)

        merged.activeFacts = branchState.activeFacts.filter { _, fact in
            live.entityPages[fact.entityID] != nil || branchState.entityPages[fact.entityID] == nil
        }
        merged.epistemicBeliefs = branchState.epistemicBeliefs.filter { _, belief in
            live.entityPages[belief.characterID] != nil || branchState.entityPages[belief.characterID] == nil
        }
        for key in Array(merged.episodicEvents.keys) {
            merged.episodicEvents[key]?.participantEntityIDs.removeAll { entityID in
                live.entityPages[entityID] == nil && branchState.entityPages[entityID] != nil
            }
        }
        for entityID in Array(merged.entityPages.keys) {
            let factIDs = merged.facts(for: entityID).map(\.id)
            merged.entityPages[entityID]?.currentFactIDs = factIDs
        }

        applyMaterializedState(merged)
        return merged
    }

    private mutating func applyMaterializedState(_ state: MaterializedNarrativeState) {
        directives = state.directiveLedger
        entityPages = state.entityPages
        activeFacts = state.activeFacts
        epistemicBeliefs = state.epistemicBeliefs
        threads = state.threads
        episodicEvents = state.episodicEvents
        conflictWarnings = state.conflictWarnings
        pyramid = state.pyramid
        hasLiveLedgers = true
    }
}
