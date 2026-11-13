// 书架上的书稿行：书脊 + 书名 + 一行元数据，右侧只有一套「⋯」菜单。
//
// 简介不进书架：一行简介会把行撑成三行，把「最近编辑时间」挤出视线（§6）。
// 简介在 ⋯ →「改简介」里编辑，列表只做索引。

import SwiftUI

/// 顶部「继续写作」：当前书稿的快速回访入口；下面的「全部书稿」仍保留它。
struct LibraryContinueRow: View {
    let project: Project
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.m) {
                LibraryCoverImage(
                    payload: project.coverImagePayload,
                    title: project.title,
                    seed: project.id
                )

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(project.shelfTitle)
                        .font(Theme.bookTitle)
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

/// 全部书稿里的一行。
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
                    seed: project.id
                )

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(project.shelfTitle)
                            .font(Theme.bookTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if isCurrent {
                            StatusPill(text: "正在写", tone: .accent)
                        }
                    }

                    metadata
                }

                // 给行尾的 ⋯ 菜单留出完整热区，文字不能伸到按钮下面。
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

    /// 时间、字数、分支数合成一行：三项都是会冒出来的数字，统一用元信息的字号。
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

    /// 行尾 ⋯：书架只有这一套菜单入口，不再另挂长按菜单。
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
