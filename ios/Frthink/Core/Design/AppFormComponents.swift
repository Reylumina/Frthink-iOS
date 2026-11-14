import SwiftUI
import UIKit


private struct FieldCaption: View {
    let title: String
    var count: String? = nil
    var countTone: AppTone = .neutral

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let count {
                Text(count)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(countTone.color)
            }
        }
    }
}

/// 字段下方的说明文字；为空时整块不出现，也不占位。
///
/// 用 @ViewBuilder 函数直接展开进父 VStack，避免包一层 View 影响间距计算。
@ViewBuilder
private func fieldHint(_ text: String?) -> some View {
    if let text, !text.isEmpty {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 单行字段：标题在上、输入框在下（三级页的字段规则）。
struct AppTextField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboard: UIKeyboardType = .default
    var capitalization: TextInputAutocapitalization = .never
    var disablesAutocorrection: Bool = true
    var hint: String? = nil
    var showsCount = false
    var maxLength: Int? = nil
    /// 表单行内使用：不在卡片里再套一层圆角（见 FieldChrome.flat）。
    var flat: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            FieldCaption(
                title: title,
                count: showsCount ? "\(text.count) 字" : nil,
                countTone: isOverMaxLength(text, maxLength: maxLength) ? .danger : .neutral
            )

            TextField(placeholder, text: $text)
                .font(.body)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(capitalization)
                .keyboardType(keyboard)
                .autocorrectionDisabled(disablesAutocorrection)
                .focused($focused)
                .accessibilityLabel(title)
                .modifier(FieldChrome(focused: focused, flat: flat))
                .clampMaxLength($text, maxLength: maxLength)

            fieldHint(hint)
        }
    }
}

/// 多行字段：默认最多 10 行，超出后在框内滚动，不在页面里再套一层滚动。
struct AppTextArea: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    var minLines: Int = 4
    var maxLines: Int = 10
    var showsCount = false
    var maxLength: Int? = nil
    var hint: String? = nil
    /// 表单行内使用：不在卡片里再套一层圆角（见 FieldChrome.flat）。
    var flat: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            FieldCaption(
                title: title,
                count: showsCount ? "\(text.count) 字" : nil,
                countTone: isOverMaxLength(text, maxLength: maxLength) ? .danger : .neutral
            )

            TextField(placeholder, text: $text, axis: .vertical)
                .font(Theme.prose)
                .textFieldStyle(.plain)
                .lineLimit(minLines...maxLines)
                .focused($focused)
                .accessibilityLabel(title)
                .modifier(FieldChrome(focused: focused, flat: flat))
                .clampMaxLength($text, maxLength: maxLength)

            fieldHint(hint)
        }
    }
}

/// 密码/Key 字段：默认不回显，带一个可切换的显示按钮。
struct AppSecureField: View {
    let title: String
    @Binding var text: String
    var placeholder: String = ""
    var hint: String? = nil

    @State private var reveals = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            FieldCaption(title: title)

            HStack(spacing: Theme.Spacing.s) {
                Group {
                    if reveals {
                        TextField(placeholder, text: $text)
                    } else {
                        SecureField(placeholder, text: $text)
                    }
                }
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.plain)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
                .accessibilityLabel(title)

                Button {
                    // TextField 与 SecureField 切换会换控件身份，光标和焦点会丢；
                    // 记住切换前的聚焦状态，替身出现后把焦点还回去。
                    let wasFocused = focused
                    reveals.toggle()
                    if wasFocused {
                        Task { @MainActor in focused = true }
                    }
                } label: {
                    Image(systemName: reveals ? "eye.slash" : "eye")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: Theme.Layout.hitTarget, height: Theme.Layout.hitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(reveals ? "隐藏 Key" : "显示 Key")
            }
            .modifier(FieldChrome(focused: focused))

            fieldHint(hint)
        }
    }
}

/// 长正文编辑器。用于整页只有一个正文输入的三级页（世界书、技能、世界建立）。
///
/// 外层不要再包 ScrollView：让它自己滚动，避免键盘与滚动互相抢。
struct AppTextEditor: View {
    @Binding var text: String
    var title: String = ""
    var placeholder: String = ""
    var minHeight: CGFloat = 200
    var showsCount = false
    var maxLength: Int? = nil
    /// true 时占满父视图剩余高度（整页正文编辑器用）。
    var expands = false

    @FocusState private var focused: Bool

    /// 编辑器没有可见标题时退回占位文案，避免 VoiceOver 只念「文本栏」。
    private var accessibilityTitle: String {
        if !title.isEmpty { return title }
        return placeholder.isEmpty ? "正文" : placeholder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if showsCount {
                HStack {
                    Spacer(minLength: 0)
                    Text("\(text.count) 字")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isOverMaxLength(text, maxLength: maxLength) ? Color.red : Color.secondary)
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(Theme.prose)
                    .foregroundStyle(.primary)
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .frame(minHeight: minHeight)
                    .frame(maxHeight: expands ? .infinity : nil)
                    .accessibilityLabel(accessibilityTitle)

                if text.isEmpty {
                    Text(placeholder)
                        .font(Theme.prose)
                        .foregroundStyle(.tertiary)
                        // 对齐 TextEditor（UITextView）默认文本容器边距
                        .padding(.top, Theme.Spacing.s)
                        .padding(.leading, Theme.Spacing.xs)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .modifier(
                FieldChrome(
                    focused: focused,
                    horizontal: Theme.Spacing.xs,
                    vertical: Theme.Spacing.xs
                )
            )
            .clampMaxLength($text, maxLength: maxLength)
        }
    }
}

private func isOverMaxLength(_ text: String, maxLength: Int?) -> Bool {
    guard let maxLength else { return false }
    return text.count > maxLength
}

private extension View {
    func clampMaxLength(_ text: Binding<String>, maxLength: Int?) -> some View {
        onChange(of: text.wrappedValue) { _, newValue in
            guard let maxLength, newValue.count > maxLength else { return }
            text.wrappedValue = String(newValue.prefix(maxLength))
        }
    }
}

// MARK: - 按钮

/// 一屏只该出现一个的主操作。
struct PrimaryActionButton: View {
    let title: String
    var systemImage: String? = nil
    var isBusy = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.s) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.onAccent)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(.body.weight(.semibold))
            }
            // 高度交给 controlSize（.large 已是系统主操作刻度），再叠内边距会到 74pt。
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Theme.accent)
        .disabled(!isEnabled || isBusy)
    }
}

/// 并排/次要操作。
struct SecondaryActionButton: View {
    let title: String
    var systemImage: String? = nil
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            // 同上：高度由 controlSize 给出。
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .tint(Theme.accent)
        .disabled(!isEnabled)
    }
}

/// 页面底部的危险动作。放在独立 Section 的最后，不贴着被破坏的数据。
struct DestructiveActionRow: View {
    let title: String
    var systemImage: String = "trash"
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: systemImage)
                Text(title)
                Spacer(minLength: 0)
            }
            .font(.body)
            // 这是列表行：行高由内容 + 系统内边距给，不再撑到 44（§5.1）。
            .frame(minHeight: Theme.Layout.rowContentHeight)
            .contentShape(Rectangle())
        }
        .disabled(!isEnabled)
    }
}

// MARK: - 空态

/// 区块内的轻量空态：一行图标 + 一句说明 + 可选一个动作。
/// 整页空态继续用 `EmptyStateView`（ContentUnavailableView）。
struct InlineEmptyState: View {
    let symbol: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.s) {
            Image(systemName: symbol)
                .font(.title3.weight(.light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.medium))
                    .buttonStyle(.borderless)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.l)
    }
}

// MARK: - 章节行

/// 章节/索引行：序号 + 标题 +（可选）字数 + 当前标记。
///
/// 阅读目录与写作台章节表共用；两处只维护这一份视觉，避免再次分叉。
struct ChapterNavigationRow: View {
    let ordinal: Int
    let title: String
    var characters: Int? = nil
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.m) {
            Text("\(ordinal)")
                .font(Theme.numeric)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .padding(.trailing, Theme.Spacing.xs)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Font.subheadline.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Theme.accent : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let characters {
                    Text("\(characters.formatted()) 字")
                        .font(Theme.numericSmall)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "book.fill")
                    .font(Font.caption)
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("当前章")
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
    }
}

// MARK: - sheet 工具栏

/// sheet / 编辑页的关闭按钮。
///
/// iOS 26 起 `Button(role: .close)` 由系统画 × 并定位置；17–25 没有这个 role，
/// 退回文字按钮。关闭不丢数据，所以不用 `.cancel`。页面里不写版本分支。
struct SheetCloseButton: View {
    /// 17–25 的文字；iOS 26 由系统给图标。
    var title: String = "取消"
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
                .accessibilityLabel(title)
        } else {
            Button(title, action: action)
        }
    }
}

/// sheet / 编辑页的确认按钮（自动保存的页面只显示完成）。
struct SheetConfirmButton: View {
    /// 17–25 的文字；iOS 26 由系统给图标。
    var title: String = "完成"
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .confirm, action: action)
                .accessibilityLabel(title)
                .disabled(!isEnabled)
        } else {
            Button(title, action: action)
                .disabled(!isEnabled)
        }
    }
}

// MARK: - 浮层按钮
/// 浮在内容上的按钮（回到最新、回到底部）。
///
/// iOS 26 用系统的玻璃按钮样式，17–25 回落到系统材质胶囊；系统补不了的
/// 是「浮在滚动内容上方」这一层，所以只封装样式和热区，不带业务。
///
/// 传 title 时是「图标 + 文字」的胶囊，不传是圆钮。会和一个圆形主操作
/// （输入条的发送键）同屏出现的地方要用胶囊：两个一样大的玻璃圆叠在一起，
/// 用户分不清哪个是发送、哪个是跳转。
struct FloatingGlassButton: View {
    let symbol: String
    let label: String
    var title: String? = nil
    var isEnabled = true
    let action: () -> Void

    /// 可见高度跟随字号缩放（§2.4）。
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = Theme.Layout.controlHeight

    var body: some View {
        // iOS 26 用系统玻璃按钮样式：按压形变和高亮由系统给，自己画一个静态玻璃
        // 会丢掉「点下去有反应」。
        if #available(iOS 26.0, *) {
            button.buttonStyle(.glass)
        } else {
            button
                .background(.regularMaterial, in: Capsule())
                .clipShape(Capsule())
        }
    }

    private var button: some View {
        Button(action: action) {
            if let title {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: symbol)
                        .font(Font.caption.weight(.semibold))
                    Text(title)
                        .font(Font.caption.weight(.medium))
                }
                .padding(.horizontal, Theme.Spacing.m)
                .frame(minHeight: size)
                .contentShape(Rectangle())
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: Theme.Layout.inlineControl, height: Theme.Layout.inlineControl)
                    .contentShape(Circle())
            }
        }
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

// MARK: - 确认弹层

extension View {
    /// 删除确认弹层（§5.8、§8.2）。只放标题与「删除 / 取消」，不加说明文案。
    func deleteConfirmationDialog(
        _ title: String,
        isPresented: Binding<Bool>,
        actionTitle: String = "删除",
        onConfirm: @escaping () -> Void
    ) -> some View {
        alert(title, isPresented: isPresented) {
            Button(actionTitle, role: .destructive, action: onConfirm)
            Button("取消", role: .cancel) {}
        }
    }

    /// 按待删条目绑定的删除确认弹层（§5.8、§8.2）。
    func deleteConfirmationDialog<Item>(
        _ title: @escaping (Item) -> String,
        item: Binding<Item?>,
        actionTitle: String = "删除",
        onConfirm: @escaping (Item) -> Void
    ) -> some View {
        alert(
            item.wrappedValue.map(title) ?? "",
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            )
        ) {
            Button(actionTitle, role: .destructive) {
                guard let target = item.wrappedValue else { return }
                item.wrappedValue = nil
                onConfirm(target)
            }
            Button("取消", role: .cancel) {
                item.wrappedValue = nil
            }
        }
    }

    /// 表单未保存退出前的放弃确认。
    func discardChangesDialog(
        isPresented: Binding<Bool>,
        hasChanges: Bool,
        onDiscard: @escaping () -> Void
    ) -> some View {
        interactiveDismissDisabled(hasChanges)
            .alert(
                "放弃未保存的修改？",
                isPresented: isPresented
            ) {
                Button("放弃修改", role: .destructive, action: onDiscard)
                Button("继续编辑", role: .cancel) {}
            }
    }
}
