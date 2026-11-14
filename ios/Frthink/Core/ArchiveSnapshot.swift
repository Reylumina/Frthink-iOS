import Foundation

extension FrthinkArchive {
    /// 存档里的书项目快照。字段名对齐 Android 真实的 `ProjectSnapshot`（54 个键，
    /// `schemaVersion = 20`）。
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
        /// 项目级补充指令（P02）。若未包含该字段，存档往返将导致配置丢失。
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
            bodyPromptTailCodePoints: Int = ProjectPayload.defaultBodyPromptTailCodePoints,
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
        continuationAnchor =
            (try? c.decodeIfPresent(Int.self, forKey: .continuationAnchorOffset))
            ?? (try? c.decodeIfPresent(Int.self, forKey: .continuationAnchor))
        assistantSupplement =
            (try? c.decode(String.self, forKey: .assistantSupplement))
            ?? (try? c.decode(String.self, forKey: .projectAssistantPrompt))
            ?? ""
        bodyPromptSendWhole =
            (try? c.decode(Bool.self, forKey: .bodyPromptSendWhole)) ?? false
        bodyPromptTailCodePoints =
            (try? c.decode(Int.self, forKey: .bodyPromptTailCodePoints))
                ?? ProjectPayload.defaultBodyPromptTailCodePoints
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

        // 事件卡：同时兼容 `world.plotEvents`（结构化对象）与 `world.events`（纯标题列表），
        // 优先取结构化事件卡。
        let events: [EventCard] = {
            let plotEvents = (worldJSON?.plotEvents ?? []).compactMap { raw -> EventCard? in
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
            if !plotEvents.isEmpty { return plotEvents }
            // 老存档只有标题，按标题还原成最小事件卡，至少不丢剧情节点。
            return EventCard.fromLegacyTitles((worldJSON?.events ?? []).map(\.title))
        }()

        let groups: [CharacterGroup] = {
            // Android 把 characterGroups 放在 snapshot 顶层；旧 iOS 存档写在 world 里，
            // 两处都读，顶层优先。
            let topLevel = (try? c.decode([GroupJSON].self, forKey: .characterGroups)) ?? []
            let source = topLevel.isEmpty ? (worldJSON?.characterGroups ?? []) : topLevel
            return source.compactMap { raw in
                guard let name = raw.name, !name.isEmpty else { return nil }
                return CharacterGroup(
                    id: raw.id ?? UUID().uuidString,
                    name: name,
                    enabled: raw.enabled ?? true
                )
            }
        }()

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
        try c.encodeIfPresent(continuationAnchor, forKey: .continuationAnchorOffset)
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

        let books = world.worldbookEntries.map {
            FrthinkArchive.androidWorldbookJSON(id: $0.id, title: $0.title, content: $0.body, enabled: $0.enabled)
        }
        try encodeAny(books, key: .worldbooks, into: &c)

        let groupJSON: [[String: Any]] = world.characterGroups.map { group in
            ["id": group.id, "name": group.name, "enabled": group.enabled]
        }
        let worldDict: [String: Any] = [
            "currentState": world.currentState,
            "plotOutline": world.plotOutline,
            "imitationTemplate": world.styleTemplate,
            // iOS 私有键：文风笔记是用户可编辑数据，原版没有对应字段。
            "styleNotes": world.styleNotes,
            "characters": FrthinkArchive.characterLines(for: world),
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
            "characterGroups": groupJSON,
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

        // Android 在 snapshot 顶层读 characterGroups；world 里的那份留给旧 iOS 存档。
        try encodeAny(groupJSON, key: .characterGroups, into: &c)

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

        // 世界分析断点：原版按分段保存，用于刷新断点续跑与世界刷新历史回溯。
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

    private func encodeAny(
        _ value: Any,
        key: SnapshotKeys,
        into container: inout KeyedEncodingContainer<SnapshotKeys>
    ) throws {
        try container.encode(AnyCodable(raw: value), forKey: key)
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
        case continuationAnchorOffset
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
        case characterGroups
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
        /// Android 结构化事件卡（`world.plotEvents`）。
        var plotEvents: [PlotEventJSON]?
        /// `world.events` 列表（通常为纯标题字符串，兼容对象形态）。
        struct LegacyEvent: Decodable {
            var title: String

            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                if let text = try? single.decode(String.self) {
                    title = text
                    return
                }
                struct Object: Decodable { var title: String? }
                title = (try? single.decode(Object.self))?.title ?? ""
            }
        }
        var events: [LegacyEvent]?
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

    /// Android `List<WorldbookEntry>` 形状的共享世界书。

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
    /// 导出给 Android 的 `world.characters`。
    ///
    /// 用当前人物卡现算「姓名 · 身份」：改名、新建或合并之后，导入时存下的
    /// `characterSummaries` 会和卡片对不上。只有一张卡都没有时才回落到快照。
    static func characterLines(for world: WorldBook) -> [String] {
        let lines: [String] = world.characters.map { card in
            let identity = card.identity.trimmingCharacters(in: .whitespacesAndNewlines)
            return identity.isEmpty ? card.name : "\(card.name) · \(identity)"
        }
        return lines.isEmpty ? world.characterSummaries : lines
    }

    static func androidWorldbookJSON(
        id: String,
        title: String,
        content: String,
        enabled: Bool
    ) -> [String: Any] {
        [
            "id": id,
            "title": title,
            "keywords": "",
            "content": content,
            "enabled": enabled,
            "dynamic": false,
        ]
    }

    private static func characterCardJSON(_ card: CharacterCard) -> [String: Any] {        var json: [String: Any] = [
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

}
