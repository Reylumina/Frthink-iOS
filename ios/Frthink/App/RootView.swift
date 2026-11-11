import SwiftUI

/// 根容器：五个一级 Tab，共享「当前书稿」这一个选择。
///
/// 原版把书架做成一层的弹层（`projectPickerVisible`），而不是根页面——
/// 所以这里也把 `LibraryView` 当 sheet 用，Tab 上只显示当前书稿和切换入口。
struct RootView: View {
    /// 上次打开的书。冷启动直接回到它，不再先给一屏「请选择书稿」。
    private static let activeProjectKey = "root.activeProjectID"

    /// 从启动参数里读初始 Tab。
    static var launchDestination: AppDestination {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-initialTab"), index + 1 < args.count
        else { return .compose }
        return AppDestination(rawValue: args[index + 1]) ?? .compose
    }

    /// 启动时先按上次打开的书落位；演示数据要另选主书，留给 onAppear。
    static var launchProjectID: String? {
        guard !DemoSeed.isRequested else { return nil }
        let id = UserDefaults.standard.string(forKey: activeProjectKey) ?? ""
        return id.isEmpty ? nil : id
    }

    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    /// 启动参数 `-initialTab 世界` 可以直接落到某个 Tab。CI 的截图流水线靠它
    /// 逐个 Tab 出图；正常启动没有这个参数，行为和以前一样。
    @State private var destination: AppDestination = RootView.launchDestination
    @State private var activeProjectID: String? = RootView.launchProjectID
    @State private var session: ProjectSession?
    @State private var libraryVisible = false
    @State private var translationVisible = false

    /// 书已选中但会话还没解码完。此时不能先闪空态，否则每开一本书都像被清空。
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
        .onAppear {
            // 截图流水线会带 -seedDemo：铺一份演示数据，否则截出来全是空状态。
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
                if ProcessInfo.processInfo.arguments.contains("-openLibrary") {
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
                store.trimSessionCache(keeping: [])
                // 上次打开的书被删除或放进回收站：落到最近一本，不留空白页。
                if let fallback = store.activeProjects.first, activeProjectID != fallback.id {
                    activeProjectID = fallback.id
                }
                return
            }
            UserDefaults.standard.set(project.id, forKey: Self.activeProjectKey)
            if let cached = store.cachedSession(for: project.id) {
                session = cached
                store.trimSessionCache(keeping: [project.id])
                return
            }
            session = nil
            let loaded = await store.openSessionAsync(for: project)
            guard !Task.isCancelled else { return }
            session = loaded
            store.trimSessionCache(keeping: [project.id])
        }
        .onChange(of: activeProjectID) { oldValue, newValue in
            // 切书：旧书在跑的世界任务必须停，否则它会继续对已被驱逐的会话落盘。
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
            // 切后台、控制中心下拉、来电都会先变 inactive；这时先把挂起编辑写盘。
            if phase != .active {
                store.flushDirtySessions()
            }
        }
        // 「界面动画帧率」开关：关掉后这次事务里的所有动画都不播，
        // 对应原版「界面动画帧率」那一项的实际效果。
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
                        // 从书架点开一本书，自然落到「创作」。
                        destination = .compose
                    },
                    onOpenSettings: {
                        libraryVisible = false
                        destination = .settings
                    }
                )
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(text: toast)
                    .padding(.bottom, Theme.Spacing.xxl * 2)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(for: .seconds(2.2))
                        withAnimation { store.toast = nil }
                    }
            }
        }
        .overlay {
            if let error = store.errorMessage {
                ErrorBanner(message: error) { store.errorMessage = nil }
            }
        }
        .overlay {
            if openingBook {
                ProgressView("正在打开书稿…")
                    .font(Font.subheadline)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.l)
                    .background(.regularMaterial, in: RoundedRectangle(
                        cornerRadius: Theme.Radius.large,
                        style: .continuous
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.toast)
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
                // 切书时重置创作页状态，避免沿用上一本的可见窗口/输入态。
                .id(session.project.id)
        } else if openingBook {
            openingPlaceholder
        } else {
            EmptyStateView(
                symbol: "square.and.pencil",
                title: "请选择或新建书稿",
                message: "从书架里挑一本书，或者新建一个书项目。"
            )
        }
    }

    @ViewBuilder
    private var readerScreen: some View {
        if let session, activeProject != nil {
            ReaderPane(session: session)
                // 切书重置阅读页状态，避免沿用上一本的滚动位置与面板。
                .id(session.project.id)
        } else if openingBook {
            openingPlaceholder
        } else {
            EmptyStateView(
                symbol: "book",
                title: "还没有选中书稿",
                message: "原文与译文对照会显示在这里。"
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
                // 切书重置世界页状态：刷新任务、状态行、打开的编辑器都属于上一本。
                .id(session.project.id)
        } else if openingBook {
            openingPlaceholder
        } else {
            EmptyStateView(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "还没有选中书稿",
                message: "世界书、人物卡、事件卡都挂在某一本书下面。"
            )
        }
    }

    /// 选中书稿后、会话解码完成前的占位：先显示加载，不先闪空态。
    private var openingPlaceholder: some View {
        VStack(spacing: Theme.Spacing.s) {
            ProgressView()
            Text("正在打开书稿…")
                .font(Font.footnote)
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
                // 这里只放「去书架」这个动作。书名已经在 navigationTitle 上，
                // 在同一个导航栏里再写一遍等于白占一行。
                Label("书架", systemImage: "books.vertical")
                    .font(Font.subheadline)
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            if let session, session.isDirty {
                ProgressView().controlSize(.small)
            }
        }
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
