import SwiftUI

/// 设计系统：系统语义色、系统字体、系统动效。
enum Theme {

    // MARK: - 颜色

    /// 系统强调色。
    static let accent = Color.accentColor

    /// 选中态淡底。
    static let accentSoft = Color(uiColor: .quaternarySystemFill)

    /// 次级表面。
    static let surfaceSecondary = Color(uiColor: .secondarySystemBackground)

    /// 内容页底：白/黑。
    static let pageBackgroundColor = Color(uiColor: .systemBackground)

    /// 卡片。
    static let card = Color(uiColor: .secondarySystemBackground)

    /// 分组列表页底。
    ///
    /// 设置、编辑器这类表单页用系统分组灰打底，Section 才是白卡片；
    /// 页面与卡片的关系和 iOS 设置一致。内容页（正文、阅读）仍用
    /// `pageBackgroundColor` 的白/黑，不铺灰。
    static let groupedPageColor = Color(uiColor: .systemGroupedBackground)

    /// 分组列表里的卡片面。
    static let groupedCard = Color(uiColor: .secondarySystemGroupedBackground)

    /// 输入框、标签、次级容器。比卡片再深一点，用来区分「可点」和「只读」。
    static let field = Color(uiColor: .tertiarySystemFill)

    /// 分隔线用系统值，自动适配深浅色。
    static let separator = Color(uiColor: .separator)

    /// 强调色低饱和渐变。用于图标印章、继续写作卡等身份性表面，
    /// 不做页面底，也不与语义状态色混用。
    static let accentWash = LinearGradient(
        colors: [Color.accentColor.opacity(0.20), Color.accentColor.opacity(0.05)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 卡片投影。浅色下给一点浮起感，深色下几乎不可见。
    static let cardShadow = Color.black.opacity(0.07)

    // MARK: - 字体

    /// 正文。系统字体，跟随 Dynamic Type。
    static let prose = Font.system(.body)
    /// 助手回复。
    static let reply = Font.system(.callout)

    /// 标题。
    static let heading = Font.system(.title3).weight(.semibold)

    /// 界面文字。无衬线、系统字号。
    static let label = Font.body
    static let labelEmphasis = Font.headline
    static let labelSmall = Font.subheadline
    /// 元信息：时间、字数、条数。最小只到 `.caption`。
    static let metadata = Font.caption
    /// 角标：与小字同级，不低过 `.caption`。
    static let badge = Font.caption.weight(.medium)

    /// 数字/版本号。
    static let numeric = Font.system(.footnote, design: .monospaced)
    static let numericSmall = Font.system(.caption, design: .monospaced)

    /// 小标题（区块名）。
    static let sectionTitle = Font.footnote.weight(.semibold)

    // MARK: - 圆角 / 间距

    enum Radius {
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let sheet: CGFloat = 24
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    // MARK: - 尺寸

    enum Layout {
        /// 顶栏标题（书名 + 模型）的最大宽度，避免长模型名挤压两侧按钮。
        static let navTitleMaxWidth: CGFloat = 220
    }

    // MARK: - 动效

    /// 选中、开关。
    static let motionSelection = Animation.snappy(duration: 0.2)
}

// MARK: - 容器

extension View {
    /// 页面底：白/黑打底；分组页在顶部叠极淡的强调色，避免大片纯灰发死。
    func pageBackground() -> some View {
        background(Theme.pageBackgroundColor.ignoresSafeArea())
    }

    /// 卡片表面：同色底、细描边 + 轻投影，靠层次而不是重色分区。
    func cardSurface(radius: CGFloat = Theme.Radius.large) -> some View {
        background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.separator.opacity(0.55), lineWidth: 0.5)
            )
            .shadow(color: Theme.cardShadow, radius: 8, y: 3)
    }

    /// 玻璃表面。
    ///
    /// iOS 26 起用系统的 Liquid Glass；更早的版本回落到材质。
    /// 只用在「浮在内容之上」的元素：输入条、浮层、气泡。
    func glassSurface(radius: CGFloat = Theme.Radius.large) -> some View {
        modifier(GlassSurfaceModifier(radius: radius))
    }
}

struct GlassSurfaceModifier: ViewModifier {
    var radius: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

/// 空状态。
///
/// 图标印章 + 标题 + 一句说明；用系统符号和语义色，不画插画。
struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String = ""
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 64, height: 64)
                .background(
                    Theme.accentWash,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.12), lineWidth: 0.5)
                )
                .shadow(color: Theme.cardShadow, radius: 10, y: 4)

            Text(title)
                .font(Font.headline)
                .foregroundStyle(.primary)

            if !message.isEmpty {
                Text(message)
                    .font(Font.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
        .padding(.horizontal, Theme.Spacing.l)
    }
}

