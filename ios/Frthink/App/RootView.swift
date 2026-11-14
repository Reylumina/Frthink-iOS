import SwiftUI

/// 根容器：五个一级 Tab，共享「当前书稿」这一个选择。
///
/// 原版把书架做成一层的弹层（`projectPickerVisible`），而不是根页面——
/// 所以这里也把 `LibraryView` 当 sheet 用，Tab 上只显示当前书稿和切换入口。
struct RootView: View {
    /// 上次打开的书。冷启动直接回到它，不再先给一屏「请选择书稿」。
    /// 当前书稿 id 的 AppStorage 键。创作页离开时要靠它判断「是不是换了书」。
    static let activeProjectKey = "root.activeProjectID"

    static var launchDestination: AppDestination {
        AppDestination(rawValue: LaunchArguments.initialTab ?? "") ?? .compose
    }

    /// 启动时先按上次打开的书落位；演示数据要另选主书，留给 onAppear。
    static var launchProjectID: String? {
        guard !DemoSeed.isRequested else { return nil }
        let id = UserDefaults.standard.string(forKey: activeProjectKey) ?? ""
        return id.isEmpty ? nil : id
    }

    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    /// 当前一级 Tab；可用启动参数 `-initialTab` 覆盖（供截图流水线使用）。
    @State private var destination: AppDestination = RootView.launchDestination
    @State private var activeProjectID: String? = RootView.launchProjectID
    @State private var session: ProjectSession?
    @State private var libraryVisible = false
    @State private var translationVisible = false

    /// 书稿已选中但会话尚未解码完成。此时不显示空状态，避免切换书稿时产生界面闪烁。
    private var openingBook: Bool {
        activeProject != nil && session == nil
    }

    private var activeProject: Project? {
        guard let id = activeProjectID else { return nil }
        // 回收站里的项目不再算「当前书稿」。
        return store.projects.first { $0.id == id && !$0.isTrashed }
    }

    var body: some View {
        @Bindable var store = store

        TabView(selection: $destination) {
            tabStack(activeProject?.title ?? "创作") {
                composeScreen
            } toolbar: {
                projectToolbar
            }
            .tabItem { Label(AppDestination.compose.rawValue, systemImage: AppDestination.compose.symbol) }
            .tag(AppDestination.compose)

            tabStack(activeProject?.title ?? "阅读") {
                readerScreen
            } toolbar: {
                projectToolbar
                translationToolbarItem
            }
            .sheet(isPresented: $translationVisible) {
                translationSheet
            }
            .tabItem { Label(AppDestination.reader.rawValue, systemImage: AppDestination.reader.symbol) }
            .tag(AppDestination.reader)

            tabStack("世界") {
                worldScreen
            } toolbar: {
                projectToolbar
            }
            .tabItem { Label(AppDestination.world.rawValue, systemImage: AppDestination.world.symbol) }
            .tag(AppDestination.world)

            tabStack("宇宙") {
                UniversePane(store: store, session: session)
                    .id(session?.project.id ?? "universe-no-book")
            }
            .tabItem { Label(AppDestination.universe.rawValue, systemImage: AppDestination.universe.symbol) }
            .tag(AppDestination.universe)

            // SettingsView 自带 NavigationStack（它内部用 NavigationLink 进二级页），
            // 这里不能再套一层，否则出现双重导航栏。
            SettingsView(store: store)
                .tabItem { Label(AppDestination.settings.rawValue, systemImage: AppDestination.settings.symbol) }
                .tag(AppDestination.settings)
        }
        .tint(Theme.accent)
        .minimizeTabBarOnScroll()
        .onAppear {
            // 截图流水线传入 -seedDemo 参数以填充演示数据，避免呈现空状态。
            if DemoSeed.isRequested {
                DemoSeed.seedIfNeeded(store: store)
                if activeProjectID == nil {
                    // 演示数据里还有分支和回收站项目，按更新时间排序时不一定是正文那本；
                    // 截图统一落到主书，保证写作/阅读/世界各页都有内容。
                    activeProjectID = store.projects
                        .first(where: { $0.title == DemoSeed.primaryTitle && !$0.isTrashed })?
                        .id
                        ?? store.activeProjects.first?.id
                }
                #if DEBUG
                // 书架截图：直接打开书稿选择器（可再带 -openTrash 进回收站）。
                if LaunchArguments.opensLibrary {
                    libraryVisible = true
                }
                #endif
                return
            }
            // 没有上次记录（首次安装）或那本书已被删除：落到最近编辑的一本。
            if activeProjectID == nil {
                activeProjectID = store.activeProjects.first?.id
            }
        }
        .task(id: activeProjectID) {
            guard let project = activeProject else {
                session = nil
                // 没有当前书稿时清除该键：创作页依赖此键判断书稿切换，
                // 保留旧 id 会导致原面板误判为同一书稿而未能停止后台任务。
                UserDefaults.standard.removeObject(forKey: Self.activeProjectKey)
                await store.trimSessionCache(keeping: [])
                // 上次打开的书被删除或放进回收站：落到最近一本，不留空白页。
                if let fallback = store.activeProjects.first, activeProjectID != fallback.id {
                    activeProjectID = fallback.id
                }
                return
            }
            UserDefaults.standard.set(project.id, forKey: Self.activeProjectKey)
            if let cached = store.cachedSession(for: project.id) {
                session = cached
                await store.trimSessionCache(keeping: [project.id])
                return
            }
            session = nil
            let loaded = await store.openSessionAsync(for: project)
            guard !Task.isCancelled else { return }
            session = loaded
            await store.trimSessionCache(keeping: [project.id])
        }
        .onChange(of: activeProjectID) { oldValue, newValue in
            // 切换书稿：必须终止旧书稿正在执行的世界任务，防止其向已驱逐的会话写盘。
            if let oldValue, oldValue != newValue {
                store.cancelWorldTask(for: oldValue)
            }
        }
        .onChange(of: activeProject?.id) { _, newValue in
            // 当前书被移进回收站/彻底删除时，task(id:) 不会因为同一 id 重跑。
            guard newValue == nil, activeProjectID != nil else { return }
            session = nil
            activeProjectID = store.activeProjects.first?.id
        }
        .preferredColorScheme(store.settings.theme.colorScheme)
        .onChange(of: scenePhase) { _, phase in
            // 应用进入非活跃状态（切换后台、下拉控制中心、来电等）时，先将挂起的编辑内容写盘，
            // 并向系统申请后台执行时间，避免写盘过程中被挂起。
            if phase != .active {
                Task { await store.flushDirtySessionsInBackground() }
            }
        }
        // 「界面动画帧率」设置：关闭后该事务中的所有动画均不执行，
        // 对齐原版「界面动画帧率」项的实际效果。
        .transaction { transaction in
            if store.settings.limitAnimationFrameRate {
                transaction.disablesAnimations = true
            }
        }
        .sheet(isPresented: $libraryVisible) {
            NavigationStack {
                LibraryView(
                    store: store,
                    activeProjectID: activeProjectID,
                    onOpen: { project in
                        activeProjectID = project.id
                        libraryVisible = false
                        // 从书架打开书稿时，默认导航至「创作」页。
                        destination = .compose
                    },
                    onOpenSettings: {
                        libraryVisible = false
                        destination = .settings
                    }
                )
            }
            // sheet 会盖住根视图的 toast：书架里的重命名、移入回收站等结果
            // 要在这一层显示，包括 push 出来的回收站页。
            .sheetToast()
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastPresenter(text: toast, bottomPadding: Theme.Spacing.xxl * 2)
                    .glassStack()
            }
        }
        .overlay {
            if let error = store.errorMessage {
                ErrorBanner(message: error) { store.errorMessage = nil }
                    .glassStack()
            }
        }
        // 「正在打开书稿…」只留各 Tab 里的占位（openingPlaceholder），不在此处另加全屏浮层。
        .themeAnimation(Theme.motionLayout, value: store.toast)
    }

    // MARK: - Tab 外壳

    /// 一级 Tab 共用的导航外壳：导航栈、页面底色、内联标题、统一工具栏。
    private func tabStack<Content: View, Toolbar: ToolbarContent>(
        _ title: String,
        @ViewBuilder content: () -> Content,
        @ToolbarContentBuilder toolbar: () -> Toolbar
    ) -> some View {
        NavigationStack {
            content()
                .pageBackground()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar() }
        }
    }

    /// 没有工具栏的 Tab（宇宙页）用的重载。
    private func tabStack<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .pageBackground()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - 各 Tab 的内容

    @ViewBuilder
    private var composeScreen: some View {
        if let session, activeProject != nil {
            WriterPane(session: session)
                // 切换书稿时重置创作页状态，避免沿用上一书稿的可见窗口与输入状态。
                .id(session.project.id)
        } else if openingBook {
            openingPlaceholder
        } else {
            EmptyStateView(
                symbol: "square.and.pencil",
                title: "请选择或新建书稿"
            )
        }
    }

    @ViewBuilder
    private var readerScreen: some View {
        if let session, activeProject != nil {
            ReaderPane(session: session)
                // 切换书稿时重置阅读页状态，避免沿用上一书稿的滚动位置与面板。
                .id(session.project.id)
        } else if openingBook {
            openingPlaceholder
        } else {
            EmptyStateView(
                symbol: "book.pages",
                title: "还没有选中书稿"
            )
        }
    }

    /// 阅读页的译文面板：译文在「翻译」面板里生成，这里只负责读。
    @ViewBuilder
    private var translationSheet: some View {
        if let session {
            NavigationStack {
                TranslationPane(session: session)
                    .navigationTitle("翻译")
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    @ViewBuilder
    private var worldScreen: some View {
        if let session, activeProject != nil {
            WorldPane(session: session)
                // 切换书稿时重置世界页状态：刷新任务、状态行及打开的编辑器均属于上一书稿。
                .id(session.project.id)
        } else if openingBook {
            openingPlaceholder
        } else {
            EmptyStateView(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "还没有选中书稿"
            )
        }
    }

    /// 选中书稿后、会话解码完成前的占位展示：显示加载状态，避免出现空状态闪烁。
    private var openingPlaceholder: some View {
        VStack(spacing: Theme.Spacing.s) {
            ProgressView()
            Text("正在打开书稿…")
                .font(Theme.metadata)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var projectToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                libraryVisible = true
            } label: {
                // 工具栏仅放置「返回书架」操作。书名已显示于 navigationTitle，
                // 无需在导航栏重复展示。
                Label("书架", systemImage: "books.vertical")
                    .font(Font.subheadline)
            }
        }
        // 不在右上角放「正在保存」转圈：自动保存保持无感，避免与页面内状态行重复（§5.8）。
    }

    /// 阅读页多出来的翻译入口，对应原版阅读页的「翻译 / 停止翻译」。
    private var translationToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                translationVisible = true
            } label: {
                Image(systemName: "translate")
            }
            .disabled(session == nil)
        }
    }
}
