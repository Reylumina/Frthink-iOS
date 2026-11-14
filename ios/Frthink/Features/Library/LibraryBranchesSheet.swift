// 同一本书的分支（平行稿）列表：可打开现有分支或新建分支。
//
// 分支也是书稿：行内沿用书架的「书脊 + 书名 + 一行元数据」语法，
// 打开后与书架行看到的是同一本书的同一份索引。

import SwiftUI

struct LibraryBranchesSheet: View {
    let store: AppStore
    /// 当前活跃分支，用于标记当前查看项。
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
            // 当前弹窗会写入 `store.toast`（分支创建结果）；因根视图 Toast 被
            // 模态层覆盖，在此处单独挂载 Toast 提示。
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
            .alert(
                "新建分支副本？",
                isPresented: $confirmingCreate
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

    /// 分支序号与最近编辑时间合并显示，保持与书架格式一致。
    private func subtitle(for branch: Project) -> String {
        "第 \(branch.branchOrder + 1) 条 · " + LibraryFormat.updatedText(branch.updatedAt)
    }

    /// 复制当前分支（即新建分支）：`duplicate` 会将副本关联至同一个分支根节点。
    private func createBranch() {
        let copy = store.duplicate(project)
        // 失败时 `duplicate` 返回原入参，通过 ID 区分操作结果。
        if copy.id != project.id {
            store.toast = "已创建分支「\(copy.title)」"
        }
    }
}
