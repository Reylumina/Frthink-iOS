// 单张人物卡的编辑页：固定字段 + 自定义词条。
//
// 编辑期间只改局部草稿，点「完成」或离开页面时一次写回 session，避免逐键触发整份 payload 的变更与防抖保存。

import SwiftUI
import Foundation

struct WorldCharacterEditor: View {
    let session: ProjectSession
    let cardID: String

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    /// 编辑期间只改局部草稿，离开或点完成时一次写回 payload。
    @State private var draft: CharacterCard
    /// 打开页面那一刻的卡片。写回时靠它判断哪些字段是用户真正改过的，
    /// 免得把刷新期间并进来的新内容用旧快照盖掉。
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
        .groupedPageBackground()
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onDisappear { commitDraft() }
        .confirmationDialog(
            "删除人物卡",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
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
        Form {
            basicSection
            personalitySection
            memorySection
            customEntriesSection

            Section {
                DestructiveActionRow(title: "删除人物卡") {
                    confirmingDelete = true
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var basicSection: some View {
        Section {
            AppTextField(
                title: "姓名",
                text: $draft.name,
                placeholder: "人物本名",
                flat: true
            )
            WorldTagsField(
                title: "别称",
                values: $draft.aliases,
                placeholder: "用、分隔",
                flat: true
            )
            AppTextField(
                title: "身份",
                text: $draft.identity,
                placeholder: "身份、职业、阵营",
                flat: true
            )
            Toggle("参与写作提示词", isOn: Binding(
                get: { draft.enabled ?? true },
                set: { draft.enabled = $0 }
            ))
            Picker("分组", selection: Binding(
                get: { draft.groupId ?? "" },
                set: { draft.groupId = $0.isEmpty ? nil : $0 }
            )) {
                Text("未分组").tag("")
                ForEach(session.payload.world.characterGroups) { group in
                    Text(group.name).tag(group.id)
                }
            }
        } header: {
            AppSectionHeader(title: "基本")
        } footer: {
            nameWarning
        }
    }

    private var personalitySection: some View {
        Section {
            AppTextArea(
                title: "性格",
                text: $draft.personality,
                placeholder: "稳定的性格与价值观",
                minLines: 3,
                flat: true
            )
            AppTextArea(
                title: "语气",
                text: $draft.voice,
                placeholder: "措辞、语气与对不同对象的说话方式",
                minLines: 3,
                flat: true
            )
            AppTextArea(
                title: "目标",
                text: $draft.goals,
                placeholder: "目标与具体动机",
                minLines: 3,
                flat: true
            )
            AppTextArea(
                title: "底线",
                text: $draft.boundaries,
                placeholder: "不会做的事、不能触碰的边界",
                minLines: 3,
                flat: true
            )
        } header: {
            AppSectionHeader(title: "说话与行为")
        }
    }

    private var memorySection: some View {
        Section {
            AppTextArea(
                title: "人物记忆",
                text: $draft.personalMemory,
                placeholder: "角色亲历或明确知晓、对其行为有持续影响的经历",
                minLines: 3,
                flat: true
            )
            AppTextArea(
                title: "关系态度",
                text: $draft.relationshipAttitudes,
                placeholder: "按对象分别记录印象、态度、信任与变化",
                minLines: 3,
                flat: true
            )
        } header: {
            AppSectionHeader(title: "记忆与关系")
        }
    }

    private var customEntriesSection: some View {
        Section {
            customEntryRows
            Button {
                addCustomEntry()
            } label: {
                Label("添加自定义词条", systemImage: "plus")
                    .font(Font.body)
            }
        } header: {
            AppSectionHeader(title: "自定义词条")
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

    /// 自定义词条行只拿两个文本绑定和删除回调，回查卡片的事留在编辑器里。
    private struct CustomEntryRow: View {
        @Binding var title: String
        @Binding var content: String
        var onDelete: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                AppTextField(
                    title: "标题",
                    text: $title,
                    placeholder: "例如：武器、口癖",
                    flat: true
                )
                AppTextArea(
                    title: "内容",
                    text: $content,
                    minLines: 3,
                    showsCount: false,
                    flat: true
                )
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("删除这条词条", systemImage: "trash")
                        .font(Font.footnote)
                        .frame(minHeight: Theme.Layout.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
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

    /// 三路合并：只把用户动过的字段写到当前卡片上，避免用打开时的旧快照覆盖刷新期间并入的新内容。
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
        // 新建后没填任何内容就退出：把这张空卡删掉，书架/列表里不留空条目。
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
