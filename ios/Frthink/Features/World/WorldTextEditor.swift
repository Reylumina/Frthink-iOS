// 世界面板共用的多行文本编辑器（标题 + 占位符 + 主题化的 TextEditor）。

import SwiftUI
import Foundation

struct WorldTextEditor: View {
    let title: String
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat = 84

    init(
        title: String,
        text: Binding<String>,
        placeholder: String,
        minHeight: CGFloat = 84
    ) {
        self.title = title
        _text = text
        self.placeholder = placeholder
        self.minHeight = minHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Font.caption.weight(.medium))
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(Theme.prose)
                    .foregroundStyle(.primary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: minHeight)

                if text.isEmpty {
                    Text(placeholder)
                        .font(Theme.prose)
                        .foregroundStyle(.tertiary)
                        .padding(.top, Theme.Spacing.s)
                        .padding(.leading, Theme.Spacing.xs)
                        .allowsHitTesting(false)
                }
            }
            .padding(Theme.Spacing.xs)
            .background(Theme.pageBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
    }
}
