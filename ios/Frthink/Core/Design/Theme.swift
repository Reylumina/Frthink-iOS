import SwiftUI
import UIKit

/// 设计系统：系统语义色、系统字体、系统动效。
///
/// 数值和用法以 `docs/DESIGN.md` 为准。新增 token 先写进文档，再补到这里；
/// 页面里不直接写颜色、字号、时长。
enum Theme {

    // MARK: - 颜色

    /// 全局 tint：单色（浅色近黑 #111 / 深色近白 #F2F2F7）。
    ///
    /// 内容型 App 的通行做法是把彩色让给内容：控件统一黑/白，颜色只出现在
    /// 状态和用户自己的素材上。iOS 26 的 Liquid Glass 本身也是中性玻璃，
    /// 再叠一层饱和蓝反而打架（Apple Music 也在往单色图标收）。
    static let accent = Color.accentColor

    /// 压在强调色实底上的字形：发送键图标、码字机圆标。
    ///
    /// 浅色档黑底白字、深色档白底近黑字，跟着 accent 一起翻转。
    /// 放在资产里是为了不写死色值。
    static let onAccent = Color(uiColor: UIColor(named: "OnAccent") ?? .white)

    /// 强调色淡底：选中胶囊、圆钮、图标印章的底色。
    ///
    /// 用 tint 压 16% 而不是固定灰：深浅两档自动翻转，和 accent 是一对。
    /// 16% 是量出来的——12% 压在深色卡面上几乎看不见。
    static let accentSoft = Theme.accent.opacity(Theme.tintedFillOpacity)

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

    /// 有色淡底的统一透明度：强调色淡底、状态胶囊、图标方块共用这一个值。
    ///
    /// 16% 是实测值——12% 压在深色卡面上几乎看不见；用户气泡用实底表达角色（见 `Theme.Bubble`），不在此列。
    static let tintedFillOpacity: Double = 0.16

    /// 用户气泡：系统灰实底 + 正文色文字。
    ///
    /// 用系统灰（浅色下是浅灰、深色下是深灰）而不是强调色：强调色只留给可点的
    /// 控件，整块气泡铺蓝会把「唯一的主操作」压掉，也和系统「信息」的收发关系
    /// 对不上。文字用 `.label`，深浅两种底色都自动满足 4.5:1（§5.6）。
    static let bubbleFill = Color(uiColor: .systemGray5)
    static let bubbleForeground = Color(uiColor: .label)

    // MARK: - 内容身份色

    /// 内容身份色：书封和一级分类图标共用的一套纸色。
    ///
    /// 它不是品牌色，也不用于按钮、开关、状态或页面底——只给「这是哪一本书 /
    /// 哪一类东西」上色。色相拉开、明度有深有浅，深色模式各降一档亮度。
    enum Identity {
        /// 12 个色相，彩度拉到能一眼分开（浅色 C*≈60–70），深色各降一档。
        ///
        /// 系统色在白底上偏灰，一排书封看着像褪了色；这里按色相环铺开，同一明度档，
        /// 白符号对比度都在 4:1 以上。只给书封和封面类身份用。
        static let colors: [Color] = [
            dynamic(light: 0xC2352B, dark: 0x8A211A),  // 朱红
            dynamic(light: 0xC96A0B, dark: 0x93490A),  // 橙
            dynamic(light: 0xB8890F, dark: 0x856208),  // 琥珀
            dynamic(light: 0x6B7A22, dark: 0x4B5617),  // 橄榄
            dynamic(light: 0x1F7A46, dark: 0x145631),  // 绿
            dynamic(light: 0x0E7C7B, dark: 0x0A5756),  // 青
            dynamic(light: 0x1668A8, dark: 0x0F4A79),  // 湖蓝
            dynamic(light: 0x3B4BA0, dark: 0x293572),  // 靛
            dynamic(light: 0x7A3EA0, dark: 0x572C73),  // 紫
            dynamic(light: 0xB03060, dark: 0x7E2144),  // 玫
            dynamic(light: 0x8A5A2B, dark: 0x63401E),  // 赭
            dynamic(light: 0x3C3A37, dark: 0x2B2926),  // 石墨
        ]

        /// 按 id 稳定取色：同一本书、同一个分类永远同一个颜色。
        static func color(for seed: String) -> Color {
            colors[Int(stableHash(seed) % UInt64(colors.count))]
        }

        /// 稳定哈希：FNV-1a 打底，末尾再做一轮 splitmix 收尾。
        ///
        /// 只做 FNV 时，名字相近的 id 会落进相邻槽位，一排书封经常撞色撞图标。
        /// 收尾那两步把低位打散，跨版本、跨设备结果一致。
        static func stableHash(_ seed: String) -> UInt64 {
            var hash: UInt64 = 1_469_598_103_934_665_603
            for scalar in seed.unicodeScalars {
                hash = (hash ^ UInt64(scalar.value)) &* 1_099_511_628_211
            }
            hash ^= hash >> 30
            hash = hash &* 0xBF58_476D_1CE4_E5B9
            hash ^= hash >> 27
            hash = hash &* 0x94D0_49BB_1331_11EB
            hash ^= hash >> 31
            return hash
        }

        private static func dynamic(light: UInt32, dark: UInt32) -> Color {
            Color(uiColor: UIColor { traits in
                UIColor(identityHex: traits.userInterfaceStyle == .dark ? dark : light)
            })
        }
    }

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

        /// 正文段落间距（§2.3）：额外行距 × 1.4。
        ///
        /// 以额外行距（字号 × (行高 − 1)）为基准而不是固定字号倍数：
        /// 阅读页把行距调到 1.2 或 2.0 时，段距会跟着变，段落与折行始终是
        /// 1.4 倍的关系，不会出现「行距调大后段落反而挤在一起」。
        /// 默认行高 1.5 时等于字号 × 0.7（18pt → 12.6pt）。
        static func paragraphSpacing(fontSize: CGFloat, lineHeight: Double = 1.5) -> CGFloat {
            fontSize * CGFloat(max(0, lineHeight - 1)) * 1.4
        }

        /// 图标方块的基准边长（§2.4）：28pt，全应用只有一个值——分类图标、
        /// 行首图标、AI 服务商品牌标都用它。
        static let iconTileSize: CGFloat = 28

        /// 阅读页页脚进度条的高度（§2.3）：两像素，够看见又不抢正文。
        static let progressBarHeight: CGFloat = 2

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
    ///
    /// `interactive` 打开系统给玻璃的触摸反馈：iOS 26 上可点的玻璃要声明成
    /// interactive，否则点下去没有形变，看起来像一张静态贴纸（§1.6）。
    /// 只给真正可点的元素开：输入框、可点的胶囊。
    func glassSurface<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(GlassShapeModifier(shape: shape, interactive: interactive))
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
    var interactive: Bool = false

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
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

// MARK: - 内容身份色辅助

extension UIColor {
    /// 内容身份色用 0xRRGGBB 写死；它们是内容身份，不是语义色，不跟随 tint。
    convenience init(identityHex: UInt32) {
        self.init(
            red: CGFloat((identityHex >> 16) & 0xFF) / 255,
            green: CGFloat((identityHex >> 8) & 0xFF) / 255,
            blue: CGFloat(identityHex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - 玻璃分组

extension View {
    /// 内容层上成组浮起的玻璃。iOS 26 交给 `GlassEffectContainer` 统一渲染，
    /// 多个玻璃元素才会相互感知、边缘与光感不打架；更早的系统原样返回。
    @ViewBuilder
    func glassStack() -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer { self }
        } else {
            self
        }
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
        // 系统空态组件（iOS 17 起）：字形层级、字号、间距都由系统给，
        // 和无障碍字号的行为一致。
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            if !message.isEmpty {
                Text(message)
            }
        } actions: {
            if let actionTitle, let action {
                actionButton(title: actionTitle, action: action)
            }
        }
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
