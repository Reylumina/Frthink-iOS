import SwiftUI

/// 设计系统：系统语义色、系统字体、系统动效。
///
/// 数值和用法以 `docs/DESIGN.md` 为准。新增 token 先写进文档，再补到这里；
/// 页面里不直接写颜色、字号、时长。
enum Theme {

    // MARK: - 颜色

    /// 系统强调色，全应用唯一的全局 tint。
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

    /// 有色淡底的统一透明度：胶囊、选中态、图标底。
    ///
    /// 用户气泡不在此列，它用实底表达角色（见 `Theme.Bubble`）。
    static let tintedFillOpacity: Double = 0.12

    /// 用户气泡：实底 + 反色文字，和系统「信息」的收发关系一致。
    ///
    /// 底色是系统强调色压深 18%：原样的系统蓝配白字只有 4.0:1，达不到正文
    /// 尺寸需要的 4.5:1（§5.6）。压深仍由系统色推导，不引入自定义色值。
    static let bubbleFill: Color = {
        if #available(iOS 18.0, *) {
            return Color.accentColor.mix(with: .black, by: 0.18)
        }
        return Color.accentColor
    }()
    static let bubbleForeground = Color.white

    // MARK: - 字体

    /// 正文。系统字体，跟随 Dynamic Type。
    static let prose = Font.body
    /// 助手回复。
    static let reply = Font.callout

    /// 标题。
    static let heading = Font.title3.weight(.semibold)

    /// 界面文字。无衬线、系统字号。
    static let label = Font.body
    static let labelEmphasis = Font.headline
    static let labelSmall = Font.subheadline
    /// 元信息：时间、字数、条数。§2.1 规定为 `.footnote`。
    static let metadata = Font.footnote
    /// 胶囊、角标。
    static let badge = Font.caption.weight(.semibold)

    /// 数字/版本号：比例字形，只让数字等宽，避免刷新时跳动。
    static let numeric = Font.footnote.monospacedDigit()
    static let numericSmall = Font.caption.monospacedDigit()

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
        /// 常规宽度下对话列的最大宽度（§5.3）。
        static let chatMaxWidth: CGFloat = 720
        /// 常规宽度下表单页的最大宽度（§5.3）。
        static let formMaxWidth: CGFloat = 640
        /// 可点热区的最小边长（§5.1）。
        static let hitTarget: CGFloat = 44

        /// 同一行控件的可见高度：搜索框、次操作胶囊、圆形图标按钮（§5.1）。
        /// 圆形按钮按它画圆，外面再留 `hitTarget` 的热区。
        /// 视图里用 `@ScaledMetric(relativeTo: .body)` 读，不直接取这个常数。
        static let controlHeight: CGFloat = 36

        /// 列表行的最小内容高度（§5.1）。
        ///
        /// 行高 = 这个高度 + 系统的上下内边距。不要写成 44：系统在 iOS 26 上
        /// 加了 22–30pt 内边距，44 的行会撑到 66–74pt，设置页六行就多占一屏。
        /// 28 让带图标印章的行落在 50pt 上下，整行可点，热区仍然够。
        static let rowContentHeight: CGFloat = 28

        /// 输入条里控件的行内高度：发送/停止圆、续写图标（§5.9）。
        /// 比 `controlHeight` 小一点：这一条浮在正文上，多一像素都在压字。
        static let inlineControl: CGFloat = 34
    }

    // MARK: - 动效

    /// 选中、开关、分段切换、聚焦。
    static let motionSelection = Animation.snappy(duration: 0.2)
    /// 展开收起、搜索栏、toast、列表增删。
    static let motionLayout = Animation.smooth
    /// 直接操作的结果，一屏最多一个。
    static let motionEmphasis = Animation.bouncy

    /// 「减弱动态效果」下把动效降级为空，调用方照常写 `withAnimation(Theme.motion(...))`。
    static func motion(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    // MARK: - 形状

    /// 内容表面的形状。
    ///
    /// iOS 26 起跟随容器同心（§3.3），并给一个最小圆角兜底；更早版本回落到
    /// 固定圆角。页面里不写 `#available` 分支。
    static func containerShape(minimum: CGFloat = Radius.large) -> AnyShape {
        if #available(iOS 26.0, *) {
            return AnyShape(
                ConcentricRectangle(
                    corners: .concentric(minimum: .fixed(minimum)),
                    isUniform: true
                )
            )
        }
        return AnyShape(RoundedRectangle(cornerRadius: minimum, style: .continuous))
    }
}

// MARK: - 容器

extension View {
    /// 页面底：白/黑打底。
    func pageBackground() -> some View {
        background(Theme.pageBackgroundColor.ignoresSafeArea())
    }

    /// 卡片表面：只做填充和连续圆角（§1.5）。
    ///
    /// 浅色下 `.secondarySystemBackground` 放在白底上已经能看出边界，不需要
    /// 描边或投影；只有「增强对比度」时才补一圈系统分隔线。
    func cardSurface(radius: CGFloat = Theme.Radius.large) -> some View {
        modifier(CardSurfaceModifier(radius: radius))
    }

    /// 玻璃表面。
    ///
    /// iOS 26 起用系统的 Liquid Glass；更早的版本回落到材质。
    /// 只用在「浮在内容之上」的元素：输入条、浮层、工具栏按钮。
    func glassSurface(radius: CGFloat = Theme.Radius.large) -> some View {
        modifier(GlassSurfaceModifier(radius: radius))
    }

    /// 任意形状的玻璃表面，用于胶囊类的浮层。
    func glassSurface<S: Shape>(_ shape: S) -> some View {
        modifier(GlassShapeModifier(shape: shape))
    }

    /// 带「减弱动态效果」降级的隐式动画。
    func themeAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(ThemeAnimationModifier(animation: animation, value: value))
    }

    /// 标签栏随下滚收起（仅 iOS 26）。
    @ViewBuilder
    func minimizeTabBarOnScroll() -> some View {
        if #available(iOS 26.0, *) {
            tabBarMinimizeBehavior(.onScrollDown)
        } else {
            self
        }
    }

    /// 滚动内容经过浮起控件时的边缘柔化（仅 iOS 26）。
    @ViewBuilder
    func softScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: .all)
        } else {
            self
        }
    }
}

struct CardSurfaceModifier: ViewModifier {
    var radius: CGFloat

    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(Theme.card)
            .clipShape(shape)
            .overlay {
                if contrast == .increased {
                    shape.strokeBorder(Theme.separator, lineWidth: 1)
                }
            }
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

struct GlassShapeModifier<S: Shape>: ViewModifier {
    var shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

struct ThemeAnimationModifier<V: Equatable>: ViewModifier {
    var animation: Animation
    var value: V

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(Theme.motion(animation, reduceMotion: reduceMotion), value: value)
    }
}

// MARK: - 空状态

/// 空状态。
///
/// 用系统字形层级表达空，不加色块、描边和投影；字号走 `.largeTitle` 跟随
/// Dynamic Type，不写死像素。
struct EmptyStateView: View {
    let symbol: String
    let title: String
    var message: String = ""
    var actionTitle: String? = nil
    /// 这一屏除了它没有别的可做时，才用实底主操作（书架首启）。
    var isPrimaryAction: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(title)
                .font(Theme.labelEmphasis)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            if !message.isEmpty {
                Text(message)
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let actionTitle, let action {
                actionButton(title: actionTitle, action: action)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xxl)
        .padding(.horizontal, Theme.Spacing.l)
    }

    /// 默认用次操作按钮，和世界页两栏的空态保持一致；整页只有一个动作时
    /// 传 isPrimaryAction 换成实底（§5.4、§5.7）。
    ///
    /// 两种按钮样式是不同类型，不能写成三元表达式，只能分支分别修饰。
    @ViewBuilder
    private func actionButton(title: String, action: @escaping () -> Void) -> some View {
        let base = Button(title, action: action)
            .controlSize(.regular)
            // 可见高度 34pt，热区补到 44pt（§5.1）。
            .frame(minHeight: Theme.Layout.hitTarget)
            .contentShape(Capsule())
            .padding(.top, Theme.Spacing.xs)
        if isPrimaryAction {
            base.buttonStyle(.borderedProminent)
        } else {
            base.buttonStyle(.bordered)
        }
    }
}
