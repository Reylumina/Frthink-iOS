// 阅读显示设置：字号、行距、底色。

import Foundation
import SwiftUI

/// 阅读页的 `@AppStorage` 键。设置项全局共用一份；书签和阅读位置按书各存一份。
enum ReaderStorageKey {
    static let fontSize = "reader.fontSize"
    static let lineHeight = "reader.lineHeight"
    static let darkPage = "reader.darkPage"
    static let mode = "reader.mode"

    static func bookmark(_ projectID: String) -> String {
        "reader.bookmark.\(projectID)"
    }

    static func position(_ projectID: String) -> String {
        "reader.position.\(projectID)"
    }
}

/// 阅读区的排版与配色换算。
enum ReaderStyle {
    /// 纸色 / 黑。黑底不跟随系统深浅色。
    static func page(dark: Bool) -> Color {
        dark ? Color.black : Theme.pageBackgroundColor
    }

    static func ink(dark: Bool) -> Color {
        dark ? Color.white.opacity(0.9) : .primary
    }

    /// 正文字体：跟随设置字号，系统字体。
    static func bodyFont(size: CGFloat) -> Font {
        Font.system(size: size, weight: .regular)
    }

    /// 行距倍数换成额外行距。
    static func lineSpacing(size: CGFloat, lineHeight: Double) -> CGFloat {
        max(0, size * CGFloat(lineHeight - 1))
    }

    /// 正文栏最大宽度：每行不超过 36 个汉字（DESIGN §2.3、§5.3）。
    static func bodyMaxWidth(size: CGFloat) -> CGFloat {
        size * 36
    }

    /// 命中高亮底色。
    static func highlightColor(current: Bool) -> Color {
        current ? Theme.accent.opacity(0.5) : Theme.accent.opacity(0.26)
    }
}

/// 阅读显示设置面板。
struct ReaderDisplaySettingsSheet: View {
    @Binding var fontSize: Double
    @Binding var lineHeight: Double
    @Binding var darkPage: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var confirmingReset = false

    private static let previewLine = "夜色像被谁拧暗了一格，走廊尽头的灯还亮着。"

    /// 预览按与阅读页相同的方式跟随 Dynamic Type。
    private var previewFontSize: CGFloat {
        DynamicTypeFont.bodySize(fontSize, dynamicTypeSize: dynamicTypeSize)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AppValueRow(title: "字号", value: "\(Int(fontSize)) pt")
                    HStack(spacing: Theme.Spacing.m) {
                        Image(systemName: "textformat.size.smaller")
                            .font(Font.footnote)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Slider(value: $fontSize, in: 13...28, step: 1)
                            .tint(Theme.accent)
                        Image(systemName: "textformat.size.larger")
                            .font(Font.title3)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }

                Section {
                    AppValueRow(title: "行距", value: String(format: "%.1f", lineHeight))
                    HStack(spacing: Theme.Spacing.m) {
                        Image(systemName: "text.alignleft")
                            .font(Font.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                        Slider(value: $lineHeight, in: 1.2...2.0, step: 0.1)
                            .tint(Theme.accent)
                        Image(systemName: "arrow.up.and.down.text.horizontal")
                            .font(Font.footnote)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }

                Section {
                    Picker("背景", selection: $darkPage) {
                        Text("纸色").tag(false)
                        Text("黑").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } header: {
                    AppSectionHeader(title: "背景")
                }

                Section {
                    previewBlock
                } header: {
                    AppSectionHeader(title: "预览")
                }

                Section {
                    Button("恢复默认") {
                        confirmingReset = true
                    }
                }
            }
            .navigationTitle("阅读显示设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton { dismiss() }
                }
            }
            .confirmationDialog(
                "恢复默认？",
                isPresented: $confirmingReset,
                titleVisibility: .visible
            ) {
                Button("恢复默认", role: .destructive) { restoreDefaults() }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var previewBlock: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
        return Text(Self.previewLine)
            .font(ReaderStyle.bodyFont(size: previewFontSize))
            .foregroundStyle(ReaderStyle.ink(dark: darkPage))
            .lineSpacing(ReaderStyle.lineSpacing(size: previewFontSize, lineHeight: lineHeight))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.m)
            .background(ReaderStyle.page(dark: darkPage))
            .clipShape(shape)
            // 内容表面默认不描边；增强对比度时补一圈系统分隔线（§1.5、§5.6）。
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Theme.separator, lineWidth: 1)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
    }

    private func restoreDefaults() {
        fontSize = 18
        lineHeight = 1.6
        darkPage = false
    }
}
