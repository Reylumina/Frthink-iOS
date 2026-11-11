import SwiftUI

/// 根容器：五个一级 Tab，共享「当前书稿」这一个选择。
///
/// 原版把书架做成一层的弹层（`projectPickerVisible`），而不是根页面——
/// 所以这里也把 `LibraryView` 当 sheet 用，Tab 上只显示当前书稿和切换入口。
struct RootView: View {
    /// 从启动参数里读初始 Tab。
    static var launchDestination: AppDestination {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-initialTab"), index + 1 < args.count
        else { return .compose }
        return AppDestination(rawValue: args[index + 1]) ?? .compose
    }

    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    /// 启动参数 `-initialTab 世界` 可以直接落到某个 Tab。CI 的截图流水线靠它
    /// 逐个 Tab 出图；正常启动没有这个参数，行为和以前一样。
    @State private var destination: AppDestination = RootView.launchDestination
    @State private var activeProjectID: String?
    @State private var session: ProjectSession?
    @State private var loadingSession = false
    @State private var libraryVisible = false
    @State private var translationVisible = false

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
            guard DemoSeed.isRequested else { return }
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
        }
        .task(id: activeProjectID) {
            guard let project = activeProject else {
                session = nil
                loadingSession = false
                store.trimSessionCache(keeping: [])
                return
            }
            if let cached = store.cachedSession(for: project.id) {
                session = cached
                loadingSession = false
                store.trimSessionCache(keeping: [project.id])
                return
            }
            session = nil
            loadingSession = true
            let loaded = await store.openSessionAsync(for: project)
            guard !Task.isCancelled else { return }
            session = loaded
            loadingSession = false
            store.trimSessionCache(keeping: [project.id])
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
            if loadingSession {
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
        } else {
            EmptyStateView(
                symbol: "point.3.connected.trianglepath.dotted",
                title: "还没有选中书稿",
                message: "世界书、人物卡、事件卡都挂在某一本书下面。"
            )
        }
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
