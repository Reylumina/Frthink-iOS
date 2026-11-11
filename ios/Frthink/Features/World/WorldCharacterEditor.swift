// 单张人物卡的编辑页：固定字段 + 自定义词条，改动直接写回 session。

import SwiftUI
import Foundation

struct WorldCharacterEditor: View {
    let session: ProjectSession
    let cardID: String

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false

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
                session.scheduleSave()
                dismiss()
            }
        }
    }

    private var editor: some View {
        Form {
            Section {
                AppTextField(
                    title: "姓名",
                    text: cardBinding.name,
                    placeholder: "人物本名"
                )
                WorldTagsField(
                    title: "别称",
                    values: cardBinding.aliases,
                    placeholder: "用、分隔"
                )
                AppTextField(
                    title: "身份",
                    text: cardBinding.identity,
                    placeholder: "身份、职业、阵营"
                )
                Toggle("参与写作提示词", isOn: Binding(
                    get: { cardBinding.wrappedValue.enabled ?? true },
                    set: { cardBinding.wrappedValue.enabled = $0 }
                ))
                Picker("分组", selection: Binding(
                    get: { cardBinding.wrappedValue.groupId ?? "" },
                    set: {
                        cardBinding.wrappedValue.groupId =
                            $0.isEmpty ? nil : $0
                    }
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

            Section {
                AppTextArea(
                    title: "性格",
                    text: cardBinding.personality,
                    placeholder: "稳定的性格与价值观",
                    minLines: 3
                )
                AppTextArea(
                    title: "语气",
                    text: cardBinding.voice,
                    placeholder: "措辞、语气与对不同对象的说话方式",
                    minLines: 3
                )
                AppTextArea(
                    title: "目标",
                    text: cardBinding.goals,
                    placeholder: "目标与具体动机",
                    minLines: 3
                )
                AppTextArea(
                    title: "底线",
                    text: cardBinding.boundaries,
                    placeholder: "不会做的事、不能触碰的边界",
                    minLines: 3
                )
            } header: {
                AppSectionHeader(title: "说话与行为")
            }

            Section {
                AppTextArea(
                    title: "人物记忆",
                    text: cardBinding.personalMemory,
                    placeholder: "角色亲历或明确知晓、对其行为有持续影响的经历",
                    minLines: 3
                )
                AppTextArea(
                    title: "关系态度",
                    text: cardBinding.relationshipAttitudes,
                    placeholder: "按对象分别记录印象、态度、信任与变化",
                    minLines: 3
                )
            } header: {
                AppSectionHeader(title: "记忆与关系")
            }

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

            Section {
                DestructiveActionRow(title: "删除人物卡") {
                    confirmingDelete = true
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var nameWarning: some View {
        if isNameEmpty {
            Text("姓名为空")
                .font(Font.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var customEntryRows: some View {
        let entries = cardBinding.wrappedValue.customEntries
        if entries.isEmpty {
            Text("还没有自定义词条")
                .font(Font.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(entries) { entry in
                let fields = entryBinding(entry.id)
                CustomEntryRow(
                    title: fields.title,
                    content: fields.body,
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
                    Label("删除这条词条", systemImage: "trash")
                        .font(Font.footnote)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    // MARK: - 绑定

    private var hasCard: Bool {
        session.payload.world.characters.contains { $0.id == cardID }
    }

    private var isNameEmpty: Bool {
        cardBinding.wrappedValue.name
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var navigationTitle: String {
        let name = session.payload.world.characters.first { $0.id == cardID }?.name ?? ""
        return name.isEmpty ? "人物卡" : name
    }

    private var cardBinding: Binding<CharacterCard> {
        Binding(
            get: {
                session.payload.world.characters.first { $0.id == cardID }
                    ?? CharacterCard(name: "")
            },
            set: { newValue in
                guard let index = session.payload.world.characters.firstIndex(where: {
                    $0.id == cardID
                }) else { return }
                var card = newValue
                card.updatedAt = Date()
                session.payload.world.characters[index] = card
                session.scheduleSave()
            }
        )
    }

    private func entryBinding(_ entryID: String) -> Binding<CharacterCard.CustomEntry> {
        Binding(
            get: {
                cardBinding.wrappedValue.customEntries.first { $0.id == entryID }
                    ?? CharacterCard.CustomEntry(title: "", body: "")
            },
            set: { newValue in
                var card = cardBinding.wrappedValue
                guard let index = card.customEntries.firstIndex(where: {
                    $0.id == entryID
                }) else { return }
                card.customEntries[index] = newValue
                cardBinding.wrappedValue = card
            }
        )
    }

    // MARK: - 操作

    private func addCustomEntry() {
        var card = cardBinding.wrappedValue
        card.customEntries.append(CharacterCard.CustomEntry(title: "", body: ""))
        cardBinding.wrappedValue = card
    }

    private func removeCustomEntry(_ entryID: String) {
        var card = cardBinding.wrappedValue
        card.customEntries.removeAll { $0.id == entryID }
        cardBinding.wrappedValue = card
    }

    private func deleteCard() {
        session.payload.world.characters.removeAll { $0.id == cardID }
        session.scheduleSave()
        dismiss()
    }
}
