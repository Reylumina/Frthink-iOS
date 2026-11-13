// 本文件负责：阅读页主界面 —— 原文/译文切换、全文搜索、显示设置、章节与段落导航、书签。

import Foundation
import SwiftUI

/// 阅读页。
///
/// 正文先按空行切成小段，再交给 `LazyVStack` 渲染：几万字的书也只画屏幕上的十几段，
/// 不会因为一个 `Text` 塞进整篇而卡住。跳章节、跳命中、跳书签一律换算成「哪一段的
/// 起始偏移」，写进 `scrollPosition` 的绑定滚过去。
struct ReaderPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let session: ProjectSession

    @AppStorage(ReaderStorageKey.fontSize) private var fontSize: Double = 18
    @AppStorage(ReaderStorageKey.lineHeight) private var lineHeight: Double = 1.5
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
    /// `scrollPosition(id:)` 报告的顶部段落起点；跳转也写它，只保留一个滚动驱动。
    @State private var scrolledBlockStart: Int?
    @State private var showSettings = false
    @State private var showChapters = false
    @State private var showSearch = false
    @State private var query = ""
    @State private var matches: [ReaderMatch] = []
    @State private var highlightMap: [Int: [NSRange]] = [:]
    @State private var matchIndex = 0
    /// 搜索是否还没出结果。面板据此先显示加载态，不先闪「没有找到」。
    @State private var isSearching = false
    /// 排版（切块）任务。56 万字的正文切块不能在主线程做。
    @State private var rebuildTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    /// 阅读页当前是否可见。不可见时正文变化不重排，切回来再补。
    @State private var isVisible = false
    /// 首帧到排版完成之间显示加载态，避免把「正在排版」误报成「正文还是空的」。
    @State private var isLoadingDocument = true
    /// 章节在显示文本里的偏移（译文模式按长度比例折算）。跟 `document` 一起更新，
    /// 不在 body 里逐帧重算——几千章的长篇也不让每帧都扫一遍章节表。
    @State private var chapterDisplayOffsets: [Int] = []
    /// 当前滚动位置落在第几章。随 `anchorOffset` 更新，body 里只读结果。
    @State private var currentChapterIndex: Int?

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
        .themeAnimation(Theme.motionLayout, value: showSearch)
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
            isSearching = false
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
        // 章节索引是后台扫描的派生数据，扫完或重扫后刷新一次折算结果。
        .onChange(of: session.payload.chapters) { _, _ in
            refreshChapterOffsets()
        }
        // 换书由 RootView 的 `.id(session.project.id)` 重建整页，这里不用再监听。
        // 搜索防抖：打字停下 220ms 再扫全文；输入变了或页面走了，上一轮自动取消。
        // 空关键词立即清结果，不做加载态；有词时先亮加载，避免先闪一下「没有找到」。
        .task(id: query) {
            let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else {
                performSearch()
                return
            }
            isSearching = true
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
                isSearching: isSearching,
                onSubmit: { jumpToMatch(0) },
                onPrevious: { stepMatch(-1) },
                onNext: { stepMatch(1) },
                onSelect: { index in jumpToMatch(index) },
                onClose: { showSearch = false }
            )
            .transition(
                reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity)
            )
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
            // 章节索引已有时直接列出来；两者都还没有，才先亮加载态。
            isLoading: session.payload.chapters.isEmpty && isLoadingDocument,
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
        switch LaunchArguments.readerPanel {
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
            HStack(spacing: Theme.Spacing.xs) {
                Text(modeBinding.wrappedValue.displayName)
                    .font(Font.subheadline)
                Image(systemName: "chevron.down")
                    .font(Font.caption)
                    .accessibilityHidden(true)
            }
            .frame(minWidth: Theme.Layout.hitTarget, minHeight: Theme.Layout.hitTarget)
            .contentShape(Rectangle())
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
                showSearch = true
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
                .frame(minWidth: Theme.Layout.hitTarget, minHeight: Theme.Layout.hitTarget)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("更多阅读操作")
    }

    // MARK: - 正文

    /// 章节标题所在块的起点；读一次，块循环里只做集合查找。
    private var chapterStarts: Set<Int> {
        Set(session.payload.chapters.map(\.location))
    }

    private var readingSurface: some View {
        ScrollView {
            LazyVStack(
                alignment: .leading,
                spacing: Theme.Layout.paragraphSpacing(
                    fontSize: scaledBodyFontSize,
                    lineHeight: lineHeight
                )
            ) {
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
                        current: currentHighlight(in: block),
                        isHeading: chapterStarts.contains(block.start)
                    )
                    .id(block.start)
                }
            }
            .scrollTargetLayout()
            // 每行不超过 36 个汉字：正文栏封顶后居中，两侧露出纸色/黑底（§2.3、§5.3）。
            .frame(maxWidth: bodyColumnMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.l)
        }
        .background(ReaderStyle.page(dark: darkPage))
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .softScrollEdge()
        // iOS 17 的滚动位置绑定：只更新一个 Int，不再给每一段挂
        // GeometryReader + PreferenceKey，滚动时不会整页重算。
        // 跳转也只写这个绑定，避免 `scrollTo` 与 id 驱动互相拉扯。
        .scrollPosition(id: $scrolledBlockStart, anchor: .top)
        .onChange(of: scrolledBlockStart) { _, start in
            guard let start, start != anchorOffset else { return }
            anchorOffset = start
            lastOffset = start
            refreshCurrentChapter()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 设置字号按 Dynamic Type 换算后的实际字号；正文栏宽度按它算。
    private var scaledBodyFontSize: CGFloat {
        DynamicTypeFont.bodySize(fontSize, dynamicTypeSize: dynamicTypeSize)
    }

    private var bodyColumnMaxWidth: CGFloat {
        ReaderStyle.bodyMaxWidth(size: scaledBodyFontSize)
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: mode == .source ? "doc.text" : "character.book.closed",
            title: mode == .source ? "正文还是空的" : "还没有译文"
        )
        .frame(maxWidth: .infinity)
    }

    /// 排版完成前的占位；大书或旧书回退全文解析时能看到，而不是先闪一下空态。
    private var loadingState: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xxl)
    }

    // MARK: - 页脚

    private var footer: some View {
        VStack(spacing: Theme.Spacing.s) {
            readingProgressBar
            HStack(spacing: Theme.Spacing.s) {
                Text(positionLabel)
                    .font(Theme.numeric)
                    .foregroundStyle(.secondary)
                if !document.blocks.isEmpty {
                    Text("\(document.characterCount.formatted()) 字")
                        .font(Theme.numeric)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
    }

    /// 读到哪儿了：一条两像素的进度条，不抢正文的注意力。
    private var readingProgressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.separator)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: proxy.size.width * readingProgress)
            }
        }
        .frame(height: Theme.Layout.progressBarHeight)
        .accessibilityHidden(true)
    }

    /// 0…1；没有正文时不画进度。
    private var readingProgress: Double {
        let total = document.blocks.count
        guard total > 0 else { return 0 }
        return min(max(Double(currentBlockNumber) / Double(total), 0), 1)
    }

    private var positionLabel: String {
        guard !document.blocks.isEmpty else { return "暂无正文" }
        return "第 \(currentBlockNumber.formatted())/\(document.blocks.count.formatted()) 段"
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

    private var currentChapterID: String? {
        let chapters = session.payload.chapters
        guard !chapters.isEmpty else { return nil }
        guard let index = currentChapterIndex, chapters.indices.contains(index) else {
            return chapters.first?.id
        }
        return chapters[index].id
    }

    private var currentChapterTitle: String? {
        let chapters = session.payload.chapters
        guard !chapters.isEmpty else { return nil }
        guard let index = currentChapterIndex, chapters.indices.contains(index) else {
            return chapters.first?.title
        }
        return chapters[index].title
    }

    /// 章节偏移只在文档重建和章节表变化时算一次；body 里直接读缓存。
    private func refreshChapterOffsets() {
        chapterDisplayOffsets = session.payload.chapters.map { displayOffset(for: $0) }
        refreshCurrentChapter()
    }

    /// 当前章按滚动锚点定位；滚动/跳转时才扫一遍，body 不做线性查找。
    private func refreshCurrentChapter() {
        currentChapterIndex = chapterDisplayOffsets.lastIndex(where: {
            $0 <= anchorOffset + 1
        })
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
        let offsets = chapterDisplayOffsets
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

    /// 跳到某个偏移：先夹到正文范围内，再落到它所在那一段的段首。
    private func jump(to offset: Int) {
        guard !document.blocks.isEmpty else { return }
        let index = ReaderLocator.blockIndex(for: clamp(offset), in: document.blocks)
        let start = document.blocks[index].start
        anchorOffset = start
        lastOffset = start
        refreshCurrentChapter()
        // 只写滚动位置绑定：它同时也是跳转驱动，避免和 scrollTo 抢位置。
        withAnimation(Theme.motion(Theme.motionSelection, reduceMotion: reduceMotion)) {
            scrolledBlockStart = start
        }
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
            isSearching = false
            return
        }
        isSearching = true
        let documentSnapshot = document
        let blocks = document.blocks
        searchTask = Task { @MainActor in
            let found = await documentSnapshot.searchMatches(query: needle)
            guard !Task.isCancelled else { return }
            matches = found
            highlightMap = ReaderSearch.grouped(found, by: blocks)
            matchIndex = 0
            isSearching = false
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

            // 译文模式只排版译文。章节位置折算所需的原文长度走元数据
            // （`session.manuscriptLength` 在正文未加载时读 `body.meta`），
            // 不再为了量长度去读 `session.manuscript`——那会把整本正文同步解密一遍。
            let isTranslation = mode == .translation
            let text = isTranslation ? translationText : session.manuscript
            let sourceLength = isTranslation ? session.manuscriptLength : 0
            let result = await Task.detached(priority: .userInitiated) {
                (
                    ReaderDocument(text: text),
                    (text as NSString).length
                )
            }.value
            guard !Task.isCancelled else { return }
            document = result.0
            manuscriptLength = isTranslation ? sourceLength : result.1
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
            isSearching = false
            chapterDisplayOffsets = []
            currentChapterIndex = nil
            return
        }
        let index = ReaderLocator.blockIndex(for: clamp(preferredOffset), in: document.blocks)
        anchorOffset = document.blocks[index].start
        scrolledBlockStart = anchorOffset
        refreshChapterOffsets()
        performSearch()
    }
}
