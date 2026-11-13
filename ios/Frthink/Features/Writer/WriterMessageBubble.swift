// 本文件负责：码字机的对话气泡 —— 用户/助手/系统三种样式、版本切换与操作条，
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

/// 一条已完成的码字机消息。
///
/// 助手气泡底部是四个图标动作（插入、追加、复制、重新生成），回退与删版本收进
/// 省略号菜单；版本切换条只在有多版本时出现。
struct WriterMessageBubble: View {
    let message: ChatMessage
    /// 有任何一条消息正在生成时，操作条禁用，避免并发改同一份对话。
    let isBusy: Bool
    /// 多选态：整条气泡可点选，操作条隐藏。
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

    /// 与流式视图、正文编辑器同一套字号。
    private var bodyFontSize: CGFloat {
        WriterTypography.fontSize(store.settings.bodyFontSize, dynamicTypeSize: dynamicTypeSize)
    }

    /// 行高固定 1.6；流式气泡用同一个值，生成结束换气泡不会变高。
    private var bodyLineSpacing: CGFloat {
        WriterTypography.lineSpacing(size: bodyFontSize)
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
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                if !isSelecting { actions.beginSelection() }
            }
        )
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
            if !isSelecting {
                footer
                    .padding(.horizontal, Theme.Spacing.xs)
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

    /// 已完成的回复：只有出现 `**`/`__` 时才解析行内 Markdown，
    /// 长对话里的普通正文保持纯文本，不每帧跑解析。
    ///
    /// 分段按段排版，段间留 `WriterTypography.paragraphSpacing`：整段当成一个
    /// Text 时，模型输出里的空行会按整行高度排版，段间比阅读页松一倍。
    private var content: some View {
        let paragraphs = WriterTypography.paragraphs(message.content)
        return Group {
            if paragraphs.isEmpty {
                Text("（空回复）")
                    .foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: WriterTypography.paragraphSpacing(size: bodyFontSize)) {
                    ForEach(paragraphs.indices, id: \.self) { index in
                        MarkdownInline.text(paragraphs[index])
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

    // MARK: - 操作条

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.xs) {
                iconAction("text.insert", "插入到光标处", actions.insert)
                iconAction("text.append", "追加到正文末尾", actions.append)

                Spacer(minLength: 0)

                iconAction("doc.on.doc", "复制消息", actions.copy)
                iconAction("arrow.clockwise", "重新生成", actions.regenerate)

                Menu {
                    Button {
                        actions.rollback()
                    } label: {
                        Label("回退到此", systemImage: "arrow.uturn.backward")
                    }
                    if message.variants.count > 1 {
                        Button {
                            actions.cleanupVersions()
                        } label: {
                            Label("清理历史版本", systemImage: "archivebox")
                        }
                    }
                    Button(role: .destructive) {
                        actions.deleteVariant()
                    } label: {
                        Label(
                            message.variants.count > 1 ? "删除当前版本" : "删除气泡",
                            systemImage: "trash"
                        )
                    }
                    Divider()
                    Button {
                        actions.beginSelection()
                    } label: {
                        Label("多选", systemImage: "checklist")
                    }
                } label: {
                    IconTile(symbol: "ellipsis", tint: .gray, filled: true)
                        .frame(width: Theme.Layout.hitTarget, height: Theme.Layout.hitTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("更多消息操作")
            }

            if message.hasBranches {
                versionSwitcher
            }
        }
        .padding(.top, Theme.Spacing.xs)
        .disabled(isBusy)
        .opacity(isBusy ? 0.45 : 1)
    }

    private func iconAction(
        _ symbol: String,
        _ label: String,
        _ action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            IconTile(symbol: symbol, tint: .gray, filled: true)
                .frame(width: Theme.Layout.hitTarget, height: Theme.Layout.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
/// 文本按 `displayInterval`（60ms）合帧后写进 `streamingText`；这里只渲染
/// 控制器给的当前值，不自己定时，也不逐 token 触发外层列表重算。
struct WriterStreamingBubble: View {
    let controller: WriterController
    /// 正文栏宽度上限。与完成态气泡同一宽度，换气泡时不重新折行（§2.3）。
    var bodyMaxWidth: CGFloat = .infinity

    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        if controller.streamingText.isEmpty {
            if let reasoning = controller.streamingReasoning, !reasoning.isEmpty {
                // 正文还是空的时候，把思考过程的末尾几行铺出来：模型思考几十秒
                // 时页面不能只挂一个转圈，看起来像卡死。
                Text(Self.recentLines(reasoning, limit: 6))
                    .font(Theme.reply)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                // 首帧就有内容：占位也算一行正文，气泡不会是零高度。
                Text("……")
                    .font(Theme.reply)
                    .foregroundStyle(.tertiary)
            }
        } else {
            if let reasoning = controller.streamingReasoning, !reasoning.isEmpty {
                DisclosureGroup(isExpanded: $reasoningExpanded) {
                    Text(reasoning)
                        .font(Theme.numeric)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } label: {
                    Text("思考过程（\(reasoning.count.formatted()) 字）")
                        .font(Font.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            // 生成中用 UITextView 增量排版；字号/行距/宽度与完成态 `Text` 同一套换算。
            StreamingTextView(
                text: controller.streamingText,
                fontSize: bodyFontSize,
                lineSpacing: WriterTypography.lineSpacing(size: bodyFontSize)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 思考过程只显示末尾几行；全文仍留在展开区里。
    private static func recentLines(_ text: String, limit: Int) -> String {
        let lines = text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let recent = lines.suffix(limit)
        return recent.isEmpty ? String(text.suffix(240)) : recent.joined(separator: "\n")
    }
}

/// 复制到系统剪贴板。单独放一处，页面里不用为了 `UIPasteboard` 再 import UIKit。
enum WriterClipboard {
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }
}
