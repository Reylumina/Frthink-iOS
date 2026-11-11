// 回收站里的一行：书脊 + 书名 + 移入时间，右侧只有一个「恢复」主操作。
//
// 「彻底删除」不进常驻布局：走左滑/右滑动作，二次确认由 `LibraryTrashView` 统一弹。
// 回收站不是一个常来常往的地方，恢复应该是唯一显眼的动作。

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
                seed: project.id
            )
            .frame(width: 40, height: 54)
            .opacity(0.85)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.shelfTitle)
                    .font(Font.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !project.synopsis.isEmpty {
                    Text(project.synopsis)
                        .font(Font.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(LibraryFormat.trashedText(project.trashedAt ?? project.updatedAt))
                    .font(Theme.numericSmall)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: Theme.Spacing.s)

            Button(action: onRestore) {
                Text("恢复")
                    .font(Font.footnote.weight(.medium))
                    .frame(minWidth: 56, minHeight: 32)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(Theme.accent)
            .accessibilityLabel("恢复「\(project.shelfTitle)」")
        }
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
