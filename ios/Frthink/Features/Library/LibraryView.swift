// 书架根页面：继续写作、全部书稿与回收站/设置入口。
//
// 提供快捷回到当前项目、切换书稿及进入回收站等核心入口；右上角提供新建入口。
// 列表以书脊、书名和最近编辑时间作为索引。
//
// 宽屏（iPad、可调整大小的窗口）下列表按 `Theme.Layout.formMaxWidth` 居中，
// 页面底色铺满，内容不随窗口拉伸。

import SwiftUI

struct LibraryView: View {
    let store: AppStore
    /// 当前活跃书稿项目；由 `RootView` 传入，用于标明当前写作项。
    var activeProjectID: String? = nil
    let onOpen: (Project) -> Void
    /// 跳转设置回调：由 `RootView` 负责关闭书架并切换至设置选项卡。
    var onOpenSettings: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var editTarget: LibraryEditTarget?
    @State private var branchTarget: Project?
    @State private var showTrashOnLaunch = false
    @State private var didApplyLaunch = false

    init(
        store: AppStore,
        activeProjectID: String? = nil,
        onOpen: @escaping (Project) -> Void,
        onOpenSettings: (() -> Void)? = nil
    ) {
        self.store = store
        self.activeProjectID = activeProjectID
        self.onOpen = onOpen
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        List {
            if let project = continueProject {
                Section {
                    LibraryContinueRow(project: project) {
                        onOpen(project)
                    }
                } header: {
                    AppSectionHeader(title: "继续写作")
                }
            }

            booksSection
            placesSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: Theme.Layout.formMaxWidth)
        .frame(maxWidth: .infinity)
        .softScrollEdge()
        // 移入回收站、新建、恢复都会增删行；列表增删使用 motionLayout。
        .themeAnimation(Theme.motionLayout, value: store.activeProjects.count)
        .groupedPageBackground()
        .navigationTitle("书架")
        .navigationBarTitleDisplayMode(.large)
        .presentationDragIndicator(.visible)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("完成") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editTarget = .newProject
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建书项目")
            }
        }
        .sheet(item: $editTarget) { target in
            editorSheet(for: target)
        }
        .sheet(item: $branchTarget) { project in
            LibraryBranchesSheet(store: store, project: project, onOpen: onOpen)
        }
        .navigationDestination(isPresented: $showTrashOnLaunch) {
            LibraryTrashView(store: store)
        }
        .task {
            #if DEBUG
            // 截图流水线：`-openTrash` 在书架出现后推进回收站。
            guard !didApplyLaunch,
                  LaunchArguments.opensTrash
            else { return }
            didApplyLaunch = true
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            showTrashOnLaunch = true
            #endif
        }
    }

    // MARK: - 全部书稿

    private var booksSection: some View {
        let projects = sortedActiveProjects
        let counts = branchCounts
        return Section {
            if projects.isEmpty {
                emptyBooksRow
            } else {
                ForEach(projects) { project in
                    LibraryProjectRow(
                        project: project,
                        branchCount: counts[project.branchRootId] ?? 1,
                        isCurrent: project.id == activeProjectID,
                        onOpen: { onOpen(project) },
                        onRename: { editTarget = .rename(project) },
                        onSynopsis: { editTarget = .synopsis(project) },
                        onBranches: { branchTarget = project },
                        onTrash: { trash(project) }
                    )
                }
            }
        } header: {
            AppSectionHeader(title: "全部书稿")
        }
    }

    private var emptyBooksRow: some View {
        EmptyStateView(
            symbol: "books.vertical",
            title: "还没有书项目",
            actionTitle: "新建书项目",
            isPrimaryAction: true,
            action: { editTarget = .newProject }
        )
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    // MARK: - 回收站 / 设置

    private var placesSection: some View {
        Section {
            NavigationLink {
                LibraryTrashView(store: store)
            } label: {
                AppSettingsRow(
                    title: "回收站",
                    symbol: "trash",
                    detail: store.trashedProjects.isEmpty
                        ? nil
                        : store.trashedProjects.count.formatted()
                )
            }

            if let onOpenSettings {
                Button(action: onOpenSettings) {
                    HStack(spacing: Theme.Spacing.s) {
                        AppSettingsRow(
                            title: "设置",
                            symbol: "gearshape"
                        )
                        Image(systemName: "chevron.right")
                            .font(Font.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - 数据

    /// 仅展示当前活跃书稿；无活跃项目时隐藏顶部区域。
    private var continueProject: Project? {
        guard let activeProjectID else { return nil }
        return store.activeProjects.first { $0.id == activeProjectID }
    }

    /// 进行中的书项目按最近修改时间倒序排列。
    private var sortedActiveProjects: [Project] {
        store.activeProjects.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 分支根节点至分支数量的映射（排除回收站）；批量计算以避免列表行重复遍历。
    private var branchCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for project in store.activeProjects {
            counts[project.branchRootId, default: 0] += 1
        }
        return counts
    }

    // MARK: - 弹窗

    @ViewBuilder
    private func editorSheet(for target: LibraryEditTarget) -> some View {
        switch target {
        case .newProject:
            LibraryInputSheet(
                navTitle: "新建书项目",
                fieldPlaceholder: "书名",
                confirmLabel: "创建",
                multiline: false,
                allowsEmpty: true,
                initialText: ""
            ) { text in
                createProject(titled: text)
            }

        case .rename(let project):
            LibraryInputSheet(
                navTitle: "重命名",
                fieldPlaceholder: "书名",
                confirmLabel: "保存",
                multiline: false,
                allowsEmpty: false,
                initialText: project.title
            ) { text in
                store.rename(project, to: text)
                store.toast = "已重命名"
            }

        case .synopsis(let project):
            LibraryInputSheet(
                navTitle: "书项目简介",
                fieldPlaceholder: "简介",
                confirmLabel: "保存",
                multiline: true,
                allowsEmpty: true,
                initialText: project.synopsis
            ) { text in
                store.setSynopsis(project, to: text)
                store.toast = "已更新简介"
            }
        }
    }

    // MARK: - 动作

    /// 新建成功后直接进入工作区；创建失败时由 `createProject` 设置错误信息，此处不执行跳转。
    private func createProject(titled title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 未命名项目规范写入默认标题，确保列表展示与重命名弹窗保持一致。
        let finalTitle = trimmed.isEmpty ? Project.untitledTitle : trimmed
        guard let project = store.createProject(title: finalTitle) else { return }
        guard store.activeProjects.contains(where: { $0.id == project.id }) else { return }
        store.toast = "已新建「\(project.shelfTitle)」"
        onOpen(project)
    }

    @MainActor
    private func trash(_ project: Project) {
        store.trash(project)
        store.showToast("已移入回收站", actionTitle: "撤销") {
            store.restore(project)
        }
        store.toast = "已移入回收站"
    }
}
