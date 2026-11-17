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

    @ViewBuilder
    private var librariesSectionContent: some View {
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
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    librariesSectionContent
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
                    SheetCloseButton(title: "关闭") { dismiss() }
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
                Button("删除", role: .destructive) {
                    if let library = pendingDelete { delete(library) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
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
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(library.name)
                            .font(Theme.label)
                            .foregroundStyle(.primary)
                        if library.id == currentLibraryID {
                            StatusPill(text: "当前", tone: .accent)
                        }
                    }
                    HStack(spacing: Theme.Spacing.s) {
                        Text("\(library.entries.count) 条")
                            .font(Theme.metadata)
                            .foregroundStyle(.secondary)
                        StatusPill(
                            text: library.enabled ? "已启用" : "已停用",
                            tone: library.enabled ? .neutral : .warning
                        )
                    }
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
                    .font(Theme.label)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: Theme.Layout.hitTarget, minHeight: Theme.Layout.hitTarget)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多操作")
        }
        .frame(minHeight: Theme.Layout.hitTarget)
        .themeAnimation(Theme.motionSelection, value: library.enabled)
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

/// 语料库名称输入页：新建与重命名共用，在管理器自身导航栈中推入展示。
struct CorpusLibraryNameEditor: View {
    let heading: String
    let initialName: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var saved = false

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
                SheetConfirmButton(title: "保存", isEnabled: !trimmedName.isEmpty) {
                    onSave(trimmedName)
                    saved = true
                    dismiss()
                }
            }
        }
        .onDisappear {
            // 当前页面仅提供保存操作：左滑返回时保存重命名结果，防止修改丢失。
            guard !saved, !trimmedName.isEmpty, trimmedName != initialName else { return }
            onSave(trimmedName)
        }
    }
}
