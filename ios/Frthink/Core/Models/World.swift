import Foundation

/// 世界书。人物卡、事件卡、仿写模板、长期写作规则都挂在这里。
///
/// 对应 Android 端「世界」「世界建立」「世界刷新」三套流程的产出。
struct WorldBook: Codable {
    /// 本地旧版「世界设定」文本；只用于迁移到世界书，不再注入。
    var setting: String
    /// APK `world.currentState`，世界摘要状态，不是用户设定。
    var currentState: String
    /// 仿写模板：可迁移的写法规则，续写时进系统提示词。
    var styleTemplate: String
    /// 文风笔记：从某一轮正文里提炼、待并入模板的增量。
    var styleNotes: String
    /// 长期写作规则日志（跨轮有效的写作要求，不是剧情摘要）。
    var longTermRules: String
    /// 已经参与过长期规则摘要的消息 id（原版 `conversationSummary.sourceMessageKeys`）。
    var summarizedMessageIDs: [String]
    var characters: [CharacterCard]
    /// 人物分组。原版人物卡可编组，关掉一组就不把该组人物发进提示词。
    var characterGroups: [CharacterGroup]
    var events: [EventCard]
    /// 语料收集库。
    var corpus: [CorpusEntry]
    /// 本书自带的世界书词条（P10），只属于当前书项目。
    var worldbookEntries: [WorldbookEntry]
    /// 旧「剧情梗概」文本（`snapshot.world.plotOutline`），仅用于存档往返。
    ///
    /// APK 的 P08 实际渲染 `plotEvents`（事件卡，`L1/W2.java:480-484`），
    /// 这段字符串在 APK 里没有任何读取点；iOS 不再把它注入提示词或单独展示。
    var plotOutline: String
    /// 人物关系摘要，原版 `world.relationships`，逐条是「甲 → 乙：关系」的文本。
    var relationships: [String]
    /// 原版 `world.characters` 的原始条目（「姓名 · 描述」字符串）。
    /// 原版只接受字符串；这里原样保存，导出时优先写回，避免只剩姓名。
    var characterSummaries: [String]
    /// 世界材料的正文分块哈希，原版 `world.materialChunkHashes`，用于判断材料是否变化。
    var materialChunkHashes: [String: String]
    /// 世界材料的分段处理进度，原版 `world.materialSourceProgress`，刷新断点续跑用。
    var materialSourceProgress: [String: MaterialSourceProgress]
    var lastRefreshedAt: Date?
    /// 上次刷新覆盖到的正文长度，用于增量刷新。
    var refreshedUpTo: Int
    /// 世界分析断点：正文哈希。与 `analysisSourceHash` 不一致时说明正文变过，
    /// 分段进度要重置。原版 `characterAnalysisCheckpoint.sourceSha256`。
    var analysisSourceHash: String
    /// 正文一共切成多少段（原版 `totalSegments`，实测 141）。
    var analysisSegmentCount: Int
    /// 已完成的段序号（原版 `completedSegments[].index`）。
    var completedAnalysisSegments: [Int]
    /// 分析源正文的码点数（原版 `sourceCodePointCount`）。
    var analysisSourceCodePointCount: Int
    /// 每段的完成详情，比 `completedAnalysisSegments` 多保存起止位置和抽取字段原文。
    var analysisSegments: [CharacterAnalysisSegment]
    /// 刷新中间草稿（原版 `mergedDraft`，通常是 null）。
    var analysisMergedDraft: CharacterDraft?
    /// 刷新合并后的人物卡（原版 `mergedCards`）。
    var analysisMergedCards: [CharacterCard]
    /// 原版 `characterBaselineSha256` / `worldMaterialSha256` / `worldRefreshComplete`。
    var analysisCharacterBaselineSHA256: String
    var analysisWorldMaterialSHA256: String
    var analysisWorldRefreshComplete: Bool

    // MARK: - 自动摘要元数据（原版 `conversationSummary`）

    var summarySourceHash: String
    /// 原版 `conversationSummary.sourceMessageKeys`，`user:<id>:<sha256>` 格式。
    var summarySourceMessageKeys: [String]
    var summaryEnabled: Bool
    /// epoch 毫秒。原版保留原值，导出不再用当前时间覆盖。
    var summaryUpdatedAt: Int64
    var summaryRulesVersion: Int
    var summaryPreviousRevisions: [SummaryRevision]

    init(
        setting: String = "",
        currentState: String = "",
        styleTemplate: String = "",
        styleNotes: String = "",
        longTermRules: String = "",
        summarizedMessageIDs: [String] = [],
        characters: [CharacterCard] = [],
        characterGroups: [CharacterGroup] = [],
        events: [EventCard] = [],
        corpus: [CorpusEntry] = [],
        worldbookEntries: [WorldbookEntry] = [],
        plotOutline: String = "",
        relationships: [String] = [],
        characterSummaries: [String] = [],
        materialChunkHashes: [String: String] = [:],
        materialSourceProgress: [String: MaterialSourceProgress] = [:],
        lastRefreshedAt: Date? = nil,
        refreshedUpTo: Int = 0,
        analysisSourceHash: String = "",
        analysisSegmentCount: Int = 0,
        completedAnalysisSegments: [Int] = [],
        analysisSourceCodePointCount: Int = 0,
        analysisSegments: [CharacterAnalysisSegment] = [],
        analysisMergedDraft: CharacterDraft? = nil,
        analysisMergedCards: [CharacterCard] = [],
        analysisCharacterBaselineSHA256: String = "",
        analysisWorldMaterialSHA256: String = "",
        analysisWorldRefreshComplete: Bool = false,
        summarySourceHash: String = "",
        summarySourceMessageKeys: [String] = [],
        summaryEnabled: Bool = true,
        summaryUpdatedAt: Int64 = 0,
        summaryRulesVersion: Int = 1,
        summaryPreviousRevisions: [SummaryRevision] = []
    ) {
        self.setting = setting
        self.currentState = currentState
        self.styleTemplate = styleTemplate
        self.styleNotes = styleNotes
        self.longTermRules = longTermRules
        self.summarizedMessageIDs = summarizedMessageIDs
        self.characters = characters
        self.characterGroups = characterGroups
        self.events = events
        self.corpus = corpus
        self.lastRefreshedAt = lastRefreshedAt
        self.refreshedUpTo = refreshedUpTo
        self.analysisSourceHash = analysisSourceHash
        self.analysisSegmentCount = analysisSegmentCount
        self.completedAnalysisSegments = completedAnalysisSegments
        self.analysisSourceCodePointCount = analysisSourceCodePointCount
        self.analysisSegments = analysisSegments
        self.analysisMergedDraft = analysisMergedDraft
        self.analysisMergedCards = analysisMergedCards
        self.analysisCharacterBaselineSHA256 = analysisCharacterBaselineSHA256
        self.analysisWorldMaterialSHA256 = analysisWorldMaterialSHA256
        self.analysisWorldRefreshComplete = analysisWorldRefreshComplete
        self.summarySourceHash = summarySourceHash
        self.summarySourceMessageKeys = summarySourceMessageKeys
        self.summaryEnabled = summaryEnabled
        self.summaryUpdatedAt = summaryUpdatedAt
        self.summaryRulesVersion = summaryRulesVersion
        self.summaryPreviousRevisions = summaryPreviousRevisions
        self.worldbookEntries = worldbookEntries
        self.plotOutline = plotOutline
        self.relationships = relationships
        self.characterSummaries = characterSummaries
        self.materialChunkHashes = materialChunkHashes
        self.materialSourceProgress = materialSourceProgress
    }

    /// 解码旧版本 payload：`worldbookEntries` 等后加字段缺失时用默认值，
    /// 不能让整本书因为一个新增键读不出来。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setting = (try? c.decode(String.self, forKey: .setting)) ?? ""
        currentState = (try? c.decode(String.self, forKey: .currentState)) ?? ""
        styleTemplate = (try? c.decode(String.self, forKey: .styleTemplate)) ?? ""
        styleNotes = (try? c.decode(String.self, forKey: .styleNotes)) ?? ""
        longTermRules = (try? c.decode(String.self, forKey: .longTermRules)) ?? ""
        summarizedMessageIDs =
            (try? c.decode([String].self, forKey: .summarizedMessageIDs)) ?? []
        characters = (try? c.decode([CharacterCard].self, forKey: .characters)) ?? []
        characterGroups =
            (try? c.decode([CharacterGroup].self, forKey: .characterGroups)) ?? []
        // 事件卡：正常是对象数组；更早的存档/Android 旧版可能写成字符串数组，
        // 此时不能整段丢掉，按标题还原成最小事件卡。
        let objectEvents = (try? c.decode([EventCard].self, forKey: .events)) ?? []
        if objectEvents.isEmpty {
            let legacyEvents = (try? c.decode([String].self, forKey: .events)) ?? []
            events = legacyEvents
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { EventCard(title: $0) }
        } else {
            events = objectEvents
        }
        corpus = (try? c.decode([CorpusEntry].self, forKey: .corpus)) ?? []
        worldbookEntries =
            (try? c.decode([WorldbookEntry].self, forKey: .worldbookEntries)) ?? []
        plotOutline = (try? c.decode(String.self, forKey: .plotOutline)) ?? ""
        relationships = (try? c.decode([String].self, forKey: .relationships)) ?? []
        characterSummaries =
            (try? c.decode([String].self, forKey: .characterSummaries)) ?? []
        materialChunkHashes =
            (try? c.decode([String: String].self, forKey: .materialChunkHashes)) ?? [:]
        materialSourceProgress =
            (try? c.decode([String: MaterialSourceProgress].self,
                           forKey: .materialSourceProgress)) ?? [:]
        lastRefreshedAt = try? c.decodeIfPresent(Date.self, forKey: .lastRefreshedAt)
        refreshedUpTo = (try? c.decode(Int.self, forKey: .refreshedUpTo)) ?? 0
        analysisSourceHash = (try? c.decode(String.self, forKey: .analysisSourceHash)) ?? ""
        analysisSegmentCount = (try? c.decode(Int.self, forKey: .analysisSegmentCount)) ?? 0
        completedAnalysisSegments =
            (try? c.decode([Int].self, forKey: .completedAnalysisSegments)) ?? []
        analysisSourceCodePointCount =
            (try? c.decode(Int.self, forKey: .analysisSourceCodePointCount)) ?? 0
        analysisSegments =
            (try? c.decode([CharacterAnalysisSegment].self, forKey: .analysisSegments)) ?? []
        analysisMergedDraft =
            (try? c.decodeIfPresent(CharacterDraft.self, forKey: .analysisMergedDraft))
        analysisMergedCards =
            (try? c.decode([CharacterCard].self, forKey: .analysisMergedCards)) ?? []
        analysisCharacterBaselineSHA256 =
            (try? c.decode(String.self, forKey: .analysisCharacterBaselineSHA256)) ?? ""
        analysisWorldMaterialSHA256 =
            (try? c.decode(String.self, forKey: .analysisWorldMaterialSHA256)) ?? ""
        analysisWorldRefreshComplete =
            (try? c.decode(Bool.self, forKey: .analysisWorldRefreshComplete)) ?? false
        summarySourceHash = (try? c.decode(String.self, forKey: .summarySourceHash)) ?? ""
        summarySourceMessageKeys =
            (try? c.decode([String].self, forKey: .summarySourceMessageKeys)) ?? []
        summaryEnabled = (try? c.decode(Bool.self, forKey: .summaryEnabled))
            ?? !longTermRules.isEmpty
        summaryUpdatedAt = (try? c.decode(Int64.self, forKey: .summaryUpdatedAt)) ?? 0
        summaryRulesVersion = (try? c.decode(Int.self, forKey: .summaryRulesVersion)) ?? 1
        summaryPreviousRevisions =
            (try? c.decode([SummaryRevision].self, forKey: .summaryPreviousRevisions)) ?? []

        // 旧版 iOS 的 setting 迁移成真实世界书词条；currentState 保持 APK 语义。
        let legacy = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if !legacy.isEmpty {
            if !worldbookEntries.contains(where: { $0.title == "世界设定" }) {
                worldbookEntries.insert(
                    WorldbookEntry(
                        id: "legacy-setting",
                        title: "世界设定",
                        body: legacy,
                        enabled: true
                    ),
                    at: 0
                )
            }
            setting = ""
        }
    }

    /// 把一次摘要更新写回元数据。
    ///
    /// 规则来自原版 `C0402j0.a(...)`：旧内容进 `previousRevisions`（最多 10 条），
    /// 键只保留 `user:` 前缀，`sourceHash` 按排序去重后的键重算，`rulesVersion` 固定 1。
    @discardableResult
    mutating func applySummaryUpdate(
        content: String,
        newKeys: [String],
        now: Int64
    ) -> Bool {
        guard content != longTermRules else { return false }

        if !longTermRules.isEmpty {
            summaryPreviousRevisions.append(
                SummaryRevision(
                    content: longTermRules,
                    sourceMessageKeys: summarySourceMessageKeys,
                    sourceHash: summarySourceHash,
                    enabled: summaryEnabled,
                    updatedAt: summaryUpdatedAt,
                    rulesVersion: summaryRulesVersion
                )
            )
            summaryPreviousRevisions = Array(summaryPreviousRevisions.suffix(10))
        }

        var keys = summarySourceMessageKeys.filter { $0.hasPrefix("user:") }
        for key in newKeys where !keys.contains(key) {
            keys.append(key)
        }
        summarySourceMessageKeys = keys
        summarySourceHash = SummaryKey.sourceHash(keys: keys)
        summaryEnabled = true
        summaryUpdatedAt = now
        summaryRulesVersion = 1
        longTermRules = content

        var ids = summarizedMessageIDs
        for id in keys.compactMap(SummaryKey.messageID(from:)) where !ids.contains(id) {
            ids.append(id)
        }
        summarizedMessageIDs = ids
        return true
    }

    /// 恢复上一版摘要。
    ///
    /// 原版 `E/e0` 的恢复动作：取 `previousRevisions` 最后一条，套回内容与源键，
    /// 把这条历史弹出，`updatedAt` 记为当前时间；当前内容不回收，恢复是单向的。
    @discardableResult
    mutating func restorePreviousSummary(now: Int64) -> Bool {
        guard let revision = summaryPreviousRevisions.popLast() else { return false }
        longTermRules = revision.content
        summarySourceMessageKeys = revision.sourceMessageKeys
        summarySourceHash = revision.sourceHash
        summaryEnabled = revision.enabled
        summaryUpdatedAt = now
        summaryRulesVersion = revision.rulesVersion
        summarizedMessageIDs = revision.sourceMessageKeys.compactMap {
            SummaryKey.messageID(from: $0)
        }
        return true
    }
}

/// 世界材料的分段处理进度。原版 `world.materialSourceProgress` 的值，
/// 刷新中断后靠它判断从哪一段接着跑。
struct MaterialSourceProgress: Codable, Hashable {
    var processedUtf16: Int
    var prefixHash: String
    var promptHash: String
}

/// 人物记忆条目。原版 `CharacterMemory`；备份里是对象数组，不是字符串。
struct CharacterMemory: Codable, Hashable {
    var id: String
    var content: String
    var evidence: String
    /// epoch 毫秒，原版 `Long`。
    var createdAt: Int64
}

/// 世界刷新的一段完成记录（原版 `CharacterAnalysisSegmentResult`）。
struct CharacterAnalysisSegment: Codable, Hashable {
    var index: Int
    var startCodePoint: Int
    var endCodePoint: Int
    var extractedFields: String
}

/// 刷新过程中的合并草稿（原版 `CharacterDraft`）。字段全部按缺省容错。
struct CharacterDraft: Codable, Hashable {
    var name: String
    var identity: String
    var personality: String
    var voice: String
    var goals: String
    var boundaries: String
    var aliases: [String]
    var personalMemory: String
    var relationshipAttitudes: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        identity = (try? c.decode(String.self, forKey: .identity)) ?? ""
        personality = (try? c.decode(String.self, forKey: .personality)) ?? ""
        voice = (try? c.decode(String.self, forKey: .voice)) ?? ""
        goals = (try? c.decode(String.self, forKey: .goals)) ?? ""
        boundaries = (try? c.decode(String.self, forKey: .boundaries)) ?? ""
        aliases = (try? c.decode([String].self, forKey: .aliases)) ?? []
        personalMemory = (try? c.decode(String.self, forKey: .personalMemory)) ?? ""
        relationshipAttitudes =
            (try? c.decode(String.self, forKey: .relationshipAttitudes)) ?? ""
    }
}

/// 长期摘要的历史版本（原版 `conversationSummary.previousRevisions[]`）。
struct SummaryRevision: Codable, Hashable {
    var content: String
    var sourceMessageKeys: [String]
    var sourceHash: String
    var enabled: Bool
    var updatedAt: Int64
    var rulesVersion: Int

    init(
        content: String,
        sourceMessageKeys: [String],
        sourceHash: String,
        enabled: Bool,
        updatedAt: Int64,
        rulesVersion: Int
    ) {
        self.content = content
        self.sourceMessageKeys = sourceMessageKeys
        self.sourceHash = sourceHash
        self.enabled = enabled
        self.updatedAt = updatedAt
        self.rulesVersion = rulesVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = (try? c.decode(String.self, forKey: .content)) ?? ""
        sourceMessageKeys =
            (try? c.decode([String].self, forKey: .sourceMessageKeys)) ?? []
        sourceHash = (try? c.decode(String.self, forKey: .sourceHash)) ?? ""
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? false
        updatedAt = (try? c.decode(Int64.self, forKey: .updatedAt)) ?? 0
        rulesVersion = (try? c.decode(Int.self, forKey: .rulesVersion)) ?? 1
    }
}

/// 人物卡。
///
/// 字段名严格照抄 Android 端 LLM 输出 schema：`name` / `identity` /
/// `personality` / `voice` / `goals` / `boundaries` / `aliases`，外加两个
/// 只在增量刷新时才出现的字符串字段 `personal_memory`、
/// `relationship_attitudes`，以及自由字段 `custom_entries`。
struct CharacterCard: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var identity: String
    var personality: String
    var voice: String
    var goals: String
    var boundaries: String
    var aliases: [String]
    /// 该角色亲历或明确知晓、对其行为有持续影响的经历。
    var personalMemory: String
    /// 按对象分别记录该角色对认识的人的印象、态度、信任与有依据的变化。
    var relationshipAttitudes: String
    var customEntries: [CustomEntry]
    /// 人物记忆条目。原版 `memories`；可能缺键，缺省按无记忆处理。
    var memories: [CharacterMemory]?
    var updatedAt: Date
    /// 是否进入写作提示词。原版 nabled，历史数据缺失时按启用处理。
    var enabled: Bool?
    /// 所属人物分组；nil/空串表示未分组。
    var groupId: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        identity: String = "",
        personality: String = "",
        voice: String = "",
        goals: String = "",
        boundaries: String = "",
        aliases: [String] = [],
        personalMemory: String = "",
        relationshipAttitudes: String = "",
        customEntries: [CustomEntry] = [],
        memories: [CharacterMemory]? = nil,
        updatedAt: Date = Date(),
        enabled: Bool? = nil,
        groupId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.identity = identity
        self.personality = personality
        self.voice = voice
        self.goals = goals
        self.boundaries = boundaries
        self.aliases = aliases
        self.personalMemory = personalMemory
        self.relationshipAttitudes = relationshipAttitudes
        self.customEntries = customEntries
        self.memories = memories
        self.updatedAt = updatedAt
        self.enabled = enabled
        self.groupId = groupId
    }

    /// 提示词里「任何其他有标题的内容都写入 custom_entries」的落点。
    struct CustomEntry: Identifiable, Codable, Hashable {
        var id: String
        var title: String
        var body: String

        init(id: String = UUID().uuidString, title: String, body: String) {
            self.id = id
            self.title = title
            self.body = body
        }
    }
}

/// 人物分组：原版人物卡编组，组关掉时组内卡片不进入提示词。
struct CharacterGroup: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var enabled: Bool

    init(id: String = UUID().uuidString, name: String, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.enabled = enabled
    }
}

/// 事件卡。对应提示词要求的 `title` / `scene` / `characters` /
/// `cause` / `development` / `consequence` 六个字段。
///
/// 「已有事件的后续使用完全相同的 title」——所以去重键是 `title`。
struct EventCard: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var scene: String
    var characters: [String]
    var cause: String
    var development: String
    var consequence: String
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        scene: String = "",
        characters: [String] = [],
        cause: String = "",
        development: String = "",
        consequence: String = "",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.scene = scene
        self.characters = characters
        self.cause = cause
        self.development = development
        self.consequence = consequence
        self.updatedAt = updatedAt
    }
}

/// 语料收集库条目。对应语料收集提示词要求的
/// `{"entries":[{"source","title","text","category","tags"}]}`。
struct CorpusEntry: Identifiable, Codable, Hashable {
    var id: String
    /// 来源片段编号，提示词里是 `C0`、`C1` 这种。
    var source: String
    var title: String
    /// 必须逐字复制自原文，不改标点。
    var text: String
    var category: String
    var tags: [String]
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        source: String,
        title: String,
        text: String,
        category: String = "",
        tags: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.text = text
        self.category = category
        self.tags = tags
        self.createdAt = createdAt
    }
}
