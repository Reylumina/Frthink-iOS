// 同一本书的分支（平行稿）列表：可以打开任意分支，或再创建一条。
//
// 分支也是书稿：行内沿用书架的「书脊 + 书名 + 一行元数据」语法，
// 打开后与书架行看到的是同一本书的同一份索引。

import SwiftUI

struct LibraryBranchesSheet: View {
    let store: AppStore
    /// 当前正在看的这条分支，用来标记「当前」。
    let project: Project
    let onOpen: (Project) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingCreate = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(branches) { branch in
                        row(branch)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: Theme.Layout.formMaxWidth)
            .frame(maxWidth: .infinity)
            .softScrollEdge()
            .themeAnimation(Theme.motionLayout, value: branches.count)
            .groupedPageBackground()
            .navigationTitle("分支")
            .navigationBarTitleDisplayMode(.inline)
            // 这个 sheet 会写 `store.toast`（创建分支的结果），根视图的 toast 被
            // 展示层盖住，所以在这一层再挂一次。
            .sheetToast()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        confirmingCreate = true
                    } label: {
                        Text("新建分支")
                    }
                }
            }
            .confirmationDialog(
                "新建分支副本？",
                isPresented: $confirmingCreate,
                titleVisibility: .visible
            ) {
                Button("新建分支副本") {
                    createBranch()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private func row(_ branch: Project) -> some View {
        Button {
            onOpen(branch)
            dismiss()
        } label: {
            HStack(spacing: Theme.Spacing.m) {
                LibraryCoverImage(
                    payload: branch.coverImagePayload,
                    title: branch.title,
                    seed: branch.coverSeed
                )

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(branch.shelfTitle)
                        .font(Theme.label.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(subtitle(for: branch))
                        .font(Theme.metadata.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Theme.Spacing.s)

                if branch.id == project.id {
                    StatusPill(text: "当前")
                }
            }
            .frame(minHeight: Theme.Layout.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var branches: [Project] {
        store.branches(of: project)
    }

    /// 第几条 + 最近编辑时间：和书架一样合成一行，不再单独放一行说明。
    private func subtitle(for branch: Project) -> String {
        "第 \(branch.branchOrder + 1) 条 · " + LibraryFormat.updatedText(branch.updatedAt)
    }

    /// 复制当前分支就是「再创建一条分支」：`duplicate` 会把副本挂到同一个分支根下。
    private func createBranch() {
        let copy = store.duplicate(project)
        // 失败时 `duplicate` 原样返回入参，用 id 区分成功与失败。
        if copy.id != project.id {
            store.toast = "已创建分支「\(copy.title)」"
        }
    }
}
