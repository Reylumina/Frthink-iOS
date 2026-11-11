// 提示词集成管理器：技能、全局预设、去 AI 味规则、项目补充指令四类可编辑指令。
//
// 预览直接走 `PromptComposer`，和真正发出去的内容一致。

import SwiftUI

struct PromptManagerPane: View {
    let store: AppStore
    let session: ProjectSession?

    @State private var activeSheet: PromptManagerSheet?
    @State private var pendingDelete: Skill?
    @State private var pickedProjectID: String?
    /// 从设置页进来时没有现成会话；在 `.task` 里按所选书项目异步打开，不在 body 里读盘。
    @State private var resolvedSession: ProjectSession?
    @State private var saveTask: Task<Void, Never>?

    init(store: AppStore, session: ProjectSession? = nil) {
        self.store = store
        self.session = session
    }

    private var skills: [Skill] {
        store.settings.skills
    }

    private var enabledSkillCount: Int {
        skills.filter(\.enabled).count
    }

    private var previewBlocks: [PromptBlock] {
        PromptIntegration.blocks(
            projectID: resolvedSession?.project.id ?? "",
            assistantSupplement: resolvedSession?.payload.assistantSupplement ?? "",
            globalPreset: store.settings.globalPreset,
            skills: skills,
            aiFlavorRules: store.settings.aiFlavorRules
        )
    }

    var body: some View {
        List {
            skillsSection
            globalPresetSection
            flavorRulesSection
            projectSupplementSection
            previewSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .keyboardDismissOnScroll()
        .navigationTitle("提示词集成管理器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    activeSheet = .newSkill
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建技能")
            }
        }
        .onAppear {
            if pickedProjectID == nil, session == nil {
                pickedProjectID = store.activeProjects.first?.id
            }
        }
        .task(id: pickedProjectID) {
            await loadResolvedSession()
        }
        .onDisappear {
            saveTask?.cancel()
            store.saveSettings()
            resolvedSession?.scheduleSave()
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .newSkill:
                PromptSkillEditor(
                    skill: Skill(name: ""),
                    isNew: true,
                    onSave: { skill in
                        upsert(skill)
                    }
                )
            case .edit(let skill):
                PromptSkillEditor(
                    skill: skill,
                    isNew: false,
                    onSave: { updated in
                        upsert(updated)
                    },
                    onDelete: {
                        delete(skill)
                    }
                )
            case .preview:
                PromptBlocksPreviewSheet(blocks: previewBlocks)
            }
        }
        .alert(deleteAlertTitle, isPresented: deleteAlertBinding) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("删除", role: .destructive) {
                if let skill = pendingDelete { delete(skill) }
                pendingDelete = nil
            }
        }
    }

    // MARK: - 技能

    private var skillsSection: some View {
        Section {
            if skills.isEmpty {
                InlineEmptyState(
                    symbol: "text.badge.plus",
                    message: "还没有技能",
                    actionTitle: "新建技能"
                ) {
                    activeSheet = .newSkill
                }
            } else {
                ForEach(skills) { skill in
                    skillRow(skill)
                }
            }
        } header: {
            AppSectionHeader(title: "技能")
        }
    }

    private func skillRow(_ skill: Skill) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            Toggle("", isOn: skillEnabledBinding(skill))
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("启用「\(skill.name)」")

            Button {
                activeSheet = .edit(skill)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(skill.name.isEmpty ? "未命名技能" : skill.name)
                        .font(Font.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(skill.content.isEmpty ? "未填写" : collapsed(skill.content))
                        .font(Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDelete = skill
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func collapsed(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    // MARK: - 全局预设

    private var globalPresetSection: some View {
        Section {
            AppTextArea(
                title: "预设正文",
                text: globalPresetBinding,
                placeholder: "预设内容",
                minLines: 5,
                maxLines: 10
            )
        } header: {
            AppSectionHeader(title: "全局预设")
        }
    }

    // MARK: - 去 AI 味规则

    private var flavorRulesSection: some View {
        Section {
            AppTextArea(
                title: "规则正文",
                text: aiFlavorRulesBinding,
                placeholder: "写作规则",
                minLines: 5,
                maxLines: 10
            )
            Button("填入示例") {
                store.settings.aiFlavorRules = "减少模板化转折、空泛总结和机械分段；只修改未锁定正文。"
                scheduleSettingsSave()
            }
            .font(Font.footnote)
        } header: {
            AppSectionHeader(title: "去 AI 味规则")
        }
    }

    // MARK: - 项目补充指令

    private var projectSupplementSection: some View {
        Section {
            if session == nil {
                if store.activeProjects.isEmpty {
                    InlineEmptyState(
                        symbol: "books.vertical",
                        message: "还没有书项目"
                    )
                } else {
                    projectPickerRow
                }
            }

            if let resolved = resolvedSession {
                PromptProjectSupplementFields(session: resolved)
            } else if session == nil, !store.activeProjects.isEmpty {
                AppStatusLine(kind: .progress, text: "正在打开书稿…")
            }
        } header: {
            AppSectionHeader(title: "项目补充指令")
        }
    }

    private var projectPickerRow: some View {
        Menu {
            ForEach(store.activeProjects) { project in
                Button {
                    pickedProjectID = project.id
                } label: {
                    if project.id == pickedProjectID {
                        Label(project.title, systemImage: "checkmark")
                    } else {
                        Text(project.title)
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Text("书项目")
                    .font(Font.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: Theme.Spacing.s)
                Text(pickedProjectTitle)
                    .font(Font.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .frame(minHeight: 36)
        }
    }

    private var pickedProjectTitle: String {
        guard let id = pickedProjectID,
              let project = store.activeProjects.first(where: { $0.id == id })
        else { return "选择书项目" }
        return project.title
    }

    // MARK: - 预览

    private var previewSection: some View {
        Section {
            Button {
                activeSheet = .preview
            } label: {
                HStack(spacing: Theme.Spacing.m) {
                    IconTile(symbol: "doc.text.magnifyingglass")
                    Text("查看最终提示词")
                        .font(Font.body)
                        .foregroundStyle(.primary)
                    Spacer(minLength: Theme.Spacing.s)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .frame(minHeight: 36)
            }
            .buttonStyle(.plain)
        } header: {
            AppSectionHeader(title: "最终提示词预览")
        }
    }

    // MARK: - 加载与保存

    @MainActor
    private func loadResolvedSession() async {
        if let session {
            resolvedSession = session
            return
        }
        guard let id = pickedProjectID,
              let project = store.activeProjects.first(where: { $0.id == id })
        else {
            resolvedSession = nil
            return
        }
        if let cached = store.cachedSession(for: id) {
            resolvedSession = cached
            return
        }
        resolvedSession = nil
        let loaded = await store.openSessionAsync(for: project)
        guard !Task.isCancelled, pickedProjectID == id else { return }
        resolvedSession = loaded
    }

    private var globalPresetBinding: Binding<String> {
        Binding(
            get: { store.settings.globalPreset },
            set: { text in
                store.settings.globalPreset = text
                scheduleSettingsSave()
            }
        )
    }

    private var aiFlavorRulesBinding: Binding<String> {
        Binding(
            get: { store.settings.aiFlavorRules },
            set: { text in
                store.settings.aiFlavorRules = text
                scheduleSettingsSave()
            }
        )
    }

    /// 文本编辑不做逐字落盘，停手 0.6 秒后再写设置文件。
    private func scheduleSettingsSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            store.saveSettings()
        }
    }

    private func skillEnabledBinding(_ skill: Skill) -> Binding<Bool> {
        Binding(
            get: { skill.enabled },
            set: { enabled in
                var list = store.settings.skills
                guard let index = list.firstIndex(where: { $0.id == skill.id }) else { return }
                list[index].enabled = enabled
                store.settings.skills = list
                store.saveSettings()
            }
        )
    }

    private func upsert(_ skill: Skill) {
        var updated = skill
        updated.name = skill.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = store.settings.skills
        if let index = list.firstIndex(where: { $0.id == skill.id }) {
            list[index] = updated
        } else {
            list.append(updated)
        }
        store.settings.skills = list
        store.saveSettings()
    }

    private func delete(_ skill: Skill) {
        store.settings.skills.removeAll { $0.id == skill.id }
        store.saveSettings()
        store.toast = "已删除技能"
    }

    private var deleteAlertTitle: String {
        let name = pendingDelete?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "删除这个技能？" : "删除「\(name)」？"
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private enum PromptManagerSheet: Identifiable {
        case newSkill
        case edit(Skill)
        case preview

        var id: String {
            switch self {
            case .newSkill: return "new"
            case .edit(let skill): return skill.id
            case .preview: return "preview"
            }
        }
    }
}

/// 本书写作助手补充指令的编辑区。拆出来是因为它绑在 `ProjectSession` 上。
private struct PromptProjectSupplementFields: View {
    let session: ProjectSession

    private var binding: Binding<String> {
        Binding(
            get: { session.payload.assistantSupplement },
            set: { text in
                session.payload.assistantSupplement = text
                session.scheduleSave()
            }
        )
    }

    var body: some View {
        AppTextArea(
            title: "补充指令",
            text: binding,
            placeholder: "补充指令",
            minLines: 5,
            maxLines: 10
        )
    }
}
