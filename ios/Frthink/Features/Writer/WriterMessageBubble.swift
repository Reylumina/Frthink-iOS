// 本文件负责：码字机的对话气泡 —— 用户/助手/系统三种样式、版本切换与操作条，
// 以及流式生成中的气泡（只订阅控制器里的实时文本）。

import SwiftUI
import UIKit

/// 一条已完成的码字机消息。
///
/// 助手气泡底部只保留一个主操作「插入正文」和两个图标动作，其余（回退、删版本）
/// 收进省略号菜单。常驻控件从 4 个文字按钮 + 版本条压到 3 个，长对话才不吵。
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

struct WriterMessageBubble: View {
    let message: ChatMessage
    /// 有任何一条消息正在生成时，操作条禁用，避免并发改同一份对话。
    let isBusy: Bool
    /// 多选态：整条气泡可点选，操作条隐藏。
    let isSelecting: Bool
    let isSelected: Bool
    /// 上次生成被系统中断；状态属于这条消息，不再由外层挂 overlay。
    var isInterrupted = false
    let actions: WriterMessageActions

    @Environment(AppStore.self) private var store

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
                    .padding(4)
                    .background(.regularMaterial, in: Circle())
                    .offset(x: -2, y: -2)
            }
        }
    }

    // MARK: - 三种样式

    private var systemRow: some View {
        Text(message.content)
            .font(Font.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var userRow: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 48)
            MarkdownInline.text(message.content)
                .font(Font.subheadline)
                .foregroundStyle(.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s + 2)
                .background(Theme.accentSoft)
                .clipShape(RoundedRectangle(
                    cornerRadius: Theme.Radius.large,
                    style: .continuous
                ))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var assistantRow: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            header
            content
            if !isSelecting {
                footer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text("码字机")
                .font(Font.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
            if let model = message.model, !model.isEmpty {
                Text(model)
                    .font(Theme.numeric)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if isInterrupted {
                Text("生成中断")
                    .font(Theme.badge)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, Theme.Spacing.s)
                    .padding(.vertical, 2)
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
    private var content: some View {
        Group {
            if message.content.isEmpty {
                Text("（空回复）")
                    .foregroundStyle(.tertiary)
            } else {
                MarkdownInline.text(message.content)
            }
        }
        .dynamicBodyFont(store.settings.bodyFontSize)
        .foregroundStyle(.primary)
        .lineSpacing(3)
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
                    Image(systemName: "ellipsis")
                        .font(Font.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
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
            Image(systemName: symbol)
                .font(Font.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
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
                    .frame(width: 44, height: 44)
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
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .disabled(message.selectedVariant >= message.variants.count - 1)
            .accessibilityLabel("下一版本")

            Spacer(minLength: 0)
        }
    }
}

/// 流式生成中的气泡，只订阅控制器里的实时文本。
struct WriterStreamingBubble: View {
    let controller: WriterController

    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var reasoningExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Text("码字机")
                    .font(Font.caption.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                ProgressView().controlSize(.mini)
                Text(controller.streamingText.isEmpty ? "思考中…" : "正在生成")
                    .font(Font.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text("\(controller.streamingCharacterCount.formatted()) 字")
                    .font(Theme.numericSmall)
                    .foregroundStyle(.tertiary)
            }

            if let reasoning = controller.streamingReasoning, !reasoning.isEmpty {
                DisclosureGroup(isExpanded: $reasoningExpanded) {
                    Text(reasoning)
                        .font(Theme.numeric)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } label: {
                    Text("思考过程 · \(reasoning.count.formatted()) 字")
                        .font(Font.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }

            if controller.streamingText.isEmpty {
                Text("……")
                    .font(Theme.reply)
                    .foregroundStyle(.tertiary)
            } else {
                // 生成中用 UITextView 增量排版；结束后的普通气泡仍用 Text。
                StreamingTextView(
                    text: controller.streamingText,
                    fontSize: DynamicTypeFont.bodySize(
                        store.settings.bodyFontSize,
                        dynamicTypeSize: dynamicTypeSize
                    )
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

/// 复制到系统剪贴板。单独放一处，页面里不用为了 `UIPasteboard` 再 import UIKit。
enum WriterClipboard {
    static func copy(_ text: String) {
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }
}
