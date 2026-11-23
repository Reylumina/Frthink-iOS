import Foundation

/// 单个书项目的叙事状态工作区：
/// 统一维护「可直接 O(1) 读写的现状三账本（写作规则、实体独立页、客观事实/私有认知、五态伏笔、文风与折叠状态）」
/// 与「仅记录剧情节拍及因果分叉汇合关系的纯情节因果图（StoryGraph）」。
struct NarrativeWorkspace: Codable, Hashable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var storyGraph: StoryGraph
    var directives: AuthorDirectiveLedger
    var entityPages: [String: EntityPage]
    var activeFacts: [String: WorldFactEvent]
    var epistemicBeliefs: [String: EpistemicBelief]
    var threads: [String: ProspectiveThread]
    var conflictWarnings: [StateConflictWarning]
    var pyramid: NarrativePyramid
    var anchorIndex: AnchorIndex
    var reFoldBoundary: ReFoldBoundary
    var preservedStyle: PreservedStyleDistillation
    var latestStyleLint: StyleLintReport?
    var migratedFromLegacyAt: Date?
    var hasLiveLedgers: Bool

    init(
        schemaVersion: Int = NarrativeWorkspace.currentSchemaVersion,
        storyGraph: StoryGraph = StoryGraph.makeInitial(),
        directives: AuthorDirectiveLedger = AuthorDirectiveLedger(),
        entityPages: [String: EntityPage] = [:],
        activeFacts: [String: WorldFactEvent] = [:],
        epistemicBeliefs: [String: EpistemicBelief] = [:],
        threads: [String: ProspectiveThread] = [:],
        conflictWarnings: [StateConflictWarning] = [],
        pyramid: NarrativePyramid = NarrativePyramid(),
        anchorIndex: AnchorIndex = AnchorIndex(),
        reFoldBoundary: ReFoldBoundary = ReFoldBoundary(),
        preservedStyle: PreservedStyleDistillation = PreservedStyleDistillation(),
        latestStyleLint: StyleLintReport? = nil,
        migratedFromLegacyAt: Date? = nil,
        hasLiveLedgers: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.storyGraph = storyGraph
        self.directives = directives
        self.entityPages = entityPages
        self.activeFacts = activeFacts
        self.epistemicBeliefs = epistemicBeliefs
        self.threads = threads
        self.conflictWarnings = conflictWarnings
        self.pyramid = pyramid
        self.anchorIndex = anchorIndex
        self.reFoldBoundary = reFoldBoundary
        self.preservedStyle = preservedStyle
        self.latestStyleLint = latestStyleLint
        self.migratedFromLegacyAt = migratedFromLegacyAt
        self.hasLiveLedgers = hasLiveLedgers
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

    /// 沿指定节点重放情节图谱，并将结果同步至工作区现状账本。
    @discardableResult
    mutating func synchronizeMaterializedHead() throws -> MaterializedNarrativeState {
        let state = try storyGraph.replay(to: storyGraph.headNodeID)
        applyMaterializedState(state)
        return state
    }

    private mutating func applyMaterializedState(_ state: MaterializedNarrativeState) {
        directives = state.directiveLedger
        entityPages = state.entityPages
        activeFacts = state.activeFacts
        epistemicBeliefs = state.epistemicBeliefs
        threads = state.threads
        conflictWarnings = state.conflictWarnings
        pyramid = state.pyramid
        hasLiveLedgers = true
    }
}
