// 书架上的书稿行：书脊 + 书名 + 简介 + 元信息，右侧只有一套「⋯」菜单。

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
                .frame(width: 56, height: 74)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(project.shelfTitle)
                        .font(Font.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(LibraryFormat.updatedText(project.updatedAt))
                        .font(Font.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: Theme.Spacing.s)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
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
                .frame(width: 52, height: 70)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(project.shelfTitle)
                            .font(Font.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isCurrent {
                            StatusPill(text: "正在写", tone: .accent)
                        }
                    }

                    if !project.synopsis.isEmpty {
                        Text(project.synopsis)
                            .font(Font.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: Theme.Spacing.s) {
                        Text(LibraryFormat.updatedText(project.updatedAt))
                        if let count = project.bodyCharacterCount, count > 0 {
                            Text("\(count.formatted()) 字")
                        }
                        if branchCount > 1 {
                            Text("\(branchCount) 分支")
                        }
                    }
                    .font(Theme.numericSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                }

                Spacer(minLength: 40)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            Menu {
                Button { onOpen() } label: {
                    Label("打开", systemImage: "book")
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
                    .font(Font.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .tint(.secondary)
            .accessibilityLabel("管理「\(project.shelfTitle)」")
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
}
