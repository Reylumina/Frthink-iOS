// 写作台聊天区的布局常量与可复用 chrome。
//
// 从 WriterPane 拆离，降低组件耦合。

import SwiftUI

enum WriterChatLayout {
    /// 聊天列表底部锚点。ScrollViewReader 的滚动目标集中在这里。
    static let bottomAnchor = "writer-chat-bottom"
}

/// 多选的选择集运算。
///
/// 多选操作范围限定在当前窗口已加载的消息集合内。
enum WriterSelection {
    /// 「全选 / 取消全选」后的选择集。
    ///
    /// 当当前选择集等于可见集合时清空，否则全选可见集合。
    static func togglingAll(current: Set<String>, visible: Set<String>) -> Set<String> {
        current == visible ? [] : visible
    }

    /// 消息列表变化后把选择集裁回还能看到的消息。
    static func pruning(_ current: Set<String>, visible: Set<String>) -> Set<String> {
        current.intersection(visible)
    }
}

/// 多选条：替换输入条，只保留选择/删除/完成。
struct WriterSelectionBar: View {
    let totalCount: Int
    let selectedCount: Int
    let isBusy: Bool
    let onToggleAll: () -> Void
    let onDelete: () -> Void
    let onDone: () -> Void

    private var allSelected: Bool {
        totalCount > 0 && selectedCount == totalCount
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button(allSelected ? "取消全选" : "全选", action: onToggleAll)
                .font(Font.footnote.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)

            Text("多选 · \(selectedCount)")
                .font(Font.footnote.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(Font.subheadline.weight(.semibold))
                    .frame(
                        minWidth: Theme.Layout.hitTarget,
                        minHeight: Theme.Layout.hitTarget
                    )
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0 || isBusy)
            .accessibilityLabel("删除选中的消息")

            Button("完成", action: onDone)
                .font(Font.footnote.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .background(.bar)
    }
}

/// 跟随流式内容滚到底部。
///
/// 单独成一个零尺寸视图挂在滚动区背景里：`displayTick` 每次合帧才变一次，
/// 读它的小视图只让这一层重算，不会把整列气泡和正文栏一起拉进高频更新
/// （PERFORMANCE.md §2.1）。
///
/// 滚动操作推迟至下一事件循环执行，等待文本追加完成排版后计算准确的滚动目标。
struct WriterStreamingFollower: View {
    let controller: WriterController
    let proxy: ScrollViewProxy
    let isAtBottom: Bool

    @State private var pendingScroll: Task<Void, Never>?

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .onChange(of: controller.displayTick) { _, _ in
                guard isAtBottom, pendingScroll == nil else { return }
                pendingScroll = Task { @MainActor in
                    defer { pendingScroll = nil }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(WriterChatLayout.bottomAnchor, anchor: .bottom)
                }
            }
            .onDisappear {
                pendingScroll?.cancel()
                pendingScroll = nil
            }
    }
}
