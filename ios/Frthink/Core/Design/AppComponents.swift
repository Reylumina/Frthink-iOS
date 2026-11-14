// 二/三/四级界面通用组件：仅补充系统默认样式缺失部分，不持有业务状态。

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 通用纯文本导出文档（UTF-8 `.txt`），供阅读页与创作页 `.fileExporter` 复用。
struct PlainTextFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let decoded = String(data: data, encoding: .utf8)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = decoded
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - 页面底板

extension View {
    /// 分组表单页底：系统分组灰。层次交给卡片、留白和系统材质。
    func groupedPageBackground() -> some View {
        background(Theme.groupedPageColor.ignoresSafeArea())
    }
}

// MARK: - 行内控件

/// 行内圆形图标按钮的可见部分：36pt 圆 + 居中符号（§5.1）。
///
/// 仅绘制视觉外形，点击热区由外层 `CircleIconButton` 或调用方补足至 44pt。
/// 独立拆分以便 `Menu` 组件复用该圆形样式作为 label。
struct CircleIconLabel: View {
    let symbol: String
    var fill: Color = Theme.accentSoft
    var tint: Color = Theme.accent

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = Theme.Layout.controlHeight

    var body: some View {
        Image(systemName: symbol)
            .font(Font.footnote.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
    }
}

/// 行内圆形图标按钮：可见 36pt（Theme.Layout.controlHeight），热区 44pt（§5.1）。
///
/// 世界页排序、新建等行内圆形按钮统一使用此组件，避免各处重复编写
/// 绘制圆形、补足热区与 contentShape 逻辑。
struct CircleIconButton: View {
    let symbol: String
    let label: String
    var fill: Color = Theme.accentSoft
    var tint: Color = Theme.accent
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            CircleIconLabel(symbol: symbol, fill: fill, tint: tint)
                .frame(
                    minWidth: Theme.Layout.hitTarget,
                    minHeight: Theme.Layout.hitTarget
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}

/// 行内搜索框：36pt 胶囊 + 放大镜 + 清除键（§5.1）。
///
/// 清除按钮与胶囊等高，不参与行高计算：若设为 44pt 会导致输入文字后整栏高度增加 8pt。
/// 焦点由组件自己持有，调用方不关心。
struct InlineSearchField: View {
    let placeholder: String
    @Binding var text: String

    @FocusState private var focused: Bool
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = Theme.Layout.controlHeight

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(Font.footnote)
                .foregroundStyle(.tertiary)

            TextField(placeholder, text: $text)
                .font(Font.subheadline)
                .textFieldStyle(.plain)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { focused = false }

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Font.footnote)
                        .foregroundStyle(.tertiary)
                        // 点击热区 44pt，通过负内边距抵消外扩占位，避免搜索框高度增加（§5.1）。
                        .frame(
                            width: Theme.Layout.hitTarget,
                            height: Theme.Layout.hitTarget
                        )
                        .contentShape(Rectangle())
                        .padding(.vertical, -(Theme.Layout.hitTarget - size) / 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(minHeight: size)
        .background(Theme.field)
        .clipShape(Capsule())
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

    /// 胶囊里的文字色：比色相本身更靠近正文色，保证小字对比度。
    var pillText: Color {
        if #available(iOS 18.0, *) {
            return color.mix(with: .primary, by: 0.35)
        }
        return color
    }

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
/// 尺寸采用 `@ScaledMetric`（基准 28pt）：图标背景方块在辅助功能字号下同步缩放。
/// 圆角与字形比例严格对齐系统设置规范：22.6% 圆角、54% 字形比例、medium 字重。
struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    /// 显式尺寸（可选，用于特殊场合）。不传就按 28pt 基准跟随 Dynamic Type 缩放。
    var size: CGFloat? = nil
    /// 实底 + 白色符号（一级分类用，和 Apple 设置同一个做法）；默认是淡底 + tint 符号。
    var filled: Bool = false

    /// 基准 28pt、圆角 22.6%、字形 54%、medium：对齐系统设置规范度量。
    @ScaledMetric(relativeTo: .body) private var baseSize: CGFloat = Theme.Layout.iconTileSize

    private var effectiveSize: CGFloat { size ?? baseSize }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: effectiveSize * 0.54, weight: .medium))
            .foregroundStyle(filled ? Color.white : tint)
            .frame(width: effectiveSize, height: effectiveSize)
            .background(
                filled ? tint : tint.opacity(Theme.tintedFillOpacity),
                in: RoundedRectangle(cornerRadius: effectiveSize * 0.226, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// AI 服务商图标：优先使用官方品牌资产图标，无资产时回退至 SF Symbol。
///
/// 品牌标不做 tinted symbol，保留官方颜色；底色用中性灰，避免品牌色和主题色
/// 互相染色。当前项由旁边的「当前」胶囊表示，不靠图标颜色。
struct ProviderIcon: View {
    let kind: ProviderKind
    var baseURL: String? = nil
    var tint: Color = Theme.accent
    /// 显式尺寸（可选）。默认比 `IconTile` 大 4pt 容纳外框留白，使内部品牌标视觉尺寸与 28pt `IconTile` 一致。
    var size: CGFloat? = nil

    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = Theme.Layout.iconTileSize + 4

    private var resolvedSize: CGFloat { size ?? scaledSize }
    private var resolvedAsset: String? { kind.logoAssetName(forBaseURL: baseURL) }

    var body: some View {
        Group {
            if let asset = resolvedAsset {
                Image(asset)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            } else {
                Image(systemName: kind.symbolName)
                    .font(.system(size: resolvedSize * 0.54, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: resolvedSize, height: resolvedSize)
        .background(
            background,
            in: RoundedRectangle(cornerRadius: resolvedSize * 0.226, style: .continuous)
        )
        .accessibilityHidden(true)
    }

    private var background: Color {
        resolvedAsset == nil ? tint.opacity(0.12) : Color.primary.opacity(0.06)
    }
}

/// 工具栏圆形按钮的标签：28pt 圆 + 一条细描边。
///
/// 与系统搜索框右侧关闭按钮同构，使顶栏各操作具备统一的视觉轮廓，
/// 避免多个独立符号粗细不一致。
struct ToolbarCircleIcon: View {
    let symbol: String
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = Theme.Layout.iconTileSize

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Theme.separator, lineWidth: 0.5))
            // 圆形只是外观，热区补到 44pt（§5.1）。
            .frame(width: Theme.Layout.hitTarget, height: Theme.Layout.hitTarget)
            .contentShape(Circle())
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
    /// 一级分类用实底图标，和内容身份色一致。
    var symbolFilled: Bool = false
    var detail: String? = nil

    var body: some View {
        // 辅助功能字号下横向空间不足时切换为纵向排版：图标置顶，标题与数值各占一行（§5.5）。
        ViewThatFits(in: .horizontal) {
            horizontal
            vertical
        }
    }

    private var horizontal: some View {
        HStack(spacing: Theme.Spacing.m) {
            if let symbol {
                IconTile(symbol: symbol, tint: symbolTint, filled: symbolFilled)
            }
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: Theme.Spacing.s)
            detailText(lineLimit: 1)
        }
        .contentShape(Rectangle())
        .frame(minHeight: Theme.Layout.rowContentHeight)
    }

    private var vertical: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.m) {
                if let symbol {
                    IconTile(symbol: symbol, tint: symbolTint, filled: symbolFilled)
                }
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
            }
            detailText(lineLimit: nil)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Theme.Layout.rowContentHeight)
    }

    @ViewBuilder
    private func detailText(lineLimit: Int?) -> some View {
        if let detail, !detail.isEmpty {
            Text(detail)
                .font(Theme.label)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(lineLimit)
        }
    }
}

/// 两端对齐的只读数值行。数字用等宽，避免刷新时抖动。
struct AppValueRow: View {
    let title: String
    let value: String
    var symbol: String? = nil
    var tone: AppTone = .neutral

    /// 图标列宽随字号缩放，和无障碍字号下的文字列对齐。
    @ScaledMetric(relativeTo: .footnote) private var iconColumn: CGFloat = 20

    var body: some View {
        // 辅助功能字号下数值无法单行容纳时切换为纵向排版，避免数值异常折行断字（§5.5）。
        ViewThatFits(in: .horizontal) {
            horizontal
            vertical
        }
    }

    private var horizontal: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.footnote)
                    .foregroundStyle(tone.color)
                    .frame(width: iconColumn)
            }
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: Theme.Spacing.s)
            Text(value)
                .font(Theme.label)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: Theme.Layout.rowContentHeight)
    }

    private var vertical: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Text(value)
                .font(Theme.label)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Theme.Layout.rowContentHeight)
    }
}

// MARK: - 状态

/// 胶囊状态：当前 / 已停用 / 未填 Key / 已保存。
struct StatusPill: View {
    let text: String
    var tone: AppTone = .neutral

    var body: some View {
        Text(text)
            .font(Theme.badge)
            // 同色小字置于 16% 纯度背景时，浅色模式对比度仅约 2:1；向正文色阶调整后，
            // 深浅两档对比度均满足 4.5:1 标准，且保持色彩语义清晰。
            .foregroundStyle(tone.pillText)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 2)
            .background(Capsule().fill(tone.color.opacity(Theme.tintedFillOpacity)))
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
struct FieldChrome: ViewModifier {
    let focused: Bool
    var horizontal: CGFloat = Theme.Spacing.m
    var vertical: CGFloat = Theme.Spacing.s
    /// 表单行内的字段：不自己画圆角矩形。
    ///
    /// 卡片容器本身具备圆角，若内部输入框重复绘制圆角易造成视觉嵌套不协调，
    /// 且同心圆角半径难保证完全匹配。表单场景下将圆角由外部卡片统一呈现，
    /// 输入字段仅保留内边距与聚焦描边。
    var flat: Bool = false

    func body(content: Content) -> some View {
        let effectiveHorizontal = flat ? 0 : horizontal
        let effectiveVertical = flat ? Theme.Spacing.xs : vertical
        let padded = content
            .padding(.horizontal, effectiveHorizontal)
            .padding(.vertical, effectiveVertical)
        let strokeColor = focused ? Theme.accent.opacity(0.45) : Color.clear

        Group {
            if flat {
                padded
                    .overlay(alignment: .bottom) {
                        if focused {
                            Rectangle()
                                .fill(Theme.accent.opacity(0.6))
                                .frame(height: 1)
                        }
                    }
            } else {
                let shape = RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                padded
                    .background(Theme.field)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(strokeColor, lineWidth: 1))
            }
        }
        .themeAnimation(Theme.motionSelection, value: focused)
    }
}
