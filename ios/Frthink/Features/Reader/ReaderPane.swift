// 阅读页主界面：原文/译文切换、全文搜索、显示设置、章节与段落导航及书签管理。

import Foundation
import SwiftUI

/// 阅读页。
///
/// 正文按空行切分为段落并通过 `LazyVStack` 惰性渲染，避免一次性渲染全量文本造成卡顿。
/// 章节、搜索命中与书签跳转均换算为段落起始偏移，通过 `scrollPosition` 实现精确定位。
struct ReaderPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let session: ProjectSession

    @AppStorage(ReaderStorageKey.fontSize) private var fontSize: Double = 18
    @AppStorage(ReaderStorageKey.lineHeight) private var lineHeight: Double = 1.5
    @AppStorage(ReaderStorageKey.mode) private var modeRaw = ReaderMode.source.rawValue
    @AppStorage private var bookmarkOffset: Int
    @AppStorage private var lastOffset: Int

    @State private var document = ReaderDocument.empty
    /// 译文拼接结果：仅在 `translations` 变化时重新拼接，避免每帧重复计算。
    @State private var translationText = ""
    /// 原文 UTF-16 长度：译文模式折算章节位置时使用，避免频繁桥接 NSString。
    @State private var manuscriptLength = 0
    /// 当前定位点（UTF-16 偏移），随视口顶部段落滚动更新。
    @State private var position = ReaderPositionState()
    @State private var offsetSaveTask: Task<Void, Never>?
    /// `scrollPosition(id:)` 报告的顶部段落起点；跳转时亦驱动该状态以保持单一驱动源。
    @State private var scrolledBlockStart: Int?
    @State private var showSettings = false
    @State private var showChapters = false
    @State private var isExportingBody = false
    @State private var bodyExportDocument = PlainTextFileDocument()
    @State private var bodyExportFilename = "正文.txt"
    @State private var showSearch = false
    @State private var query = ""
    @State private var matches: [ReaderMatch] = []
    @State private var highlightMap: [Int: [NSRange]] = [:]
    @State private var matchIndex = 0
    /// 搜索进行中状态；用于展示加载中视图，避免界面闪烁空结果提示。
    @State private var isSearching = false
    /// 文本排版与切块后台任务，避免阻塞主线程。
    @State private var rebuildTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    /// 阅读页可见状态；不可见时跳过排版，重新可见时补算。
    @State private var isVisible = false
    /// 首帧至排版完成期间展示加载状态，避免误展示为空状态。
    @State private var isLoadingDocument = true
    /// 章节在显示文本里的偏移（译文模式按长度比例折算）。跟 `document` 一起更新，
    /// 不在 body 里逐帧重算——几千章的长篇也不让每帧都扫一遍章节表。
    @State private var chapterDisplayOffsets: [Int] = []
    /// 当前滚动位置落在第几章。随 `anchorOffset` 更新，body 里只读结果。
    @State private var currentChapterIndex: Int?
    /// 章节标题所在块的起点，随章节偏移一起缓存。
    @State private var chapterStarts: Set<Int> = []

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
            ReaderFooterView(position: position, document: document)
        }
        // 搜索面板使用覆盖层展示，不占据正文布局高度。
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
            // 页面离开时收起搜索浮层并注销键盘响应。
            showSearch = false
            isSearching = false
            rebuildTask?.cancel()
            rebuildTask = nil
            searchTask?.cancel()
            searchTask = nil
            offsetSaveTask?.cancel()
            offsetSaveTask = nil
            lastOffset = anchorOffset
        }
        // 仅在结构性变更（插入、撤销、导入、覆盖恢复）时触发重排，避免逐字编辑时比对全量长文本。
        .onChange(of: session.manuscriptRevision) { _, _ in
            if isVisible { scheduleRebuild() }
        }
        .onChange(of: session.translations) { _, _ in
            if isVisible { scheduleRebuild() }
        }
        .onChange(of: modeRaw) { _, _ in
            if isVisible { scheduleRebuild(immediate: true) }
        }
        // 章节索引由后台扫描派生，扫描完成后更新映射结果。
        .onChange(of: session.payload.chapters) { _, _ in
            refreshChapterOffsets()
        }
        // 书项目切换由 RootView 视图标识驱动重建，此处无需冗余监听。
        // 搜索防抖：输入停止 220ms 后执行检索；输入变更或页面销毁时自动取消前置任务。
        // 空关键词立即清空结果；非空时展示加载状态，避免界面瞬时闪烁空提示。
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
        .fileExporter(
            isPresented: $isExportingBody,
            document: bodyExportDocument,
            contentType: .plainText,
            defaultFilename: bodyExportFilename
        ) { result in
            switch result {
            case .success:
                store.toast = "已导出正文"
            case .failure(let error):
                guard !settingsIsUserCancelled(error) else { return }
                store.errorMessage = "导出正文失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 浮层与弹窗

    /// 搜索浮层：通过 overlay 挂载，不参与正文排版布局。
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
            lineHeight: $lineHeight
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
                prepareBodyExport()
            } label: {
                Label("导出正文…", systemImage: "square.and.arrow.up")
            }
            .disabled(session.manuscriptCharacterCount == 0)

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

    @MainActor
    private func prepareBodyExport() {
        let title = session.project.title
        let files = store.fileStore
        Task { @MainActor in
            let plain = await TextFileCodec.loadPlainExport(session: session, files: files)
            guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                store.errorMessage = "当前作品暂无可导出的正文。"
                return
            }
            bodyExportDocument = PlainTextFileDocument(text: plain)
            bodyExportFilename = TextFileCodec.exportFilename(title: title)
            isExportingBody = true
        }
    }

    // MARK: - 正文

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
                        darkPage: false,
                        highlights: highlightMap[block.start] ?? [],
                        current: currentHighlight(in: block),
                        isHeading: chapterStarts.contains(block.start)
                    )
                    .equatable()
                    .id(block.start)
                }
            }
            .scrollTargetLayout()
            // 每行不超过 36 个汉字：正文栏封顶后居中（§2.3、§5.3）。
            .frame(maxWidth: bodyColumnMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.l)
        }
        .background(ReaderStyle.page(dark: false))
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
        .softScrollEdge()
        // 使用 iOS 17 滚动位置绑定机制，避免为每个段落挂载 GeometryReader 导致重绘；
        // 跳转统一驱动绑定变量，避免与 scrollTo 冲突。
        .scrollPosition(id: $scrolledBlockStart, anchor: .top)
        .onChange(of: scrolledBlockStart) { _, start in
            guard let start, start != anchorOffset else { return }
            anchorOffset = start
            scheduleOffsetSave(start)
            refreshCurrentChapter()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 设置字号经 Dynamic Type 换算后的实际字号；正文栏宽度据此计算。
    private var scaledBodyFontSize: CGFloat {
        DynamicTypeFont.bodySize(fontSize, dynamicTypeSize: dynamicTypeSize)
    }

    private var bodyColumnMaxWidth: CGFloat {
        ReaderStyle.bodyMaxWidth(size: scaledBodyFontSize)
    }

    private var emptyState: some View {
        EmptyStateView(
            symbol: mode == .source ? "doc.text" : "globe",
            title: mode == .source ? "暂无正文" : "暂无译文"
        )
        .frame(maxWidth: .infinity)
    }

    /// 排版未完成时的占位视图，避免回退解析全量文本时闪现空状态。
    private var loadingState: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.xxl)
    }

    // MARK: - 页脚与位置状态

    private var anchorOffset: Int {
        get { position.anchorOffset }
        nonmutating set { position.anchorOffset = newValue }
    }

    private func scheduleOffsetSave(_ offset: Int) {
        offsetSaveTask?.cancel()
        offsetSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            lastOffset = offset
        }
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

    /// 章节偏移仅在文档重建与章节表变动时计算一次，body 中直接读取缓存。
    private func refreshChapterOffsets() {
        chapterStarts = Set(session.payload.chapters.map(\.location))
        chapterDisplayOffsets = session.payload.chapters.map { displayOffset(for: $0) }
        refreshCurrentChapter()
    }

    /// 当前章节根据滚动锚点计算；仅在滚动或跳转时更新，避免在 body 求值时线性扫描。
    private func refreshCurrentChapter() {
        currentChapterIndex = chapterDisplayOffsets.lastIndex(where: {
            $0 <= anchorOffset + 1
        })
    }

    /// 章节 `location` 为原文 UTF-16 偏移；译文因未保持字符级严格对齐，按长度比例估算映射位置。
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

    /// 跳转至指定偏移：约束在正文有效范围内，并对齐至所在段落起点。
    private func jump(to offset: Int) {
        guard !document.blocks.isEmpty else { return }
        let index = ReaderLocator.blockIndex(for: clamp(offset), in: document.blocks)
        let start = document.blocks[index].start
        anchorOffset = start
        lastOffset = start
        refreshCurrentChapter()
        // 仅更新滚动位置绑定变量以驱动定位，避免与 scrollTo 冲突。
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

    /// 计算当前匹配项在段落内的相对区间，供段落高亮渲染。
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

    /// 后台异步执行分块与字数统计，避免阻塞主线程。
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

            // 原文分页读取：分块索引读取自 body.meta，滚动时仅解密覆盖到的页。
            if mode == .source, session.canReadByPage, let blocks = session.bodyBlocks {
                let readerBlocks = blocks.map {
                    ReaderBlock(start: $0.start, length: $0.length)
                }
                let fileStore = store.fileStore
                let projectID = session.project.id
                let pageSource = ReaderPageSource(
                    pageCount: session.bodyPageCount,
                    pageSize: FileStore.bodyPageSize,
                    loader: { index in fileStore.loadBodyPage(projectID, index: index) }
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

            // 译文模式仅排版译文。章节折算所需的原文长度直接读取元数据，
            // 避免为了获取长度同步解密全量正文。
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

@Observable
private final class ReaderPositionState {
    var anchorOffset = 0
}

private struct ReaderFooterView: View {
    let position: ReaderPositionState
    let document: ReaderDocument

    var body: some View {
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

    private var readingProgressBar: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.separator)
            Capsule()
                .fill(Theme.accent)
                .scaleEffect(x: max(0, min(1, readingProgress)), y: 1, anchor: .leading)
        }
        .frame(height: Theme.Layout.progressBarHeight)
        .accessibilityHidden(true)
    }

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
        return ReaderLocator.blockIndex(for: position.anchorOffset, in: document.blocks) + 1
    }
}
