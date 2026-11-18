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
    @State private var activationMode: WorldbookActivationMode
    @State private var keysText: String
    @State private var confirmingDiscard = false

    init(entry: WorldbookEntry, isNew: Bool, onSave: @escaping (WorldbookEntry) -> Void) {
        self.entry = entry
        self.isNew = isNew
        self.onSave = onSave
        _title = State(initialValue: entry.title)
        _bodyText = State(initialValue: entry.body)
        _enabled = State(initialValue: entry.enabled)
        _activationMode = State(initialValue: entry.resolvedActivationMode)
        _keysText = State(initialValue: entry.resolvedKeys.joined(separator: "、"))
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

    private var parsedKeys: [String] {
        keysText
            .components(separatedBy: CharacterSet(charactersIn: "、,，;；\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var hasChanges: Bool {
        trimmedTitle != entry.title
            || bodyText != entry.body
            || enabled != entry.enabled
            || activationMode != entry.resolvedActivationMode
            || parsedKeys != entry.resolvedKeys
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        AppTextField(
                            title: "词条名",
                            text: $title,
                            placeholder: "例如：雾港城的潮汐规则"
                        )
                        AppTextArea(
                            title: "内容",
                            text: $bodyText,
                            placeholder: "输入设定内容或规则说明",
                            minLines: 6,
                            maxLines: 14
                        )
                    }

                    Toggle("启用词条", isOn: $enabled)
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.vertical, Theme.Spacing.s)
                        .background(
                            Theme.field,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                        Picker("触发方式", selection: $activationMode) {
                            Text("常驻注入").tag(WorldbookActivationMode.constant)
                            Text("关键词触发").tag(WorldbookActivationMode.keyword)
                        }
                        .pickerStyle(.segmented)

                        if activationMode == .keyword {
                            AppTextField(
                                title: "触发关键词",
                                text: $keysText,
                                placeholder: "用顿号或逗号分隔，例如：雾港、潮汐税、旧灯塔"
                            )
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
            }
            .pageBackground()
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
                        updated.activationMode = activationMode == .constant ? nil : activationMode
                        updated.keys = parsedKeys.isEmpty ? nil : parsedKeys
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
