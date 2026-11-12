// 语料库管理：新建 / 重命名 / 启用 / 删除多个语料库，并切换当前库。

import SwiftUI

struct CorpusLibraryManagerSheet: View {
    let store: AppStore
    @Binding var activeLibraryID: String?

    @Environment(\.dismiss) private var dismiss

    @State private var nameAction: CorpusLibraryNameAction?
    @State private var pendingDelete: CorpusLibrary?

    private var libraries: [CorpusLibrary] {
        store.settings.corpusLibraries
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if libraries.isEmpty {
                        InlineEmptyState(
                            symbol: "books.vertical",
                            message: "还没有语料库",
                            actionTitle: "新建语料库"
                        ) {
                            nameAction = .create
                        }
                    } else {
                        ForEach(libraries) { library in
                            row(library)
                        }
                    }
                } header: {
                    AppSectionHeader(title: "语料库（\(libraries.count)）")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .groupedPageBackground()
            .navigationTitle("语料库管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        nameAction = .create
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新建语料库")
                }
            }
            .navigationDestination(item: $nameAction) { action in
                switch action {
                case .create:
                    CorpusLibraryNameEditor(
                        heading: "新建语料库",
                        initialName: defaultLibraryName
                    ) { name in
                        create(name)
                    }
                case .rename(let library):
                    CorpusLibraryNameEditor(
                        heading: "重命名语料库",
                        initialName: library.name
                    ) { name in
                        rename(library, to: name)
                    }
                }
            }
            .alert(deleteAlertTitle, isPresented: deleteAlertBinding) {
                Button("取消", role: .cancel) { pendingDelete = nil }
                Button("删除", role: .destructive) {
                    if let library = pendingDelete { delete(library) }
                    pendingDelete = nil
                }
            }
        }
        .sheetToast()
    }

    // MARK: - 行

    private func row(_ library: CorpusLibrary) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            Button {
                activeLibraryID = library.id
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(library.name)
                            .font(Font.body.weight(.medium))
                            .foregroundStyle(.primary)
                        if library.id == currentLibraryID {
                            StatusPill(text: "当前")
                        }
                    }
                    Text("\(library.entries.count) 条" + (library.enabled ? " · 已启用" : " · 未启用"))
                        .font(Font.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: enabledBinding(library))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("启用「\(library.name)」")

            Menu {
                Button {
                    nameAction = .rename(library)
                } label: {
                    Label("重命名", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    pendingDelete = library
                } label: {
                    Label("删除", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(Font.body)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = library
            } label: {
                Label("删除", systemImage: "trash")
            }
            Button {
                nameAction = .rename(library)
            } label: {
                Label("重命名", systemImage: "square.and.pencil")
            }
            .tint(Theme.accent)
        }
    }

    private var currentLibraryID: String? {
        activeLibraryID ?? libraries.first?.id
    }

    private var defaultLibraryName: String {
        "语料库 \(libraries.count + 1)"
    }

    // MARK: - 动作

    private func enabledBinding(_ library: CorpusLibrary) -> Binding<Bool> {
        Binding(
            get: { library.enabled },
            set: { enabled in
                var updated = library
                updated.enabled = enabled
                save(updated)
            }
        )
    }

    private func create(_ name: String) {
        let library = CorpusLibrary(name: name)
        var list = store.settings.corpusLibraries
        list.append(library)
        store.settings.corpusLibraries = list
        activeLibraryID = library.id
        store.saveSettings()
        store.toast = "已新建语料库：\(name)"
    }

    private func rename(_ library: CorpusLibrary, to name: String) {
        var updated = library
        updated.name = name
        save(updated)
        store.toast = "已重命名语料库"
    }

    private func delete(_ library: CorpusLibrary) {
        store.settings.corpusLibraries.removeAll { $0.id == library.id }
        if activeLibraryID == library.id {
            activeLibraryID = store.settings.corpusLibraries.first?.id
        }
        store.saveSettings()
        store.toast = "已删除语料库"
    }

    private func save(_ library: CorpusLibrary) {
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
        guard let library = pendingDelete else { return "删除语料库？" }
        return "删除「\(library.name)」？"
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private enum CorpusLibraryNameAction: Hashable {
        case create
        case rename(CorpusLibrary)
    }
}

/// 语料库名称输入页。新建和重命名共用，在管理器自己的导航栈里推进来。
struct CorpusLibraryNameEditor: View {
    let heading: String
    let initialName: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(heading: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.heading = heading
        self.initialName = initialName
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                AppTextField(
                    title: "名称",
                    text: $name,
                    placeholder: "环境描写素材"
                )
            }
        }
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .keyboardDismissOnScroll()
        .navigationTitle(heading)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    onSave(trimmedName)
                    dismiss()
                }
                .disabled(trimmedName.isEmpty)
            }
        }
    }
}
