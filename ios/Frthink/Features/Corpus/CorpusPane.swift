// 「语料收集库」面板：多库管理、条目增删改、分类 / 标签筛选与关键词搜索。
//
// 语料在提示词里只作为「可选表达参考」出现（规格 D · P09），不会当成书里
// 已经发生的事实；每条原句要求逐字复制自原文。
//
// 总开关只在「设置 → 提示词与资料」里维护，这一页不重复放同一个开关。

import SwiftUI

struct CorpusPane: View {
    let store: AppStore
    let onPick: (CorpusEntry) -> Void

    @State private var activeLibraryID: String?
    @State private var query = CorpusQuery()
    @State private var activeSheet: CorpusSheet?
    @State private var pendingDelete: CorpusEntry?
    @State private var highlightCache = CorpusHighlightCache()
    /// 分类 / 标签候选集只在当前库的条目变化时重算，不跟每次 body 求值。
    @State private var categories: [String] = []
    @State private var tags: [String] = []

    init(store: AppStore, onPick: @escaping (CorpusEntry) -> Void) {
        self.store = store
        self.onPick = onPick
    }

    private var libraries: [CorpusLibrary] {
        store.settings.corpusLibraries
    }

    private var activeLibrary: CorpusLibrary? {
        if let id = activeLibraryID,
           let library = libraries.first(where: { $0.id == id }) {
            return library
        }
        return libraries.first
    }

    private var activeEntries: [CorpusEntry] {
        activeLibrary?.entries ?? []
    }

    var body: some View {
        let filtered = query.filtered(activeEntries)
        let tokens = query.tokens
        List {
            librarySection
            if !libraries.isEmpty, !activeEntries.isEmpty {
                filterSection(matched: filtered.count)
            }
            contentSection(filtered, tokens: tokens)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .searchable(
            text: $query.keyword,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索"
        )
        .keyboardDismissOnScroll()
        .settingsFormColumn()
        .navigationTitle("语料收集库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    activeSheet = .newEntry
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新增语料")
                .disabled(activeLibrary == nil)
            }
        }
        .onChange(of: activeLibrary, initial: true) { _, library in
            rebuildFilterOptions(for: library)
        }
        .onDisappear {
            store.saveSettings()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .newEntry:
                CorpusEntryEditor(
                    entry: CorpusEntry(source: "手动录入", title: "", text: ""),
                    isNew: true
                ) { entry in
                    upsert(entry)
                }
            case .edit(let entry):
                CorpusEntryEditor(
                    entry: entry,
                    isNew: false
                ) { updated in
                    upsert(updated)
                }
            case .libraryManager:
                CorpusLibraryManagerSheet(store: store, activeLibraryID: $activeLibraryID)
            }
        }
        .confirmationDialog(deleteAlertTitle, isPresented: deleteAlertBinding, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let entry = pendingDelete { delete(entry) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    // MARK: - 语料库

    private var librarySection: some View {
        Section {
            Menu {
                ForEach(libraries) { library in
                    Button {
                        select(library)
                    } label: {
                        if library.id == activeLibrary?.id {
                            Label(library.name, systemImage: "checkmark")
                        } else {
                            Text(library.name)
                        }
                    }
                }
                if !libraries.isEmpty { Divider() }
                Button {
                    activeSheet = .libraryManager
                } label: {
                    Label("管理语料库…", systemImage: "slider.horizontal.3")
                }
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    SettingsLabelRow(
                        title: activeLibrary?.name ?? "还没有语料库",
                        symbol: "books.vertical",
                        detail: activeLibrary.map { "\($0.entries.count) 条" }
                    )
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }

            if let library = activeLibrary {
                Toggle(isOn: libraryEnabledBinding(library)) {
                    Text("启用")
                }
                .controlSize(.small)
                .accessibilityLabel("启用「\(library.name)」")
            }
        } header: {
            AppSectionHeader(title: "语料库")
        }
    }

    // MARK: - 搜索与筛选

    private func filterSection(matched: Int) -> some View {
        Section {
            categoryFilterRow
            tagFilterRow
            if query.isActive {
                Button("清除筛选") {
                    query = CorpusQuery()
                }
            }
        } header: {
            AppSectionHeader(title: "筛选")
        } footer: {
            Text("命中 \(matched) 条 / 共 \(activeEntries.count) 条")
        }
    }

    private var categoryFilterRow: some View {
        CorpusFilterMenuRow(
            title: "分类",
            symbol: "square.grid.2x2",
            allTitle: "全部分类",
            optionPrefix: "",
            options: categories,
            selection: $query.category
        )
    }

    private var tagFilterRow: some View {
        CorpusFilterMenuRow(
            title: "标签",
            symbol: "tag",
            allTitle: "全部标签",
            optionPrefix: "#",
            options: tags,
            selection: $query.tag
        )
    }

    // MARK: - 列表

    @ViewBuilder
    private func contentSection(_ filtered: [CorpusEntry], tokens: [String]) -> some View {
        if libraries.isEmpty {
            Section {
                InlineEmptyState(
                    symbol: "books.vertical",
                    message: "还没有语料库",
                    actionTitle: "管理语料库"
                ) {
                    activeSheet = .libraryManager
                }
            }
        } else if activeEntries.isEmpty {
            Section {
                InlineEmptyState(
                    symbol: "text.quote",
                    message: "这个语料库还没有语料",
                    actionTitle: "新增语料"
                ) {
                    activeSheet = .newEntry
                }
            }
        } else if filtered.isEmpty {
            Section {
                InlineEmptyState(
                    symbol: "magnifyingglass",
                    message: "没有匹配的语料",
                    actionTitle: "清除筛选"
                ) {
                    query = CorpusQuery()
                }
            }
        } else {
            Section {
                ForEach(filtered) { entry in
                    row(entry, tokens: tokens)
                }
            }
        }
    }

    private func row(_ entry: CorpusEntry, tokens: [String]) -> some View {
        CorpusEntryRow(
            entry: entry,
            highlighted: highlightCache.highlight(entry: entry, tokens: tokens),
            onEdit: { activeSheet = .edit(entry) },
            onPick: { onPick(entry) },
            onDelete: { pendingDelete = entry }
        )
    }

    // MARK: - 动作

    private func select(_ library: CorpusLibrary) {
        activeLibraryID = library.id
        query = CorpusQuery()
    }

    private func rebuildFilterOptions(for library: CorpusLibrary?) {
        let entries = library?.entries ?? []

        var seenCategories = Set<String>()
        var nextCategories: [String] = []
        for entry in entries where !entry.category.isEmpty {
            if seenCategories.insert(entry.category).inserted {
                nextCategories.append(entry.category)
            }
        }
        categories = nextCategories.sorted()

        var seenTags = Set<String>()
        var nextTags: [String] = []
        for entry in entries {
            for tag in entry.tags where !tag.isEmpty {
                if seenTags.insert(tag).inserted {
                    nextTags.append(tag)
                }
            }
        }
        tags = nextTags.sorted()
    }

    private func libraryEnabledBinding(_ library: CorpusLibrary) -> Binding<Bool> {
        Binding(
            get: { library.enabled },
            set: { enabled in
                var updated = library
                updated.enabled = enabled
                saveLibrary(updated)
            }
        )
    }

    private func upsert(_ entry: CorpusEntry) {
        guard let library = activeLibrary else { return }
        var updatedLibrary = library
        if let index = updatedLibrary.entries.firstIndex(where: { $0.id == entry.id }) {
            updatedLibrary.entries[index] = entry
        } else {
            updatedLibrary.entries.append(entry)
        }
        saveLibrary(updatedLibrary)
    }

    private func delete(_ entry: CorpusEntry) {
        guard let library = activeLibrary else { return }
        var updatedLibrary = library
        updatedLibrary.entries.removeAll { $0.id == entry.id }
        saveLibrary(updatedLibrary)
    }

    private func saveLibrary(_ library: CorpusLibrary) {
        var list = store.settings.corpusLibraries
        if let index = list.firstIndex(where: { $0.id == library.id }) {
            list[index] = library
        } else {
            list.append(library)
        }
        store.settings.corpusLibraries = list
        store.saveSettings()
    }

    private var deleteAlertTitle: String {
        let title = pendingDelete?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "删除这条语料？" : "删除「\(title)」？"
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    /// 新增条目、编辑条目、语料库管理共用一个 sheet。
    private enum CorpusSheet: Identifiable {
        case newEntry
        case edit(CorpusEntry)
        case libraryManager

        var id: String {
            switch self {
            case .newEntry: return "new"
            case .edit(let entry): return entry.id
            case .libraryManager: return "libraries"
            }
        }
    }
}

// MARK: - 筛选行

/// 分类 / 标签共用的一行：下拉里选一个值，再选同一个值就取消。
///
/// 两处原本是两份几乎相同的 Menu，只有标题、图标与「#」前缀不同；合并后
/// 选中态的勾选、清空回退和主题色的规则只留一份。
private struct CorpusFilterMenuRow: View {
    let title: String
    let symbol: String
    let allTitle: String
    let optionPrefix: String
    let options: [String]
    @Binding var selection: String?

    private var displayValue: String {
        selection.map { optionPrefix + $0 } ?? allTitle
    }

    var body: some View {
        Menu {
            Button(allTitle) { selection = nil }
            ForEach(options, id: \.self) { option in
                Button {
                    selection = selection == option ? nil : option
                } label: {
                    if selection == option {
                        Label(optionPrefix + option, systemImage: "checkmark")
                    } else {
                        Text(optionPrefix + option)
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                Label(title, systemImage: symbol)
                    .font(Theme.label)
                    .foregroundStyle(.primary)
                Spacer(minLength: Theme.Spacing.s)
                Text(displayValue)
                    .font(Theme.label)
                    .foregroundStyle(selection == nil ? Color.secondary : Theme.accent)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .frame(minHeight: Theme.Layout.hitTarget)
        }
    }
}

// MARK: - 行内容

/// 一条语料的完整行：点按编辑，右滑取用 / 删除，长按菜单给出同样的三个动作。
private struct CorpusEntryRow: View {
    let entry: CorpusEntry
    let highlighted: CorpusRowHighlight
    let onEdit: () -> Void
    let onPick: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button {
            onEdit()
        } label: {
            CorpusRowContent(entry: entry, highlighted: highlighted)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                onPick()
            } label: {
                Label("取用", systemImage: "plus.circle")
            }
            .tint(Theme.accent)
        }
        .contextMenu {
            Button {
                onPick()
            } label: {
                Label("取用", systemImage: "plus.circle")
            }
            Button {
                onEdit()
            } label: {
                Label("编辑", systemImage: "square.and.pencil")
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

/// 单条语料的展示。高亮文本只在条目或搜索词变化时重算，滚动重绘直接复用。
private struct CorpusRowContent: View {
    let entry: CorpusEntry
    let highlighted: CorpusRowHighlight

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(highlighted.title)
                .font(Theme.label)
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: Theme.Spacing.s) {
                if !entry.category.isEmpty {
                    Text(highlighted.category)
                        .font(Theme.badge)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, Theme.Spacing.s)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Capsule().fill(Theme.accentSoft))
                }
                if !entry.source.isEmpty {
                    Text("来源 \(entry.source)")
                        .font(Theme.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            if !entry.text.isEmpty {
                Text(highlighted.body)
                    .font(Theme.reply)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !highlighted.tags.isEmpty {
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(highlighted.tags) { pill in
                        Text(pill.text)
                            .font(Theme.badge)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.Spacing.s)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(
                                Capsule().fill(pill.matched ? Theme.accentSoft : Theme.field)
                            )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func highlight(_ entry: CorpusEntry, tokens: [String]) -> CorpusRowHighlight {
        CorpusRowHighlight(
            title: CorpusHighlight.attributed(
                entry.title.isEmpty ? "未命名语料" : entry.title,
                tokens: tokens
            ),
            category: CorpusHighlight.attributed(entry.category, tokens: tokens),
            body: CorpusHighlight.attributed(entry.text, tokens: tokens),
            tags: tagPills(for: entry.tags, tokens: tokens)
        )
    }

    /// 每条标签一个 pill。id 用「标签 + 出现序号」：导入的旧数据可能带重复标签，
    /// 序号保证 ForEach 的 id 仍然唯一；序号总带着，避免「a#1」这种标签名
    /// 和标签 a 的第二次出现撞上同一个 id。
    private static func tagPills(for tags: [String], tokens: [String]) -> [CorpusTagPill] {
        var occurrences: [String: Int] = [:]
        return tags.prefix(5).map { tag in
            let occurrence = occurrences[tag, default: 0]
            occurrences[tag] = occurrence + 1
            return CorpusTagPill(
                id: "\(tag)#\(occurrence)",
                text: CorpusHighlight.attributed("#" + tag, tokens: tokens),
                matched: CorpusHighlight.containsMatch(tag, tokens: tokens)
            )
        }
    }
}

private struct CorpusTagPill: Identifiable {
    let id: String
    let text: AttributedString
    let matched: Bool
}

private struct CorpusRowHighlight {
    let title: AttributedString
    let category: AttributedString
    let body: AttributedString
    let tags: [CorpusTagPill]
}

/// 行高亮缓存。父视图每次求值都会新建行值类型，渲染结果放在缓存里，
/// 只有条目内容或关键词变化才重新扫描。
private final class CorpusHighlightCache {
    private struct Entry {
        let signature: String
        let value: CorpusRowHighlight
    }

    private var values: [String: Entry] = [:]

    func highlight(entry: CorpusEntry, tokens: [String]) -> CorpusRowHighlight {
        let signature = [
            tokens.joined(separator: "\u{1F}"),
            String(entry.title.count),
            String(entry.text.count),
            String(entry.category.count),
            entry.tags.joined(separator: "\u{1F}"),
        ].joined(separator: "|")
        if let cached = values[entry.id], cached.signature == signature {
            return cached.value
        }
        let value = CorpusRowContent.highlight(entry, tokens: tokens)
        values[entry.id] = Entry(signature: signature, value: value)
        if values.count > 2_000 {
            values.removeAll(keepingCapacity: true)
        }
        return value
    }
}
