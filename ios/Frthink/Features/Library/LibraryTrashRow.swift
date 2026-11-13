// 回收站里的一行：书脊 + 书名 + 移入时间，右侧只有一个「恢复」动作。
//
// 「彻底删除」不进常驻布局：走左滑/右滑动作，二次确认由 `LibraryTrashView` 统一弹。
// 回收站不是一个常来常往的地方，恢复应该是唯一显眼的动作。
//
// 行内动作使用纯文字按钮，避免与「恢复」抢层级。

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
