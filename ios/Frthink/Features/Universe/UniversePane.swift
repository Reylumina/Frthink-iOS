// 宇宙面板：跨项目共享的全局预设、共享世界书与技能配置。
// 数据归属于全局层级，独立于特定书籍项目，各书按需配置启用范围。

import SwiftUI

struct UniversePane: View {
    let store: AppStore
    /// 当前项目会话：若提供则修改项目内 enabledUniverseEntryIDs，缺省时作用于全局开关。
    var session: ProjectSession? = nil

    @State private var isCreating = false
    @State private var draftTitle = ""
    @State private var draftBody = ""
    @State private var draftKind: UniverseEntry.Kind = .worldbook
    @State private var pendingDelete: UniverseEntry?
    @State private var confirmingDiscardDraft = false

    private var entries: [UniverseEntry] {
        store.settings.universeEntries.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var trimmedDraftTitle: String {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasDraftChanges: Bool {
        !trimmedDraftTitle.isEmpty || !draftBody.isEmpty
    }

    var body: some View {
        Group {
            if entries.isEmpty {
                EmptyStateView(
                    symbol: AppDestination.universe.symbol,
                    title: "还没有宇宙资料",
                    actionTitle: "新建宇宙资料",
                    action: startCreating
                )
            } else {
                list
            }
        }
        // 占满可用空间，使缺省空状态视图保持居中展示。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .groupedPageBackground()
        .settingsFormColumn()
        .navigationDestination(for: UniverseEntry.self) { entry in
            editor(for: entry)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    startCreating()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建宇宙资料")
            }
        }
        .sheet(isPresented: $isCreating) {
            creationSheet
        }
        .alert(deleteAlertTitle, isPresented: deleteBinding) {
            Button("删除", role: .destructive) {
                if let entry = pendingDelete { delete(entry) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    private var deleteAlertTitle: String {
        let title = pendingDelete?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? "删除此资料？" : "删除「\(title)」？"
    }

    // MARK: - 列表

    /// 按类型归类的分组列表，于计算属性中统一构建，避免在 body 内重复运算。
    private var sections: [UniverseSectionGroup] {
        UniverseEntry.Kind.allCases.compactMap { kind in
            let group = entries.filter { $0.kind == kind }
            return group.isEmpty ? nil : UniverseSectionGroup(kind: kind, entries: group)
        }
    }

    private var list: some View {
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.entries) { entry in
                        row(entry)
                    }
                } header: {
                    AppSectionHeader(title: section.kind.displayName)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func row(_ entry: UniverseEntry) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            Toggle("", isOn: Binding(
                get: { isEnabled(entry) },
                set: { on in toggle(entry, on: on) }
            ))
            .labelsHidden()
            .controlSize(.small)
            .accessibilityLabel("本书启用「\(entry.title)」")

            NavigationLink(value: entry) {
                entryLabel(entry)
            }
        }
        .frame(minHeight: Theme.Layout.rowContentHeight)
        .themeAnimation(Theme.motionSelection, value: entry.enabled)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = entry
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func entryLabel(_ entry: UniverseEntry) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xs) {
                Text(entry.title)
                    .font(Theme.label)
                if !entry.enabled {
                    StatusPill(text: "已停用", tone: .warning)
                }
            }
            if !entry.body.isEmpty {
                Text(entry.body)
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - 编辑

    private func editor(for entry: UniverseEntry) -> some View {
        UniverseEntryEditor(entry: entry) { updated in
            upsert(updated)
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var creationSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    UniverseEntryFields(
                        kind: $draftKind,
                        title: $draftTitle,
                        bodyText: $draftBody
                    )
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
            }
            .pageBackground()
            .keyboardDismissOnScroll()
            .navigationTitle("新建宇宙资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton {
                        if hasDraftChanges {
                            confirmingDiscardDraft = true
                        } else {
                            isCreating = false
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton(
                        title: "保存",
                        isEnabled: !trimmedDraftTitle.isEmpty
                    ) {
                        guard !trimmedDraftTitle.isEmpty else { return }
                        upsert(UniverseEntry(title: trimmedDraftTitle, body: draftBody, kind: draftKind))
                        isCreating = false
                    }
                }
            }
            .discardChangesDialog(isPresented: $confirmingDiscardDraft, hasChanges: hasDraftChanges) {
                isCreating = false
            }
        }
    }

    // MARK: - 动作

    private func startCreating() {
        draftTitle = ""
        draftBody = ""
        draftKind = .worldbook
        isCreating = true
    }

    private func upsert(_ entry: UniverseEntry) {
        var list = store.settings.universeEntries
        if let index = list.firstIndex(where: { $0.id == entry.id }) {
            var updated = entry
            updated.updatedAt = Date()
            list[index] = updated
            store.settings.universeEntries = list
            store.saveSettings()
            store.toast = "已保存"
        } else {
            list.append(entry)
            store.settings.universeEntries = list
            store.saveSettings()
            store.toast = "已新建「\(entry.title)」"
        }
    }

    private func delete(_ entry: UniverseEntry) {
        store.settings.universeEntries.removeAll { $0.id == entry.id }
        store.settings.enabledUniverseEntryIDs.removeAll { $0 == entry.id }
        if let session {
            session.payload.enabledUniverseEntryIDs.removeAll { $0 == entry.id }
            session.scheduleSave()
        }
        store.saveSettings()
        store.toast = "已删除"
    }

    private func isEnabled(_ entry: UniverseEntry) -> Bool {
        if let session {
            return session.payload.enabledUniverseEntryIDs.contains(entry.id)
        }
        return store.settings.enabledUniverseEntryIDs.contains(entry.id)
    }

    private func toggle(_ entry: UniverseEntry, on: Bool) {
        if let session {
            var ids = session.payload.enabledUniverseEntryIDs
            if on {
                if !ids.contains(entry.id) { ids.append(entry.id) }
            } else {
                ids.removeAll { $0 == entry.id }
            }
            session.payload.enabledUniverseEntryIDs = ids
            session.scheduleSave()
            return
        }
        var ids = store.settings.enabledUniverseEntryIDs
        if on {
            if !ids.contains(entry.id) { ids.append(entry.id) }
        } else {
            ids.removeAll { $0 == entry.id }
        }
        store.settings.enabledUniverseEntryIDs = ids
        store.saveSettings()
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }
}

/// 宇宙资料编辑视图：支持编辑标题、内容与所属分类。
private struct UniverseEntryEditor: View {
    let entry: UniverseEntry
    let onSave: (UniverseEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: String
    @State private var kind: UniverseEntry.Kind
    @State private var enabled: Bool
    @State private var saved = false

    init(entry: UniverseEntry, onSave: @escaping (UniverseEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _title = State(initialValue: entry.title)
        _bodyText = State(initialValue: entry.body)
        _kind = State(initialValue: entry.kind)
        _enabled = State(initialValue: entry.enabled)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        trimmedTitle != entry.title
            || bodyText != entry.body
            || kind != entry.kind
            || enabled != entry.enabled
    }

    private func save() {
        guard !trimmedTitle.isEmpty else { return }
        var updated = entry
        updated.title = trimmedTitle
        updated.body = bodyText
        updated.kind = kind
        updated.enabled = enabled
        onSave(updated)
        saved = true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                UniverseEntryFields(
                    kind: $kind,
                    title: $title,
                    bodyText: $bodyText
                )
                Toggle("全局启用", isOn: $enabled)
                    .padding(.horizontal, Theme.Spacing.m)
                    .padding(.vertical, Theme.Spacing.s)
                    .background(
                        Theme.field,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    )
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
        }
        .pageBackground()
        .keyboardDismissOnScroll()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SheetConfirmButton(title: "保存", isEnabled: !trimmedTitle.isEmpty) {
                    save()
                    dismiss()
                }
            }
        }        .onDisappear {
            // 返回上一级时自动保存未落盘的有效改动。
            guard !saved, hasChanges, !trimmedTitle.isEmpty else { return }
            save()
        }
    }
}

private struct UniverseSectionGroup: Identifiable {
    let kind: UniverseEntry.Kind
    let entries: [UniverseEntry]

    var id: UniverseEntry.Kind { kind }
}

/// 新建与编辑共用的字段区：类型、标题、内容。
private struct UniverseEntryFields: View {
    @Binding var kind: UniverseEntry.Kind
    @Binding var title: String
    @Binding var bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                AppSectionHeader(title: "类型")
                Picker("类型", selection: $kind) {
                    ForEach(UniverseEntry.Kind.allCases) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            }

            AppTextField(
                title: "标题",
                text: $title,
                placeholder: "通用叙事视角约定"
            )

            AppTextArea(
                title: "内容",
                text: $bodyText,
                placeholder: "内容",
                minLines: 6,
                maxLines: 12
            )
        }
    }
}
