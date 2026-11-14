// 技能编辑页：技能名、内容、启用开关；编辑已有技能时可以在底部删除。
//
// 详细编辑使用导航推入页面而非弹窗。当前页面仅提供保存操作，
// 左滑返回时自动持久化非空修改，删除操作置于底部独立分组并需二次确认。

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

    /// 存在未保存的修改时由 `onDisappear` 触发自动保存。
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
                // 执行删除后退出页面：设置状态位防止 onDisappear 再次触发保存。
                saved = true
                dismiss()
            }
            Button("取消", role: .cancel) {}
        }
        .onDisappear {
            // 仅提供保存操作：左滑返回时持久化非空修改，防止编辑内容丢失。
            guard !saved, hasChanges, !trimmedName.isEmpty else { return }
            save()
        }
    }
}
