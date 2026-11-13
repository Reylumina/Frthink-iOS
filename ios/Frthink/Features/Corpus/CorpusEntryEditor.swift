// 语料条目的新增 / 编辑页：标题、原句、分类、标签、来源。

import SwiftUI

struct CorpusEntryEditor: View {
    let entry: CorpusEntry
    let isNew: Bool
    let onSave: (CorpusEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var text: String
    @State private var category: String
    @State private var tagText: String
    @State private var source: String
    @State private var confirmingDiscard = false

    /// 提示词要求每条 2–3000 字；手填时给 UI 一个上限提示。
    static let maxTextLength = 3000

    /// 常用分类建议，减少手打（也可自由输入）。
    static let suggestedCategories = [
        "环境描写", "人物描写", "动作", "对白", "心理", "比喻", "叙事", "其他",
    ]

    init(entry: CorpusEntry, isNew: Bool, onSave: @escaping (CorpusEntry) -> Void) {
        self.entry = entry
        self.isNew = isNew
        self.onSave = onSave
        _title = State(initialValue: entry.title)
        _text = State(initialValue: entry.text)
        _category = State(initialValue: entry.category)
        _tagText = State(initialValue: entry.tags.joined(separator: "，"))
        _source = State(initialValue: entry.source)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedTitle.isEmpty && !trimmedText.isEmpty && text.count <= Self.maxTextLength
    }

    private var hasChanges: Bool {
        trimmedTitle != entry.title
            || text != entry.text
            || category.trimmingCharacters(in: .whitespacesAndNewlines) != entry.category
            || parseTags(tagText) != entry.tags
            || source.trimmingCharacters(in: .whitespacesAndNewlines) != entry.source
    }

    var body: some View {
        NavigationStack {
            editorForm
                .scrollContentBackground(.hidden)
                .groupedPageBackground()
                .keyboardDismissOnScroll()
                .navigationTitle(isNew ? "新增语料" : "编辑语料")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .discardChangesDialog(isPresented: $confirmingDiscard, hasChanges: hasChanges) {
                    dismiss()
                }
        }
    }

    private var editorForm: some View {
        Form {
            Section {
                AppTextField(
                    title: "标题",
                    text: $title,
                    placeholder: "潮水退去后的礁石"
                )
            }

            Section {
                AppTextArea(
                    title: "原句",
                    text: $text,
                    placeholder: "原句",
                    minLines: 6,
                    maxLines: 12
                )
                if text.count > Self.maxTextLength {
                    Text("已超出 3000 字")
                        .font(Theme.metadata)
                        .foregroundStyle(AppTone.danger.color)
                }
            }

            Section {
                AppTextField(
                    title: "分类",
                    text: $category,
                    placeholder: "环境描写"
                )
                suggestedCategoriesGrid
            }

            Section {
                AppTextField(
                    title: "标签",
                    text: $tagText,
                    placeholder: "用逗号分隔"
                )
            }

            Section {
                AppTextField(
                    title: "来源",
                    text: $source,
                    placeholder: "手动录入"
                )
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            SheetCloseButton {
                if hasChanges {
                    confirmingDiscard = true
                } else {
                    dismiss()
                }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            SheetConfirmButton(title: "保存", isEnabled: canSave) {
                var updated = entry
                updated.title = trimmedTitle
                updated.text = text
                updated.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
                updated.tags = parseTags(tagText)
                updated.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
                onSave(updated)
                dismiss()
            }
        }
    }

    /// 使用自适应网格换行，避免横向滚动被裁剪。
    private var suggestedCategoriesGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 92), spacing: Theme.Spacing.s)],
            alignment: .leading,
            spacing: Theme.Spacing.s
        ) {
            ForEach(Self.suggestedCategories, id: \.self) { item in
                categoryChip(item)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func categoryChip(_ item: String) -> some View {
        Button {
            category = item
        } label: {
            Text(item)
                .font(Theme.labelSmall)
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Theme.Layout.hitTarget)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .fill(Theme.accentSoft)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func parseTags(_ raw: String) -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for part in raw.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }) {
            let tag = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, !seen.contains(tag) else { continue }
            seen.insert(tag)
            tags.append(tag)
        }
        return tags
    }
}
