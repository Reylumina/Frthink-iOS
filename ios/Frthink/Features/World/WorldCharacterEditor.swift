// 人物卡编辑视图：提供预设字段与自定义词条编辑能力。
//
// 编辑过程维护局部草稿，确认完成或退出页面时统一提交至 session，避免每次输入触发整份数据序列化与持久化。

import SwiftUI
import Foundation

struct WorldCharacterEditor: View {
    let session: ProjectSession
    let cardID: String

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    /// 编辑期间维护局部草稿，退出或点击完成时统一提交至 payload。
    @State private var draft: CharacterCard
    /// 打开页面时的初始卡片快照，用于判断字段实际修改项，
    /// 避免旧快照覆盖刷新过程中并入的新数据。
    private let openedCard: CharacterCard

    init(session: ProjectSession, cardID: String) {
        self.session = session
        self.cardID = cardID
        let current = session.payload.world.characters.first { $0.id == cardID }
            ?? CharacterCard(name: "")
        _draft = State(initialValue: current)
        openedCard = current
    }

    var body: some View {
        Group {
            if hasCard {
                editor
            } else {
                EmptyStateView(
                    symbol: "person.crop.circle.badge.questionmark",
                    title: "这张人物卡已被删除"
                )
            }
        }
        .pageBackground()
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onDisappear { commitDraft() }
        .alert(
            "删除人物卡",
            isPresented: $confirmingDelete
        ) {
            Button("删除", role: .destructive) {
                deleteCard()
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 结构

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button("完成") {
                commitDraft()
                dismiss()
            }
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                basicSection
                personalitySection
                memorySection
                customEntriesSection

                DestructiveActionRow(title: "删除人物卡") {
                    confirmingDelete = true
                }
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.xs)
                .background(
                    Theme.field,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                )
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
        }
        .keyboardDismissOnScroll()
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            AppSectionHeader(title: "基本")
            AppTextField(
                title: "姓名",
                text: $draft.name,
                placeholder: "人物本名"
            )
            nameWarning
            WorldTagsField(
                title: "别称",
                values: $draft.aliases,
                placeholder: "用、分隔"
            )
            AppTextField(
                title: "身份",
                text: $draft.identity,
                placeholder: "身份、职业、阵营"
            )
            Toggle("参与写作提示词", isOn: Binding(
                get: { draft.enabled ?? true },
                set: { draft.enabled = $0 }
            ))
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .background(
                Theme.field,
                in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            )
            HStack {
                Text("分组")
                    .font(Font.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Picker("分组", selection: Binding(
                    get: { draft.groupId ?? "" },
                    set: { draft.groupId = $0.isEmpty ? nil : $0 }
                )) {
                    Text("未分组").tag("")
                    ForEach(session.payload.world.characterGroups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
                .labelsHidden()
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                Theme.field,
                in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
            )
        }
    }

    private var personalitySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            AppSectionHeader(title: "说话与行为")
            AppTextArea(
                title: "性格",
                text: $draft.personality,
                placeholder: "稳定的性格与价值观",
                minLines: 3
            )
            AppTextArea(
                title: "语气",
                text: $draft.voice,
                placeholder: "措辞、语气与对不同对象的说话方式",
                minLines: 3
            )
            AppTextArea(
                title: "目标",
                text: $draft.goals,
                placeholder: "目标与具体动机",
                minLines: 3
            )
            AppTextArea(
                title: "底线",
                text: $draft.boundaries,
                placeholder: "不会做的事、不能触碰的边界",
                minLines: 3
            )
        }
    }

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            AppSectionHeader(title: "记忆与关系")
            AppTextArea(
                title: "人物记忆",
                text: $draft.personalMemory,
                placeholder: "角色亲历或明确知晓、对其行为有持续影响的经历",
                minLines: 3
            )
            AppTextArea(
                title: "关系态度",
                text: $draft.relationshipAttitudes,
                placeholder: "按对象分别记录印象、态度、信任与变化",
                minLines: 3
            )
        }
    }

    private var customEntriesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            AppSectionHeader(title: "自定义词条")
            customEntryRows
            Button {
                addCustomEntry()
            } label: {
                Label("添加自定义词条", systemImage: "plus")
                    .font(Font.body)
                    .frame(maxWidth: .infinity, minHeight: Theme.Layout.hitTarget, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.m)
                    .background(
                        Theme.field,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    )
            }
        }
    }

    @ViewBuilder
    private var nameWarning: some View {
        if isNameEmpty {
            Text("姓名为空")
                .font(Font.caption)
                .foregroundStyle(AppTone.warning.color)
        }
    }

    @ViewBuilder
    private var customEntryRows: some View {
        if draft.customEntries.isEmpty {
            Text("还没有自定义词条")
                .font(Font.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach($draft.customEntries) { $entry in
                CustomEntryRow(
                    title: $entry.title,
                    content: $entry.body,
                    onDelete: { removeCustomEntry(entry.id) }
                )
            }
        }
    }

    /// 自定义词条行视图组件，接收标题、内容绑定与删除回调。
    private struct CustomEntryRow: View {
        @Binding var title: String
        @Binding var content: String
        var onDelete: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                AppTextField(
                    title: "标题",
                    text: $title,
                    placeholder: "例如：武器、口癖"
                )
                AppTextArea(
                    title: "内容",
                    text: $content,
                    minLines: 3,
                    showsCount: false
                )
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除词条", systemImage: "trash")
                        .font(Font.footnote)
                        .frame(minHeight: Theme.Layout.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                Divider()
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    // MARK: - 草稿

    private var hasCard: Bool {
        session.payload.world.characters.contains { $0.id == cardID }
    }

    private var isNameEmpty: Bool {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var navigationTitle: String {
        draft.name.isEmpty ? "人物卡" : draft.name
    }

    /// 差异合并：仅提交发生变动的字段，防止以旧快照覆盖并发刷新的最新数据。
    private func commitDraft() {
        guard let index = session.payload.world.characters.firstIndex(where: {
            $0.id == cardID
        }) else { return }
        guard draft != openedCard else { return }

        var merged = session.payload.world.characters[index]
        if draft.name != openedCard.name { merged.name = draft.name }
        if draft.identity != openedCard.identity { merged.identity = draft.identity }
        if draft.personality != openedCard.personality { merged.personality = draft.personality }
        if draft.voice != openedCard.voice { merged.voice = draft.voice }
        if draft.goals != openedCard.goals { merged.goals = draft.goals }
        if draft.boundaries != openedCard.boundaries { merged.boundaries = draft.boundaries }
        if draft.aliases != openedCard.aliases { merged.aliases = draft.aliases }
        if draft.personalMemory != openedCard.personalMemory {
            merged.personalMemory = draft.personalMemory
        }
        if draft.relationshipAttitudes != openedCard.relationshipAttitudes {
            merged.relationshipAttitudes = draft.relationshipAttitudes
        }
        if draft.customEntries != openedCard.customEntries {
            merged.customEntries = draft.customEntries
        }
        // 若新建卡片内容为空则移除该条目，保持列表数据有效。
        if Self.isBlank(merged) {
            session.payload.world.characters.remove(at: index)
            session.scheduleSave()
            return
        }
        guard merged != session.payload.world.characters[index] else { return }
        merged.updatedAt = Date()
        session.payload.world.characters[index] = merged
        draft = merged
        session.scheduleSave()
    }

    /// 整张卡只有空白内容。
    private static func isBlank(_ card: CharacterCard) -> Bool {
        let texts = [card.name, card.identity, card.personality, card.voice,
                     card.goals, card.boundaries, card.personalMemory,
                     card.relationshipAttitudes]
        return texts.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && card.aliases.isEmpty
            && card.customEntries.allSatisfy {
                $0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
    }

    // MARK: - 操作

    private func addCustomEntry() {
        draft.customEntries.append(CharacterCard.CustomEntry(title: "", body: ""))
    }

    private func removeCustomEntry(_ entryID: String) {
        draft.customEntries.removeAll { $0.id == entryID }
    }

    private func deleteCard() {
        session.payload.world.characters.removeAll { $0.id == cardID }
        session.scheduleSave()
        dismiss()
    }
}
