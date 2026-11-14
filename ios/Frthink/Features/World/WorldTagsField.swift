// 用「、」分隔的字符串数组编辑框：别称、事件人物等字段共用。
//
// 内部维护输入草稿，内容变动时解析并更新数组，避免输入分隔符时被即时格式化吞没。

import SwiftUI
import Foundation

struct WorldTagsField: View {
    let title: String
    @Binding var values: [String]
    var placeholder: String
    var separator: String = "、"
    var flat: Bool = false

    @State private var draft = ""
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(title)
                .font(Font.footnote.weight(.medium))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $draft)
                .font(Font.body)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .accessibilityLabel(title)
                .padding(.horizontal, flat ? 0 : Theme.Spacing.m)
                .padding(.vertical, flat ? Theme.Spacing.xs : Theme.Spacing.s)
                .background(flat ? Color.clear : Theme.field)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: flat ? 0 : Theme.Radius.medium,
                        style: .continuous
                    )
                )
                .overlay(alignment: .bottom) {
                    if flat {
                        Divider()
                            .overlay(focused ? Theme.accent.opacity(0.6) : Color.clear)
                    }
                }
                .overlay {
                    if !flat {
                        RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                            .strokeBorder(
                                focused ? Theme.accent.opacity(0.45) : Color.clear,
                                lineWidth: 1
                            )
                    }
                }
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
            // 处于输入焦点时优先保持当前输入；外部数据变动时同步更新草稿。
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
