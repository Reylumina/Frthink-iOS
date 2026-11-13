// 新建 / 重命名 / 改简介共用的输入弹窗。
//
// 这一页有草稿：关闭（取消或下滑）前必须确认放弃，不能静默丢掉已经输入的内容。
// 单行字段只有填充底，没有描边和投影。

import SwiftUI

struct LibraryInputSheet: View {
    let navTitle: String
    let fieldPlaceholder: String
    let confirmLabel: String
    /// 简介是多行，书名是单行。
    let multiline: Bool
    /// 简介允许清空，书名不允许。
    let allowsEmpty: Bool
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var confirmingDiscard = false
    @FocusState private var focused: Bool
    /// 打开时的原文，用来判断有没有未提交的输入。
    private let initialText: String

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
        self.initialText = initialText
        self.onCommit = onCommit
        _text = State(initialValue: initialText)
        // `@FocusState` 在自定义 init 里要显式建好，避免漏初始化。
        _focused = FocusState<Bool>()
    }

    private var hasChanges: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            != initialText.trimmingCharacters(in: .whitespacesAndNewlines)
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
                        .background(Theme.field)
                        .clipShape(Theme.containerShape(minimum: Theme.Radius.medium))
                }

                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.l)
            .frame(
                maxWidth: Theme.Layout.formMaxWidth,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .frame(maxWidth: .infinity, alignment: .top)
            .pageBackground()
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            // 重命名/改简介的结果句要在这个 sheet 里可见。
            .sheetToast()
            .interactiveDismissDisabled(hasChanges)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") {
                        if hasChanges {
                            confirmingDiscard = true
                        } else {
                            dismiss()
                        }
                    }
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
            .confirmationDialog(
                "放弃未保存的输入？",
                isPresented: $confirmingDiscard,
                titleVisibility: .visible
            ) {
                Button("放弃输入", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
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
