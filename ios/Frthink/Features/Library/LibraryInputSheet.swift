// 新建 / 重命名 / 改简介共用的输入弹窗。
//
// 包含草稿状态：关闭（取消或下拉返回）前需确认放弃，防止未保存输入丢失。
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
    /// 打开时的初始文本，用于比对判断是否存在未提交修改。
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
        // 在自定义 init 中显式初始化 @FocusState，确保状态正常绑定。
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
            // 确保当前弹窗能够展示操作结果 Toast 提示。
            .sheetToast()
            .toolbar { toolbarContent }
            .discardChangesDialog(isPresented: $confirmingDiscard, hasChanges: hasChanges) {
                dismiss()
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            // 单行输入框进入时默认聚焦，减少用户操作步骤。
            focused = !multiline
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCommit: Bool {
        allowsEmpty || !trimmedText.isEmpty
    }

    private func commit() {
        guard canCommit else { return }
        // 先提交再关闭：新建项目在此处触发 onOpen，
        // 先提交可确保弹窗收起与导航推入由同一轮状态更新驱动。
        onCommit(trimmedText)
        dismiss()
    }
}
