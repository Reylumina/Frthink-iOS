// 本文件负责：阅读页主界面 —— 原文/译文切换、全文搜索、显示设置、章节与段落导航、书签。

import Foundation
import SwiftUI

/// 阅读页。
///
/// 正文先按空行切成小段，再交给 `LazyVStack` 渲染：几万字的书也只画屏幕上的十几段，
/// 不会因为一个 `Text` 塞进整篇而卡住。跳章节、跳命中、跳书签一律换算成「哪一段的
/// 起始偏移」，交给 `ScrollViewReader.scrollTo` 滚过去。
struct ReaderPane: View {
    @Environment(AppStore.self) private var store

    private let session: ProjectSession

    @AppStorage(ReaderStorageKey.fontSize) private var fontSize: Double = 18
    @AppStorage(ReaderStorageKey.lineHeight) private var lineHeight: Double = 1.6
    @AppStorage(ReaderStorageKey.darkPage) private var darkPage = false
    @AppStorage(ReaderStorageKey.mode) private var modeRaw = ReaderMode.source.rawValue
    @AppStorage private var bookmarkOffset: Int
    @AppStorage private var lastOffset: Int

    @State private var document = ReaderDocument.empty
    /// 译文拼接结果。只在 `translations` 变化时重拼，不在每帧重算。
    @State private var translationText = ""
    /// 原文的 UTF-16 长度。译文模式折算章节位置时要用，避免每帧桥接一次 NSString。
    @State private var manuscriptLength = 0
    /// 当前定位点（UTF-16 偏移），滚动时跟着视口顶部那一段走。
    @State private var anchorOffset = 0
    /// `scrollPosition(id:)` 报告的顶部段落起点。
    @State private var scrolledBlockStart: Int?
    @State private var jump: ReaderJump?
    @State private var showSettings = false
    @State private var showChapters = false
    @State private var showSearch = false
    @State private var query = ""
    @State private var matches: [ReaderMatch] = []
    @State private var highlightMap: [Int: [NSRange]] = [:]
    @State private var matchIndex = 0
    /// 排版（切块）任务。56 万字的正文切块不能在主线程做。
    @State private var rebuildTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    /// 阅读页当前是否可见。不可见时正文变化不重排，切回来再补。
    @State private var isVisible = false
    /// 首帧到排版完成之间显示加载态，避免把「正在排版」误报成「正文还是空的」。
    @State private var isLoadingDocument = true

    init(session: ProjectSession) {
        self.session = session
        _bookmarkOffset = AppStorage(
            wrappedValue: -1,
            ReaderStorageKey.bookmark(session.project.id)
        )
        _lastOffset = AppStorage(
            wrappedValue: -1,
            ReaderStorageKey.position(session.project.id)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            readingSurface
            Divider().overlay(Theme.separator)
            footer
        }
        // 搜索是浮在正文上的控制层：不占布局高度，打开时正文不下推。
        .overlay(alignment: .top) {
            searchOverlay
        }
        .background(Theme.pageBackgroundColor.ignoresSafeArea())
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                modeMenu
                readerMenu
            }
        }
        .onAppear {
            isVisible = true
            prepare()
            #if DEBUG
            applyLaunchPanel()
            #endif
        }
        .onDisappear {
            isVisible = false
            // 切走时把搜索浮层一起收起，键盘不会留在别处。
            showSearch = false
            rebuildTask?.cancel()
            rebuildTask = nil
            searchTask?.cancel()
            searchTask = nil
        }
        // 结构改动（插入/撤销/导入/覆盖恢复）才需要重排；逐字编辑走正文编辑器，
        // 不用在这里比一遍 56 万字的字符串。
        .onChange(of: session.manuscriptRevision) { _, _ in
            if isVisible { scheduleRebuild() }
        }
        .onChange(of: session.translations) { _, _ in
            if isVisible { scheduleRebuild() }
        }
        .onChange(of: modeRaw) { _, _ in
            if isVisible { scheduleRebuild(immediate: true) }
        }
        .onChange(of: session.project.id) { _, _ in reloadProject() }
        // 搜索防抖：打字停下 220ms 再扫全文；输入变了或页面走了，上一轮自动取消。
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            performSearch()
        }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(isPresented: $showChapters) { chaptersSheet }
    }

    // MARK: - 浮层与弹窗

    /// 搜索浮层。挂在 overlay 上，不参与正文布局。
    @ViewBuilder
    private var searchOverlay: some View {
        if showSearch {
            ReaderSearchPanel(
                mode: mode,
                query: $query,
                matches: matches,
                currentIndex: matchIndex,
                onSubmit: { jumpToMatch(0) },
                onPrevious: { stepMatch(-1) },
                onNext: { stepMatch(1) },
                onSelect: { index in jumpToMatch(index) },
                onClose: {
                    withAnimation(.easeInOut(duration: 0.18)) { showSearch = false }
                }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var settingsSheet: some View {
        ReaderDisplaySettingsSheet(
            fontSize: $fontSize,
            lineHeight: $lineHeight,
            darkPage: $darkPage
        )
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var chaptersSheet: some View {
        ReaderChapterList(
            chapters: session.payload.chapters,
            currentChapterID: currentChapterID
        ) { chapter in
            jump(to: displayOffset(for: chapter))
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - 导航栏菜单

    #if DEBUG
    /// 截图流水线：`-readerPanel display|chapters|search` 直接打开对应面板。
    private func applyLaunchPanel() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-readerPanel"),
              index + 1 < args.count
        else { return }
        switch args[index + 1] {
        case "display": showSettings = true
        case "chapters": showChapters = true
        case "search": showSearch = true
        default: break
        }
    }
    #endif

    private var modeMenu: some View {
        Menu {
            Picker("模式", selection: modeBinding) {
                ForEach(ReaderMode.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(modeBinding.wrappedValue.displayName)
                    .font(Font.subheadline)
                Image(systemName: "chevron.down")
                    .font(Font.caption2)
            }
        }
        .accessibilityLabel("阅读模式")
        .accessibilityValue(modeBinding.wrappedValue.displayName)
    }

    private var readerMenu: some View {
        Menu {
            if let title = currentChapterTitle {
                Text(title)
                Divider()
            }
            Button {
                stepChapter(-1)
            } label: {
                Label("上一章", systemImage: "chevron.backward.2")
            }
            Button {
                stepChapter(1)
            } label: {
                Label("下一章", systemImage: "chevron.forward.2")
            }
            Button {
                showChapters = true
            } label: {
                Label("目录", systemImage: "list.bullet")
            }

            Divider()

            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showSearch = true }
            } label: {
                Label(mode == .source ? "搜索正文" : "搜索译文", systemImage: "magnifyingglass")
            }

            Button {
                bookmarkOffset = anchorOffset
                store.toast = "已在此处加书签"
            } label: {
                Label("在此处加书签", systemImage: "bookmark")
            }
            if bookmarkOffset >= 0 {
                Button {
                    jump(to: bookmarkOffset)
                } label: {
                    Label("跳到书签", systemImage: "arrow.uturn.backward")
                }
                Button(role: .destructive) {
                    bookmarkOffset = -1
                    store.toast = "已清除书签"
                } label: {
                    Label("清除书签", systemImage: "trash")
                }
            }

            Divider()

            Button {
                showSettings = true
            } label: {
                Label("阅读显示设置", systemImage: "textformat.size")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(Font.subheadline)
        }
        .accessibilityLabel("更多阅读操作")
    }

    // MARK: - 正文

    private var readingSurface: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    if document.blocks.isEmpty {
                        if isLoadingDocument {
                            loadingState
                        } else {
                            emptyState
                        }
                    }
                    ForEach(document.blocks) { block in
                        ReaderParagraphView(
                            text: document.text(for: block),
                            fontSize: CGFloat(fontSize),
                            lineHeight: lineHeight,
                            darkPage: darkPage,
                            highlights: highlightMap[block.start] ?? [],
                            current: currentHighlight(in: block)
                        )
                        .id(block.start)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.l)
            }
            .background(ReaderStyle.page(dark: darkPage))
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            // iOS 17 的滚动位置绑定：只更新一个 Int，不再给每一段挂
            // GeometryReader + PreferenceKey，滚动时不会整页重算。
            .scrollPosition(id: $scrolledBlockStart, anchor: .top)
            .onChange(of: scrolledBlockStart) { _, start in
                guard let start, start != anchorOffset else { return }
                anchorOffset = start
                lastOffset = start
            }
            .onChange(of: jump) { _, request in
                guard let request else { return }
                if request.animated {
                    withAnimation(.easeInOut(duration: 0.22)) {
                        proxy.scrollTo(request.offset, anchor: .top)
                    }
                } else {
                    proxy.scrollTo(request.offset, anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: mode == .source ? "doc.text" : "character.book.closed",
            title: mode == .source ? "正文还是空的" : "还没有译文",
            message: mode == .source
                ? "先在「创作」里写点东西，这里就会按段落显示。"
                : "把要读的段落翻好之后，译文会按分段顺序拼在这里。"
        )
        .frame(height: 260)
    }

    /// 排版完成前的占位；大书或旧书回退全文解析时能看到，而不是先闪一下空态。
    private var loadingState: some View {
        VStack(spacing: Theme.Spacing.s) {
            ProgressView()
            Text("正在排版正文…")
                .font(Font.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
    }

    // MARK: - 页脚

    private var footer: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(positionLabel)
                .font(Theme.numeric)
                .foregroundStyle(.tertiary)
            if !document.blocks.isEmpty {
                Text("·")
                    .font(Theme.numeric)
                    .foregroundStyle(.tertiary)
                Text("\(document.characterCount) 字")
                    .font(Theme.numeric)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if bookmarkOffset >= 0 {
                Button {
                    jump(to: bookmarkOffset)
                } label: {
                    Label("书签", systemImage: "bookmark.fill")
                        .font(Font.caption)
                        .foregroundStyle(Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("跳到书签")
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.xs + 2)
    }

    private var positionLabel: String {
        guard !document.blocks.isEmpty else { return "暂无正文" }
        return "第 \(currentBlockNumber)/\(document.blocks.count) 段"
    }

    private var currentBlockNumber: Int {
        guard !document.blocks.isEmpty else { return 0 }
        return ReaderLocator.blockIndex(for: anchorOffset, in: document.blocks) + 1
    }

    // MARK: - 模式与章节位置

    private var mode: ReaderMode {
        ReaderMode(rawValue: modeRaw) ?? .source
    }

    private var modeBinding: Binding<ReaderMode> {
        Binding(
            get: { ReaderMode(rawValue: modeRaw) ?? .source },
            set: { modeRaw = $0.rawValue }
        )
    }

    private var chapterOffsets: [Int] {
        session.payload.chapters.map { displayOffset(for: $0) }
    }

    private var currentChapterID: String? {
        let chapters = session.payload.chapters
        guard !chapters.isEmpty else { return nil }
        let offsets = chapterOffsets
        guard let index = offsets.lastIndex(where: { $0 <= anchorOffset + 1 }) else {
            return chapters.first?.id
        }
        return chapters[index].id
    }

    private var currentChapterTitle: String? {
        let chapters = session.payload.chapters
        guard !chapters.isEmpty else { return nil }
        let offsets = chapterOffsets
        guard let index = offsets.lastIndex(where: { $0 <= anchorOffset + 1 }) else {
            return chapters.first?.title
        }
        return chapters[index].title
    }

    /// 章节的 `location` 是原文里的 UTF-16 偏移。译文是把分段按顺序拼起来的，
    /// 与正文没有字符级对齐，只能按长度比例折算出一个大致位置。
    private func displayOffset(for chapter: Chapter) -> Int {
        if mode == .source {
            return clamp(chapter.location)
        }
        guard manuscriptLength > 0, document.length > 0 else { return 0 }
        let ratio = Double(chapter.location) / Double(manuscriptLength)
        let mapped = Int(ratio * Double(document.length))
        return max(0, min(document.length - 1, mapped))
    }

    // MARK: - 跳转

    private func stepChapter(_ delta: Int) {
        let offsets = chapterOffsets
        guard !offsets.isEmpty else {
            store.toast = "正文里还没扫到章节标题"
            return
        }
        if delta < 0 {
            guard let index = offsets.lastIndex(where: { $0 < anchorOffset - 1 }) else {
                store.toast = "已经是第一章"
                return
            }
            jump(to: offsets[index])
        } else {
            guard let index = offsets.firstIndex(where: { $0 > anchorOffset + 1 }) else {
                store.toast = "已经是最后一章"
                return
            }
            jump(to: offsets[index])
        }
    }

    private func stepBlock(_ delta: Int) {
        guard !document.blocks.isEmpty else { return }
        let index = ReaderLocator.blockIndex(for: anchorOffset, in: document.blocks)
        let target = index + delta
        guard target >= 0, target < document.blocks.count else {
            store.toast = delta < 0 ? "已经是第一段" : "已经是最后一段"
            return
        }
        jump(to: document.blocks[target].start)
    }

    /// 跳到某个偏移：先夹到正文范围内，再落到它所在那一段的段首。
    private func jump(to offset: Int) {
        guard !document.blocks.isEmpty else { return }
        let index = ReaderLocator.blockIndex(for: clamp(offset), in: document.blocks)
        let start = document.blocks[index].start
        anchorOffset = start
        lastOffset = start
        jump = ReaderJump(offset: start, animated: true)
    }

    private func clamp(_ offset: Int) -> Int {
        max(0, min(offset, max(document.length - 1, 0)))
    }

    // MARK: - 搜索

    private func performSearch() {
        searchTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, document.length > 0 else {
            matches = []
            highlightMap = [:]
            matchIndex = 0
            return
        }
        let documentSnapshot = document
        let blocks = document.blocks
        searchTask = Task { @MainActor in
            let found = await documentSnapshot.searchMatches(query: needle)
            guard !Task.isCancelled else { return }
            matches = found
            highlightMap = ReaderSearch.grouped(found, by: blocks)
            matchIndex = 0
        }
    }

    private func stepMatch(_ delta: Int) {
        guard !matches.isEmpty else {
            store.toast = "没有可以跳转的命中"
            return
        }
        var index = matchIndex + delta
        if index < 0 { index = matches.count - 1 }
        if index >= matches.count { index = 0 }
        jumpToMatch(index)
    }

    private func jumpToMatch(_ index: Int) {
        guard matches.indices.contains(index) else { return }
        matchIndex = index
        jump(to: matches[index].offset)
    }

    /// 当前命中落在这一段的哪一段区间里，交给段落去加重底色。
    private func currentHighlight(in block: ReaderBlock) -> NSRange? {
        guard matches.indices.contains(matchIndex) else { return nil }
        let match = matches[matchIndex]
        let start = match.offset - block.start
        guard start >= 0, start < block.length else { return nil }
        let length = min(match.length, block.length - start)
        guard length > 0 else { return nil }
        return NSRange(location: start, length: length)
    }

    // MARK: - 重建与位置

    private func prepare() {
        anchorOffset = max(0, lastOffset)
        if document.blocks.isEmpty { isLoadingDocument = true }
        scheduleRebuild(immediate: true)
    }

    /// 换书时视图身份不变、`@State` 会留下来，必须手动清一遍再按新书的位置恢复。
    private func reloadProject() {
        document = .empty
        translationText = ""
        manuscriptLength = 0
        query = ""
        matches = []
        highlightMap = [:]
        matchIndex = 0
        anchorOffset = 0
        prepare()
    }

    /// 后台重排。56 万字的切块、逐块 substring、字数统计，全都不能在主线程做——
    /// 以前打开阅读页或在写作台敲字都会同步跑这一遍，是另一个「整页卡住」的来源。
    private func scheduleRebuild(immediate: Bool = false) {
        rebuildTask?.cancel()
        if document.blocks.isEmpty { isLoadingDocument = true }
        if mode == .translation {
            translationText = ReaderText.translation(session.translations)
        }
        let preferredOffset = anchorOffset
        let delay: Duration = immediate ? .zero : .milliseconds(500)

        rebuildTask = Task { @MainActor in
            if delay > .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }

            // 原文分页：块索引来自 body.meta，滚动时只解密覆盖到的页。
            if mode == .source, session.canReadByPage, let blocks = session.bodyBlocks {
                let readerBlocks = blocks.map {
                    ReaderBlock(start: $0.start, length: $0.length)
                }
                let pageSource = ReaderPageSource(
                    pageCount: session.bodyPageCount,
                    pageSize: FileStore.bodyPageSize,
                    loader: { [weak session] index in session?.bodyPage(index) }
                )
                document = ReaderDocument(
                    blocks: readerBlocks,
                    length: session.bodyUTF16Length,
                    characterCount: session.manuscriptCharacterCount,
                    pageSource: pageSource
                )
                manuscriptLength = session.bodyUTF16Length
                applyRebuiltDocument(preferredOffset: preferredOffset)
                return
            }

            let text = mode == .translation
                ? translationText
                : session.manuscript
            let manuscriptSnapshot = session.manuscript
            let result = await Task.detached(priority: .userInitiated) {
                (
                    ReaderDocument(text: text),
                    (manuscriptSnapshot as NSString).length
                )
            }.value
            guard !Task.isCancelled else { return }
            document = result.0
            manuscriptLength = result.1
            applyRebuiltDocument(preferredOffset: preferredOffset)
        }
    }

    private func applyRebuiltDocument(preferredOffset: Int) {
        isLoadingDocument = false
        guard !document.blocks.isEmpty else {
            anchorOffset = 0
            matches = []
            highlightMap = [:]
            matchIndex = 0
            return
        }
        let index = ReaderLocator.blockIndex(for: clamp(preferredOffset), in: document.blocks)
        anchorOffset = document.blocks[index].start
        jump = ReaderJump(offset: anchorOffset, animated: false)
        performSearch()
    }
}

// MARK: - 内部类型

/// 一次跳转请求。带 token 是为了「同一段连点两次」也能重新滚一次。
private struct ReaderJump: Equatable {
    let offset: Int
    let animated: Bool
    let token: UUID

    init(offset: Int, animated: Bool) {
        self.offset = offset
        self.animated = animated
        self.token = UUID()
    }
}
