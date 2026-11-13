// 本文件负责：码字机的对话气泡 —— 用户/助手/系统三种样式与版本切换，
// 以及流式生成中的气泡（只订阅控制器里的实时文本）。

import SwiftUI
import UIKit

/// 气泡上的用户动作。集中成一组，调用方不用在 init 里排十几行闭包。
struct WriterMessageActions {
    var copy: () -> Void = {}
    var insert: () -> Void = {}
    var append: () -> Void = {}
    var regenerate: () -> Void = {}
    var rollback: () -> Void = {}
    var selectVariant: (Int) -> Void = { _ in }
    var cleanupVersions: () -> Void = {}
    var deleteVariant: () -> Void = {}
    var toggleSelection: () -> Void = {}
    var beginSelection: () -> Void = {}
}

/// 一条已完成的码字机消息。版本切换条只在有多版本时出现。
struct WriterMessageBubble: View {
    let message: ChatMessage
    /// 生成中传 true，避免并发修改同一份对话。
    let isBusy: Bool
    /// 多选态：整条气泡可点选。
    let isSelecting: Bool
    let isSelected: Bool
    /// 上次生成被系统中断；状态属于这条消息，不再由外层挂 overlay。
    var isInterrupted = false
    /// 正文栏宽度上限（字号 × 36，§2.3）。超出时居中（§5.3）。
    var bodyMaxWidth: CGFloat = .infinity
    /// 用户气泡的宽度上限 = 对话列宽的 80%（§5.3）。nil 表示列宽还没量到。
    var userBubbleMaxWidth: CGFloat?
    let actions: WriterMessageActions

    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 阅读页调过的行距，创作页跟着用同一个值。
    @AppStorage(ReaderStorageKey.lineHeight) private var lineHeight: Double = 1.5

    /// 与流式视图、正文编辑器同一套字号。
    private var bodyFontSize: CGFloat {
        WriterTypography.fontSize(store.settings.bodyFontSize, dynamicTypeSize: dynamicTypeSize)
    }

    /// 与流式气泡共用同一套行距，生成结束换气泡不会变高。
    private var bodyLineSpacing: CGFloat {
        WriterTypography.lineSpacing(size: bodyFontSize, lineHeight: lineHeight)
    }

    var body: some View {
        Group {
            switch message.role {
            case .system:
                systemRow
            case .user:
                userRow
            case .assistant:
                assistantRow
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting { actions.toggleSelection() }
        }
        // 长按交给外层挂的 contextMenu（复制/撤回/重新生成…），这里不再抢手势。
        .overlay(alignment: .topLeading) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(Font.title3)
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                    .padding(Theme.Spacing.xs)
                    // 浮在内容上的选中标记也走统一玻璃入口，不在页面里直接铺材质（§1.6）。
                    .glassSurface(Circle())
                    .offset(x: -2, y: -2)
            }
        }
    }

    // MARK: - 三种样式

    /// 系统行：一次性状态，只占一行，最常见的弱层级。
    private var systemRow: some View {
        Text(message.content)
            .font(Font.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 用户气泡：实底 + 反色文字（§1.3）。收发关系由实底/无底表达，
    /// 和系统「信息」一致；不加描边、不加投影，宽度不超过列宽 80%（§5.3）。
    private var userRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: Theme.Spacing.xxl)
            MarkdownInline.text(message.content)
                .font(Font.body)
                .dynamicBodyFont(store.settings.bodyFontSize)
                .foregroundStyle(Theme.bubbleForeground)
                .lineSpacing(bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .background(Theme.bubbleFill, in: Theme.containerShape())
                .frame(maxWidth: userBubbleMaxWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            header
            content
            if message.hasBranches, !isSelecting {
                versionSwitcher
                    .padding(.top, Theme.Spacing.xs)
            }
        }
        // 助手回复不铺底色，正文即气泡（§1.3）。
        .frame(maxWidth: bodyMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            WriterAssistantBadge()
            if let model = message.model, !model.isEmpty {
                Text(model)
                    .font(Theme.numeric)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if isInterrupted {
                Text("已中断")
                    .font(Theme.badge)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(Capsule().fill(Theme.accentSoft))
            }
            Spacer(minLength: 0)
            if message.hasBranches {
                Text("\(message.selectedVariant + 1)/\(message.variants.count)")
                    .font(Theme.numericSmall)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 已完成的回复：分段按段排版，段间留 `WriterTypography.paragraphSpacing`。
    /// 整段当成一个视图时，模型输出里的空行会按整行高度排版，段间比阅读页松一倍。
    private var content: some View {
        let paragraphs = WriterTypography.paragraphs(message.content)
        return Group {
            if paragraphs.isEmpty {
                Text("（空回复）")
                    .foregroundStyle(.tertiary)
            } else {
                // 段与段之间用 TextKit 的段后间距，VStack 不再额外留白。
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(paragraphs.indices, id: \.self) { index in
                        paragraph(paragraphs[index], isLast: index == paragraphs.count - 1)
                    }
                }
            }
        }
        .dynamicBodyFont(store.settings.bodyFontSize)
        .foregroundStyle(.primary)
        .lineSpacing(bodyLineSpacing)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 一段正文：两端对齐，一到三级标题按字号和字重区分。
    ///
    /// 排版走 `JustifiedText`（TextKit）：SwiftUI 的 Text 没有两端对齐，
    /// 而中文长行左对齐时右边参差很明显。
    private func paragraph(_ text: String, isLast: Bool) -> some View {
        let level = MarkdownInline.headingLevel(text)
        let plain = level == nil ? text : MarkdownInline.strippingHeadingMarker(text)
        let size = level.map(headingSize) ?? bodyFontSize
        let weight: UIFont.Weight = level == nil ? .regular : .semibold
        return JustifiedText(
            attributed: attributed(plain, size: size, weight: weight),
            lineSpacing: WriterTypography.lineSpacing(size: bodyFontSize, lineHeight: lineHeight),
            paragraphSpacing: isLast
                ? 0
                : WriterTypography.paragraphSpacing(size: bodyFontSize, lineHeight: lineHeight)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 段内排版：加粗/斜体按 run 换字体，颜色交给系统语义色。
    private func attributed(
        _ text: String,
        size: CGFloat,
        weight: UIFont.Weight
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (run, style) in MarkdownInline.runs(text) {
            let font: UIFont
            switch style {
            case .normal:
                font = .systemFont(ofSize: size, weight: weight)
            case .bold:
                font = .systemFont(ofSize: size, weight: weight == .semibold ? .bold : .bold)
            case .italic:
                let base = UIFont.systemFont(ofSize: size, weight: weight)
                font = base.fontDescriptor.withSymbolicTraits(.traitItalic)
                    .map { UIFont(descriptor: $0, size: size) } ?? base
            }
            result.append(NSAttributedString(
                string: run,
                attributes: [.font: font, .foregroundColor: UIColor.label]
            ))
        }
        return result
    }

    /// 标题字号按正文字号派生：一/二/三级分别 1.45 / 1.26 / 1.12 倍。
    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return bodyFontSize * 1.45
        case 2: return bodyFontSize * 1.26
        default: return bodyFontSize * 1.12
        }
    }

    /// `‹ 2/3 ›`：同一条回复的候选版本，切换只改 selectedVariant，不新增消息。
    private var versionSwitcher: some View {
        HStack(spacing: Theme.Spacing.s) {
            Button {
                actions.selectVariant(message.selectedVariant - 1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(Font.caption.weight(.semibold))
                    .frame(width: Theme.Layout.hitTarget, height: Theme.Layout.hitTarget)
            }
            .buttonStyle(.plain)
            .disabled(message.selectedVariant <= 0)
            .accessibilityLabel("上一版本")

            Text("\(message.selectedVariant + 1)/\(message.variants.count) 版本")
                .font(Theme.numericSmall)
                .foregroundStyle(.secondary)

            Button {
                actions.selectVariant(message.selectedVariant + 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(Font.caption.weight(.semibold))
                    .frame(width: Theme.Layout.hitTarget, height: Theme.Layout.hitTarget)
            }
            .buttonStyle(.plain)
            .disabled(message.selectedVariant >= message.variants.count - 1)
            .accessibilityLabel("下一版本")

            Spacer(minLength: 0)
        }
    }
}

/// 码字机的身份标记：圆形符号 + 名字，完成与流式气泡共用。
struct WriterAssistantBadge: View {
    /// 圆标直径跟随字号缩放（§5.1、§2.4），图标尺寸由所在文字决定。
    @ScaledMetric(relativeTo: .caption) private var markDiameter: CGFloat = 18

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "sparkles")
                .font(Theme.badge)
                // 强调色圆底上的图标用 onAccent（深色档 accent 是浅墨青，白字不够）。
                .foregroundStyle(Theme.onAccent)
                .frame(width: markDiameter, height: markDiameter)
                .background(Theme.accent, in: Circle())
            Text("码字机")
                .font(Font.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("码字机")
    }
}

/// 流式生成中的气泡，只订阅控制器里的实时文本。
///
/// 文本按 `displayInterval`（33ms）合帧后写进 `streamingText`；这里只渲染
/// 控制器给的当前值，不自己定时，也不逐 token 触发外层列表重算。
struct WriterStreamingBubble: View {
    let controller: WriterController
    /// 正文栏宽度上限。与完成态气泡同一宽度，换气泡时不重新折行（§2.3）。
    var bodyMaxWidth: CGFloat = .infinity

    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// 阅读页调过的行距，流式气泡跟着用同一个值。
    @AppStorage(ReaderStorageKey.lineHeight) private var lineHeight: Double = 1.5
    @State private var reasoningExpanded = false

    private var bodyFontSize: CGFloat {
        WriterTypography.fontSize(store.settings.bodyFontSize, dynamicTypeSize: dynamicTypeSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            header
            content
        }
        .frame(maxWidth: bodyMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xs)
    }

    /// 生成中的状态行：只报「创作中 + 字数」。
    /// 停止入口在输入条的主操作键上（§5.7），这里不再放第二个停止按钮。
    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            WriterAssistantBadge()
            Text("创作中")
                .font(Font.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("\(controller.streamingCharacterCount.formatted()) 字")
                .font(Theme.numericSmall)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder
    private var content: some View {
        // 思考过程默认收起：只是一行字，点一下展开，不加任何图标。
        if let reasoning = controller.streamingReasoning, !reasoning.isEmpty {
            reasoningBlock(reasoning)
        }

        if controller.streamingText.isEmpty {
            // 首帧就有内容：占位也算一行正文，气泡不会是零高度。
            Text("……")
                .font(Theme.reply)
                .foregroundStyle(.tertiary)
        } else {
            // 生成中用 UITextView 增量排版；字号/行距/宽度与完成态气泡同一套换算。
            StreamingTextView(
                text: controller.streamingText,
                fontSize: bodyFontSize,
                lineSpacing: WriterTypography.lineSpacing(size: bodyFontSize, lineHeight: lineHeight)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 思考过程：一行文字按钮，点一下展开全文，再点收起。不用 DisclosureGroup——
    /// 它自带一个箭头图标，触屏上直接点这一行更好用。
    private func reasoningBlock(_ reasoning: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Button {
                reasoningExpanded.toggle()
            } label: {
                Text(reasoningExpanded
                     ? "收起思考过程（\(reasoning.count.formatted()) 字）"
                     : "思考过程（\(reasoning.count.formatted()) 字）")
                    .font(Font.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(reasoningExpanded ? "收起思考过程" : "展开思考过程")

            if reasoningExpanded {
                Text(reasoning)
                    .font(Theme.numeric)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}

/// 复制到系统剪贴板。单独放一处，页面里不用为了 `UIPasteboard` 再 import UIKit。
enum WriterClipboard {
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }
}
