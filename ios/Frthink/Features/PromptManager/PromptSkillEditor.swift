// 技能编辑页：技能名、内容、启用开关；编辑已有技能时可以在底部删除。

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
    @State private var pendingAction: PendingAction?

    private enum PendingAction {
        case discard
        case delete
    }

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

    /// 有未保存的改动时禁止下滑关闭，点取消也要确认。
    private var hasChanges: Bool {
        trimmedName != skill.name || content != skill.content || enabled != skill.enabled
    }

    private var pendingTitle: String {
        switch pendingAction {
        case .discard: return "放弃未保存的修改？"
        case .delete: return deleteTitle
        case nil: return ""
        }
    }

    private var pendingBinding: Binding<Bool> {
        Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )
    }

    private var deleteTitle: String {
        trimmedName.isEmpty ? "删除这个技能？" : "删除「\(trimmedName)」？"
    }

    var body: some View {
        NavigationStack {
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
                            pendingAction = .delete
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .groupedPageBackground()
            .keyboardDismissOnScroll()
            .navigationTitle(isNew ? "新建技能" : "编辑技能")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if hasChanges {
                            pendingAction = .discard
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = skill
                        updated.name = trimmedName
                        updated.content = content
                        updated.enabled = enabled
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
            .confirmationDialog(
                pendingTitle,
                isPresented: pendingBinding,
                titleVisibility: .visible
            ) {
                switch pendingAction {
                case .discard:
                    Button("放弃修改", role: .destructive) { dismiss() }
                    Button("继续编辑", role: .cancel) {}
                case .delete:
                    Button("删除", role: .destructive) {
                        onDelete?()
                        dismiss()
                    }
                    Button("取消", role: .cancel) {}
                case nil:
                    Button("取消", role: .cancel) {}
                }
            }
        }
        .presentationDetents([.large])
    }
}
