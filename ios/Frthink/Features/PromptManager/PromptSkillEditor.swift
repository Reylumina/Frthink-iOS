// 技能编辑页：技能名、内容、启用开关；编辑已有技能时可以在底部删除。
//
// 长文编辑使用推入页而非 sheet。这一页只有「保存」没有「取消」，
// 左滑返回时自动存下非空改动，删除走底部独立一节并二次确认。

import SwiftUI

struct PromptSkillEditor: View {
    let skill: Skill
    let isNew: Bool
    let onSave: (Skill) -> Void
    let onDelete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var content: String
    @State private var enabled: Bool
    @State private var saved = false
    @State private var confirmingDelete = false

    init(
        skill: Skill,
        isNew: Bool,
        onSave: @escaping (Skill) -> Void,
        onDelete: (() -> Void)? = nil
    ) {
        self.skill = skill
        self.isNew = isNew
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: skill.name)
        _content = State(initialValue: skill.content)
        _enabled = State(initialValue: skill.enabled)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 有未保存的改动时返回要自动保存，交给 `onDisappear`。
    private var hasChanges: Bool {
        trimmedName != skill.name || content != skill.content || enabled != skill.enabled
    }

    private var deleteTitle: String {
        trimmedName.isEmpty ? "删除这个技能？" : "删除「\(trimmedName)」？"
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        var updated = skill
        updated.name = trimmedName
        updated.content = content
        updated.enabled = enabled
        onSave(updated)
        saved = true
    }

    var body: some View {
        Form {
            Section {
                AppTextField(
                    title: "技能名",
                    text: $name,
                    placeholder: "对白节奏"
                )
            }

            Section {
                AppTextEditor(
                    text: $content,
                    placeholder: "技能内容",
                    minHeight: 260
                )
            } header: {
                AppSectionHeader(title: "内容")
            }

            Section {
                Toggle("启用技能", isOn: $enabled)
            }

            if !isNew, onDelete != nil {
                Section {
                    DestructiveActionRow(title: "删除技能") {
                        confirmingDelete = true
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .keyboardDismissOnScroll()
        .navigationTitle(isNew ? "新建技能" : "编辑技能")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SheetConfirmButton(title: "保存", isEnabled: !trimmedName.isEmpty) {
                    save()
                    dismiss()
                }
            }
        }
        .alert(deleteTitle, isPresented: $confirmingDelete) {
            Button("删除", role: .destructive) {
                onDelete?()
                // 删除即结束这一页：置位避免 onDisappear 又把改动存回去。
                saved = true
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
        .onDisappear {
            // 只有「保存」没有「取消」：左滑返回时存下非空改动，别静默丢。
            guard !saved, hasChanges, !trimmedName.isEmpty else { return }
            save()
        }
    }
}
