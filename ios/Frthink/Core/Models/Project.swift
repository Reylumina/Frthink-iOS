import Foundation

/// 书架上的一个书项目。
///
/// 字段与 Android 端 `projects` 表一一对应（`updatedAt`/`trashedAt` 在那边是
/// epoch 毫秒，这里用 `Date`，落盘走 ISO8601）。
struct Project: Identifiable, Codable, Hashable {
    /// 导入、新建或旧数据缺标题时统一显示的占位书名。
    static let untitledTitle = "未命名书项目"

    var id: String
    var title: String
    var synopsis: String
    var updatedAt: Date
    /// 乐观并发用的修订号，每次保存 +1。
    var revision: Int
    /// 封面图，base64 编码的 PNG。Android 端同名字段存的是同样的东西。
    var coverImagePayload: String?
    /// 分支（平行稿）归属：同一根的所有分支共享 `branchRootId`。
    var branchRootId: String
    var branchOrder: Int
    /// 非 nil 表示在回收站里。
    var trashedAt: Date?
    /// 正文字符数（正文懒加载时，书架和字数不依赖解密全文）。
    var bodyCharacterCount: Int?
    /// 正文 UTF-16 长度（光标、锚点边界用）。
    var bodyUTF16Length: Int?

    var isTrashed: Bool { trashedAt != nil }

    /// 封面身份种子：同一根的分支沿用母本的种子，书架上一本和它的平行稿
    /// 拿到同一组纸色与图标；没有分支归属时用它自己的 id。
    var coverSeed: String { branchRootId.isEmpty ? id : branchRootId }

    init(
        id: String = UUID().uuidString,
        title: String,
        synopsis: String = "",
        updatedAt: Date = Date(),
        revision: Int = 0,
        coverImagePayload: String? = nil,
        branchRootId: String = "",
        branchOrder: Int = 0,
        trashedAt: Date? = nil,
        bodyCharacterCount: Int? = nil,
        bodyUTF16Length: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.synopsis = synopsis
        self.updatedAt = updatedAt
        self.revision = revision
        self.coverImagePayload = coverImagePayload
        self.branchRootId = branchRootId.isEmpty ? id : branchRootId
        self.branchOrder = branchOrder
        self.trashedAt = trashedAt
        self.bodyCharacterCount = bodyCharacterCount
        self.bodyUTF16Length = bodyUTF16Length
    }
}

/// 「插入正文」的一次凭据，用于撤销（原版 `bodyAppendReceiptIds` /
/// `lastBodyAppendUndo`）。记下插入位置和插入的原文，撤销时按同样位置删掉。
struct BodyAppendReceipt: Identifiable, Codable, Hashable {
    var id: String
    /// 插入处的 UTF-16 偏移。
    var location: Int
    var text: String
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        location: Int,
        text: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.location = location
        self.text = text
        self.createdAt = createdAt
    }
}

/// 一次生成请求的快照（原版 `requestSnapshots` / `RequestSnapshot`）。
///
/// 「提示词回看」就是这个功能：每次生成都把当时发出去的真实 messages、
/// 估算 token、预算上限存下来，事后能查「模型到底看到了什么」。
struct RequestSnapshot: Identifiable, Codable, Hashable {
    var id: String
    var createdAt: Date
    var modelId: String
    /// 这次请求用了哪些块，例如 `preset:global`、`body:authoritative`。
    var sourceIds: [String]
    var messages: [LLMMessage]
    var estimatedInputTokens: Int
    var inputBudgetTokens: Int
    var modelContextWindowTokens: Int
    var outputReserveTokens: Int
    /// 为满足上下文预算限制而裁剪的历史消息条数。
    var omittedHistoryMessages: Int

    init(
        id: String = UUID().uuidString,
        createdAt: Date = Date(),
        modelId: String = "",
        sourceIds: [String] = [],
        messages: [LLMMessage] = [],
        estimatedInputTokens: Int = 0,
        inputBudgetTokens: Int = 0,
        modelContextWindowTokens: Int = 0,
        outputReserveTokens: Int = 0,
        omittedHistoryMessages: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.modelId = modelId
        self.sourceIds = sourceIds
        self.messages = messages
        self.estimatedInputTokens = estimatedInputTokens
        self.inputBudgetTokens = inputBudgetTokens
        self.modelContextWindowTokens = modelContextWindowTokens
        self.outputReserveTokens = outputReserveTokens
        self.omittedHistoryMessages = omittedHistoryMessages
    }
}

/// 一个章节标题在正文中的位置。正文本身是连续字符串，章节只是索引。
struct Chapter: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    /// 在 `ProjectPayload.manuscript` 中的 UTF-16 偏移。
    var location: Int

    init(id: String = UUID().uuidString, title: String, location: Int) {
        self.id = id
        self.title = title
        self.location = location
    }
}

/// 书项目的全部内容。对应 Android 端 `project_manuscripts` / `project_snapshots`
/// 里 `payload` 列存的 JSON。
///
/// 拆成 `payload.json` + `source.json` 两个文件，是因为原文（翻译源）和书稿的
/// 读写时机完全不同：原文只在导入和翻译时碰。
struct ProjectPayload: Codable {
    /// 结构版本。Android 端遇到不认识的值会报「书项目数据版本不受支持」。
    var schemaVersion: Int
    /// 正文。
    var manuscript: String
    var chapters: [Chapter]
    /// 码字机对话。
    var messages: [ChatMessage]
    /// 世界书（人物卡、事件卡、仿写模板、长期规则）。
    var world: WorldBook
    /// 当前选中的正文锚点：续写从这里之后开始。nil 表示从正文末尾续写。
    var continuationAnchor: Int?
    /// 续写时发送**整篇正文**还是只发末尾一段。原版 `bodyPromptSendWhole`。
    var bodyPromptSendWhole: Bool
    /// 只发末尾时取多少个码点。原版 `bodyPromptTailCodePoints`，实测默认 5000。
    var bodyPromptTailCodePoints: Int

    /// 新建书与存档导入共用的默认值，避免两处写死不同数字。
    static let defaultBodyPromptTailCodePoints = 5_000
    /// 阅读页滚动位置（UTF-16 偏移）。
    var readerOffset: Int
    /// 阅读书签位置。
    var readerBookmarkOffset: Int
    /// 这本书启用了哪些宇宙条目。原版 `enabledUniverseEntryIds`。
    var enabledUniverseEntryIDs: [String]
    /// 输入框里没发出去的草稿。原版 `composerDraft`。
    var composerDraft: String
    /// 已删除消息的墓碑 id。对齐原版 `deletedChatMessageIds`：用于防止
    /// 重新导入或同步时已删除的消息被恢复。
    var deletedChatMessageIDs: [String]
    /// 历史请求快照。原版 `requestSnapshots`：每次生成都把**当时发出去的
    /// 完整 messages 和 token 预算**存一份，用于「提示词回看」。
    var requestSnapshots: [RequestSnapshot]
    /// 「插入正文」的凭据栈，用于撤销。
    var bodyAppendReceipts: [BodyAppendReceipt]
    /// 上一次撤销掉的凭据（原版 `lastBodyAppendUndo`）。
    var lastBodyAppendUndo: BodyAppendReceipt?
    /// 正在流式生成的消息 id。应用进程异常终止后，下次启动据此将消息标记为中断状态。
    /// iOS 本地状态，不参与原版存档导出。
    var generatingMessageID: String?
    /// 已经中断的消息 id 列表。同样是 iOS 本地状态。
    var interruptedMessageIDs: [String]?
    /// 本书写作助手补充指令（P02）。项目级；空串时整块不出现。
    var assistantSupplement: String

    init(
        schemaVersion: Int = 1,
        manuscript: String = "",
        chapters: [Chapter] = [],
        messages: [ChatMessage] = [],
        world: WorldBook = WorldBook(),
        continuationAnchor: Int? = nil,
        assistantSupplement: String = "",
        bodyPromptSendWhole: Bool = false,
        bodyPromptTailCodePoints: Int = ProjectPayload.defaultBodyPromptTailCodePoints,
        readerOffset: Int = 0,
        readerBookmarkOffset: Int = 0,
        enabledUniverseEntryIDs: [String] = [],
        composerDraft: String = "",
        deletedChatMessageIDs: [String] = [],
        requestSnapshots: [RequestSnapshot] = [],
        bodyAppendReceipts: [BodyAppendReceipt] = [],
        lastBodyAppendUndo: BodyAppendReceipt? = nil,
        generatingMessageID: String? = nil,
        interruptedMessageIDs: [String]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.manuscript = manuscript
        self.chapters = chapters
        self.messages = messages
        self.world = world
        self.continuationAnchor = continuationAnchor
        self.assistantSupplement = assistantSupplement
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
        self.generatingMessageID = generatingMessageID
        self.interruptedMessageIDs = interruptedMessageIDs
    }

    /// 兼容早期存档：可选字段缺失时按默认值回填，避免整本书解码失败。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = (try? c.decode(Int.self, forKey: .schemaVersion)) ?? 1
        manuscript = (try? c.decode(String.self, forKey: .manuscript)) ?? ""
        chapters = (try? c.decode([Chapter].self, forKey: .chapters)) ?? []
        messages = (try? c.decode([ChatMessage].self, forKey: .messages)) ?? []
        world = (try? c.decode(WorldBook.self, forKey: .world)) ?? WorldBook()
        continuationAnchor = try? c.decodeIfPresent(Int.self, forKey: .continuationAnchor)
        assistantSupplement = (try? c.decode(String.self, forKey: .assistantSupplement)) ?? ""
        bodyPromptSendWhole = (try? c.decode(Bool.self, forKey: .bodyPromptSendWhole)) ?? false
        bodyPromptTailCodePoints =
            (try? c.decode(Int.self, forKey: .bodyPromptTailCodePoints))
                ?? ProjectPayload.defaultBodyPromptTailCodePoints
        readerOffset = (try? c.decode(Int.self, forKey: .readerOffset)) ?? 0
        readerBookmarkOffset = (try? c.decode(Int.self, forKey: .readerBookmarkOffset)) ?? 0
        enabledUniverseEntryIDs =
            (try? c.decode([String].self, forKey: .enabledUniverseEntryIDs)) ?? []
        composerDraft = (try? c.decode(String.self, forKey: .composerDraft)) ?? ""
        deletedChatMessageIDs =
            (try? c.decode([String].self, forKey: .deletedChatMessageIDs)) ?? []
        requestSnapshots =
            (try? c.decode([RequestSnapshot].self, forKey: .requestSnapshots)) ?? []
        bodyAppendReceipts =
            (try? c.decode([BodyAppendReceipt].self, forKey: .bodyAppendReceipts)) ?? []
        lastBodyAppendUndo =
            try? c.decodeIfPresent(BodyAppendReceipt.self, forKey: .lastBodyAppendUndo)
        generatingMessageID =
            try? c.decodeIfPresent(String.self, forKey: .generatingMessageID)
        interruptedMessageIDs =
            try? c.decodeIfPresent([String].self, forKey: .interruptedMessageIDs)
    }

    /// 上次进程在生成过程中异常终止：将 `generatingMessageID` 转换为中断标记。
    /// 返回被标记的消息 id；没有未完成的生成时返回 nil。
    @discardableResult
    mutating func recoverInterruptedGeneration() -> String? {
        guard let id = generatingMessageID else { return nil }
        generatingMessageID = nil
        var ids = interruptedMessageIDs ?? []
        if !ids.contains(id) { ids.append(id) }
        interruptedMessageIDs = ids
        return id
    }
}
