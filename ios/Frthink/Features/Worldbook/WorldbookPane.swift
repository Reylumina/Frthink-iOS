// 「世界书」面板：当前书项目的世界书词条（规格 D · P10）。
//
// 词条标题就是提示词里的标题行；只有启用的词条随本书的写作请求发送。

import SwiftUI

struct WorldbookPane: View {
    let session: ProjectSession

    @State private var activeSheet: WorldbookSheet?
    @State private var pendingDelete: WorldbookEntry?

    init(session: ProjectSession) {
        self.session = session
    }

    private var entries: [WorldbookEntry] {
        session.payload.world.worldbookEntries
    }

    private var enabledEntries: [WorldbookEntry] {
        entries.filter { $0.enabled && $0.promptBlock != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .onDisappear {
            session.scheduleSave()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .newEntry:
                WorldbookEntryEditor(entry: WorldbookEntry(title: ""), isNew: true) { updated in
                    upsert(updated)
                }
            case .edit(let entry):
                WorldbookEntryEditor(entry: entry, isNew: false) { updated in
                    upsert(updated)
                }
            case .preview:
                WorldbookPromptPreviewSheet(entries: entries)
            }
        }
        .alert("删除这条世界书词条？", isPresented: deleteAlertBinding) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let entry = pendingDelete { delete(entry) }
                pendingDelete = nil
            }
        }
    }

    // MARK: - 头部

    /// 一行就够：启用计数 + 预览 + 新建。列表尽量早出现。
    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text("\(enabledEntries.count) / \(entries.count) 已启用")
                .font(Font.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: Theme.Spacing.s)

            Button {
                activeSheet = .preview
            } label: {
                Label("预览", systemImage: "doc.text.magnifyingglass")
                    .font(Font.footnote)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
            .disabled(entries.isEmpty)

            Button {
                activeSheet = .newEntry
            } label: {
                Label("新建", systemImage: "plus")
                    .font(Font.footnote.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Theme.accent)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
    }

    // MARK: - 列表

    private var list: some View {
        List {
            Section {
                ForEach(entries) { entry in
                    WorldbookRow(
                        entry: entry,
                        enabled: Binding(
                            get: { entry.enabled },
                            set: { setEnabled(entry, $0) }
                        ),
                        onEdit: { activeSheet = .edit(entry) },
                        onDelete: { pendingDelete = entry }
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
    }

    // MARK: - 行

    /// 列表行只依赖词条本身；开关、编辑、删除都交回面板处理。
    private struct WorldbookRow: View {
        let entry: WorldbookEntry
        let enabled: Binding<Bool>
        let onEdit: () -> Void
        let onDelete: () -> Void

        var body: some View {
            HStack(alignment: .center, spacing: Theme.Spacing.m) {
                Toggle("", isOn: enabled)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel(entry.title.isEmpty ? "启用未命名词条" : "启用 \(entry.title)")

                Button {
                    onEdit()
                } label: {
                    HStack(alignment: .top, spacing: Theme.Spacing.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title.isEmpty ? "未命名词条" : entry.title)
                                .font(Font.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            if !entry.summary.isEmpty {
                                Text(entry.summary)
                                    .font(Font.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text("更新于 \(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(Font.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(Font.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .padding(.top, Theme.Spacing.xs)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, Theme.Spacing.xs)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除", systemImage: "trash")
                }
                Button {
                    onEdit()
                } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }
                .tint(Theme.accent)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label("当前项目还没有世界书", systemImage: "character.book.closed")
        } description: {
            Text("添加设定后，只保存在这本书中。")
        } actions: {
            Button("新建词条") { activeSheet = .newEntry }
                .buttonStyle(.bordered)
        }
    }

    // MARK: - 动作

    private func setEnabled(_ entry: WorldbookEntry, _ enabled: Bool) {
        var list = entries
        guard let index = list.firstIndex(where: { $0.id == entry.id }) else { return }
        list[index].enabled = enabled
        list[index].updatedAt = Date()
        session.payload.world.worldbookEntries = list
        session.scheduleSave()
    }

    private func upsert(_ entry: WorldbookEntry) {
        var list = entries
        var updated = entry
        updated.title = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.updatedAt = Date()
        if let index = list.firstIndex(where: { $0.id == entry.id }) {
            list[index] = updated
        } else {
            list.append(updated)
        }
        session.payload.world.worldbookEntries = list
        session.scheduleSave()
    }

    private func delete(_ entry: WorldbookEntry) {
        var list = entries
        list.removeAll { $0.id == entry.id }
        session.payload.world.worldbookEntries = list
        session.scheduleSave()
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    /// 新建、编辑、预览共用一个 sheet，避免同一个视图上挂多个 `.sheet`。
    private enum WorldbookSheet: Identifiable {
        case newEntry
        case edit(WorldbookEntry)
        case preview

        var id: String {
            switch self {
            case .newEntry: return "new"
            case .edit(let entry): return entry.id
            case .preview: return "preview"
            }
        }
    }
}

/// 世界书词条块预览：把启用词条的提示词块原样列出来。
struct WorldbookPromptPreviewSheet: View {
    let entries: [WorldbookEntry]

    @Environment(\.dismiss) private var dismiss

    private var renderedEntries: [WorldbookEntry] {
        entries.filter { $0.enabled && $0.promptBlock != nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if renderedEntries.isEmpty {
                    EmptyStateView(
                        symbol: "text.book.closed",
                        title: "没有启用的词条"
                    )
                } else {
                    List {
                        Section {
                            ForEach(renderedEntries) { entry in
                                Text(entry.promptBlock ?? "")
                                    .font(Theme.numeric)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } header: {
                            AppSectionHeader(title: "提示词块")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .groupedPageBackground()
            .navigationTitle("提示词块预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
