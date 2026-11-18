import Foundation

/// 世界书词条激活模式（缺省按常驻处理以兼容旧存档）。
enum WorldbookActivationMode: String, Codable, Hashable {
    case constant
    case keyword
}

/// 项目自带的世界书词条（规格 D · P10）。
///
/// 词条标题对应提示词中的 `# <词条名>`，正文紧随下一行；仅启用的词条
/// 会随当前书稿的写作请求发送。与「宇宙」共享世界书的区别在于归属范围：此类词条仅归属于
/// 当前书项目（`WorldBook.worldbookEntries`）。
struct WorldbookEntry: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var body: String
    var enabled: Bool
    var updatedAt: Date
    /// 激活模式：nil 或 `.constant` 表示常驻，`.keyword` 表示命中关键词/递归触发后才注入。
    var activationMode: WorldbookActivationMode?
    /// 关键词触发词列表（支持别名、地名、物件名）。
    var keys: [String]?
    /// 优先级（数值越大越优先保留，缺省为 0）。
    var order: Int?

    init(
        id: String = UUID().uuidString,
        title: String,
        body: String = "",
        enabled: Bool = true,
        updatedAt: Date = Date(),
        activationMode: WorldbookActivationMode? = nil,
        keys: [String]? = nil,
        order: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.enabled = enabled
        self.updatedAt = updatedAt
        self.activationMode = activationMode
        self.keys = keys
        self.order = order
    }

    var resolvedActivationMode: WorldbookActivationMode {
        activationMode ?? .constant
    }

    var resolvedKeys: [String] {
        (keys ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// P10 · `# <词条名>\n<词条内容>`。
    ///
    /// 正文为空时整块不出现（规格 P10「无启用词条 → 0 块」的同一口径），
    /// 所以这里返回 nil，调用方直接 `compactMap` 即可。
    var promptBlock: String? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return PromptLibrary.render(PromptLibrary.worldbookBlockTemplate, [
            "词条名": title,
            "词条内容": body,
        ])
    }

    /// 列表里显示的一行摘要：去掉换行，限制长度。
    var summary: String {
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > 80 else { return collapsed }
        return String(collapsed.prefix(80)) + "…"
    }
}
