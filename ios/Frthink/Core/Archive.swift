import Foundation

/// `.frthink` 存档：信封 + gzip/base64 载荷，以及导入导出用的数据结构。
///
/// 外层格式必须和 Android 互认（`FrthinkArchiveEnvelope`，`I1\M` / `I1\O`）：
/// ```
/// {
///   "format": "writing-workspace-backup" | "frthink-full-backup",
///   "version": 1,
///   "compression": "gzip+base64",
///   "createdAt": <epoch 毫秒>,
///   "payload": "<base64(gzip(utf8(json)))>"
/// }
/// ```
/// gzip 容器在 `FrthinkGzip` 里手写：`Compression` 框架的 `COMPRESSION_ZLIB` 只
/// 吐裸 DEFLATE（RFC 1951），`NSData.compressed(using: .zlib)` 吐的是 zlib
/// （RFC 1950），两者都不能直接当 gzip（RFC 1952）用。Android 侧导入走
/// `GZIPInputStream`、导出走 `GZIPOutputStream`，所以头尾必须按 RFC 1952 补齐。
///
/// 内层载荷是 iOS 自己的结构：Android 的 `ProjectSnapshot` 是 56 字段的库内
/// 结构，和 `ProjectPayload` 没有一一对应（见 spec 03 §5.1），这里按能对上的
/// 键名对齐（`ArchivedSnapshot`），跨端只保证「信封 + gzip + 正文」读得回来。
enum FrthinkArchive {

    // MARK: - 常量

    /// 单个 `.frthink` 文件的字节上限：300 MiB（原版判定 `n < 314572801`）。
    static let maxBytes = 314_572_800
    /// 信封版本，只接受 1。
    static let envelopeVersion = 1
    /// 内层载荷的结构版本。
    static let payloadVersion = 1
    /// 唯一接受的压缩标记。
    static let compressionName = "gzip+base64"
    /// 书项目存档的 `format`。
    static let projectFormat = "writing-workspace-backup"
    /// 全量存档的 `format`。
    static let fullFormat = "frthink-full-backup"
    /// 导出的文件后缀。
    static let fileExtension = "frthink"

    /// 存档粒度。两个方向的校验规则只在文案和 format 上不同。
    enum Kind {
        case project
        case full

        var isFull: Bool { self == .full }
    }

    /// 当前时间戳（epoch 毫秒）。信封里的 `createdAt` 用这个单位。
    static var nowMillis: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    // MARK: - 信封

    /// 最外层信封，字段名照抄原版（`I1\M`）。
    struct Envelope: Codable {
        var format: String
        var version: Int
        var compression: String
        /// epoch 毫秒。
        var createdAt: Int64
        /// `base64(gzip(utf8(json)))`。
        var payload: String

        init(format: String, createdAt: Int64, payload: String) {
            self.format = format
            self.version = FrthinkArchive.envelopeVersion
            self.compression = FrthinkArchive.compressionName
            self.createdAt = createdAt
            self.payload = payload
        }
    }

    // MARK: - 载荷

    /// 书项目存档载荷（`ProjectArchivePayload`，`I1\K0`）。
    struct ProjectArchivePayload: Codable {
        var formatVersion: Int
        var createdAt: Int64
        var projects: [ProjectBackup]

        init(projects: [ProjectBackup], createdAt: Int64 = FrthinkArchive.nowMillis) {
            self.formatVersion = FrthinkArchive.payloadVersion
            self.createdAt = createdAt
            self.projects = projects
        }
    }

    /// 单本书的存档内容（字段对齐 `I1\O0`）。
    ///
    /// iOS 多一个 `sourceText`：Android 的原文放在 source blob 里按哈希去重，
    /// 这边直接内联整段原文，省掉 blob 表。
    struct ProjectBackup: Codable {
        var formatVersion: Int
        var createdAt: Int64
        var projectId: String
        var title: String
        var synopsis: String
        var snapshot: ArchivedSnapshot
        var sourceText: String
        var translations: [TranslationSegment]
        var universeEntries: [UniverseEntry]
        /// Android 端叫 `coverImageBase64`；iOS 的 `Project.coverImagePayload` 同义。
        var coverImageBase64: String
        var branchRootId: String
        var branchOrder: Int
        /// epoch 毫秒，0 表示不在回收站。
        var trashedAt: Int64

        private enum CodingKeys: String, CodingKey {
            case formatVersion, createdAt, projectId, title, synopsis, snapshot
            case sourceText, translations, universeEntries, coverImageBase64
            case branchRootId, branchOrder, trashedAt
        }

        init(
            project: Project,
            payload: ProjectPayload,
            sourceText: String,
            translations: [TranslationSegment],
            universeEntries: [UniverseEntry]
        ) {
            self.formatVersion = FrthinkArchive.payloadVersion
            self.createdAt = FrthinkArchive.nowMillis
            self.projectId = project.id
            self.title = project.title
            self.synopsis = project.synopsis
            self.snapshot = ArchivedSnapshot(payload: payload)
            self.sourceText = sourceText
            self.translations = translations
            self.universeEntries = universeEntries
            self.coverImageBase64 = project.coverImagePayload ?? ""
            self.branchRootId = project.branchRootId
            self.branchOrder = project.branchOrder
            self.trashedAt = project.trashedAt.map {
                Int64($0.timeIntervalSince1970 * 1000)
            } ?? 0
        }

        /// 宽容解码：缺字段按默认值补，坏字段（例如 Android 的译文记录结构不同）
        /// 只丢那一项，不整份失败。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = (try? c.decode(Int.self, forKey: .formatVersion)) ?? 1
            createdAt = (try? c.decode(Int64.self, forKey: .createdAt)) ?? 0
            projectId = (try? c.decode(String.self, forKey: .projectId)) ?? ""
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            synopsis = (try? c.decode(String.self, forKey: .synopsis)) ?? ""
            snapshot = (try? c.decode(ArchivedSnapshot.self, forKey: .snapshot))
                ?? ArchivedSnapshot()
            // 原版没有顶层 sourceText：原文在 snapshot.localSourceDocuments 里，
            // 已经由 ArchivedSnapshot 解出来了，这里回填。
            let ownSource = (try? c.decode(String.self, forKey: .sourceText)) ?? ""
            sourceText = ownSource.isEmpty ? snapshot.sourceText : ownSource
            translations = (try? c.decode([TranslationSegment].self, forKey: .translations)) ?? []
            universeEntries = (try? c.decode([UniverseEntry].self, forKey: .universeEntries)) ?? []
            coverImageBase64 = (try? c.decode(String.self, forKey: .coverImageBase64)) ?? ""
            branchRootId = (try? c.decode(String.self, forKey: .branchRootId)) ?? ""
            branchOrder = (try? c.decode(Int.self, forKey: .branchOrder)) ?? 0
            trashedAt = (try? c.decode(Int64.self, forKey: .trashedAt)) ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(formatVersion, forKey: .formatVersion)
            try c.encode(createdAt, forKey: .createdAt)
            try c.encode(projectId, forKey: .projectId)
            try c.encode(title, forKey: .title)
            try c.encode(synopsis, forKey: .synopsis)
            try c.encode(snapshot, forKey: .snapshot)
            try c.encode(sourceText, forKey: .sourceText)
            try c.encode(translations, forKey: .translations)
            try c.encode(universeEntries, forKey: .universeEntries)
            try c.encode(coverImageBase64, forKey: .coverImageBase64)
            try c.encode(branchRootId, forKey: .branchRootId)
            try c.encode(branchOrder, forKey: .branchOrder)
            try c.encode(trashedAt, forKey: .trashedAt)
        }
    }

    /// 存档里的 `snapshot`。
    ///
    /// iOS 的正文/章节/对话/世界书都在这一个结构里。Android 的对应物是
    /// `ProjectSnapshot`（56 字段，spec 03 §5.1），键名几乎全不同，只有正文
    /// （`authoritativeBody`）和 `messages` 能勉强对上——跨端迁移就靠这两项。
    /// 书项目快照。**字段名对齐 Android 真实的 `ProjectSnapshot`**（54 个键，
    /// `schemaVersion = 20`），不是早期从 DEX 反推的那份猜测结构。
    ///
    /// 真实样本（用户 2026-10-30 导出的全量备份）确认的布局：
    /// ```
    /// snapshot: {
    ///   schemaVersion, coreIdentity, projectRevision,
    ///   messages[{id,kind,title,content,isAccepted,versions[{id,content,source,requestId,status,tokenUsage,createdAt}],activeVersionId}],
    ///   world{currentState,plotOutline,imitationTemplate,characters,events,…},
    ///   projectAssistantPrompt, characterCards[{id,name,identity,personality,voice,goals,boundaries,aliases,memories,customEntries[{id,name,content}],enabled}],
    ///   worldbooks[{id,title,keywords,content,enabled,dynamic}],
    ///   conversationSummary{content,sourceMessageKeys,sourceHash,enabled,updatedAt,…},
    ///   localSourceDocuments[{id,name,mediaType,content,enabledForPrompt,…}],
    ///   authoritativeBody, coreBody*, reader*, agent*, audit*, task{…}
    /// }
    /// ```
    /// 只声明需要映射的键，其余由 `Decodable` 忽略。
    struct ArchivedSnapshot: Codable {
        var schemaVersion: Int
        var manuscript: String
        var chapters: [Chapter]
        var messages: [ChatMessage]
        var world: WorldBook
        var continuationAnchor: Int?
        /// 项目级补充指令（P02）。不带它的话存档往返会把这个字段丢掉。
        var assistantSupplement: String
        /// 原文（翻译源）。Android 放在 `localSourceDocuments[0]` 里。
        var sourceText: String
        /// 续写时发全文还是只发末尾。原版 `bodyPromptSendWhole`（实测 false）。
        var bodyPromptSendWhole: Bool
        /// 只发末尾时取多少码点。原版 `bodyPromptTailCodePoints`（实测 5000）。
        var bodyPromptTailCodePoints: Int
        var readerOffset: Int
        var readerBookmarkOffset: Int
        /// 这本书启用了哪些宇宙条目。原版 `enabledUniverseEntryIds`。
        var enabledUniverseEntryIDs: [String]
        /// 输入框草稿。原版 `composerDraft`。
        var composerDraft: String
        /// 已删消息墓碑。原版 `deletedChatMessageIds`。
        var deletedChatMessageIDs: [String]
        /// 历史请求快照。原版 `requestSnapshots`（「提示词回看」的数据）。
        var requestSnapshots: [RequestSnapshot]
        /// 「插入正文」的撤销凭据（原版 `bodyAppendReceiptIds`）。
        var bodyAppendReceipts: [BodyAppendReceipt]
        /// 上一次撤销掉的凭据（原版 `lastBodyAppendUndo`）。
        var lastBodyAppendUndo: BodyAppendReceipt?

        init(
            schemaVersion: Int = 1,
            manuscript: String = "",
            chapters: [Chapter] = [],
            messages: [ChatMessage] = [],
            world: WorldBook = WorldBook(),
            continuationAnchor: Int? = nil,
            assistantSupplement: String = "",
            sourceText: String = "",
            bodyPromptSendWhole: Bool = false,
            bodyPromptTailCodePoints: Int = 5000,
            readerOffset: Int = 0,
            readerBookmarkOffset: Int = 0,
            enabledUniverseEntryIDs: [String] = [],
            composerDraft: String = "",
            deletedChatMessageIDs: [String] = [],
            requestSnapshots: [RequestSnapshot] = [],
            bodyAppendReceipts: [BodyAppendReceipt] = [],
            lastBodyAppendUndo: BodyAppendReceipt? = nil
        ) {
            self.schemaVersion = schemaVersion
            self.manuscript = manuscript
            self.chapters = chapters
            self.messages = messages
            self.world = world
            self.continuationAnchor = continuationAnchor
            self.assistantSupplement = assistantSupplement
            self.sourceText = sourceText
            self.bodyPromptSendWhole = bodyPromptSendWhole
            self.bodyPromptTailCodePoints = bodyPromptTailCodePoints
            self.readerOffset = readerOffset
            self.readerBookmarkOffset = readerBookmarkOffset
            self.enabledUniverseEntryIDs = enabledUniverseEntryIDs
            self.composerDraft = composerDraft
            self.deletedChatMessageIDs = deletedChatMessageIDs
            self.requestSnapshots = requestSnapshots
            self.bodyAppendReceipts = bodyAppendReceipts
            self.lastBodyAppendUndo = lastBodyAppendUndo
        }

        init(payload: ProjectPayload, sourceText: String = "") {
            self.schemaVersion = payload.schemaVersion
            self.manuscript = payload.manuscript
            self.chapters = payload.chapters
            self.messages = payload.messages
            self.world = payload.world
            self.continuationAnchor = payload.continuationAnchor
            self.assistantSupplement = payload.assistantSupplement
            self.sourceText = sourceText
            self.bodyPromptSendWhole = payload.bodyPromptSendWhole
            self.bodyPromptTailCodePoints = payload.bodyPromptTailCodePoints
            self.readerOffset = payload.readerOffset
            self.readerBookmarkOffset = payload.readerBookmarkOffset
            self.enabledUniverseEntryIDs = payload.enabledUniverseEntryIDs
            self.composerDraft = payload.composerDraft
            self.deletedChatMessageIDs = payload.deletedChatMessageIDs
            self.requestSnapshots = payload.requestSnapshots
            self.bodyAppendReceipts = payload.bodyAppendReceipts
            self.lastBodyAppendUndo = payload.lastBodyAppendUndo
        }

        var projectPayload: ProjectPayload {
            ProjectPayload(
                schemaVersion: 1,
                manuscript: manuscript,
                chapters: chapters,
                messages: messages,
                world: world,
                continuationAnchor: continuationAnchor,
                assistantSupplement: assistantSupplement,
                bodyPromptSendWhole: bodyPromptSendWhole,
                bodyPromptTailCodePoints: bodyPromptTailCodePoints,
                readerOffset: readerOffset,
                readerBookmarkOffset: readerBookmarkOffset,
                enabledUniverseEntryIDs: enabledUniverseEntryIDs,
                composerDraft: composerDraft,
                deletedChatMessageIDs: deletedChatMessageIDs,
                requestSnapshots: requestSnapshots,
                bodyAppendReceipts: bodyAppendReceipts,
                lastBodyAppendUndo: lastBodyAppendUndo
            )
        }
    

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: SnapshotKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1

        // 正文：Android 叫 authoritativeBody，iOS 早期导出叫 manuscript。
        if let text = try? c.decode(String.self, forKey: .authoritativeBody), !text.isEmpty {
            manuscript = text
        } else {
            manuscript = (try? c.decode(String.self, forKey: .manuscript)) ?? ""
        }

        chapters = (try? c.decode([Chapter].self, forKey: .chapters)) ?? []
        continuationAnchor = try? c.decodeIfPresent(Int.self, forKey: .continuationAnchor)
        assistantSupplement =
            (try? c.decode(String.self, forKey: .assistantSupplement))
            ?? (try? c.decode(String.self, forKey: .projectAssistantPrompt))
            ?? ""
        bodyPromptSendWhole =
            (try? c.decode(Bool.self, forKey: .bodyPromptSendWhole)) ?? false
        bodyPromptTailCodePoints =
            (try? c.decode(Int.self, forKey: .bodyPromptTailCodePoints)) ?? 5000
        readerOffset = (try? c.decode(Int.self, forKey: .readerOffset)) ?? 0
        readerBookmarkOffset =
            (try? c.decode(Int.self, forKey: .readerBookmarkOffset)) ?? 0
        enabledUniverseEntryIDs =
            (try? c.decode([String].self, forKey: .enabledUniverseEntryIds)) ?? []
        composerDraft = (try? c.decode(String.self, forKey: .composerDraft)) ?? ""
        bodyAppendReceipts =
            (try? c.decode([BodyAppendReceipt].self, forKey: .bodyAppendReceipts)) ?? []
        lastBodyAppendUndo =
            try? c.decodeIfPresent(BodyAppendReceipt.self, forKey: .lastBodyAppendUndo)
        deletedChatMessageIDs =
            (try? c.decode([String].self, forKey: .deletedChatMessageIds)) ?? []
        let rawSnapshots =
            (try? c.decode([RequestSnapshotJSON].self, forKey: .requestSnapshots)) ?? []
        requestSnapshots = rawSnapshots.map { raw in
            RequestSnapshot(
                id: raw.id ?? UUID().uuidString,
                createdAt: Date(
                    timeIntervalSince1970: Double(raw.createdAt ?? 0) / 1000
                ),
                modelId: raw.modelId ?? "",
                sourceIds: raw.sourceIds ?? [],
                messages: (raw.messages ?? []).map {
                    LLMMessage(role: $0.role ?? "user", content: $0.content ?? "")
                },
                estimatedInputTokens: raw.estimatedInputTokens ?? 0,
                inputBudgetTokens: raw.inputBudgetTokens ?? 0,
                modelContextWindowTokens: raw.modelContextWindowTokens ?? 0,
                outputReserveTokens: raw.outputReserveTokens ?? 0,
                omittedHistoryMessages: raw.omittedHistoryMessages ?? 0
            )
        }

        // 消息：kind → role，versions → variants。
        //
        // 版本里可能有没有正文的失败版本（`content == null`）。先按「有正文的版本」
        // 建变体数组，再用 activeVersionId 在这一数组里的位置定选中项——直接拿
        // versions 的下标去索引 compactMap 后的数组，会错位到另一版。
        let rawMessages = (try? c.decode([MessageJSON].self, forKey: .messages)) ?? []
        messages = rawMessages.map { raw in
            let role: ChatMessage.Role
            switch (raw.kind ?? "USER").uppercased() {
            case "ASSISTANT": role = .assistant
            case "SYSTEM": role = .system
            default: role = .user
            }
            let versions = raw.versions ?? []
            var variants: [String] = []
            var selected = 0
            for version in versions {
                guard let content = version.content else { continue }
                if version.id == raw.activeVersionId { selected = variants.count }
                variants.append(content)
            }
            if variants.isEmpty {
                variants = [raw.content ?? ""]
                selected = 0
            }
            if selected >= variants.count { selected = variants.count - 1 }
            let created = versions
                .compactMap { $0.createdAt }
                .first
                .map { Date(timeIntervalSince1970: Double($0) / 1000) }
                ?? Date()
            var message = ChatMessage(
                id: raw.id ?? UUID().uuidString,
                role: role,
                content: variants.indices.contains(selected) ? variants[selected] : "",
                createdAt: created
            )
            message.variants = variants
            message.selectedVariant = selected
            return message
        }

        // 墓碑：原版把已删消息的 id 记下来，防止重新导入或同步时复活。
        // 这里连「记录」带「过滤」一起做，否则删掉的消息会在导入后重新出现。
        if !deletedChatMessageIDs.isEmpty {
            let tombstones = Set(deletedChatMessageIDs)
            messages = messages.filter { !tombstones.contains($0.id) }
        }

        // 世界：优先用顶层 characterCards（这是原版真正在用的那份）。
        let worldJSON = try? c.decode(SnapshotWorld.self, forKey: .world)
        let rawCharacters =
            (try? c.decode([CharacterJSON].self, forKey: .characterCards)) ?? []
        // 顶层 characterCards 是原版真正在用的那份；缺失时才退回
        // world.characters（原版是「姓名 · 描述」字符串列表）。
        let cards: [CharacterCard] = (
            rawCharacters.isEmpty
                ? (worldJSON?.characters ?? []).map { CharacterCard(name: $0.name) }
                : rawCharacters.map { FrthinkArchive.characterCard(from: $0) }
        ).filter { !$0.name.isEmpty }

        let rawBooks = (try? c.decode([WorldbookJSON].self, forKey: .worldbooks)) ?? []
        let books = rawBooks.map {
            WorldbookEntry(
                id: $0.id ?? UUID().uuidString,
                title: $0.title ?? "",
                body: $0.content ?? "",
                enabled: $0.enabled ?? true
            )
        }.filter { !$0.title.isEmpty }

        let summary = try? c.decode(SummaryJSON.self, forKey: .conversationSummary)
        let docs = (try? c.decode([SourceDocJSON].self, forKey: .localSourceDocuments)) ?? []
        sourceText = docs.first?.content ?? ""

        // 事件卡：Android 的新版本把剧情事件放在 `world.plotEvents`
        // （`PlotEventCard`），老版本放 `world.events` 字符串数组。两者都读，
        // 前者是真正能还原成事件卡的那份。
        let events: [EventCard] = (worldJSON?.plotEvents ?? []).compactMap { raw in
            guard let title = raw.title, !title.isEmpty else { return nil }
            return EventCard(
                id: raw.id ?? UUID().uuidString,
                title: title,
                scene: raw.scene ?? "",
                characters: raw.characters ?? [],
                cause: raw.cause ?? "",
                development: raw.development ?? "",
                consequence: raw.consequence ?? ""
            )
        }

        let groups: [CharacterGroup] = (worldJSON?.characterGroups ?? []).compactMap { raw in
            guard let name = raw.name, !name.isEmpty else { return nil }
            return CharacterGroup(
                id: raw.id ?? UUID().uuidString,
                name: name,
                enabled: raw.enabled ?? true
            )
        }

        world = WorldBook(
            currentState: worldJSON?.currentState ?? "",
            styleTemplate: worldJSON?.imitationTemplate ?? "",
            styleNotes: worldJSON?.styleNotes ?? "",
            longTermRules: summary?.content ?? "",
            summarizedMessageIDs: (summary?.sourceMessageKeys ?? [])
                .compactMap(SummaryKey.messageID(from:)),
            characters: cards,
            characterGroups: groups,
            events: events,
            corpus: [],
            worldbookEntries: books,
            plotOutline: worldJSON?.plotOutline ?? "",
            relationships: worldJSON?.relationships ?? [],
            characterSummaries: (worldJSON?.characters ?? []).map(\.summary),
            materialChunkHashes: worldJSON?.materialChunkHashes ?? [:],
            materialSourceProgress: (worldJSON?.materialSourceProgress ?? [:]).mapValues {
                MaterialSourceProgress(
                    processedUtf16: $0.processedUtf16 ?? 0,
                    prefixHash: $0.prefixHash ?? "",
                    promptHash: $0.promptHash ?? ""
                )
            },
            lastRefreshedAt: nil,
            refreshedUpTo: 0
        )

        // 世界分析断点：正文哈希 + 每段完成状态。放在 `world` 赋值之后，
        // 否则是在用未初始化的属性。
        if let checkpoint = try? c.decode(
            AnalysisCheckpointJSON.self,
            forKey: .characterAnalysisCheckpoint
        ) {
            world.analysisSourceHash = checkpoint.sourceSha256 ?? ""
            world.analysisSourceCodePointCount = checkpoint.sourceCodePointCount ?? 0
            world.analysisSegmentCount = checkpoint.totalSegments ?? 0
            world.analysisSegments = (checkpoint.completedSegments ?? []).map {
                CharacterAnalysisSegment(
                    index: $0.index ?? 0,
                    startCodePoint: $0.startCodePoint ?? 0,
                    endCodePoint: $0.endCodePoint ?? 0,
                    extractedFields: $0.extractedFields ?? ""
                )
            }
            world.completedAnalysisSegments = world.analysisSegments.map(\.index)
            world.analysisMergedDraft = checkpoint.mergedDraft
            world.analysisMergedCards =
                (checkpoint.mergedCards ?? []).map { FrthinkArchive.characterCard(from: $0) }
            world.analysisCharacterBaselineSHA256 = checkpoint.characterBaselineSha256 ?? ""
            world.analysisWorldMaterialSHA256 = checkpoint.worldMaterialSha256 ?? ""
            world.analysisWorldRefreshComplete = checkpoint.worldRefreshComplete ?? false
        }

        if let summary {
            world.summarySourceHash = summary.sourceHash ?? ""
            world.summarySourceMessageKeys = summary.sourceMessageKeys ?? []
            world.summaryEnabled = summary.enabled ?? !(summary.content ?? "").isEmpty
            world.summaryUpdatedAt = summary.updatedAt ?? 0
            world.summaryRulesVersion = summary.rulesVersion ?? 1
            world.summaryPreviousRevisions = summary.previousRevisions ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: SnapshotKeys.self)
        // 导出的 schemaVersion 写 20 —— 这是原版认识的值。
        try c.encode(20, forKey: .schemaVersion)
        try c.encode(manuscript, forKey: .authoritativeBody)
        try c.encode(assistantSupplement, forKey: .projectAssistantPrompt)
        try c.encode(bodyPromptSendWhole, forKey: .bodyPromptSendWhole)
        try c.encode(bodyPromptTailCodePoints, forKey: .bodyPromptTailCodePoints)
        try c.encode(readerOffset, forKey: .readerOffset)
        try c.encode(readerBookmarkOffset, forKey: .readerBookmarkOffset)
        try c.encode(enabledUniverseEntryIDs, forKey: .enabledUniverseEntryIds)
        try c.encode(composerDraft, forKey: .composerDraft)
        try c.encode(deletedChatMessageIDs, forKey: .deletedChatMessageIds)
        try c.encode(bodyAppendReceipts, forKey: .bodyAppendReceipts)
        try c.encodeIfPresent(lastBodyAppendUndo, forKey: .lastBodyAppendUndo)
        let snapshotJSON: [[String: Any]] = requestSnapshots.map { snap in
            [
                "id": snap.id,
                "createdAt": Int64(snap.createdAt.timeIntervalSince1970 * 1000),
                "modelId": snap.modelId,
                "sourceIds": snap.sourceIds,
                "messages": snap.messages.map { ["role": $0.role, "content": $0.content] },
                "estimatedInputTokens": snap.estimatedInputTokens,
                "inputBudgetTokens": snap.inputBudgetTokens,
                "modelContextWindowTokens": snap.modelContextWindowTokens,
                "outputReserveTokens": snap.outputReserveTokens,
                "omittedHistoryMessages": snap.omittedHistoryMessages,
            ]
        }
        try encodeAny(snapshotJSON, key: .requestSnapshots, into: &c)

        let messageJSON = messages.map { message -> [String: Any] in
            let kind: String
            switch message.role {
            case .assistant: kind = "ASSISTANT"
            case .system: kind = "SYSTEM"
            case .user: kind = "USER"
            }
            let created = Int64(message.createdAt.timeIntervalSince1970 * 1000)
            let versions = message.variants.enumerated().map { index, content in
                [
                    "id": "\(message.id)-v\(index)",
                    "content": content,
                    "source": "legacy",
                    "requestId": "",
                    "status": "completed",
                    "createdAt": created,
                ] as [String: Any]
            }
            let activeID = message.variants.indices.contains(message.selectedVariant)
                ? "\(message.id)-v\(message.selectedVariant)"
                : (versions.first?["id"] as? String ?? "")
            return [
                "id": message.id,
                "kind": kind,
                "title": message.role == .user ? "你" : "码字机",
                "content": message.content,
                "isAccepted": false,
                "versions": versions,
                "activeVersionId": activeID,
            ]
        }
        try encodeAny(messageJSON, key: .messages, into: &c)

        let characters: [[String: Any]] = world.characters.map(FrthinkArchive.characterCardJSON)
        try encodeAny(characters, key: .characterCards, into: &c)

        let books: [[String: Any]] = world.worldbookEntries.map { entry in
            [
                "id": entry.id,
                "title": entry.title,
                "keywords": "",
                "content": entry.body,
                "enabled": entry.enabled,
                "dynamic": false,
            ]
        }
        try encodeAny(books, key: .worldbooks, into: &c)

        let worldDict: [String: Any] = [
            "currentState": world.currentState,
            "plotOutline": world.plotOutline,
            "imitationTemplate": world.styleTemplate,
            // iOS 私有键：文风笔记是用户可编辑数据，原版没有对应字段。
            "styleNotes": world.styleNotes,
            "characters": world.characterSummaries.isEmpty
                ? world.characters.map(\.name)
                : world.characterSummaries,
            "relationships": world.relationships,
            "events": [],
            "plotEvents": world.events.map { event in
                [
                    "id": event.id,
                    "title": event.title,
                    "scene": event.scene,
                    "characters": event.characters,
                    "cause": event.cause,
                    "development": event.development,
                    "consequence": event.consequence,
                ]
            },
            "characterGroups": world.characterGroups.map { group in
                ["id": group.id, "name": group.name, "enabled": group.enabled]
            },
            "materialChunkHashes": world.materialChunkHashes,
            "materialSourceProgress": world.materialSourceProgress.mapValues { progress in
                [
                    "processedUtf16": progress.processedUtf16,
                    "prefixHash": progress.prefixHash,
                    "promptHash": progress.promptHash,
                ]
            },
        ]
        try encodeAny(worldDict, key: .world, into: &c)

        // 原版键格式是 `user:<id>:<sha256>`；旧 iOS 数据只有消息 id 时现补。
        let contentByID = Dictionary(
            messages.map { ($0.id, $0.content) },
            uniquingKeysWith: { first, _ in first }
        )
        let summaryKeys: [String] = world.summarySourceMessageKeys.isEmpty
            ? world.summarizedMessageIDs.compactMap { id in
                contentByID[id].map { SummaryKey.messageKey(id: id, content: $0) }
            }
            : world.summarySourceMessageKeys
        let summaryHash: String
        if !world.summarySourceHash.isEmpty {
            summaryHash = world.summarySourceHash
        } else if !summaryKeys.isEmpty {
            summaryHash = SummaryKey.sourceHash(keys: summaryKeys)
        } else {
            summaryHash = ""
        }

        let summary: [String: Any] = [
            "content": world.longTermRules,
            "sourceMessageKeys": summaryKeys,
            "sourceHash": summaryHash,
            "enabled": world.summaryEnabled,
            "updatedAt": world.summaryUpdatedAt > 0
                ? world.summaryUpdatedAt
                : Int64(Date().timeIntervalSince1970 * 1000),
            "previousRevisions": world.summaryPreviousRevisions.map { revision in
                [
                    "content": revision.content,
                    "sourceMessageKeys": revision.sourceMessageKeys,
                    "sourceHash": revision.sourceHash,
                    "enabled": revision.enabled,
                    "updatedAt": revision.updatedAt,
                    "rulesVersion": revision.rulesVersion,
                ]
            },
            "rulesVersion": world.summaryRulesVersion,
        ]
        try encodeAny(summary, key: .conversationSummary, into: &c)

        // 世界分析断点：原版按段保存，刷新断点续跑和「世界刷新」历史都靠它。
        let hasCheckpoint = !world.analysisSourceHash.isEmpty
            || world.analysisSourceCodePointCount > 0
            || !world.analysisSegments.isEmpty
            || !world.analysisMergedCards.isEmpty
        if hasCheckpoint {
            let checkpoint: [String: Any] = [
                "sourceSha256": world.analysisSourceHash,
                "sourceCodePointCount": world.analysisSourceCodePointCount,
                "totalSegments": world.analysisSegmentCount,
                "completedSegments": world.analysisSegments.map { segment in
                    [
                        "index": segment.index,
                        "startCodePoint": segment.startCodePoint,
                        "endCodePoint": segment.endCodePoint,
                        "extractedFields": segment.extractedFields,
                    ]
                },
                "mergedDraft": world.analysisMergedDraft.map(FrthinkArchive.characterDraftJSON)
                    ?? NSNull(),
                "mergedCards": world.analysisMergedCards.map(FrthinkArchive.characterCardJSON),
                "characterBaselineSha256": world.analysisCharacterBaselineSHA256,
                "worldMaterialSha256": world.analysisWorldMaterialSHA256,
                "worldRefreshComplete": world.analysisWorldRefreshComplete,
            ]
            try encodeAny(checkpoint, key: .characterAnalysisCheckpoint, into: &c)
        }

        let docs: [[String: Any]] = sourceText.isEmpty ? [] : [[
            "id": UUID().uuidString,
            "name": "原文",
            "mediaType": "text/plain",
            "content": sourceText,
            "enabledForPrompt": false,
            "importedAt": Int64(Date().timeIntervalSince1970 * 1000),
        ]]
        try encodeAny(docs, key: .localSourceDocuments, into: &c)
    }

    /// 用 `JSONSerialization` 打洞写任意结构：这些字段是字典数组，
    /// 用 Codable 建一堆中间类型反而更乱。
    private func encodeAny(
        _ value: Any,
        key: SnapshotKeys,
        into container: inout KeyedEncodingContainer<SnapshotKeys>
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        let wrapper = try JSONDecoder().decode(AnyBox.self, from: data)
        try container.encode(wrapper, forKey: key)
    }

    /// 把任意 JSON 原样编回去的盒子。
    private struct AnyBox: Codable {
        let value: AnyCodable

        init(value: AnyCodable) {
            self.value = value
        }

        init(from decoder: Decoder) throws {
            value = try AnyCodable(from: decoder)
        }

        func encode(to encoder: Encoder) throws {
            try value.encode(to: encoder)
        }
    }
    }

    // MARK: 真实 JSON 的子结构

    private enum SnapshotKeys: String, CodingKey {
        case schemaVersion
        case authoritativeBody
        case messages
        case world
        case projectAssistantPrompt
        case characterCards
        case worldbooks
        case conversationSummary
        case localSourceDocuments
        case readerOffset
        case readerBookmarkOffset
        // 早期 iOS 自身导出的键，保持兼容
        case manuscript
        case chapters
        case continuationAnchor
        case assistantSupplement
        // 行为参数与界面状态
        case bodyPromptSendWhole
        case bodyPromptTailCodePoints
        case enabledUniverseEntryIds
        case composerDraft
        case deletedChatMessageIds
        case requestSnapshots
        case bodyAppendReceipts
        case lastBodyAppendUndo
        case characterAnalysisCheckpoint
    }

    private struct SnapshotWorld: Decodable {
        struct PlotEventJSON: Decodable {
            var id: String?
            var title: String?
            var scene: String?
            var characters: [String]?
            var cause: String?
            var development: String?
            var consequence: String?
        }
        /// 原版 `world.characters` 是 `List<String>`（kotlinx.serialization 描述符
        /// 确认只接受字符串），条目形如「姓名 · 描述」。对象形态不再接受。
        struct WorldCharacterEntry: Decodable {
            /// 原样保留的条目文本。
            var summary: String
            /// 回退建卡用的名字；取「·」之前的部分。
            var name: String

            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                let value = try single.decode(String.self)
                summary = value
                name = value
                    .split(separator: "·", maxSplits: 1, omittingEmptySubsequences: true)
                    .first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? value
            }
        }

        var currentState: String?
        var plotOutline: String?
        var imitationTemplate: String?
        /// iOS 私有键：文风笔记，原版没有对应字段。
        var styleNotes: String?
        var characters: [WorldCharacterEntry]?
        /// 人物关系摘要，原版 `world.relationships`。
        var relationships: [String]?
        /// 世界材料分块哈希，原版 `world.materialChunkHashes`。
        var materialChunkHashes: [String: String]?
        /// 世界材料分段进度，原版 `world.materialSourceProgress`。
        var materialSourceProgress: [String: RawMaterialProgress]?
        /// 新版 Android 的事件卡（`world.plotEvents`）。
        var plotEvents: [PlotEventJSON]?
        /// iOS 存档携带的人物分组；Android 无此键时缺省。
        var characterGroups: [GroupJSON]?
    }

    /// 材料进度的原始形态。字段都可缺省，避免一个坏条目让整份世界解不出来。
    private struct RawMaterialProgress: Decodable {
        var processedUtf16: Int?
        var prefixHash: String?
        var promptHash: String?
    }

    private struct GroupJSON: Decodable {
        var id: String?
        var name: String?
        var enabled: Bool?
    }

    private struct CharacterJSON: Decodable {
        struct RawEntry: Decodable {
            var id: String?
            var name: String?
            var content: String?
        }
        /// 记忆条目：规范是对象，旧 iOS 存档写成字符串；两种都接。
        struct MemoryJSON: Decodable {
            var id: String?
            var content: String?
            var evidence: String?
            var createdAt: Int64?

            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                if let text = try? single.decode(String.self) {
                    content = text
                    return
                }
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try? c.decode(String.self, forKey: .id)
                content = try? c.decode(String.self, forKey: .content)
                evidence = try? c.decode(String.self, forKey: .evidence)
                createdAt = try? c.decode(Int64.self, forKey: .createdAt)
            }

            enum CodingKeys: String, CodingKey {
                case id, content, evidence, createdAt
            }
        }
        var id: String?
        var name: String?
        var identity: String?
        var personality: String?
        var voice: String?
        var goals: String?
        var boundaries: String?
        var aliases: [String]?
        var memories: [MemoryJSON]?
        var customEntries: [RawEntry]?
        var enabled: Bool?
        var groupId: String?
        var personalMemory: String?
        var relationshipAttitudes: String?
    }

    /// 人物卡 JSON → 模型。memories 规范是对象数组，旧 iOS 存档的字符串
    /// 形态已在 `MemoryJSON` 里转成条目。
    private static func characterCard(from raw: CharacterJSON) -> CharacterCard {
        let entries = (raw.customEntries ?? []).map {
            CharacterCard.CustomEntry(
                id: $0.id ?? UUID().uuidString,
                title: $0.name ?? "",
                body: $0.content ?? ""
            )
        }
        let memories = (raw.memories ?? []).map {
            CharacterMemory(
                id: $0.id ?? UUID().uuidString,
                content: $0.content ?? "",
                evidence: $0.evidence ?? "",
                createdAt: $0.createdAt ?? 0
            )
        }
        return CharacterCard(
            id: raw.id ?? UUID().uuidString,
            name: raw.name ?? "",
            identity: raw.identity ?? "",
            personality: raw.personality ?? "",
            voice: raw.voice ?? "",
            goals: raw.goals ?? "",
            boundaries: raw.boundaries ?? "",
            aliases: raw.aliases ?? [],
            personalMemory: raw.personalMemory ?? "",
            relationshipAttitudes: raw.relationshipAttitudes ?? "",
            customEntries: entries,
            memories: memories,
            enabled: raw.enabled,
            groupId: raw.groupId
        )
    }

    /// 人物卡模型 → 存档 JSON。memories 按原版对象数组写；空字段沿用原版
    /// 「默认值不输出」的习惯，减少与真实备份的差异。
    private static func characterCardJSON(_ card: CharacterCard) -> [String: Any] {
        var json: [String: Any] = [
            "id": card.id,
            "name": card.name,
            "identity": card.identity,
            "personality": card.personality,
            "voice": card.voice,
            "goals": card.goals,
            "boundaries": card.boundaries,
            "aliases": card.aliases,
            "memories": (card.memories ?? []).map { memory in
                [
                    "id": memory.id,
                    "content": memory.content,
                    "evidence": memory.evidence,
                    "createdAt": memory.createdAt,
                ]
            },
            "enabled": card.enabled ?? true,
            "groupId": card.groupId ?? "",
            "customEntries": card.customEntries.map {
                ["id": $0.id, "name": $0.title, "content": $0.body]
            },
        ]
        if !card.personalMemory.isEmpty {
            json["personalMemory"] = card.personalMemory
        }
        if !card.relationshipAttitudes.isEmpty {
            json["relationshipAttitudes"] = card.relationshipAttitudes
        }
        return json
    }

    private static func characterDraftJSON(_ draft: CharacterDraft) -> [String: Any] {
        [
            "name": draft.name,
            "identity": draft.identity,
            "personality": draft.personality,
            "voice": draft.voice,
            "goals": draft.goals,
            "boundaries": draft.boundaries,
            "aliases": draft.aliases,
            "personalMemory": draft.personalMemory,
            "relationshipAttitudes": draft.relationshipAttitudes,
        ]
    }

    private struct WorldbookJSON: Decodable {
        var id: String?
        var title: String?
        var content: String?
        var enabled: Bool?
        var keywords: String?
    }

    private struct SummaryJSON: Decodable {
        var content: String?
        var sourceMessageKeys: [String]?
        var sourceHash: String?
        var enabled: Bool?
        var updatedAt: Int64?
        var rulesVersion: Int?
        var previousRevisions: [SummaryRevision]?
    }

    private struct SourceDocJSON: Decodable {
        var content: String?
    }

    private struct MessageJSON: Decodable {
        struct VersionJSON: Decodable {
            var id: String?
            var content: String?
            var createdAt: Int64?
        }
        var id: String?
        var kind: String?
        var title: String?
        var content: String?
        var versions: [VersionJSON]?
        var activeVersionId: String?
    }

    /// 世界分析断点（`characterAnalysisCheckpoint`）。原版按段记录完成状态，
    /// 正文没变时只补没做完的段。
    private struct AnalysisCheckpointJSON: Decodable {
        struct SegmentJSON: Decodable {
            var index: Int?
            var startCodePoint: Int?
            var endCodePoint: Int?
            var extractedFields: String?
        }
        var sourceSha256: String?
        var sourceCodePointCount: Int?
        var totalSegments: Int?
        var completedSegments: [SegmentJSON]?
        var mergedDraft: CharacterDraft?
        var mergedCards: [CharacterJSON]?
        var characterBaselineSha256: String?
        var worldMaterialSha256: String?
        var worldRefreshComplete: Bool?
    }

    /// 「提示词回看」的一条原始记录（`requestSnapshots[i]`）。
    private struct RequestSnapshotJSON: Decodable {
        struct MessageJSON: Decodable {
            var role: String?
            var content: String?
        }
        var id: String?
        var createdAt: Int64?
        var modelId: String?
        var sourceIds: [String]?
        var messages: [MessageJSON]?
        var estimatedInputTokens: Int?
        var inputBudgetTokens: Int?
        var modelContextWindowTokens: Int?
        var outputReserveTokens: Int?
        var omittedHistoryMessages: Int?
    }

    // MARK: 编解码


    /// 任意 JSON 的透传包装。
    struct AnyCodable: Codable {
        let raw: Any

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let v = try? single.decode([String: AnyCodable].self) {
                raw = v.mapValues(\.raw)
            } else if let v = try? single.decode([AnyCodable].self) {
                raw = v.map(\.raw)
            } else if let v = try? single.decode(String.self) {
                raw = v
            } else if let v = try? single.decode(Int.self) {
                raw = v
            } else if let v = try? single.decode(Double.self) {
                raw = v
            } else if let v = try? single.decode(Bool.self) {
                raw = v
            } else if single.decodeNil() {
                raw = NSNull()
            } else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "不支持的 JSON 值"
                )
            }
        }

        init(raw: Any) { self.raw = raw }

        func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch raw {
            case let v as [String: Any]:
                try single.encode(v.mapValues { AnyCodable(raw: $0) })
            case let v as [Any]:
                try single.encode(v.map { AnyCodable(raw: $0) })
            case let v as String:
                try single.encode(v)
            case let v as Int:
                try single.encode(v)
            case let v as Double:
                try single.encode(v)
            case let v as Bool:
                try single.encode(v)
            default:
                try single.encodeNil()
            }
        }
    }
    /// 全量存档载荷（`FullFrthinkBackupPayload`，`I1\S`）。
    ///
    /// `credentialSecrets` 故意不实现：API Key 只在系统钥匙串里，导出永远不带
    /// （原版界面文案就是「不含 API 信息」）。
    struct FullBackupPayload: Codable {
        var formatVersion: Int
        var createdAt: Int64
        var settings: AppSettings
        var projects: [ProjectBackup]
        /// 原版字段叫 `activeProjectId`；iOS 的当前书由根视图持有，导出时留空。
        var activeProjectID: String

        private enum CodingKeys: String, CodingKey {
            case formatVersion, createdAt, settings, projects
            case corpusLibrary
            case activeProjectID = "activeProjectId"
        }

        init(
            settings: AppSettings,
            projects: [ProjectBackup],
            activeProjectID: String = ""
        ) {
            self.formatVersion = FrthinkArchive.payloadVersion
            self.createdAt = FrthinkArchive.nowMillis
            self.settings = settings
            self.projects = projects
            self.activeProjectID = activeProjectID
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = (try? c.decode(Int.self, forKey: .formatVersion)) ?? 1
            createdAt = (try? c.decode(Int64.self, forKey: .createdAt)) ?? 0
            // settings / projects 是必填：原版的全量导入也接受
            // `writing-workspace-backup` 这个 format，书项目存档正好也叫这个，
            // 靠「有没有 settings」把两者分开，避免把本机设置清空。
            // 先按 iOS 自己的结构宽松解，再用原版的真实字段覆盖。
            // Android 的 StoredSettings 键名和 iOS 不同，这一步是能不能把
            // 全局预设 / 技能 / 世界书 / 语料库读进来的关键。
            var merged = (try? c.decode(AppSettings.self, forKey: .settings)) ?? AppSettings()
            if let extra = try? c.decode(SettingsExtra.self, forKey: .settings) {
                extra.apply(to: &merged)
            }
            // 真实备份的语料库不在 settings 里，而是和 projects 平级的
            // `corpusLibrary`（库 → 集合嵌套）。旧版本放在 settings 里，
            // 上面那条 `SettingsExtra` 已经兼容；这里读顶层，后者优先。
            if let topLevelCorpus = try? c.decode(
                SettingsExtra.CorpusLibraryJSON.self,
                forKey: .corpusLibrary
            ) {
                let libraries = topLevelCorpus.libraries()
                if !libraries.isEmpty {
                    merged.corpusLibraries = libraries
                    if libraries.contains(where: \.enabled) {
                        merged.corpusEnabled = true
                    }
                }
            }
            settings = merged
            projects = try c.decode([ProjectBackup].self, forKey: .projects)
            activeProjectID = (try? c.decode(String.self, forKey: .activeProjectID)) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(formatVersion, forKey: .formatVersion)
            try c.encode(createdAt, forKey: .createdAt)
            try c.encode(androidSettingsObject, forKey: .settings)
            try c.encode(projects, forKey: .projects)
            try c.encode(activeProjectID, forKey: .activeProjectID)
            if let corpus = androidCorpusNode {
                try c.encode(corpus, forKey: .corpusLibrary)
            }
        }

        /// 导出同时保留 iOS 键和 Android 读得懂的键；Android 忽略多余键。
        private var androidSettingsObject: AnyCodable {
            let data = (try? FrthinkArchive.jsonEncoder.encode(settings)) ?? Data()
            var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let provider = settings.activeProvider
            dict["globalPreset"] = settings.globalPreset
            dict["aiFlavorRules"] = settings.aiFlavorRules
            dict["worldBuildInstruction"] = settings.worldBuildInstruction
            dict["inputBudgetTokens"] = settings.inputBudgetTokens
            dict["outputBudgetTokens"] = settings.reservedOutputTokens
            dict["autoConversationSummary"] = settings.autoConversationSummary
            dict["conversationSummaryThresholdPercent"] =
                settings.conversationSummaryThresholdPercent
            dict["excludeAssistantChatHistory"] = settings.excludeAssistantChatHistory
            dict["primaryModel"] = provider?.resolvedModel ?? ""
            dict["writingModel"] = provider?.resolvedModel ?? ""
            dict["summaryModel"] = settings.summaryModel
            // 原版 `translationModel` 是模型名，不是 iOS 的供应方 id；跟随当前时留空。
            dict["translationModel"] = settings.providers
                .first { $0.id == settings.translationProviderID }?
                .resolvedModel ?? ""
            dict["baseUrl"] = provider?.baseURLForDisplay ?? ""
            dict["skills"] = settings.skills.map {
                [
                    "id": $0.id,
                    "name": $0.name,
                    "prompt": $0.content,
                    "enabled": $0.enabled,
                ]
            }
            dict["worldbooks"] = settings.universeEntries
                .filter { $0.kind == .worldbook }
                .map {
                    [
                        "id": $0.id,
                        "title": $0.title,
                        "keywords": "",
                        "content": $0.body,
                        "enabled": true,
                        "dynamic": false,
                    ]
                }
            return AnyCodable(raw: dict)
        }

        private var androidCorpusNode: AnyCodable? {
            guard !settings.corpusLibraries.isEmpty else { return nil }
            let node: [String: Any] = [
                "id": "ios-corpus",
                "name": "本机语料库",
                "enabled": settings.corpusEnabled,
                "collections": settings.corpusLibraries.map { library in
                    [
                        "id": library.id,
                        "name": library.name,
                        "enabled": library.enabled,
                        "entries": library.entries.map { entry in
                            [
                                "source": entry.source,
                                "title": entry.title,
                                "text": entry.text,
                                "category": entry.category,
                                "tags": entry.tags,
                            ]
                        },
                    ] as [String: Any]
                },
            ]
            return AnyCodable(raw: node)
        }
    }

    // MARK: - 原版 settings 的适配层

    /// Android `StoredSettings` 里 iOS 也需要的那部分字段。
    ///
    /// 键名以真实备份文件为准（2026-10-30 导出的全量备份）。只声明要映射的，
    /// 其余交给 Decodable 忽略。
    struct SettingsExtra: Decodable {
        struct SkillJSON: Decodable {
            var id: String?
            var name: String?
            /// 原版字段叫 `prompt`，iOS 叫 `content`。
            var prompt: String?
            var enabled: Bool?
        }
        struct WorldbookJSON: Decodable {
            var id: String?
            var title: String?
            var content: String?
            var enabled: Bool?
        }
        struct CorpusEntryJSON: Decodable {
            var source: String?
            var title: String?
            var text: String?
            var category: String?
            var tags: [String]?
        }
        /// 语料库。原版允许「库 → 集合 → 子集合」任意嵌套，iOS 侧平铺成
        /// 多个 `CorpusLibrary`，每一层有自己的名字和条目。
        struct CorpusLibraryJSON: Decodable {
            struct NodeJSON: Decodable {
                var id: String?
                var name: String?
                var enabled: Bool?
                var entries: [CorpusEntryJSON]?
                var collections: [NodeJSON]?
            }
            var id: String?
            var name: String?
            var enabled: Bool?
            var entries: [CorpusEntryJSON]?
            var collections: [NodeJSON]?

            /// 把嵌套结构压平成 iOS 的库列表；没有名字也没有条目的节点跳过。
            func libraries() -> [CorpusLibrary] {
                var result: [CorpusLibrary] = []
                append(
                    id: id,
                    name: name,
                    enabled: enabled ?? true,
                    entries: entries ?? [],
                    into: &result
                )
                for collection in collections ?? [] {
                    flatten(collection, into: &result)
                }
                return result
            }

            private func flatten(_ node: NodeJSON, into result: inout [CorpusLibrary]) {
                append(
                    id: node.id,
                    name: node.name,
                    enabled: node.enabled ?? true,
                    entries: node.entries ?? [],
                    into: &result
                )
                for child in node.collections ?? [] {
                    flatten(child, into: &result)
                }
            }

            private func append(
                id: String?,
                name: String?,
                enabled: Bool,
                entries rawEntries: [CorpusEntryJSON],
                into result: inout [CorpusLibrary]
            ) {
                let mapped = rawEntries.compactMap { raw -> CorpusEntry? in
                    guard let text = raw.text, !text.isEmpty else { return nil }
                    return CorpusEntry(
                        source: raw.source ?? "",
                        title: raw.title ?? "",
                        text: text,
                        category: raw.category ?? "",
                        tags: raw.tags ?? []
                    )
                }
                let trimmedName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty || !mapped.isEmpty else { return }
                result.append(
                    CorpusLibrary(
                        id: id.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
                        name: trimmedName.isEmpty ? "导入语料" : trimmedName,
                        entries: mapped,
                        enabled: enabled
                    )
                )
            }
        }

        var globalPreset: String?
        var aiFlavorRules: String?
        var worldBuildInstruction: String?
        var plotOutlineInstruction: String?
        var imitationInstruction: String?
        var skills: [SkillJSON]?
        var worldbooks: [WorldbookJSON]?
        var corpusLibrary: CorpusLibraryJSON?
        /// 原版 `inputBudgetTokens`（长上下文预算里的输入上限）。
        var inputBudgetTokens: Int?
        /// 原版 `outputBudgetTokens`（单次生成的最大输出）。
        var outputBudgetTokens: Int?
        var autoConversationSummary: Bool?
        var conversationSummaryThresholdPercent: Int?
        var excludeAssistantChatHistory: Bool?
        var summaryModel: String?

        func apply(to settings: inout AppSettings) {
            if let globalPreset, !globalPreset.isEmpty {
                settings.globalPreset = globalPreset
            }
            if let aiFlavorRules, !aiFlavorRules.isEmpty {
                settings.aiFlavorRules = aiFlavorRules
            }
            if let worldBuildInstruction, !worldBuildInstruction.isEmpty {
                settings.worldBuildInstruction = worldBuildInstruction
            }
            if let inputBudgetTokens, inputBudgetTokens > 0 {
                settings.inputBudgetTokens = min(max(inputBudgetTokens, 1024), 1_000_000)
            }
            if let outputBudgetTokens, outputBudgetTokens > 0 {
                settings.reservedOutputTokens = min(max(outputBudgetTokens, 1024), 100_000)
            }
            if let autoConversationSummary {
                settings.autoConversationSummary = autoConversationSummary
            }
            if let conversationSummaryThresholdPercent {
                settings.conversationSummaryThresholdPercent =
                    min(max(conversationSummaryThresholdPercent, 1), 100)
            }
            if let excludeAssistantChatHistory {
                settings.excludeAssistantChatHistory = excludeAssistantChatHistory
            }
            if let summaryModel {
                settings.summaryModel = summaryModel
            }
            if let skills, !skills.isEmpty {
                let mapped = skills.compactMap { raw -> Skill? in
                    guard let name = raw.name, !name.isEmpty else { return nil }
                    return Skill(
                        id: raw.id ?? UUID().uuidString,
                        name: name,
                        content: raw.prompt ?? "",
                        enabled: raw.enabled ?? true
                    )
                }
                if !mapped.isEmpty { settings.skills = mapped }
            }
            if let worldbooks, !worldbooks.isEmpty {
                settings.universeEntries = worldbooks.compactMap { raw in
                    guard let title = raw.title, !title.isEmpty else { return nil }
                    return UniverseEntry(
                        id: raw.id ?? UUID().uuidString,
                        title: title,
                        body: raw.content ?? "",
                        kind: .worldbook,
                        enabled: raw.enabled ?? true
                    )
                }
                // 全局启用状态已经落在条目的 `enabled` 上；项目勾选由
                // `enabledUniverseEntryIds` 单独导入，不能再拿它当全局闸门。
            }
            if let corpusLibrary {
                let libraries = corpusLibrary.libraries()
                if !libraries.isEmpty {
                    settings.corpusLibraries = libraries
                    if libraries.contains(where: \.enabled) {
                        settings.corpusEnabled = true
                    }
                }
            }
        }
    }

    // MARK: - 导出

    /// 组一个书项目存档（整份文件的 UTF-8 字节）。
    static func makeProjectArchive(_ backups: [ProjectBackup]) throws -> Data {
        try makeEnvelope(format: projectFormat, payload: ProjectArchivePayload(projects: backups))
    }

    /// 组一个全量存档。
    static func makeFullArchive(
        settings: AppSettings,
        projects: [ProjectBackup],
        activeProjectID: String = ""
    ) throws -> Data {
        let payload = FullBackupPayload(
            settings: settings,
            projects: projects,
            activeProjectID: activeProjectID
        )
        return try makeEnvelope(format: fullFormat, payload: payload)
    }

    /// JSON → gzip → base64 塞进信封。任何一步失败都按「无法创建存档」处理。
    private static func makeEnvelope<T: Encodable>(format: String, payload: T) throws -> Data {
        let json: Data
        do {
            json = try jsonEncoder.encode(payload)
        } catch {
            throw FrthinkArchiveError.createFailed
        }
        let compressed: Data
        do {
            compressed = try FrthinkGzip.compress(json)
        } catch {
            throw FrthinkArchiveError.createFailed
        }
        let envelope = Envelope(
            format: format,
            createdAt: nowMillis,
            payload: compressed.base64EncodedString()
        )
        do {
            return try jsonEncoder.encode(envelope)
        } catch {
            throw FrthinkArchiveError.createFailed
        }
    }

    /// 原版文件名：`frthink书项目-yyyy-MM-dd-HHmm.frthink` /
    /// `frthink备份-yyyy-MM-dd-HHmm.frthink`。
    static func filename(kind: Kind, at date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        let stamp = formatter.string(from: date)
        let prefix = kind.isFull ? "frthink备份" : "frthink书项目"
        return "\(prefix)-\(stamp).\(fileExtension)"
    }

    // MARK: - 导入

    /// 读书项目存档：解信封 → 解压 → 解载荷 → 语义校验。
    static func readProjectArchive(_ data: Data) throws -> ProjectArchivePayload {
        let json = try openEnvelope(data, kind: .project)
        let payload: ProjectArchivePayload
        do {
            payload = try jsonDecoder.decode(ProjectArchivePayload.self, from: json)
        } catch {
            throw FrthinkArchiveError.corruptedDetail(
                isFull: false,
                detail: decodeDetail(error)
            )
        }
        try validate(payload)
        return payload
    }

    /// 自动识别格式并用正确的读取器打开。
    ///
    /// 原版是两个导入入口（书项目存档 / 全量存档），格式白名单不同。用户拿到
    /// 一个 `chapleap-full-backup` 却点了书项目导入，只会得到「不是有效存档」——
    /// 那不是用户的错。这里先按格式判定，再分派。
    static func openAny(_ data: Data) throws -> FrthinkArchive.AnyArchive {
        let envelope = try? jsonDecoder.decode(Envelope.self, from: data)
        let looksFull = envelope.map { isAcceptedFormat($0.format, kind: .full) } ?? false
        let looksProject = envelope.map { isAcceptedFormat($0.format, kind: .project) } ?? false

        // 先按信封里的 format 走对应读取器；失败则记住它的错误，
        // 两个都失败时把最有信息量的那条抛出去——「不是有效文件」太笼统。
        var lastError: Error?
        if looksFull {
            do { return .full(try readFullBackup(data)) } catch { lastError = error }
        }
        if looksProject {
            do { return .projects(try readProjectArchive(data)) } catch { lastError = error }
        }
        do { return .full(try readFullBackup(data)) } catch { lastError = error }
        do { return .projects(try readProjectArchive(data)) } catch {
            // 书项目读取器的错误更具体时用它。
            if lastError == nil { lastError = error }
        }
        throw lastError ?? FrthinkArchiveError.notAnArchive(isFull: true)
    }

    /// `openAny` 的结果。
    enum AnyArchive {
        case full(FullBackupPayload)
        case projects(ProjectArchivePayload)

        var projects: [ProjectBackup] {
            switch self {
            case .full(let payload): return payload.projects
            case .projects(let payload): return payload.projects
            }
        }
    }

    /// 读全量存档。
    static func readFullBackup(_ data: Data) throws -> FullBackupPayload {
        let json = try openEnvelope(data, kind: .full)
        let payload: FullBackupPayload
        do {
            payload = try jsonDecoder.decode(FullBackupPayload.self, from: json)
        } catch DecodingError.keyNotFound(let key, _) where key.stringValue == "settings" {
            // 书项目存档的 format 也在全量白名单里，但它没有 settings：
            // 按「不是有效的全量 .frthink 文件」处理，别把本机设置清空。
            throw FrthinkArchiveError.notAnArchive(isFull: true)
        } catch {
            throw FrthinkArchiveError.corruptedDetail(
                isFull: true,
                detail: decodeDetail(error)
            )
        }
        try validate(payload)
        return payload
    }

    /// 校验顺序照抄原版（spec 03 §9.3）：大小 → JSON → format/version →
    /// compression → base64/gzip → 载荷。
    private static func openEnvelope(_ data: Data, kind: Kind) throws -> Data {
        // 1. 2 ≤ n ≤ 300 MiB。
        guard data.count >= 2 else { throw FrthinkArchiveError.emptyOrDamaged }
        guard data.count <= maxBytes else {
            throw FrthinkArchiveError.fileTooLarge(isFull: kind.isFull)
        }

        // 2. 整份文件当 JSON 信封读。
        let envelope: Envelope
        do {
            envelope = try jsonDecoder.decode(Envelope.self, from: data)
        } catch {
            throw FrthinkArchiveError.notAnArchive(isFull: kind.isFull)
        }

        // 3. format + version。
        guard envelope.version == envelopeVersion,
              isAcceptedFormat(envelope.format, kind: kind)
        else {
            throw FrthinkArchiveError.unsupportedFormat
        }

        // 4. 压缩标记。
        guard envelope.compression == compressionName else {
            throw FrthinkArchiveError.unsupportedCompression
        }

        // 5. base64 → gzip。Java 的 Base64 默认每 76 字符换行，用宽容模式解。
        guard let compressed = Data(
            base64Encoded: envelope.payload,
            options: .ignoreUnknownCharacters
        ) else {
            throw FrthinkArchiveError.corrupted(isFull: kind.isFull)
        }
        do {
            return try FrthinkGzip.decompress(compressed, maxOutputBytes: maxBytes)
        } catch FrthinkGzipError.outputLimitExceeded {
            throw FrthinkArchiveError.decompressedTooLarge
        } catch {
            throw FrthinkArchiveError.corrupted(isFull: kind.isFull)
        }
    }

    /// 原版的接受规则：
    /// - 书项目存档只认 `writing-workspace-backup`；
    /// - 全量存档认 `writing-workspace-backup`、`frthink-full-backup`，以及任何
    ///   以 `-full-backup` 结尾的 format（给后续版本留的兼容口）。
    static func isAcceptedFormat(_ format: String, kind: Kind) -> Bool {
        switch kind {
        case .project:
            return format == projectFormat
        case .full:
            return format == projectFormat
                || format == fullFormat
                || format.hasSuffix("-full-backup")
        }
    }

    // MARK: - 语义校验

    /// 书项目存档的语义校验（`I1\L0.b`）。
    static func validate(_ payload: ProjectArchivePayload) throws {
        guard payload.formatVersion == payloadVersion else {
            throw FrthinkArchiveError.projectVersionUnsupported
        }
        guard !payload.projects.isEmpty else {
            throw FrthinkArchiveError.emptyProjectArchive
        }
        try validateProjects(payload.projects, isFull: false)
    }

    /// 全量存档的语义校验（`I1\L0.a`）。
    static func validate(_ payload: FullBackupPayload) throws {
        guard payload.formatVersion == payloadVersion else {
            throw FrthinkArchiveError.payloadVersionUnsupported
        }
        try validateProjects(payload.projects, isFull: true)
    }

    private static func validateProjects(_ projects: [ProjectBackup], isFull: Bool) throws {
        var projectIDs = Set<String>()
        for backup in projects {
            guard backup.formatVersion == payloadVersion else {
                throw FrthinkArchiveError.projectVersionUnsupported
            }
            guard !backup.projectId.isEmpty else {
                throw FrthinkArchiveError.corrupted(isFull: isFull)
            }
            guard projectIDs.insert(backup.projectId).inserted else {
                throw FrthinkArchiveError.duplicateProjects(isFull: isFull)
            }
        }
        try validateTranslations(projects)
    }

    /// 译文分段的主键是 `(owner, project, target, segment)`。
    private static func validateTranslations(_ projects: [ProjectBackup]) throws {
        var keys = Set<String>()
        for backup in projects {
            for segment in backup.translations {
                let key = [
                    segment.owner,
                    segment.project,
                    segment.target,
                    String(segment.segment),
                ].joined(separator: "\u{1F}")
                guard keys.insert(key).inserted else {
                    throw FrthinkArchiveError.duplicateTranslations
                }
            }
        }
    }

    // MARK: - 落盘

    /// 把校验过的书项目写进 `FileStore`，返回真正落盘的 `Project`。
    ///
    /// 同 id 的项目被覆盖（「恢复存档」语义），其余项目不动——原版导入也不
    /// 清空现有数据。译文按本机 `ownerID` 重打归属：Android 的 `owner` 是设备/
    /// 账号标识，跨端带过来会触发「存档项目归属不匹配」。
    @discardableResult
    static func restore(
        _ backups: [ProjectBackup],
        into files: FileStore,
        ownerID: String
    ) throws -> [Project] {
        var restored: [Project] = []
        for backup in backups {
            let project = Project(
                id: backup.projectId,
                title: backup.title.isEmpty ? "未命名书项目" : backup.title,
                synopsis: backup.synopsis,
                updatedAt: Date(),
                revision: 0,
                coverImagePayload: backup.coverImageBase64.isEmpty
                    ? nil
                    : backup.coverImageBase64,
                branchRootId: backup.branchRootId,
                branchOrder: backup.branchOrder,
                trashedAt: backup.trashedAt > 0
                    ? Date(timeIntervalSince1970: TimeInterval(backup.trashedAt) / 1000)
                    : nil
            )

            var payload = backup.snapshot.projectPayload
            // 锚点是 UTF-16 偏移，存档来自别的版本时可能越界，直接丢掉。
            if let anchor = payload.continuationAnchor,
               anchor < 0 || anchor > payload.manuscript.utf16.count {
                payload.continuationAnchor = nil
            }
            // 原版存档不带 iOS 的章节索引（章节是扫出来的派生数据）。不补这一步，
            // 导入后写作台的章节条与阅读页目录都是空的，直到用户手动改一次正文。
            if payload.chapters.isEmpty, !payload.manuscript.isEmpty {
                payload.chapters = ChapterScanner.scan(payload.manuscript)
            }

            let translations = backup.translations.map { segment -> TranslationSegment in
                var copy = segment
                copy.owner = ownerID
                copy.project = project.id
                return copy
            }

            do {
                try files.saveProject(project)
                try files.savePayload(payload, projectID: project.id)
                // payload.json 里的正文只是兜底；正文实际由分页文件承载。
                // 覆盖导入时必须一并重写，否则旧 body.pages 会盖住新正文。
                try files.saveBody(
                    payload.manuscript,
                    chapters: payload.chapters,
                    projectID: project.id
                )
                try files.saveSource(backup.sourceText, projectID: project.id)
                try files.saveTranslations(translations, projectID: project.id)
            } catch {
                throw FrthinkArchiveError.writeFailed(error.localizedDescription)
            }
            restored.append(project)
        }
        return restored
    }

    /// 全量存档里的设置并进本机：整份替换，但保留本机身份（译文 `owner`）。
    ///
    /// API Key 不在存档里，所以替换设置不会丢 Key；供应方列表为空时保留本机的。
    static func mergeSettings(_ imported: AppSettings, into local: AppSettings) -> AppSettings {
        var result = imported
        result.ownerID = local.ownerID
        if result.providers.isEmpty {
            result.providers = local.providers
        }
        let activeID = result.activeProviderID
        if !result.providers.contains(where: { $0.id == activeID }) {
            result.activeProviderID = result.providers.first?.id ?? ""
        }
        return result
    }

    /// 存档里带的宇宙条目按 id 并入本机设置，已有条目不覆盖。
    static func mergedUniverseEntries(
        _ imported: [UniverseEntry],
        with existing: [UniverseEntry]
    ) -> [UniverseEntry] {
        var result = existing
        var ids = Set(existing.map { $0.id })
        for entry in imported where ids.insert(entry.id).inserted {
            result.append(entry)
        }
        return result
    }

    // MARK: - 编解码器

    /// 内部日期统一走 ISO8601，和 `FileStore` 落盘时一致。
    static var jsonEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }

    static var jsonDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 把 `DecodingError` 翻成能上屏的一句话：缺哪个键、哪个键类型不对。
    ///
    /// 导入失败最怕「备份内容损坏」四个字——用户没法据此行动。原版的
    /// `corruptedDetail` 就是为这个准备的，之前定义了却没接上调用点。
    static func decodeDetail(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return error.localizedDescription
        }
        func path(_ codingPath: [CodingKey], appending key: String? = nil) -> String {
            var keys = codingPath.map(\.stringValue)
            if let key { keys.append(key) }
            return keys.isEmpty ? "根 JSON" : keys.joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "缺少字段 \(path(context.codingPath, appending: key.stringValue))"
        case .typeMismatch(let type, let context):
            return "字段 \(path(context.codingPath)) 的类型不是 \(type)"
        case .valueNotFound(let type, let context):
            return "字段 \(path(context.codingPath)) 是 null，应为 \(type)"
        case .dataCorrupted(let context):
            return "\(path(context.codingPath)) 无法解析：\(context.debugDescription)"
        @unknown default:
            return decoding.localizedDescription
        }
    }
}
