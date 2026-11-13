// 提示词集成管理器：技能、全局预设、去 AI 味规则、项目补充指令四类可编辑指令。
//
// 列表只做入口与开关；长文一律点进推入库页面编辑（DESIGN §5.8），
// 预览直接走 `PromptComposer`，和真正发出去的内容一致。

import SwiftUI

struct PromptManagerPane: View {
    let store: AppStore
    let session: ProjectSession?

    @State private var skillRoute: SkillRoute?
    @State private var showingPreview = false
    @State private var pendingDelete: Skill?
    @State private var pickedProjectID: String?
    /// 从设置页进来时没有现成会话；在 `.task` 里按所选书项目异步打开，不在 body 里读盘。
    @State private var resolvedSession: ProjectSession?

    /// 技能编辑页的推入路由。新建时点一次只生成一条空白技能，id 在这里就定下来，
    /// 避免推入过程中重复求值换掉身份。
    private enum SkillRoute: Hashable {
        case create(Skill)
        case edit(Skill)
    }

    init(store: AppStore, session: ProjectSession? = nil) {
        self.store = store
        self.session = session
    }

    private var skills: [Skill] {
        store.settings.skills
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
            presetSection
            projectSupplementSection
            previewSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .keyboardDismissOnScroll()
        .settingsFormColumn()
        .navigationTitle("提示词集成管理器")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    skillRoute = .create(Skill(name: ""))
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
            store.saveSettings()
            resolvedSession?.scheduleSave()
        }
        .navigationDestination(item: $skillRoute) { route in
            switch route {
            case .create(let skill):
                PromptSkillEditor(
                    skill: skill,
                    isNew: true,
                    onSave: { upsert($0) }
                )
            case .edit(let skill):
                PromptSkillEditor(
                    skill: skill,
                    isNew: false,
                    onSave: { upsert($0) },
                    onDelete: { delete(skill) }
                )
            }
        }
        .sheet(isPresented: $showingPreview) {
            PromptBlocksPreviewSheet(blocks: previewBlocks)
        }
        .confirmationDialog(deleteAlertTitle, isPresented: deleteAlertBinding, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let skill = pendingDelete { delete(skill) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
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
                    skillRoute = .create(Skill(name: ""))
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
                skillRoute = .edit(skill)
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(skill.name.isEmpty ? "未命名技能" : skill.name)
                        .font(Theme.label)
                        .foregroundStyle(.primary)
                    Text(skill.content.isEmpty ? "未填写" : collapsed(skill.content))
                        .font(Theme.labelSmall)
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
        .frame(minHeight: Theme.Layout.rowContentHeight)
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

    // MARK: - 预设与规则

    private var presetSection: some View {
        Section {
            NavigationLink {
                SettingsTextEditorPage(
                    title: "全局预设",
                    text: store.settings.globalPreset,
                    placeholder: "预设内容"
                ) { text in
                    guard store.settings.globalPreset != text else { return }
                    store.settings.globalPreset = text
                    store.saveSettings()
                }
            } label: {
                SettingsLabelRow(
                    title: "全局预设",
                    detail: filledLabel(store.settings.globalPreset)
                )
            }

            NavigationLink {
                SettingsTextEditorPage(
                    title: "去 AI 味规则",
                    text: store.settings.aiFlavorRules,
                    placeholder: "写作规则"
                ) { text in
                    guard store.settings.aiFlavorRules != text else { return }
                    store.settings.aiFlavorRules = text
                    store.saveSettings()
                }
            } label: {
                SettingsLabelRow(
                    title: "去 AI 味规则",
                    detail: filledLabel(store.settings.aiFlavorRules)
                )
            }

            Button("填入示例") {
                store.settings.aiFlavorRules = Self.flavorRulesSample
                store.saveSettings()
                store.toast = "已填入示例"
            }
        } header: {
            AppSectionHeader(title: "预设与规则")
        }
    }

    private static let flavorRulesSample = "减少模板化转折、空泛总结和机械分段；只修改未锁定正文。"

    private func filledLabel(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未填写" : "已填写"
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
                NavigationLink {
                    SettingsTextEditorPage(
                        title: "补充指令",
                        text: resolved.payload.assistantSupplement,
                        placeholder: "补充指令"
                    ) { text in
                        guard resolved.payload.assistantSupplement != text else { return }
                        resolved.payload.assistantSupplement = text
                        resolved.scheduleSave()
                    }
                } label: {
                    SettingsLabelRow(
                        title: "补充指令",
                        detail: filledLabel(resolved.payload.assistantSupplement)
                    )
                }
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
                    .font(Theme.label)
                    .foregroundStyle(.primary)
                Spacer(minLength: Theme.Spacing.s)
                Text(pickedProjectTitle)
                    .font(Theme.label)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .frame(minHeight: Theme.Layout.rowContentHeight)
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
                showingPreview = true
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    SettingsLabelRow(title: "查看最终提示词")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
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
}
