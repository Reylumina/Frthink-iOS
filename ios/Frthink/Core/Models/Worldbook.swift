import Foundation

/// 项目自带的世界书词条（规格 D · P10）。
///
/// 词条标题就是提示词里的 `# <词条名>`，正文原样跟在下一行；只有启用的词条
/// 会随本书的写作请求发送。和「宇宙」共享世界书的区别是归属：这些词条只属于
/// 当前书项目（`WorldBook.worldbookEntries`）。
struct WorldbookEntry: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var body: String
    var enabled: Bool
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        body: String = "",
        enabled: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.enabled = enabled
        self.updatedAt = updatedAt
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
