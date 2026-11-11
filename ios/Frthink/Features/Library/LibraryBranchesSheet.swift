// 同一本书的分支（平行稿）列表：可以打开任意分支，或再创建一条。

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
            .groupedPageBackground()
            .navigationTitle("分支")
            .navigationBarTitleDisplayMode(.inline)
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
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(branch.title)
                        .font(Font.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(subtitle(for: branch))
                        .font(Font.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: Theme.Spacing.s)

                if branch.id == project.id {
                    StatusPill(text: "当前")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var branches: [Project] {
        store.branches(of: project)
    }

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
