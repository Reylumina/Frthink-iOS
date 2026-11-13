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
            Form {
                Section {
                    AppTextField(
                        title: "词条名",
                        text: $title,
                        placeholder: "例如：雾港城的潮汐规则",
                        flat: true
                    )
                    AppTextArea(
                        title: "内容",
                        text: $bodyText,
                        placeholder: "这条设定具体是什么",
                        minLines: 6,
                        maxLines: 14,
                        flat: true
                    )
                }

                Section {
                    Toggle("启用词条", isOn: $enabled)
                }
            }
            .scrollContentBackground(.hidden)
            .groupedPageBackground()
            .keyboardDismissOnScroll()
            .navigationTitle(isNew ? "新建世界书词条" : "编辑世界书词条")
            .navigationBarTitleDisplayMode(.inline)
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
            .discardChangesDialog(isPresented: $confirmingDiscard, hasChanges: hasChanges) {
                dismiss()
            }
        }
    }
}
