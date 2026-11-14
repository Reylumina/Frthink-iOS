// 回收站列表项：书脊 + 书名 + 移入时间，右侧提供恢复主操作。
//
// 「彻底删除」不置于常驻视图：通过滑动操作触发，由 `LibraryTrashView` 统一展示二次确认。
// 回收站属于低频管理场景，将恢复操作作为视觉主操作。
//
// 行内辅助操作使用文本按钮，保持视觉层级清晰。

import SwiftUI

struct LibraryTrashRow: View {
    let project: Project
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            LibraryCoverImage(
                payload: project.coverImagePayload,
                title: project.title,
                seed: project.coverSeed
            )

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(project.shelfTitle)
                    .font(Theme.label.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(LibraryFormat.trashedText(project.trashedAt ?? project.updatedAt))
                    .font(Theme.metadata.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.s)

            Button(action: onRestore) {
                Text("恢复")
                    .font(Theme.label)
                    .frame(minWidth: Theme.Layout.hitTarget, minHeight: Theme.Layout.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("恢复「\(project.shelfTitle)」")
        }
        .frame(minHeight: Theme.Layout.hitTarget)
        .padding(.vertical, Theme.Spacing.xs)
        .swipeActions(edge: .leading) {
            Button(action: onRestore) {
                Label("恢复", systemImage: "arrow.uturn.backward")
            }
            .tint(Theme.accent)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive, action: onDelete) {
                Label("彻底删除", systemImage: "trash.slash")
            }
        }
    }
}
