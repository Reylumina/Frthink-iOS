// 二/三/四级界面通用件：只补系统默认样式缺的部分，不持业务状态。

import SwiftUI
import UIKit

// MARK: - 页面底板

extension View {
    /// 分组表单页底：系统分组灰 + 顶部一层极淡的强调色，避免整页发死。
    func groupedPageBackground() -> some View {
        background(
            LinearGradient(
                colors: [Theme.accent.opacity(0.05), Theme.groupedPageColor],
                startPoint: .top,
                endPoint: .center
            )
            .ignoresSafeArea()
        )
    }
}

// MARK: - 语义色

/// 状态色调。
enum AppTone {
    case neutral
    case accent
    case success
    case warning
    case danger

    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .accent: return Theme.accent
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }
}

// MARK: - 图标

/// 设置行 / 分类入口左侧的图标印章。
///
/// 固定 28pt 是控件尺寸（不是文字），不参与 Dynamic Type；符号本身用 SF Symbol，
/// 随无障碍设置缩放。
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [tint.opacity(0.24), tint.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .strokeBorder(tint.opacity(0.10), lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }
}

/// AI 服务商图标：有官方品牌标就用资产图，否则退回 SF Symbol。
///
/// 品牌标不做 tinted symbol，保留官方颜色；底色用中性灰，避免品牌色和主题色
/// 互相染色。当前项由旁边的「当前」胶囊表示，不靠图标颜色。
struct ProviderIcon: View {
    let kind: ProviderKind
    var tint: Color = Theme.accent
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let asset = kind.logoAssetName {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.14)
            } else {
                Image(systemName: kind.symbolName)
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: size, height: size)
        .background(
            background,
            in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        )
        .accessibilityHidden(true)
    }

    private var background: Color {
        kind.logoAssetName == nil ? tint.opacity(0.12) : Color.primary.opacity(0.06)
    }
}

// MARK: - 区块标题

/// Form / List 的 Section header。
///
/// 中文没有大小写，默认的 uppercase 不适用；层级交给字重与颜色。
struct AppSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}

// MARK: - 行

/// 设置/索引页的统一导航行：图标 + 标题 + 右侧值。
///
/// 放在 `NavigationLink` 里由系统补 chevron；单独使用时自行决定是否可点。
struct AppSettingsRow: View {
    let title: String
    var symbol: String? = nil
    var symbolTint: Color = Theme.accent
    var detail: String? = nil

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            if let symbol {
                IconTile(symbol: symbol, tint: symbolTint)
            }
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: Theme.Spacing.s)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }
}

/// 两端对齐的只读数值行。数字用等宽，避免刷新时抖动。
struct AppValueRow: View {
    let title: String
    let value: String
    var symbol: String? = nil
    var tone: AppTone = .neutral

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.footnote)
                    .foregroundStyle(tone.color)
                    .frame(width: 20)
            }
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: Theme.Spacing.s)
            Text(value)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 状态

/// 胶囊状态：当前 / 已停用 / 未填 Key / 已保存。
struct StatusPill: View {
    let text: String
    var tone: AppTone = .neutral

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tone.color)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone.color.opacity(0.12)))
            .accessibilityLabel(text)
    }
}

/// 一行业务状态：加载中 / 成功 / 失败 / 普通说明。
///
/// 自带最小高度，状态在「无」与「一行」之间切换时页面不跳。
struct AppStatusLine: View {
    enum Kind {
        case info
        case progress
        case success
        case failure
    }

    let kind: Kind
    let text: String

    @ScaledMetric(relativeTo: .footnote) private var minHeight: CGFloat = 20

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.s) {
            switch kind {
            case .info:
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
            case .progress:
                ProgressView()
                    .controlSize(.small)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failure:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(isFailure ? 3 : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: isFailure)
            Spacer(minLength: 0)
        }
        .frame(minHeight: minHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var isFailure: Bool {
        if case .failure = kind { return true }
        return false
    }
}

// MARK: - 字段

/// 输入框的共用外观：填充底 + 一级圆角 + 聚焦描边。
///
/// 内边距由调用方给：单行/多行字段是 m × s，长正文编辑器是 xs × xs（编辑器自带内边距）。
private struct FieldChrome: ViewModifier {
    let focused: Bool
    var horizontal: CGFloat = Theme.Spacing.m
    var vertical: CGFloat = Theme.Spacing.s

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .background(Theme.field)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                    .strokeBorder(
                        focused ? Theme.accent.opacity(0.45) : Color.clear,
                        lineWidth: 1
                    )
            )
            .animation(Theme.motionSelection, value: focused)
    }
}

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
/// 用 @ViewBuilder 函数而不是包一层 View：结果直接落进父 VStack，
/// 与原先的内联 `if` 分支等价，不会多出一个参与间距计算的子视图。
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

    @FocusState private var focused: Bool

    private var isOverLimit: Bool {
        guard let maxLength else { return false }
        return text.count > maxLength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldCaption(
                title: title,
                count: showsCount ? "\(text.count) 字" : nil,
                countTone: isOverLimit ? .danger : .neutral
            )

            TextField(placeholder, text: $text)
                .font(.body)
                .textFieldStyle(.plain)
                .textInputAutocapitalization(capitalization)
                .keyboardType(keyboard)
                .autocorrectionDisabled(disablesAutocorrection)
                .focused($focused)
                .accessibilityLabel(title)
                .modifier(FieldChrome(focused: focused))
                .onChange(of: text) { _, newValue in
                    guard let maxLength, newValue.count > maxLength else { return }
                    text = String(newValue.prefix(maxLength))
                }

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

    @FocusState private var focused: Bool

    private var isOverLimit: Bool {
        guard let maxLength else { return false }
        return text.count > maxLength
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldCaption(
                title: title,
                count: showsCount ? "\(text.count) 字" : nil,
                countTone: isOverLimit ? .danger : .neutral
            )

            TextField(placeholder, text: $text, axis: .vertical)
                .font(Theme.prose)
                .textFieldStyle(.plain)
                .lineLimit(minLines...maxLines)
                .focused($focused)
                .accessibilityLabel(title)
                .modifier(FieldChrome(focused: focused))
                .onChange(of: text) { _, newValue in
                    guard let maxLength, newValue.count > maxLength else { return }
                    text = String(newValue.prefix(maxLength))
                }

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
        VStack(alignment: .leading, spacing: 6) {
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
                        .frame(width: 44, height: 44)
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

    private var isOverLimit: Bool {
        guard let maxLength else { return false }
        return text.count > maxLength
    }

    /// 编辑器没有可见标题时退回占位文案，避免 VoiceOver 只念「文本栏」。
    private var accessibilityTitle: String {
        if !title.isEmpty { return title }
        return placeholder.isEmpty ? "正文" : placeholder
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsCount {
                HStack {
                    Spacer(minLength: 0)
                    Text("\(text.count) 字")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(isOverLimit ? Color.red : Color.secondary)
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
                        .padding(.top, Theme.Spacing.xs)
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
            .onChange(of: text) { _, newValue in
                guard let maxLength, newValue.count > maxLength else { return }
                text = String(newValue.prefix(maxLength))
            }
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
                        .tint(.white)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.m)
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
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.s)
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
            .frame(minHeight: 44)
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
