// 回收站：单独一页。恢复是主操作，彻底删除只走滑动/确认，避免误触。
//
// 彻底删除不可恢复，确认用 `confirmationDialog`，只留标题和动作按钮。

import SwiftUI

struct LibraryTrashView: View {
    let store: AppStore

    @State private var pendingDelete: Project?

    private var projects: [Project] {
        store.trashedProjects.sorted {
            ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast)
        }
    }

    @ViewBuilder
    private var trashContent: some View {
        if projects.isEmpty {
            EmptyStateView(
                symbol: "trash",
                title: "回收站是空的"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                Section {
                    ForEach(projects) { project in
                        LibraryTrashRow(
                            project: project,
                            onRestore: { restore(project) },
                            onDelete: { pendingDelete = project }
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .frame(maxWidth: Theme.Layout.formMaxWidth)
            .frame(maxWidth: .infinity)
            .softScrollEdge()
            .themeAnimation(Theme.motionLayout, value: projects.count)
        }
    }

    var body: some View {
        trashContent
            .groupedPageBackground()
            .navigationTitle("回收站")
            .navigationBarTitleDisplayMode(.inline)
        .alert(
            pendingDelete.map { "彻底删除「\($0.shelfTitle)」？" } ?? "彻底删除这本书？",
            isPresented: deleteDialogBinding
        ) {
            Button("彻底删除", role: .destructive) {
                if let project = pendingDelete {
                    store.deleteForever(project)
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { isPresented in
                if !isPresented { pendingDelete = nil }
            }
        )
    }

    @MainActor
    private func restore(_ project: Project) {
        store.restore(project)
        store.toast = "已恢复「\(project.shelfTitle)」"
    }
}
