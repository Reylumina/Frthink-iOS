import Foundation

/// 叙事工作区分文件 AES-256-GCM 加密持久化存储，将剧情图、规则账本与各实体独立页拆开落盘，
/// 避免单次更新重写整本元数据或造成兄弟实体互相覆盖。
///
/// 磁盘布局：
/// ```
/// projects/<projectID>/narrative/
///   manifest.json                  — 清单提交点、折叠边界、蒸馏资产、实体及检查点索引
///   story_graph.json               — 剥离检查点后的纯情节因果图谱基线
///   story_graph.wal                — 加密追加帧日志（FRWL + AES-256-GCM），达阈值自动压实回基线
///   directives.json                — 作者逐字规则账本
///   ledgers.json                   — 现状客观事实、私有认知、五态伏笔与冲突告警
///   pyramid.json                   — 分层时间摘要与机械索引
///   entities/<slug>_<sha>.json     — 单实体档案独立密文文件
///   checkpoints/<slug>_<sha>.json  — 按节点独立加密落盘的重放检查点缓存
/// ```
private enum NarrativeProjectLock {
    private static let registryLock = NSLock()
    private static var locks: [String: NSRecursiveLock] = [:]
    private static let tokenLock = NSLock()
    private static var writeTokens: [String: UInt64] = [:]

    private static func lock(for projectID: String) -> NSRecursiveLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[projectID] { return existing }
        let created = NSRecursiveLock()
        locks[projectID] = created
        return created
    }

    static func withLock<T>(for projectID: String, _ body: () throws -> T) rethrows -> T {
        let projectLock = lock(for: projectID)
        projectLock.lock()
        defer { projectLock.unlock() }
        return try body()
    }

    static func currentWriteToken(for projectID: String) -> UInt64 {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        return writeTokens[projectID, default: 0]
    }

    @discardableResult
    static func advanceWriteToken(for projectID: String) -> UInt64 {
        tokenLock.lock()
        defer { tokenLock.unlock() }
        let next = writeTokens[projectID, default: 0] &+ 1
        writeTokens[projectID] = next
        return next
    }
}

struct NarrativeStore {
    let fileStore: FileStore

    static func currentWriteToken(for projectID: String) -> UInt64 {
        NarrativeProjectLock.currentWriteToken(for: projectID)
    }

    @discardableResult
    static func advanceWriteToken(for projectID: String) -> UInt64 {
        NarrativeProjectLock.advanceWriteToken(for: projectID)
    }

    enum LoadState {
        case missing
        case corrupted
        case loaded(NarrativeWorkspace)
    }

    private struct Manifest: Codable {
        var schemaVersion: Int
        var reFoldBoundary: ReFoldBoundary
        var preservedStyle: PreservedStyleDistillation
        var latestStyleLint: StyleLintReport?
        var migratedFromLegacyAt: Date?
        var entityIDs: [String]
        var checkpointNodeIDs: [String]
        var pendingSyncNodeIDs: [String]
        var syncedManuscriptUTF16Offset: Int
        var activePOVCharacterID: String?

        init(
            schemaVersion: Int,
            reFoldBoundary: ReFoldBoundary,
            preservedStyle: PreservedStyleDistillation,
            latestStyleLint: StyleLintReport?,
            migratedFromLegacyAt: Date?,
            entityIDs: [String],
            checkpointNodeIDs: [String] = [],
            pendingSyncNodeIDs: [String] = [],
            syncedManuscriptUTF16Offset: Int = 0,
            activePOVCharacterID: String? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.reFoldBoundary = reFoldBoundary
            self.preservedStyle = preservedStyle
            self.latestStyleLint = latestStyleLint
            self.migratedFromLegacyAt = migratedFromLegacyAt
            self.entityIDs = entityIDs
            self.checkpointNodeIDs = checkpointNodeIDs
            self.pendingSyncNodeIDs = pendingSyncNodeIDs
            self.syncedManuscriptUTF16Offset = syncedManuscriptUTF16Offset
            self.activePOVCharacterID = activePOVCharacterID
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? NarrativeWorkspace.currentSchemaVersion
            reFoldBoundary = (try? c.decode(ReFoldBoundary.self, forKey: .reFoldBoundary)) ?? ReFoldBoundary()
            preservedStyle =
                (try? c.decode(PreservedStyleDistillation.self, forKey: .preservedStyle))
                    ?? PreservedStyleDistillation()
            latestStyleLint = try? c.decodeIfPresent(StyleLintReport.self, forKey: .latestStyleLint)
            migratedFromLegacyAt = try? c.decodeIfPresent(Date.self, forKey: .migratedFromLegacyAt)
            entityIDs = (try? c.decode([String].self, forKey: .entityIDs)) ?? []
            checkpointNodeIDs = (try? c.decode([String].self, forKey: .checkpointNodeIDs)) ?? []
            pendingSyncNodeIDs = (try? c.decode([String].self, forKey: .pendingSyncNodeIDs)) ?? []
            syncedManuscriptUTF16Offset = (try? c.decode(Int.self, forKey: .syncedManuscriptUTF16Offset)) ?? 0
            activePOVCharacterID = try? c.decodeIfPresent(String.self, forKey: .activePOVCharacterID)
        }
    }

    private struct PyramidBundle: Codable {
        var pyramid: NarrativePyramid
        var anchorIndex: AnchorIndex
    }

    private struct LedgerBundle: Codable {
        var activeFacts: [String: WorldFactEvent]
        var epistemicBeliefs: [String: EpistemicBelief]
        var threads: [String: ProspectiveThread]
        var episodicEvents: [String: EpisodicEvent]
        var conflictWarnings: [StateConflictWarning]

        init(
            activeFacts: [String: WorldFactEvent] = [:],
            epistemicBeliefs: [String: EpistemicBelief] = [:],
            threads: [String: ProspectiveThread] = [:],
            episodicEvents: [String: EpisodicEvent] = [:],
            conflictWarnings: [StateConflictWarning] = []
        ) {
            self.activeFacts = activeFacts
            self.epistemicBeliefs = epistemicBeliefs
            self.threads = threads
            self.episodicEvents = episodicEvents
            self.conflictWarnings = conflictWarnings
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            activeFacts = (try? c.decode([String: WorldFactEvent].self, forKey: .activeFacts)) ?? [:]
            epistemicBeliefs = (try? c.decode([String: EpistemicBelief].self, forKey: .epistemicBeliefs)) ?? [:]
            threads = (try? c.decode([String: ProspectiveThread].self, forKey: .threads)) ?? [:]
            episodicEvents = (try? c.decode([String: EpisodicEvent].self, forKey: .episodicEvents)) ?? [:]
            conflictWarnings = (try? c.decode([StateConflictWarning].self, forKey: .conflictWarnings)) ?? []
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }

    private static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    init(fileStore: FileStore) {
        self.fileStore = fileStore
    }

    func narrativeDirectory(_ projectID: String) -> URL {
        fileStore
            .projectDirectory(projectID)
            .appendingPathComponent("narrative", isDirectory: true)
    }

    private func manifestURL(_ projectID: String) -> URL {
        narrativeDirectory(projectID).appendingPathComponent("manifest.json")
    }

    private func storyGraphURL(_ projectID: String) -> URL {
        narrativeDirectory(projectID).appendingPathComponent("story_graph.json")
    }

    func storyGraphWALURL(_ projectID: String) -> URL {
        narrativeDirectory(projectID).appendingPathComponent("story_graph.wal")
    }

    private func directivesURL(_ projectID: String) -> URL {
        narrativeDirectory(projectID).appendingPathComponent("directives.json")
    }

    private func ledgersURL(_ projectID: String) -> URL {
        narrativeDirectory(projectID).appendingPathComponent("ledgers.json")
    }

    private func pyramidURL(_ projectID: String) -> URL {
        narrativeDirectory(projectID).appendingPathComponent("pyramid.json")
    }

    private func entitiesDirectory(_ projectID: String) -> URL {
        narrativeDirectory(projectID).appendingPathComponent("entities", isDirectory: true)
    }

    func entityFileURL(entityID: String, projectID: String) -> URL {
        entitiesDirectory(projectID)
            .appendingPathComponent(Self.safeEntityFileName(for: entityID))
    }

    func checkpointsDirectory(_ projectID: String) -> URL {
        narrativeDirectory(projectID).appendingPathComponent("checkpoints", isDirectory: true)
    }

    func checkpointFileURL(nodeID: String, projectID: String) -> URL {
        checkpointsDirectory(projectID)
            .appendingPathComponent(Self.safeCheckpointFileName(for: nodeID))
    }

    /// 构造大小写不敏感文件系统及路径安全的实体独立文件名。
    static func safeEntityFileName(for entityID: String) -> String {
        safeIDFileName(for: entityID, fallbackPrefix: "entity")
    }

    /// 构造大小写不敏感文件系统及路径安全的检查点独立文件名。
    static func safeCheckpointFileName(for nodeID: String) -> String {
        safeIDFileName(for: nodeID, fallbackPrefix: "checkpoint")
    }

    private static func safeIDFileName(for rawID: String, fallbackPrefix: String) -> String {
        let asciiChars = rawID.unicodeScalars.prefix(24).map { scalar -> Character in
            let v = scalar.value
            let isAlnum = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            if isAlnum || v == 95 || v == 45 {
                return Character(scalar)
            }
            return "_"
        }
        let slug = String(asciiChars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let digest = String(SummaryKey.sha256Hex(rawID).prefix(16))
        return slug.isEmpty ? "\(fallbackPrefix)_\(digest).json" : "\(slug)_\(digest).json"
    }

    func hasWorkspace(projectID: String) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(projectID).path)
    }

    /// 清除指定书目的叙事工作区磁盘目录并递增写令牌，防止旧后台写入回流。
    func resetWorkspace(projectID: String) throws {
        try NarrativeProjectLock.withLock(for: projectID) {
            NarrativeProjectLock.advanceWriteToken(for: projectID)
            let dir = narrativeDirectory(projectID)
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
        }
    }

    /// 加载工作区状态：读取基线图谱并重放增量 WAL、加载独立检查点缓存；核心结构损坏返回 `.corrupted`。
    func loadWorkspaceState(projectID: String) -> LoadState {
        NarrativeProjectLock.withLock(for: projectID) {
            let mURL = manifestURL(projectID)
            let decoder = Self.makeDecoder()
            switch fileStore.readEncryptedResult(mURL) {
            case .missing:
                return .missing
            case .unreadable:
                return .corrupted
            case .loaded(let manifestData):
                guard let manifest = try? decoder.decode(Manifest.self, from: manifestData) else {
                    return .corrupted
                }
                guard var storyGraph: StoryGraph = readDecoded(storyGraphURL(projectID), decoder: decoder),
                      let directives: AuthorDirectiveLedger = readDecoded(directivesURL(projectID), decoder: decoder),
                      let bundle: PyramidBundle = readDecoded(pyramidURL(projectID), decoder: decoder)
                else {
                    return .corrupted
                }

                do {
                    _ = try StoryGraphWAL.replay(from: storyGraphWALURL(projectID), into: &storyGraph)
                } catch {
                    return .corrupted
                }

                for nodeID in manifest.checkpointNodeIDs {
                    if let cp: ReplayCheckpoint = readDecoded(
                        checkpointFileURL(nodeID: nodeID, projectID: projectID),
                        decoder: decoder
                    ) {
                        storyGraph.checkpoints[nodeID] = cp
                    }
                }

                var pages: [String: EntityPage] = [:]
                for entityID in manifest.entityIDs {
                    guard let page: EntityPage = readDecoded(
                        entityFileURL(entityID: entityID, projectID: projectID),
                        decoder: decoder
                    ),
                          page.id == entityID
                    else {
                        return .corrupted
                    }
                    pages[entityID] = page
                }

                var workspace = NarrativeWorkspace(
                    schemaVersion: manifest.schemaVersion,
                    storyGraph: storyGraph,
                    directives: directives,
                    entityPages: pages,
                    pyramid: bundle.pyramid,
                    anchorIndex: bundle.anchorIndex,
                    reFoldBoundary: manifest.reFoldBoundary,
                    preservedStyle: manifest.preservedStyle,
                    latestStyleLint: manifest.latestStyleLint,
                    migratedFromLegacyAt: manifest.migratedFromLegacyAt,
                    pendingSyncNodeIDs: manifest.pendingSyncNodeIDs,
                    syncedManuscriptUTF16Offset: manifest.syncedManuscriptUTF16Offset,
                    activePOVCharacterID: manifest.activePOVCharacterID
                )

                switch fileStore.readEncryptedResult(ledgersURL(projectID)) {
                case .missing:
                    if let replayed = try? workspace.storyGraph.replay(to: workspace.storyGraph.headNodeID) {
                        workspace.activeFacts = replayed.activeFacts.filter { _, fact in
                            workspace.entityPages[fact.entityID] != nil || replayed.entityPages[fact.entityID] == nil
                        }
                        workspace.epistemicBeliefs = replayed.epistemicBeliefs.filter { _, belief in
                            workspace.entityPages[belief.characterID] != nil || replayed.entityPages[belief.characterID] == nil
                        }
                        workspace.threads = replayed.threads
                        workspace.episodicEvents = replayed.episodicEvents
                        workspace.conflictWarnings = replayed.conflictWarnings
                        workspace.hasLiveLedgers = true
                    }
                case .unreadable:
                    return .corrupted
                case .loaded(let ledgerData):
                    guard let ledgers = try? decoder.decode(LedgerBundle.self, from: ledgerData) else {
                        return .corrupted
                    }
                    workspace.activeFacts = ledgers.activeFacts
                    workspace.epistemicBeliefs = ledgers.epistemicBeliefs
                    workspace.threads = ledgers.threads
                    workspace.episodicEvents = ledgers.episodicEvents
                    workspace.conflictWarnings = ledgers.conflictWarnings
                    workspace.hasLiveLedgers = true
                }
                return .loaded(workspace)
            }
        }
    }

    /// 按先写子文件、最后写 `manifest.json` 作为提交点的顺序落盘，确保并发或中断下状态一致。
    func saveWorkspace(_ workspace: NarrativeWorkspace, projectID: String) throws {
        try saveWorkspace(workspace, previous: nil, projectID: projectID)
    }

    /// 增量落盘工作区：利用子域修订号 O(1) 判脏，纯新增节点优先追加加密 WAL，检查点按节点独立密文落盘。
    func saveWorkspace(
        _ workspace: NarrativeWorkspace,
        previous: NarrativeWorkspace?,
        projectID: String,
        expectedWriteToken: UInt64? = nil
    ) throws {
        try NarrativeProjectLock.withLock(for: projectID) {
            if let expectedWriteToken, Self.currentWriteToken(for: projectID) != expectedWriteToken {
                return
            }
            if let previous, workspace.hasSameRevision(as: previous), hasWorkspace(projectID: projectID) {
                return
            }

            let fm = FileManager.default
            let dir = narrativeDirectory(projectID)
            let entDir = entitiesDirectory(projectID)
            let cpDir = checkpointsDirectory(projectID)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.createDirectory(at: entDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: cpDir, withIntermediateDirectories: true)

            let canDiff = previous != nil
                && fm.fileExists(atPath: manifestURL(projectID).path)
                && fm.fileExists(atPath: storyGraphURL(projectID).path)
                && fm.fileExists(atPath: directivesURL(projectID).path)
                && fm.fileExists(atPath: pyramidURL(projectID).path)
            let sameLineage = canDiff && previous?.sectionRevisions.lineageID == workspace.sectionRevisions.lineageID
            let sameGraphLineage = sameLineage && previous?.storyGraph.lineageID == workspace.storyGraph.lineageID

            let encoder = Self.makeEncoder()
            let walURL = storyGraphWALURL(projectID)

            let topologyChanged: Bool
            if !canDiff {
                topologyChanged = true
            } else if sameGraphLineage {
                topologyChanged = previous?.storyGraph.topologyRevision != workspace.storyGraph.topologyRevision
            } else {
                topologyChanged = previous?.storyGraph.withoutCheckpoints() != workspace.storyGraph.withoutCheckpoints()
            }

            if topologyChanged {
                if canDiff,
                   let prevGraph = previous?.storyGraph,
                   prevGraph.rootNodeID == workspace.storyGraph.rootNodeID,
                   prevGraph.nodes.keys.allSatisfy({ workspace.storyGraph.nodes[$0] != nil }) {
                    var walRecords: [StoryGraphWALRecord] = []
                    for nodeID in workspace.storyGraph.nodes.keys.sorted() {
                        guard let node = workspace.storyGraph.nodes[nodeID] else { continue }
                        if prevGraph.nodes[nodeID] != node {
                            walRecords.append(.upsertNode(node))
                        }
                    }
                    if prevGraph.headNodeID != workspace.storyGraph.headNodeID {
                        walRecords.append(.setHead(workspace.storyGraph.headNodeID))
                    }

                    let walInfo = StoryGraphWAL.inspect(at: walURL)
                    if !walInfo.hasTrailingGarbage,
                       !walRecords.isEmpty,
                       walInfo.count + walRecords.count < StoryGraphWAL.compactionThreshold {
                        try StoryGraphWAL.append(records: walRecords, to: walURL)
                    } else if !walRecords.isEmpty || fm.fileExists(atPath: walURL.path) || !sameGraphLineage {
                        try fileStore.writeEncrypted(
                            try encoder.encode(workspace.storyGraph.withoutCheckpoints()),
                            to: storyGraphURL(projectID)
                        )
                        StoryGraphWAL.remove(at: walURL)
                    }
                } else {
                    try fileStore.writeEncrypted(
                        try encoder.encode(workspace.storyGraph.withoutCheckpoints()),
                        to: storyGraphURL(projectID)
                    )
                    StoryGraphWAL.remove(at: walURL)
                }
            }

            let hasMissingCheckpointFiles = !workspace.storyGraph.checkpoints.isEmpty
                && workspace.storyGraph.checkpoints.keys.contains {
                    !fm.fileExists(atPath: checkpointFileURL(nodeID: $0, projectID: projectID).path)
                }
            let checkpointsChanged: Bool
            if !canDiff || hasMissingCheckpointFiles {
                checkpointsChanged = true
            } else if sameGraphLineage {
                checkpointsChanged = previous?.storyGraph.checkpointsRevision != workspace.storyGraph.checkpointsRevision
            } else {
                checkpointsChanged = previous?.storyGraph.checkpoints != workspace.storyGraph.checkpoints
            }

            var cachedSortedCheckpointIDs: [String]?
            func sortedCheckpointIDs() -> [String] {
                if let cached = cachedSortedCheckpointIDs { return cached }
                let sorted = workspace.storyGraph.checkpoints.keys.sorted()
                cachedSortedCheckpointIDs = sorted
                return sorted
            }

            if checkpointsChanged {
                var expectedCPFiles = Set<String>()
                for nodeID in sortedCheckpointIDs() {
                    guard let cp = workspace.storyGraph.checkpoints[nodeID] else { continue }
                    let fileName = Self.safeCheckpointFileName(for: nodeID)
                    expectedCPFiles.insert(fileName)
                    let targetURL = cpDir.appendingPathComponent(fileName)
                    let cpChanged = !canDiff
                        || previous?.storyGraph.checkpoints[nodeID] != cp
                        || !fm.fileExists(atPath: targetURL.path)
                    if cpChanged {
                        try fileStore.writeEncrypted(
                            try encoder.encode(cp),
                            to: targetURL
                        )
                    }
                }
                if let existing = try? fm.contentsOfDirectory(atPath: cpDir.path) {
                    for name in existing where name.hasSuffix(".json") && !expectedCPFiles.contains(name) {
                        try? fm.removeItem(at: cpDir.appendingPathComponent(name))
                    }
                }
            }

            let directivesChanged = !canDiff
                || (sameLineage
                    ? previous?.sectionRevisions.directives != workspace.sectionRevisions.directives
                    : previous?.directives != workspace.directives)
            if directivesChanged {
                try fileStore.writeEncrypted(
                    try encoder.encode(workspace.directives),
                    to: directivesURL(projectID)
                )
            }

            let ledgersPathExists = fm.fileExists(atPath: ledgersURL(projectID).path)
            let ledgersChanged = !canDiff
                || !ledgersPathExists
                || (!workspace.hasLiveLedgers && topologyChanged)
                || (sameLineage
                    ? previous?.sectionRevisions.ledgers != workspace.sectionRevisions.ledgers
                    : (previous?.activeFacts != workspace.activeFacts
                        || previous?.epistemicBeliefs != workspace.epistemicBeliefs
                        || previous?.threads != workspace.threads
                        || previous?.episodicEvents != workspace.episodicEvents
                        || previous?.conflictWarnings != workspace.conflictWarnings))
            if ledgersChanged {
                let effectiveState: (
                    facts: [String: WorldFactEvent],
                    beliefs: [String: EpistemicBelief],
                    threads: [String: ProspectiveThread],
                    events: [String: EpisodicEvent],
                    warnings: [StateConflictWarning]
                )
                if workspace.hasLiveLedgers {
                    effectiveState = (
                        workspace.activeFacts,
                        workspace.epistemicBeliefs,
                        workspace.threads,
                        workspace.episodicEvents,
                        workspace.conflictWarnings
                    )
                } else {
                    let materialized = workspace.currentState()
                    effectiveState = (
                        materialized.activeFacts,
                        materialized.epistemicBeliefs,
                        materialized.threads,
                        materialized.episodicEvents,
                        materialized.conflictWarnings
                    )
                }
                let hasAnyLedgerContent = !effectiveState.facts.isEmpty
                    || !effectiveState.beliefs.isEmpty
                    || !effectiveState.threads.isEmpty
                    || !effectiveState.events.isEmpty
                    || !effectiveState.warnings.isEmpty
                if !canDiff || workspace.hasLiveLedgers || hasAnyLedgerContent || ledgersPathExists {
                    let ledgers = LedgerBundle(
                        activeFacts: effectiveState.facts,
                        epistemicBeliefs: effectiveState.beliefs,
                        threads: effectiveState.threads,
                        episodicEvents: effectiveState.events,
                        conflictWarnings: effectiveState.warnings
                    )
                    try fileStore.writeEncrypted(
                        try encoder.encode(ledgers),
                        to: ledgersURL(projectID)
                    )
                }
            }

            let pyramidChanged = !canDiff
                || (sameLineage
                    ? previous?.sectionRevisions.pyramid != workspace.sectionRevisions.pyramid
                    : (previous?.pyramid != workspace.pyramid || previous?.anchorIndex != workspace.anchorIndex))
            if pyramidChanged {
                let bundle = PyramidBundle(pyramid: workspace.pyramid, anchorIndex: workspace.anchorIndex)
                try fileStore.writeEncrypted(
                    try encoder.encode(bundle),
                    to: pyramidURL(projectID)
                )
            }

            let entitiesChanged = !canDiff
                || (sameLineage
                    ? previous?.sectionRevisions.entities != workspace.sectionRevisions.entities
                    : previous?.entityPages != workspace.entityPages)
            var cachedSortedEntityIDs: [String]?
            func sortedEntityIDs() -> [String] {
                if let cached = cachedSortedEntityIDs { return cached }
                let sorted = workspace.entityPages.keys.sorted()
                cachedSortedEntityIDs = sorted
                return sorted
            }

            if entitiesChanged {
                var expectedFileNames = Set<String>()
                for entityID in sortedEntityIDs() {
                    guard let page = workspace.entityPages[entityID] else { continue }
                    let fileName = Self.safeEntityFileName(for: entityID)
                    expectedFileNames.insert(fileName)
                    let targetURL = entDir.appendingPathComponent(fileName)
                    let entityChanged = !canDiff
                        || previous?.entityPages[entityID] != page
                        || !fm.fileExists(atPath: targetURL.path)
                    if entityChanged {
                        try fileStore.writeEncrypted(
                            try encoder.encode(page),
                            to: targetURL
                        )
                    }
                }

                if let existing = try? fm.contentsOfDirectory(atPath: entDir.path) {
                    for name in existing where name.hasSuffix(".json") && !expectedFileNames.contains(name) {
                        try? fm.removeItem(at: entDir.appendingPathComponent(name))
                    }
                }
            }

            let manifestFieldChanged = sameLineage
                ? previous?.sectionRevisions.manifest != workspace.sectionRevisions.manifest
                : (previous?.schemaVersion != workspace.schemaVersion
                    || previous?.reFoldBoundary != workspace.reFoldBoundary
                    || previous?.preservedStyle != workspace.preservedStyle
                    || previous?.latestStyleLint != workspace.latestStyleLint
                    || previous?.migratedFromLegacyAt != workspace.migratedFromLegacyAt
                    || previous?.pendingSyncNodeIDs != workspace.pendingSyncNodeIDs
                    || previous?.syncedManuscriptUTF16Offset != workspace.syncedManuscriptUTF16Offset
                    || previous?.activePOVCharacterID != workspace.activePOVCharacterID)
            let entityIndexChanged = entitiesChanged
                && (previous.map { Set($0.entityPages.keys) != Set(workspace.entityPages.keys) } ?? true)
            let checkpointIndexChanged = (checkpointsChanged || hasMissingCheckpointFiles)
                && (previous.map { Set($0.storyGraph.checkpoints.keys) != Set(workspace.storyGraph.checkpoints.keys) } ?? true)
            let manifestChanged = !canDiff
                || manifestFieldChanged
                || entityIndexChanged
                || checkpointIndexChanged
                || hasMissingCheckpointFiles

            if manifestChanged {
                let manifest = Manifest(
                    schemaVersion: workspace.schemaVersion,
                    reFoldBoundary: workspace.reFoldBoundary,
                    preservedStyle: workspace.preservedStyle,
                    latestStyleLint: workspace.latestStyleLint,
                    migratedFromLegacyAt: workspace.migratedFromLegacyAt,
                    entityIDs: sortedEntityIDs(),
                    checkpointNodeIDs: sortedCheckpointIDs(),
                    pendingSyncNodeIDs: workspace.pendingSyncNodeIDs,
                    syncedManuscriptUTF16Offset: workspace.syncedManuscriptUTF16Offset,
                    activePOVCharacterID: workspace.activePOVCharacterID
                )
                try fileStore.writeEncrypted(
                    try encoder.encode(manifest),
                    to: manifestURL(projectID)
                )
            }
        }
    }

    /// 孤立持久化单个实体页，不触碰兄弟实体或其他状态文件。
    func saveEntityPage(_ page: EntityPage, projectID: String) throws {
        try NarrativeProjectLock.withLock(for: projectID) {
            let entDir = entitiesDirectory(projectID)
            try FileManager.default.createDirectory(at: entDir, withIntermediateDirectories: true)
            let encoder = Self.makeEncoder()
            let decoder = Self.makeDecoder()
            try fileStore.writeEncrypted(
                try encoder.encode(page),
                to: entityFileURL(entityID: page.id, projectID: projectID)
            )

            if case .loaded(let data) = fileStore.readEncryptedResult(manifestURL(projectID)),
               var manifest = try? decoder.decode(Manifest.self, from: data),
               !manifest.entityIDs.contains(page.id) {
                manifest.entityIDs = (manifest.entityIDs + [page.id]).sorted()
                try fileStore.writeEncrypted(
                    try encoder.encode(manifest),
                    to: manifestURL(projectID)
                )
            }
        }
    }

    func loadEntityPage(id: String, projectID: String) -> EntityPage? {
        NarrativeProjectLock.withLock(for: projectID) {
            readDecoded(
                entityFileURL(entityID: id, projectID: projectID),
                decoder: Self.makeDecoder()
            )
        }
    }

    func deleteEntityPage(id: String, projectID: String) throws {
        try NarrativeProjectLock.withLock(for: projectID) {
            let url = entityFileURL(entityID: id, projectID: projectID)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            let decoder = Self.makeDecoder()
            let encoder = Self.makeEncoder()
            if case .loaded(let data) = fileStore.readEncryptedResult(manifestURL(projectID)),
               var manifest = try? decoder.decode(Manifest.self, from: data),
               manifest.entityIDs.contains(id) {
                manifest.entityIDs.removeAll { $0 == id }
                try fileStore.writeEncrypted(
                    try encoder.encode(manifest),
                    to: manifestURL(projectID)
                )
            }
        }
    }

    private func readDecoded<T: Decodable>(_ url: URL, decoder: JSONDecoder) -> T? {
        guard case .loaded(let data) = fileStore.readEncryptedResult(url) else {
            return nil
        }
        return try? decoder.decode(T.self, from: data)
    }
}

extension FileStore {
    var narrative: NarrativeStore {
        NarrativeStore(fileStore: self)
    }
}
