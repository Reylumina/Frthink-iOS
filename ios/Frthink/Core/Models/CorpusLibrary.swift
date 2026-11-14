import Foundation

/// 语料收集库（规格 01 §8）。
///
/// 原版 `CorpusLibrary` 的字段是 `id, name, enabled, collections, revision,
/// rules, entries, processedKeys, deletedTextKeys, classifiedKeys`，并且库可以
/// 嵌套集合；iOS 这里只保留一层，多库靠 `AppSettings.corpusLibraries` 平铺。
///
/// 条目复用 `CorpusEntry`（`World.swift`），不在这里重复定义。
struct CorpusLibrary: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var entries: [CorpusEntry]
    var enabled: Bool
    var createdAt: Date
    /// 语料提取规则提示词与已处理去重键（对齐 Android `CorpusLibrary`）。
    var rules: String
    var processedKeys: [String]
    var deletedTextKeys: [String]
    var classifiedKeys: [String]

    init(
        id: String = UUID().uuidString,
        name: String,
        entries: [CorpusEntry] = [],
        enabled: Bool = true,
        createdAt: Date = Date(),
        rules: String = "",
        processedKeys: [String] = [],
        deletedTextKeys: [String] = [],
        classifiedKeys: [String] = []
    ) {
        self.id = id
        self.name = name
        self.entries = entries
        self.enabled = enabled
        self.createdAt = createdAt
        self.rules = rules
        self.processedKeys = processedKeys
        self.deletedTextKeys = deletedTextKeys
        self.classifiedKeys = classifiedKeys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        entries = (try? c.decode([CorpusEntry].self, forKey: .entries)) ?? []
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        rules = (try? c.decode(String.self, forKey: .rules)) ?? ""
        processedKeys = (try? c.decode([String].self, forKey: .processedKeys)) ?? []
        deletedTextKeys = (try? c.decode([String].self, forKey: .deletedTextKeys)) ?? []
        classifiedKeys = (try? c.decode([String].self, forKey: .classifiedKeys)) ?? []
    }

    /// 本次会进入提示词的条目：库启用、原句非空，按 0.8.213 全量注入（无 10 条上限）。
    var promptEntries: [CorpusEntry] {
        guard enabled else { return [] }
        return entries.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// 本库的一条条目渲染成 P09 块。
    func promptBlock(for entry: CorpusEntry) -> String {
        PromptLibrary.render(PromptLibrary.corpusEntryBlockTemplate, [
            "语料库名": name,
            "条目名": entry.title,
            "分类": entry.category,
            "原句": entry.text,
        ])
    }

    /// 提示词里的块键：`corpus:<库ID>:<条目ID>`。
    func promptKey(for entry: CorpusEntry) -> String {
        "corpus:\(id):\(entry.id)"
    }
}

extension CorpusEntry {
    /// 关键词搜索的合并文本：标题 / 原句 / 分类 / 标签。
    ///
    /// 原版对这四个字段建 FTS4 派生索引（`CREATE VIRTUAL TABLE corpus USING
    /// fts4(id, tokens, notindexed=id, tokenize=simple)`），iOS 没有 SQLite 依赖，
    /// 用同一份字段集合做内存过滤，语义保持一致。
    var searchableText: String {
        ([title, text, category, tags.joined(separator: " ")]).joined(separator: "\n")
    }

    /// 列表摘要：折叠换行，避免一条语料把列表撑开。
    var summary: String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed
    }
}

/// 语料搜索条件。原版用 FTS4 的 `tokens MATCH ?`；这里把关键词按空白拆词，
/// 每个词都要在「标题 / 原句 / 分类 / 标签」里命中（AND），分类与标签是精确筛选。
struct CorpusQuery: Equatable {
    var keyword: String = ""
    var category: String?
    var tag: String?

    /// 搜索词。空关键词 → 不需要关键词过滤。
    var tokens: [String] {
        Self.tokens(in: keyword)
    }

    var isActive: Bool {
        !tokens.isEmpty || category != nil || tag != nil
    }

    static func tokens(in keyword: String) -> [String] {
        keyword
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// 预先处理关键词后再统一执行批量过滤，避免对每条语料重复执行 split 与 lowercase 操作。
    func filtered(_ entries: [CorpusEntry]) -> [CorpusEntry] {
        let words = tokens.map { $0.lowercased() }
        return entries.filter { entry in
            if let category, entry.category != category { return false }
            if let tag, !entry.tags.contains(tag) { return false }
            guard !words.isEmpty else { return true }
            let haystack = entry.searchableText.lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}
