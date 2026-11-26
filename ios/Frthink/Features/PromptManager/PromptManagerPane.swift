// 全局写作基准：管理跨书通用的技能、全局预设与去 AI 味规则。
//
// 列表仅提供入口与开关；详细内容推入二级页面编辑，
// 预览调用 `PromptIntegration`，与实际发送内容保持一致。

import SwiftUI

struct PromptManagerPane: View {
    let store: AppStore
    let session: ProjectSession?

    @State private var skillRoute: SkillRoute?
    @State private var showingPreview = false
    @State private var pendingDelete: Skill?

    /// 技能编辑页的导航路由：新建操作固定生成单个空白技能并确定 ID，避免导航跳转时重复求值导致 ID 变动。
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
        var blocks = PromptIntegration.blocks(
            projectID: session?.project.id ?? "",
            assistantSupplement: "",
            globalPreset: store.settings.globalPreset,
            skills: skills,
            aiFlavorRules: store.settings.aiFlavorRules
        )
        if let workspace = session?.narrativeWorkspace {
            let state = workspace.currentState()
            let rules = state.directiveLedger.activeDirectives()
                .map(\.verbatimRule)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !rules.isEmpty {
                blocks.append(
                    PromptBlock(
                        key: "narrative:directives",
                        category: .agentPrompt,
                        title: "写作规则",
                        body: rules.joined(separator: "\n")
                    )
                )
            }
            let template = workspace.preservedStyle.styleTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !template.isEmpty {
                blocks.append(
                    PromptBlock(
                        key: "narrative:styleTemplate",
                        category: .skill,
                        title: "仿写模板",
                        body: template
                    )
                )
            }
        }
        return blocks
    }

    var body: some View {
        List {
            skillsSection
            presetSection
            previewSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .keyboardDismissOnScroll()
        .settingsFormColumn()
        .navigationTitle("全局写作基准")
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
        .onDisappear {
            store.saveSettings()
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
        .alert(deleteAlertTitle, isPresented: deleteAlertBinding) {
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
