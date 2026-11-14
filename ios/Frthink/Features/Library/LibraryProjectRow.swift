// 书架上的书稿行：书脊 + 书名 + 一行元数据，右侧只有一套「⋯」菜单。
//
// 简介不展示在书架列表行中，避免高度增加并遮挡编辑时间等关键元数据。
// 简介在 ⋯ →「改简介」中编辑，列表仅作为索引导航。

import SwiftUI

/// 顶部「继续写作」：当前书稿的快速访问入口；下方「全部书稿」仍保留该项。
struct LibraryContinueRow: View {
    let project: Project
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.m) {
                LibraryCoverImage(
                    payload: project.coverImagePayload,
                    title: project.title,
                    seed: project.coverSeed
                )

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(project.shelfTitle)
                        .font(Theme.labelEmphasis)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(LibraryFormat.updatedText(project.updatedAt))
                        .font(Theme.metadata.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Theme.Spacing.s)

                Image(systemName: "chevron.right")
                    .font(Font.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: Theme.Layout.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("继续写作：\(project.shelfTitle)")
    }
}

struct LibraryProjectRow: View {
    let project: Project
    let branchCount: Int
    let isCurrent: Bool
    let onOpen: () -> Void
    let onRename: () -> Void
    let onSynopsis: () -> Void
    let onBranches: () -> Void
    let onTrash: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.m) {
                LibraryCoverImage(
                    payload: project.coverImagePayload,
                    title: project.title,
                    seed: project.coverSeed
                )

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(project.shelfTitle)
                            .font(Theme.label.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if isCurrent {
                            StatusPill(text: "正在写", tone: .accent)
                        }
                    }

                    metadata
                }

                // 为行尾操作菜单预留完整交互热区，文本避免与按钮重叠。
                Spacer(minLength: Theme.Layout.hitTarget)
            }
            .frame(minHeight: Theme.Layout.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            menu
        }
        .padding(.vertical, Theme.Spacing.xs)
        .swipeActions(edge: .leading) {
            Button { onBranches() } label: {
                Label("分支", systemImage: "arrow.triangle.branch")
            }
            .tint(Theme.accent)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { onTrash() } label: {
                Label("移入回收站", systemImage: "trash")
            }
        }
    }

    /// 时间、字数与分支数合并展示，统一使用辅助元数据字号。
    private var metadata: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(LibraryFormat.updatedText(project.updatedAt))
            if let count = project.bodyCharacterCount, count > 0 {
                Text("\(count.formatted()) 字")
            }
            if branchCount > 1 {
                Text(LibraryFormat.branchText(branchCount))
            }
        }
        .font(Theme.metadata.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// 行尾操作菜单：书架列表的统一操作入口，不额外挂载长按上下文菜单。
    private var menu: some View {
        Menu {
            Button { onOpen() } label: {
                Label("打开", systemImage: "book.pages")
            }
            Button { onRename() } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button { onSynopsis() } label: {
                Label("改简介", systemImage: "text.alignleft")
            }
            Button { onBranches() } label: {
                Label("分支（\(branchCount)）", systemImage: "arrow.triangle.branch")
            }
            Divider()
            Button(role: .destructive) { onTrash() } label: {
                Label("移入回收站", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(Theme.label.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Theme.Layout.hitTarget, height: Theme.Layout.hitTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("管理「\(project.shelfTitle)」")
    }
}
