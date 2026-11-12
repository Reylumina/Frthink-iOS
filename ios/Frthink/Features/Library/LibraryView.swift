// 书架根页面：继续写作 + 全部书稿 + 回收站/设置入口。
//
// 一屏三件事：回到正在写的书、打开另一本、处理回收站。新建在右上角。
// 不再用大封面网格：占位封面在写作应用里辨识度低，书名和最近编辑时间才是索引。

import SwiftUI

struct LibraryView: View {
    let store: AppStore
    /// 当前正在写的书；`RootView` 传入，用来标「正在写」与顶部的继续写作。
    var activeProjectID: String? = nil
    let onOpen: (Project) -> Void
    /// 从书架去设置：`RootView` 负责关掉书架并切到设置 Tab。
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
        .groupedPageBackground()
        .navigationTitle("本机书架")
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
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "books.vertical")
                .font(.system(.largeTitle).weight(.light))
                .foregroundStyle(.tertiary)

            Text("还没有书项目")
                .font(.headline)
                .foregroundStyle(.primary)

            PrimaryActionButton(title: "新建书项目", systemImage: "plus") {
                editTarget = .newProject
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
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
                        : "\(store.trashedProjects.count)"
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
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }
        }
    }

    // MARK: - 数据

    /// 只有「当前正在写」的那本才出现在顶部；新开书架时没有当前书就隐藏。
    private var continueProject: Project? {
        guard let activeProjectID else { return nil }
        return store.activeProjects.first { $0.id == activeProjectID }
    }

    /// 进行中的书项目按最近改动时间倒序。
    private var sortedActiveProjects: [Project] {
        store.activeProjects.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// 分支根 → 分支数（不含回收站）。一次算完，避免每行都 `filter` 全书架。
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

    /// 新建成功后直接进工作区；创建失败时 `createProject` 已经设了 `errorMessage`，这里不跳转。
    private func createProject(titled title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空书名在列表里会显示为「未命名书项目」；直接把它写成正式标题，
        // 避免列表与重命名弹窗里出现两种名字。
        let finalTitle = trimmed.isEmpty ? Project.untitledTitle : trimmed
        guard let project = store.createProject(title: finalTitle) else { return }
        guard store.activeProjects.contains(where: { $0.id == project.id }) else { return }
        store.toast = "已新建「\(project.shelfTitle)」"
        onOpen(project)
    }

    @MainActor
    private func trash(_ project: Project) {
        store.trash(project)
        store.toast = "已移入回收站"
    }
}
