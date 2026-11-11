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

    /// 三级表面：输入框、统计条。
    static let surfaceTertiary = Color(uiColor: .tertiarySystemBackground)

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

    /// 选中态填充。系统四级的填充最轻，配合系统 tint 的前景色正好。
    static let selectionFill = Color(uiColor: .quaternarySystemFill)

    /// 分隔线用系统值，自动适配深浅色。
    static let separator = Color(uiColor: .separator)

    // MARK: - 字体

    /// 正文。系统字体，跟随 Dynamic Type。
    static let prose = Font.system(.body)
    /// 大段正文（阅读页）。
    static let proseLarge = Font.system(.title3)
    /// 助手回复。
    static let reply = Font.system(.callout)

    /// 标题。
    static let heading = Font.system(.title3).weight(.semibold)
    static let headingLarge = Font.system(.title2).weight(.semibold)

    /// 界面文字。无衬线、系统字号。
    static let label = Font.body
    static let labelEmphasis = Font.headline
    static let labelSmall = Font.subheadline
    /// 元信息：时间、字数、条数。最小只到 `.caption`。
    static let metadata = Font.caption
    static let metadataEmphasis = Font.caption.weight(.medium)
    /// 极小号只用于角标，且不再小于 `.caption2`。
    static let badge = Font.caption2.weight(.medium)

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

    /// 常规状态切换。
    static let motion = Animation.snappy(duration: 0.3)
    /// 强调：内容出现、生成开始。
    static let motionEmphasis = Animation.smooth(duration: 0.35)
    /// 选中、开关。
    static let motionSelection = Animation.snappy(duration: 0.2)
    /// 数值滚动。
    static let motionNumeric = Animation.smooth(duration: 0.4)
}

// MARK: - 容器

extension View {
    /// 页面底：白/黑打底，不加渐变、不加灰。
    func pageBackground() -> some View {
        background(Theme.pageBackgroundColor.ignoresSafeArea())
    }

    /// 卡片表面：与页面同色，靠描边和间距分区。
    func cardSurface(radius: CGFloat = Theme.Radius.large) -> some View {
        background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.separator.opacity(0.6), lineWidth: 0.5)
            )
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

struct CardContainer<Content: View>: View {
    var padding: CGFloat = Theme.Spacing.l
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }
}

/// 空状态。
///
/// 只用图标 + 两行字。不画装饰圆、不加渐变、不放营销腔的文案。
struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String = ""
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if !message.isEmpty {
                Text(message)
            }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// 元信息行：左标签右值，全局统一。
struct MetadataRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Theme.labelSmall)
                .foregroundStyle(.secondary)
            Spacer(minLength: Theme.Spacing.s)
            Text(value)
                .font(Theme.numericSmall)
                .foregroundStyle(.primary)
        }
    }
}




