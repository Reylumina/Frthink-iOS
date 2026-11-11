// 世界书词条的编辑页：名称、正文、启用开关。

import SwiftUI

struct WorldbookEntryEditor: View {
    let entry: WorldbookEntry
    let isNew: Bool
    let onSave: (WorldbookEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var bodyText: String
    @State private var enabled: Bool
    @State private var confirmingDiscard = false

    init(entry: WorldbookEntry, isNew: Bool, onSave: @escaping (WorldbookEntry) -> Void) {
        self.entry = entry
        self.isNew = isNew
        self.onSave = onSave
        _title = State(initialValue: entry.title)
        _bodyText = State(initialValue: entry.body)
        _enabled = State(initialValue: entry.enabled)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBody: String {
        bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty && !trimmedBody.isEmpty
    }

    private var hasChanges: Bool {
        trimmedTitle != entry.title || bodyText != entry.body || enabled != entry.enabled
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                AppTextField(
                    title: "词条名",
                    text: $title,
                    placeholder: "例如：雾港城的潮汐规则"
                )

                AppTextEditor(
                    text: $bodyText,
                    placeholder: "这条设定具体是什么",
                    minHeight: 160,
                    expands: true
                )

                Toggle("启用词条", isOn: $enabled)
                    .font(Font.body)
                    .padding(.horizontal, Theme.Spacing.m)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(Theme.groupedCard)
                    .clipShape(
                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    )
            }
            .padding(Theme.Spacing.l)
            .groupedPageBackground()
            .navigationTitle(isNew ? "新建世界书词条" : "编辑世界书词条")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if hasChanges {
                            confirmingDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = entry
                        updated.title = trimmedTitle
                        updated.body = bodyText
                        updated.enabled = enabled
                        updated.updatedAt = Date()
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .confirmationDialog(
                "放弃未保存的修改？",
                isPresented: $confirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
        }
    }
}
