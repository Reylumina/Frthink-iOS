// 回收站：单独一页。恢复是主操作，彻底删除只走滑动/确认，避免误触。

import SwiftUI

struct LibraryTrashView: View {
    let store: AppStore

    @State private var pendingDelete: Project?

    private var projects: [Project] {
        store.trashedProjects.sorted {
            ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast)
        }
    }

    var body: some View {
        Group {
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
            }
        }
        .groupedPageBackground()
        .navigationTitle("回收站")
        .navigationBarTitleDisplayMode(.inline)
        .alert(deleteAlertTitle, isPresented: deleteAlertBinding) {
            Button("取消", role: .cancel) { pendingDelete = nil }
            Button("彻底删除", role: .destructive) {
                if let project = pendingDelete {
                    store.deleteForever(project)
                    store.toast = "已彻底删除"
                }
                pendingDelete = nil
            }
        }
    }

    private var deleteAlertTitle: String {
        guard let project = pendingDelete else { return "彻底删除这本书？" }
        return "彻底删除「\(project.shelfTitle)」？"
    }

    private var deleteAlertBinding: Binding<Bool> {
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
