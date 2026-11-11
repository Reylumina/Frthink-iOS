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

    /// 原版提示词要求每条 2–3000 字；手填时给 UI 一个上限提示。
    static let maxTextLength = 3000

    /// 分类建议。原版由模型自由分类，这里只给几个常用值减少手打。
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

    var body: some View {
        NavigationStack {
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
                            .font(Font.footnote)
                            .foregroundStyle(.red)
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
            .scrollContentBackground(.hidden)
            .groupedPageBackground()
            .keyboardDismissOnScroll()
            .navigationTitle(isNew ? "新增语料" : "编辑语料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var updated = entry
                        updated.title = trimmedTitle
                        updated.text = text
                        updated.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.tags = parseTags(tagText)
                        updated.source = source.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(updated)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }

    /// 建议分类用自适应网格换行，不再用会被裁掉一截的横向滚动。
    private var suggestedCategoriesGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 92), spacing: Theme.Spacing.s)],
            alignment: .leading,
            spacing: Theme.Spacing.s
        ) {
            ForEach(Self.suggestedCategories, id: \.self) { item in
                Button {
                    category = item
                } label: {
                    Text(item)
                        .font(Font.footnote)
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.vertical, Theme.Spacing.s)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                .fill(Theme.accentSoft)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
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
