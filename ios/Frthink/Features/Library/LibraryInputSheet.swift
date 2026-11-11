// 新建 / 重命名 / 改简介共用的输入弹窗。

import SwiftUI

struct LibraryInputSheet: View {
    /// 导航栏标题，例如「新建书项目」。
    let navTitle: String
    let fieldPlaceholder: String
    /// 右上角提交按钮的文案，例如「创建」「保存」。
    let confirmLabel: String
    /// 简介是多行，书名是单行。
    let multiline: Bool
    /// 简介允许清空，书名不允许。
    let allowsEmpty: Bool
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(
        navTitle: String,
        fieldPlaceholder: String,
        confirmLabel: String,
        multiline: Bool,
        allowsEmpty: Bool,
        initialText: String,
        onCommit: @escaping (String) -> Void
    ) {
        self.navTitle = navTitle
        self.fieldPlaceholder = fieldPlaceholder
        self.confirmLabel = confirmLabel
        self.multiline = multiline
        self.allowsEmpty = allowsEmpty
        self.onCommit = onCommit
        _text = State(initialValue: initialText)
        // `@FocusState` 在自定义 init 里要显式建好，避免漏初始化。
        _focused = FocusState<Bool>()
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if multiline {
                    AppTextArea(
                        title: "简介",
                        text: $text,
                        placeholder: fieldPlaceholder,
                        minLines: 6,
                        maxLines: 10
                    )
                } else {
                    TextField(fieldPlaceholder, text: $text)
                        .font(Theme.heading)
                        .textFieldStyle(.plain)
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit { commit() }
                        .padding(Theme.Spacing.m)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                                .stroke(Theme.separator, lineWidth: 0.5)
                        )
                }

                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .pageBackground()
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        commit()
                    } label: {
                        Text(confirmLabel)
                    }
                    .disabled(!canCommit)
                }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            // 单行输入一进来就给焦点，省一次点击。
            focused = !multiline
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCommit: Bool {
        allowsEmpty || !trimmedText.isEmpty
    }

    private func commit() {
        guard canCommit else { return }
        // 先提交再关闭：新建书项目会在这里就触发 onOpen，
        // 先提交可以保证弹窗收起和导航推入由同一轮状态更新驱动。
        onCommit(trimmedText)
        dismiss()
    }
}
