// 用「、」分隔的字符串数组编辑框：别称、事件人物等字段共用。
//
// 内部保留用户的原始输入，只在内容变化时写回数组；否则边输入分隔符、
// 边解析、边重新拼回显示，会把刚打的分隔符吃掉。

import SwiftUI
import Foundation

struct WorldTagsField: View {
    let title: String
    @Binding var values: [String]
    var placeholder: String
    var separator: String = "、"

    @State private var draft = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Font.footnote.weight(.medium))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $draft)
                .font(Font.body)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .background(Theme.field)
                .clipShape(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(
                            focused ? Theme.accent.opacity(0.45) : Color.clear,
                            lineWidth: 1
                        )
                )
                .animation(Theme.motionSelection, value: focused)
                .onChange(of: draft) { _, newValue in
                    commit(newValue)
                }
        }
        .onAppear {
            guard !loaded else { return }
            draft = values.joined(separator: separator)
            loaded = true
        }
        .onChange(of: values) { _, newValue in
            // 焦点内以用户输入为准；外部刷新（AI 合并/撤销）时才回灌草稿。
            guard loaded, !focused else { return }
            let joined = newValue.joined(separator: separator)
            if joined != draft {
                draft = joined
            }
        }
    }

    private func commit(_ text: String) {
        guard loaded else { return }
        let parts = text
            .components(separatedBy: CharacterSet(charactersIn: "、,，;；/|\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard parts != values else { return }
        values = parts
    }
}
