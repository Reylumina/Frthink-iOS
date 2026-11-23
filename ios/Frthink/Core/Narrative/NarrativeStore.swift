import Foundation

/// 叙事工作区分文件 AES-256-GCM 加密持久化存储，将剧情图、规则账本与各实体独立页拆开落盘，
/// 避免单次更新重写整本元数据或造成兄弟实体互相覆盖。
///
/// 磁盘布局：
/// ```
/// projects/<projectID>/narrative/
///   manifest.json              — 清单提交点、折叠边界、深度蒸馏资产与实体索引
///   story_graph.json           — 纯情节因果图谱与节拍节点
///   directives.json            — 作者逐字规则账本
///   ledgers.json               — 现状客观事实、私有认知、五态伏笔与冲突告警
///   pyramid.json               — 分层时间摘要与机械索引
///   entities/<slug>_<sha>.json — 单实体档案独立密文文件
/// ```
struct NarrativeStore {
    let fileStore: FileStore

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
    }

    private struct PyramidBundle: Codable {
        var pyramid: NarrativePyramid
        var anchorIndex: AnchorIndex
    }

    private struct LedgerBundle: Codable {
        var activeFacts: [String: WorldFactEvent]
        var epistemicBeliefs: [String: EpistemicBelief]
        var threads: [String: ProspectiveThread]
        var conflictWarnings: [StateConflictWarning]
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

    /// 构造大小写不敏感文件系统及路径安全的实体独立文件名。
    static func safeEntityFileName(for entityID: String) -> String {
        let asciiChars = entityID.unicodeScalars.prefix(24).map { scalar -> Character in
            let v = scalar.value
            let isAlnum = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            if isAlnum || v == 95 || v == 45 {
                return Character(scalar)
            }
            return "_"
        }
        let slug = String(asciiChars).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let digest = String(SummaryKey.sha256Hex(entityID).prefix(16))
        return slug.isEmpty ? "entity_\(digest).json" : "\(slug)_\(digest).json"
    }

    func hasWorkspace(projectID: String) -> Bool {
        FileManager.default.fileExists(atPath: manifestURL(projectID).path)
    }

    /// 加载工作区状态，任一必需文件无法解密或校验失败均返回 `.corrupted`，防止以空工作区覆盖原数据。
    func loadWorkspaceState(projectID: String) -> LoadState {
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
            guard let storyGraph: StoryGraph = readDecoded(storyGraphURL(projectID), decoder: decoder),
                  let directives: AuthorDirectiveLedger = readDecoded(directivesURL(projectID), decoder: decoder),
                  let bundle: PyramidBundle = readDecoded(pyramidURL(projectID), decoder: decoder)
            else {
                return .corrupted
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
                migratedFromLegacyAt: manifest.migratedFromLegacyAt
            )

            switch fileStore.readEncryptedResult(ledgersURL(projectID)) {
            case .missing:
                try? workspace.synchronizeMaterializedHead()
            case .unreadable:
                return .corrupted
            case .loaded(let ledgerData):
                guard let ledgers = try? decoder.decode(LedgerBundle.self, from: ledgerData) else {
                    return .corrupted
                }
                workspace.activeFacts = ledgers.activeFacts
                workspace.epistemicBeliefs = ledgers.epistemicBeliefs
                workspace.threads = ledgers.threads
                workspace.conflictWarnings = ledgers.conflictWarnings
                workspace.hasLiveLedgers = true
            }
            return .loaded(workspace)
        }
    }

    /// 按先写子文件、最后写 `manifest.json` 作为提交点的顺序落盘，确保并发或中断下状态一致。
    func saveWorkspace(_ workspace: NarrativeWorkspace, projectID: String) throws {
        try saveWorkspace(workspace, previous: nil, projectID: projectID)
    }

    /// 增量落盘工作区：若提供上一次已落盘快照且磁盘子文件完备，则仅加密重写发生变化的子文件与实体页。
    func saveWorkspace(
        _ workspace: NarrativeWorkspace,
        previous: NarrativeWorkspace?,
        projectID: String
    ) throws {
        if let previous, previous == workspace, hasWorkspace(projectID: projectID) {
            return
        }

        let dir = narrativeDirectory(projectID)
        let entDir = entitiesDirectory(projectID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: entDir, withIntermediateDirectories: true)

        let fm = FileManager.default
        let canDiff = previous != nil
            && fm.fileExists(atPath: manifestURL(projectID).path)
            && fm.fileExists(atPath: storyGraphURL(projectID).path)
            && fm.fileExists(atPath: directivesURL(projectID).path)
            && fm.fileExists(atPath: pyramidURL(projectID).path)

        let encoder = Self.makeEncoder()
        var wroteAnySubfile = false

        if !canDiff || previous?.storyGraph != workspace.storyGraph {
            try fileStore.writeEncrypted(
                try encoder.encode(workspace.storyGraph),
                to: storyGraphURL(projectID)
            )
            wroteAnySubfile = true
        }
        if !canDiff || previous?.directives != workspace.directives {
            try fileStore.writeEncrypted(
                try encoder.encode(workspace.directives),
                to: directivesURL(projectID)
            )
            wroteAnySubfile = true
        }
        let ledgersMissing = !fm.fileExists(atPath: ledgersURL(projectID).path)
        if !canDiff
            || ledgersMissing
            || previous?.activeFacts != workspace.activeFacts
            || previous?.epistemicBeliefs != workspace.epistemicBeliefs
            || previous?.threads != workspace.threads
            || previous?.conflictWarnings != workspace.conflictWarnings {
            let ledgers = LedgerBundle(
                activeFacts: workspace.activeFacts,
                epistemicBeliefs: workspace.epistemicBeliefs,
                threads: workspace.threads,
                conflictWarnings: workspace.conflictWarnings
            )
            try fileStore.writeEncrypted(
                try encoder.encode(ledgers),
                to: ledgersURL(projectID)
            )
            wroteAnySubfile = true
        }
        if !canDiff || previous?.pyramid != workspace.pyramid || previous?.anchorIndex != workspace.anchorIndex {
            let bundle = PyramidBundle(pyramid: workspace.pyramid, anchorIndex: workspace.anchorIndex)
            try fileStore.writeEncrypted(
                try encoder.encode(bundle),
                to: pyramidURL(projectID)
            )
            wroteAnySubfile = true
        }

        var expectedFileNames = Set<String>()
        let sortedIDs = workspace.entityPages.keys.sorted()
        for entityID in sortedIDs {
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
                wroteAnySubfile = true
            }
        }

        if let existing = try? fm.contentsOfDirectory(atPath: entDir.path) {
            for name in existing where name.hasSuffix(".json") && !expectedFileNames.contains(name) {
                try? fm.removeItem(at: entDir.appendingPathComponent(name))
                wroteAnySubfile = true
            }
        }

        let manifestChanged = !canDiff
            || previous?.schemaVersion != workspace.schemaVersion
            || previous?.reFoldBoundary != workspace.reFoldBoundary
            || previous?.preservedStyle != workspace.preservedStyle
            || previous?.latestStyleLint != workspace.latestStyleLint
            || previous?.migratedFromLegacyAt != workspace.migratedFromLegacyAt
            || (previous.map { $0.entityPages.keys.sorted() != sortedIDs } ?? true)

        if wroteAnySubfile || manifestChanged {
            let manifest = Manifest(
                schemaVersion: workspace.schemaVersion,
                reFoldBoundary: workspace.reFoldBoundary,
                preservedStyle: workspace.preservedStyle,
                latestStyleLint: workspace.latestStyleLint,
                migratedFromLegacyAt: workspace.migratedFromLegacyAt,
                entityIDs: sortedIDs
            )
            try fileStore.writeEncrypted(
                try encoder.encode(manifest),
                to: manifestURL(projectID)
            )
        }
    }

    /// 孤立持久化单个实体页，不触碰兄弟实体或其他状态文件。
    func saveEntityPage(_ page: EntityPage, projectID: String) throws {
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

    func loadEntityPage(id: String, projectID: String) -> EntityPage? {
        readDecoded(
            entityFileURL(entityID: id, projectID: projectID),
            decoder: Self.makeDecoder()
        )
    }

    func deleteEntityPage(id: String, projectID: String) throws {
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

    func deleteWorkspace(projectID: String) throws {
        let dir = narrativeDirectory(projectID)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
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
