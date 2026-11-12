import Foundation
import Observation

/// 单个书项目的编辑态。
///
/// 只做三件事：持有内存里的 payload、把改动防抖落盘、提供改对话的原子操作。
/// 生成逻辑（拼提示词、调模型）放在各自的 Feature 里，这里不掺。
@MainActor
@Observable
final class ProjectSession {
    var project: Project
    var payload: ProjectPayload
    var sourceText: String
    var translations: [TranslationSegment]
    /// 有未落盘的改动时为 true，UI 可以显示「保存中」。
    private(set) var isDirty = false
    /// 解密/解码失败时只读打开；所有保存入口直接返回，避免覆盖原文件。
    private(set) var isReadOnly = false

    /// 正文被「结构性地」改过几次（插入、撤销、导入替换）。
    ///
    /// 用户逐字编辑走 `updateManuscript`，不算外部改动：正文编辑器自己就是那次
    /// 编辑的发起者，不需要被回灌。插入/撤销/导入正文是外部改动，编辑器要把
    /// 整段文字换掉。用计数而不是比较字符串——56 万字的 `==` 每次重绘都做一遍
    /// 是纯浪费。
    private(set) var manuscriptRevision = 0

    /// 正文字数缓存。
    ///
    /// `String.count` 是 O(n)：56 万字在每次 body 求值时数一遍会白占主线程。
    /// 这里跟章节扫描一起在后台算，界面只读这个值（允许最多滞后一个防抖窗口）。
    private(set) var manuscriptCharacterCount: Int

    private let store: FileStore
    private var saveTask: Task<Void, Never>?
    /// 同一时间只允许一次编码/写盘。56 万字 payload 编一次要几十毫秒，
    /// 旧实现每秒都可能再起一个 detached task，多个编码任务叠着跑会抢 CPU、
    /// 抬内存峰值，表现就是滚动/输入偶发顿一下。
    private enum SaveKind: Equatable {
        /// 只写正文页和 body.meta，payload.json 不动。
        case bodyOnly
        /// 只写 payload.json（生成期检查点）：不含正文页，也不再带整份正文。
        case payloadOnly
        /// 正文页、body.meta 与 payload.json 都写。
        case all
    }

    private var saveInFlight = false
    /// 外部要整体替换磁盘内容（导入覆盖）期间暂停一切保存。
    ///
    /// 只在 `quiesceSaves()` 里置位：内存里的旧稿和磁盘上的新稿同时存在时，
    /// 任何一次防抖保存都会把导入结果盖回去。
    @ObservationIgnored private var savesQuiesced = false
    /// 等当前写盘结束的调用方（导入覆盖前必须等它落完）。
    @ObservationIgnored private var saveCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    /// 下一次落盘的范围；打字默认只写正文。
    private var nextSaveKind: SaveKind = .all
    /// 当前写盘结束后要补写的内容；没有就是 nil。
    private var queuedSaveKind: SaveKind?
    /// 章节扫描的防抖任务。
    private var chapterScanTask: Task<Void, Never>?
    /// 防抖窗口。正文是边打边存的，2 秒足够合并连续输入，也给背景编码留出空档。
    private let debounceInterval: Duration = .seconds(2)
    /// 正文密文是否已解密进内存。打开书时只读 body.meta，编辑/阅读/请求时才置 true。
    @ObservationIgnored private var bodyLoaded: Bool
    /// 正文有未落盘的改动。
    private var bodyDirty = false
    /// 上一次成功写盘的正文快照，用来只重写变化页。
    private var lastSavedManuscript: String?
    /// 保存时落下的块索引；阅读页按块取页，不必拼全文。
    @ObservationIgnored private(set) var bodyBlocks: [BodyBlock]?
    @ObservationIgnored private(set) var bodyPageCount = 0
    @ObservationIgnored private(set) var bodyUTF16Length = 0

    /// 编辑器窗口：只持有正文尾部若干页，起止都是整页边界。
    /// 这样打字/保存都不必把整本书拼进内存。
    @ObservationIgnored private var editorWindow: EditorWindowState?

    private struct EditorWindowState {
        var startPage: Int
        var start: Int
        var text: String
        var prefixCharacterCount: Int
        var totalLength: Int
    }

    var isWindowEditing: Bool { editorWindow != nil }

    /// 窗口在全文中的 UTF-16 起点；window 模式下光标要按它换算。
    var editorWindowStart: Int { editorWindow?.start ?? 0 }

    /// 全屏编辑器使用的正文。窗口存在时只返回尾部窗口。
    var editorText: String {
        if let editorWindow { return editorWindow.text }
        return manuscript
    }

    /// 窗口模式下全文 UTF-16 长度。
    var editorLength: Int {
        if let editorWindow { return editorWindow.totalLength }
        return manuscriptLength
    }

    func editorLocalCursor(_ global: Int) -> Int {
        guard let editorWindow else { return global }
        return min(max(global - editorWindow.start, 0), (editorWindow.text as NSString).length)
    }

    func editorGlobalCursor(_ local: Int) -> Int {
        guard let editorWindow else { return local }
        return editorWindow.start + local
    }

    /// 进入全屏编辑前只解密尾部两页。旧书没有页信息时回退全文。
    func beginWindowedEditing() {
        guard editorWindow == nil, !bodyLoaded else { return }
        guard let meta = store.loadBodyMeta(project.id),
              let pageCount = meta.pageCount,
              pageCount > 0,
              let blocks = meta.blocks,
              !blocks.isEmpty
        else {
            loadManuscriptIfNeeded()
            return
        }
        let pageSize = meta.pageSize ?? FileStore.bodyPageSize
        let startPage = max(0, pageCount - 2)
        let start = startPage * pageSize
        var text = ""
        for index in startPage..<pageCount {
            guard let page = store.loadBodyPage(project.id, index: index) else {
                loadManuscriptIfNeeded()
                return
            }
            text += page
        }
        let length = (text as NSString).length
        guard !text.isEmpty, start + length == meta.utf16Length else {
            loadManuscriptIfNeeded()
            return
        }
        editorWindow = EditorWindowState(
            startPage: startPage,
            start: start,
            text: text,
            prefixCharacterCount: max(0, meta.characterCount - text.count),
            totalLength: meta.utf16Length
        )
        manuscriptCharacterCount = meta.characterCount
    }

    func updateEditorText(_ text: String) {
        guard var window = editorWindow else {
            updateManuscript(text)
            return
        }
        window.text = text
        editorWindow = window
        bodyDirty = true
        manuscriptCharacterCount = window.prefixCharacterCount + text.count
        scheduleBodySave()
    }

    /// 章节跳到窗口之前时，把窗口起点扩到目标页；终点仍是书末。
    func reloadEditorWindow(containing offset: Int) {
        guard let current = editorWindow,
              let meta = store.loadBodyMeta(project.id),
              let pageCount = meta.pageCount,
              pageCount > 0
        else {
            beginWindowedEditing()
            return
        }
        let pageSize = meta.pageSize ?? FileStore.bodyPageSize
        let targetPage = min(max(0, offset / pageSize), pageCount - 1)
        guard targetPage < current.startPage else { return }
        var text = ""
        for index in targetPage..<pageCount {
            guard let page = store.loadBodyPage(project.id, index: index) else { return }
            text += page
        }
        editorWindow = EditorWindowState(
            startPage: targetPage,
            start: targetPage * pageSize,
            text: text,
            prefixCharacterCount: max(0, meta.characterCount - text.count),
            totalLength: meta.utf16Length
        )
        // 窗口文本换了，编辑器要重灌一次。
        manuscriptRevision += 1
    }

    /// 编辑器退出时扫一遍窗口里的章节；全文不拼回来。
    func finishWindowEditing() {
        guard let window = editorWindow else { return }
        let snapshot = window.text
        let windowStart = window.start
        Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) {
                ChapterScanner.scan(snapshot)
            }.value
            guard let self, self.editorWindow?.text == snapshot else { return }
            let prefix = self.payload.chapters.filter { $0.location < windowStart }
            let shifted = scanned.map {
                Chapter(title: $0.title, location: $0.location + windowStart)
            }
            self.payload.chapters = prefix + shifted
            self.scheduleBodySave()
        }
    }

    /// 外部需要整本正文时，把窗口拼回全文并退出窗口模式。
    private func collapseEditorWindow() {
        guard let window = editorWindow else { return }
        guard let full = store.loadBody(project.id)?.text,
              (full as NSString).length >= window.start
        else { return }
        let prefix = (full as NSString).substring(to: window.start)
        payload.manuscript = prefix + window.text
        bodyLoaded = true
        bodyDirty = true
        editorWindow = nil
        lastSavedManuscript = full
        manuscriptCharacterCount = payload.manuscript.count
        // 窗口消失后编辑器的绑定源变回全文，要让 UITextView 重灌一次。
        manuscriptRevision += 1
        scheduleBodySave()
    }

    /// 阅读页分页来源是否可用。正文一旦解密/编辑过就回退全文，
    /// 避免拿旧块索引去切新文本。
    var canReadByPage: Bool {
        !bodyLoaded && bodyPageCount > 0 && !(bodyBlocks?.isEmpty ?? true)
    }

    /// 阅读页单页解密。只在主线程、按需调用。
    func bodyPage(_ index: Int) -> String? {
        store.loadBodyPage(project.id, index: index)
    }

    init(
        project: Project,
        payload: ProjectPayload,
        source: String,
        translations: [TranslationSegment],
        store: FileStore,
        readOnly: Bool = false
    ) {
        self.project = project
        self.payload = payload
        self.sourceText = source
        self.translations = translations
        self.store = store
        self.isReadOnly = readOnly
        self.bodyLoaded = !payload.manuscript.isEmpty
        self.lastSavedManuscript = bodyLoaded ? payload.manuscript : nil
        self.manuscriptCharacterCount = payload.manuscript.isEmpty
            ? (project.bodyCharacterCount ?? 0)
            : payload.manuscript.count
        // 旧 project.json 没有正文字段时，用 body.meta 补齐（不碰正文密文）。
        // 块索引/页数也在这里读出来，阅读页打开时直接用。
        let meta = store.loadBodyMeta(project.id)
        self.bodyBlocks = meta?.blocks
        self.bodyPageCount = meta?.pageCount ?? 0
        self.bodyUTF16Length = meta?.utf16Length ?? project.bodyUTF16Length ?? 0
        if payload.manuscript.isEmpty, let meta {
            self.manuscriptCharacterCount = meta.characterCount
            self.project.bodyCharacterCount = meta.characterCount
            self.project.bodyUTF16Length = meta.utf16Length
        }
        // 上次进程在生成中被杀：把断点转为可见的中断标记。
        _ = self.payload.recoverInterruptedGeneration()
        // 导入的书、旧版本落盘的 payload 可能没有章节索引（章节是派生数据）。
        // 这里补一次后台扫描：不占打开书的这一帧，扫完再刷新章节条。
        if payload.chapters.isEmpty, !payload.manuscript.isEmpty {
            let text = payload.manuscript
            Task { [weak self] in
                let scanned = await Task.detached(priority: .utility) {
                    ChapterScanner.scan(text)
                }.value
                guard let self, self.payload.chapters.isEmpty else { return }
                self.payload.chapters = scanned
            }
        }
    }

    // MARK: - 落盘

    /// 落盘失败时通知外层。`AppStore` 在创建会话时接到全局错误条：
    /// 磁盘满/写入失败不能静默把「保存中」熄掉，让用户误以为已保存。
    @ObservationIgnored var onSaveError: ((String) -> Void)?

    /// 正文是否已解密进内存。
    var isManuscriptLoaded: Bool { bodyLoaded }

    /// 按需解密正文。打开书时不会调用；编辑器、阅读器、拼提示词前调用。
    func loadManuscriptIfNeeded() {
        if editorWindow != nil {
            collapseEditorWindow()
            return
        }
        guard !bodyLoaded else { return }
        let text = store.loadBody(project.id)?.text ?? payload.manuscript
        payload.manuscript = text
        bodyLoaded = true
        manuscriptCharacterCount = text.count
        if payload.chapters.isEmpty, !text.isEmpty {
            let snapshot = text
            Task { [weak self] in
                let scanned = await Task.detached(priority: .utility) {
                    ChapterScanner.scan(snapshot)
                }.value
                guard let self, self.payload.chapters.isEmpty else { return }
                self.payload.chapters = scanned
            }
        }
    }

    /// 正文文本。首次访问会同步解密；视图层应优先在 task/action 里调用。
    var manuscript: String {
        loadManuscriptIfNeeded()
        return payload.manuscript
    }

    /// 正文 UTF-16 长度。正文未加载时读项目元数据，不碰密文。
    var manuscriptLength: Int {
        if let editorWindow { return editorWindow.totalLength }
        if bodyLoaded { return (payload.manuscript as NSString).length }
        return bodyUTF16Length
    }

    func scheduleSave() {
        guard !isReadOnly, !savesQuiesced else { return }
        nextSaveKind = .all
        scheduleSaveTask()
    }

    /// 只保存正文/章节，不重写 payload.json。逐字编辑走这里。
    private func scheduleBodySave() {
        guard !isReadOnly, !savesQuiesced else { return }
        // 如果已经排了一次全量保存，不能被降级成只写正文。
        scheduleSaveTask()
    }

    /// 生成期检查点：只重写 payload.json 里新收的增量与生成标记。
    ///
    /// 不走 `.all`：正文页没变，`payload.manuscript` 还在内存里；每 3 秒把
    /// 56 万字正文重新编码一遍纯属浪费。正文有未落盘的改动时才升级成全量。
    func scheduleGenerationCheckpoint() {
        guard !isReadOnly, !savesQuiesced else { return }
        if nextSaveKind == .all || bodyDirty || editorWindow != nil {
            nextSaveKind = .all
        } else {
            nextSaveKind = .payloadOnly
        }
        scheduleSaveTask()
    }

    private func scheduleSaveTask() {
        guard !savesQuiesced else { return }
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.debounceInterval)
            guard !Task.isCancelled else { return }
            self.flushSave()
        }
    }

    func saveNow() {
        guard !isReadOnly, !savesQuiesced else { return }
        nextSaveKind = .all
        flushSave()
    }

    /// 落盘并等写盘真正结束。
    ///
    /// `saveNow()` 只负责起后台写盘；导出、退后台、切书这些「接下来要读磁盘」
    /// 的路径必须等它落完，否则会读到上一版内容。
    func saveNowAndWait() async {
        guard !isReadOnly, !savesQuiesced else { return }
        nextSaveKind = .all
        flushSave()
        // 写盘期间可能又排了下一轮（编辑仍在继续）：最多再等两轮。
        for _ in 0..<3 {
            await waitForSaveCompletion()
            if !saveInFlight { break }
        }
    }

    /// 导入覆盖同名书之前调用：停掉挂起保存，等正在进行的写盘结束。
    ///
    /// 返回后没有挂起保存、也没有进行中的写盘。在 `resumeSaving()` 或
    /// `replaceLoadedState(...)` 之前，任何编辑都只留在内存，不落盘。
    /// 挂起的编辑会先落一次盘：导入失败时用户刚打的字不能丢。
    func quiesceSaves() async {
        saveTask?.cancel()
        saveTask = nil
        await waitForSaveCompletion()
        if !isReadOnly, isDirty {
            nextSaveKind = .all
            flushSave()
            await waitForSaveCompletion()
        }
        savesQuiesced = true
        queuedSaveKind = nil
        nextSaveKind = .bodyOnly
        isDirty = false
    }

    private func waitForSaveCompletion() async {
        guard saveInFlight else { return }
        await withCheckedContinuation { continuation in
            saveCompletionWaiters.append(continuation)
        }
    }

    /// 这本书没有被导入覆盖（或写盘失败回滚）时恢复保存。
    func resumeSaving() {
        savesQuiesced = false
    }

    private func resumeSaveWaiters() {
        guard !saveCompletionWaiters.isEmpty else { return }
        let waiters = saveCompletionWaiters
        saveCompletionWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// 两类范围合并：相同就保持，不同就升级成全量。
    private static func merge(_ lhs: SaveKind?, _ rhs: SaveKind) -> SaveKind {
        guard let lhs, lhs != rhs else { return lhs ?? rhs }
        return .all
    }

    /// 两段正文从哪一页开始不同；只在后台写盘时调用。
    private nonisolated static func changedPageIndex(previous: String?, current: String) -> Int {
        guard let previous else { return 0 }
        let old = previous as NSString
        let new = current as NSString
        let shared = min(old.length, new.length)
        var index = 0
        while index < shared, old.character(at: index) == new.character(at: index) {
            index += 1
        }
        if index > 0, index < shared {
            let next = new.character(at: index)
            if next >= 0xDC00, next <= 0xDFFF { index -= 1 }
        }
        return index / FileStore.bodyPageSize
    }

    private func flushSave() {
        guard !isReadOnly, !savesQuiesced else { return }
        saveTask?.cancel()
        saveTask = nil

        let kind = nextSaveKind
        nextSaveKind = .bodyOnly

        // 上一次编码还没结束时不要并排再起一个，只记一个“待保存”。
        // 完成后用最新 payload 再写一次，保证最后一次修改一定落盘。
        guard !saveInFlight else {
            queuedSaveKind = Self.merge(queuedSaveKind, kind)
            return
        }
        saveInFlight = true

        // 正文没加载过、也没改过，就不要拿空串覆盖正文页。
        // payload-only 检查点不碰正文页，也不去动 bodyDirty 标记。
        let windowSnapshot = kind == .payloadOnly ? nil : editorWindow
        let bodySnapshot: String? = (kind == .payloadOnly || windowSnapshot != nil)
            ? nil
            : ((bodyLoaded || bodyDirty) ? payload.manuscript : nil)
        if kind != .payloadOnly {
            bodyDirty = false
            if let windowSnapshot {
                project.bodyCharacterCount = windowSnapshot.prefixCharacterCount
                    + windowSnapshot.text.count
                project.bodyUTF16Length = windowSnapshot.totalLength
            } else if let bodySnapshot {
                project.bodyCharacterCount = bodySnapshot.count
                project.bodyUTF16Length = (bodySnapshot as NSString).length
            }
        }

        project.updatedAt = Date()
        project.revision += 1
        let projectSnapshot = project
        // payload 是值类型，拷一份丢后台去编码写盘。整份 JSON 编码 56 万字的正文
        // 在主线程做会掉帧，这活儿不该占 UI 线程。
        let payloadSnapshot = payload
        // 检查点不把整本正文再写进 payload：正文页已经独立存在，payload 里的
        // manuscript 只是旧版兜底。仅当确认正文页存在时才裁掉，避免丢稿。
        let stripsBody = kind == .payloadOnly
            && !payloadSnapshot.manuscript.isEmpty
            && (bodyPageCount > 0 || lastSavedManuscript != nil)
        let store = self.store
        let previousManuscript = lastSavedManuscript
        // 先保留 dirty，等编码真正结束再清；期间界面显示“保存中”是对的。
        Task.detached(priority: .utility) { [weak self] in
            var firstError: Error?
            do { try store.saveProject(projectSnapshot) } catch {
                firstError = firstError ?? error
            }
            var savedBody = false
            var savedMeta: FileStore.BodyMeta?
            if let windowSnapshot {
                do {
                    try store.saveBodyWindow(
                        windowSnapshot.text,
                        startPage: windowSnapshot.startPage,
                        windowStart: windowSnapshot.start,
                        prefixCharacterCount: windowSnapshot.prefixCharacterCount,
                        chapters: payloadSnapshot.chapters,
                        projectID: projectSnapshot.id
                    )
                    savedBody = true
                    savedMeta = store.loadBodyMeta(projectSnapshot.id)
                } catch {
                    firstError = firstError ?? error
                }
            } else if let bodySnapshot {
                let fromPage = Self.changedPageIndex(
                    previous: previousManuscript,
                    current: bodySnapshot
                )
                do {
                    try store.saveBody(
                        bodySnapshot,
                        chapters: payloadSnapshot.chapters,
                        projectID: projectSnapshot.id,
                        changedFromPage: fromPage
                    )
                    savedBody = true
                } catch {
                    firstError = firstError ?? error
                }
            }
            if kind == .all || kind == .payloadOnly {
                do {
                    var payloadForDisk = payloadSnapshot
                    if stripsBody { payloadForDisk.manuscript = "" }
                    try store.savePayload(payloadForDisk, projectID: projectSnapshot.id)
                } catch {
                    firstError = firstError ?? error
                }
            }
            await MainActor.run {
                guard let self else { return }
                if savedBody { self.lastSavedManuscript = bodySnapshot }
                if let savedMeta {
                    self.bodyBlocks = savedMeta.blocks
                    self.bodyPageCount = savedMeta.pageCount ?? 0
                    self.bodyUTF16Length = savedMeta.utf16Length
                    self.manuscriptCharacterCount = savedMeta.characterCount
                }
                self.saveInFlight = false
                self.resumeSaveWaiters()
                if let firstError {
                    // 保持 dirty，但不再自动重试：磁盘满时每 2 秒重试只会更糟。
                    self.isDirty = true
                    self.queuedSaveKind = nil
                    self.onSaveError?("保存失败：\(firstError.localizedDescription)")
                    return
                }
                if self.savesQuiesced {
                    // 导入正在替换磁盘内容：旧快照不能再写回去。
                    self.queuedSaveKind = nil
                    self.isDirty = false
                } else if let queued = self.queuedSaveKind {
                    self.queuedSaveKind = nil
                    self.nextSaveKind = Self.merge(self.nextSaveKind, queued)
                    // 快照之后 payload 又变了：用最新内容再写一次。
                    self.flushSave()
                } else {
                    self.isDirty = false
                }
            }
        }
    }

    func saveSource() {
        guard !isReadOnly else { return }
        do {
            try store.saveSource(sourceText, projectID: project.id)
        } catch {
            onSaveError?("原文保存失败：\(error.localizedDescription)")
        }
    }

    func saveTranslations() {
        guard !isReadOnly else { return }
        do {
            try store.saveTranslations(translations, projectID: project.id)
        } catch {
            onSaveError?("译文保存失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 生成状态

    func beginGeneration(messageID: String) {
        payload.generatingMessageID = messageID
        payload.interruptedMessageIDs = (payload.interruptedMessageIDs ?? [])
            .filter { $0 != messageID }
        scheduleSave()
    }

    func finishGeneration() {
        guard payload.generatingMessageID != nil else { return }
        payload.generatingMessageID = nil
        scheduleSave()
    }

    func markInterrupted(_ messageID: String) {
        payload.generatingMessageID = nil
        var ids = payload.interruptedMessageIDs ?? []
        if !ids.contains(messageID) { ids.append(messageID) }
        payload.interruptedMessageIDs = ids
        scheduleSave()
    }

    func clearInterrupted(_ messageID: String) {
        guard let ids = payload.interruptedMessageIDs, ids.contains(messageID) else {
            return
        }
        payload.interruptedMessageIDs = ids.filter { $0 != messageID }
        scheduleSave()
    }

    func isInterrupted(_ messageID: String) -> Bool {
        (payload.interruptedMessageIDs ?? []).contains(messageID)
    }

    // MARK: - 正文

    /// 正文变化。章节扫描**不在这里同步做**：56 万字的全文正则一次要几十毫秒，
    /// 每敲一个字扫一遍会直接卡死输入法。改成防抖 + 后台线程。
    func updateManuscript(_ text: String) {
        payload.manuscript = text
        bodyLoaded = true
        bodyDirty = true
        scheduleBodySave()
        scheduleChapterScan()
    }

    /// 全屏编辑页关闭后，通知只读正文视图重新灌一次文字。
    ///
    /// `updateManuscript` 不能自己递增 `manuscriptRevision`：编辑页也观察这个数字，
    /// 每敲一个字都回灌整段会让 UITextView 重置光标。只在退出编辑时递增最安全。
    func noteManuscriptEdited() {
        manuscriptRevision += 1
    }

    /// 章节扫描的防抖任务。顺带把字数也算出来，界面不用再数全文。
    private func scheduleChapterScan() {
        chapterScanTask?.cancel()
        let snapshot = payload.manuscript
        chapterScanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            // 纯计算，放到后台，别占主线程。
            let result = await Task.detached(priority: .utility) {
                (ChapterScanner.scan(snapshot), snapshot.count)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.payload.chapters = result.0
            self.manuscriptCharacterCount = result.1
            // 章节索引也在正文文件里，扫完补一次正文保存。
            self.scheduleBodySave()
        }
    }

    /// 清理历史版本：只保留当前展示的版本（原版「清理历史版本」）。
    func keepOnlySelectedVariant(for messageID: String) {
        guard let index = payload.messages.firstIndex(where: { $0.id == messageID })
        else { return }
        var message = payload.messages[index]
        guard message.variants.count > 1 else { return }
        let selected = min(max(message.selectedVariant, 0), message.variants.count - 1)
        let content = message.variants[selected]
        message.variants = [content]
        message.selectedVariant = 0
        payload.messages[index] = message
        scheduleSave()
    }

    /// 删除整条消息（原版「删除这条消息？」）。用户指令和码字机回复都适用。
    func deleteMessage(_ messageID: String) {
        payload.messages.removeAll { $0.id == messageID }
        scheduleSave()
    }

    /// 多选删除：一次移除多条消息，只发一次保存。
    func deleteMessages(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        payload.messages.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    /// 清空码字机会话。原版没有这个入口；这是 iOS 侧的一次性清理。
    func clearConversation() {
        guard !payload.messages.isEmpty else { return }
        payload.messages.removeAll()
        scheduleSave()
    }

    /// 在光标处插入文本（续写结果「插入到正文」用）。
    ///
    /// 每次插入都记一条凭据，供 `undoLastBodyAppend()` 撤销。原版用
    /// `bodyAppendReceiptIds` + `lastBodyAppendUndo` 做同一件事。
    @discardableResult
    func insertIntoManuscript(_ text: String, at offset: Int) -> BodyAppendReceipt {
        loadManuscriptIfNeeded()
        let ns = payload.manuscript as NSString
        let safe = max(0, min(offset, ns.length))
        payload.manuscript = ns.replacingCharacters(
            in: NSRange(location: safe, length: 0),
            with: text
        )
        bodyLoaded = true
        bodyDirty = true
        manuscriptRevision += 1
        rescanChapters()

        let receipt = BodyAppendReceipt(location: safe, text: text)
        payload.bodyAppendReceipts.append(receipt)
        // 凭据栈不必无限增长，保留最近 100 条足够撤销。
        if payload.bodyAppendReceipts.count > 100 {
            payload.bodyAppendReceipts.removeFirst(payload.bodyAppendReceipts.count - 100)
        }
        payload.lastBodyAppendUndo = nil
        scheduleSave()
        return receipt
    }

    /// 撤销最近一次「插入正文」。成功返回被撤销的凭据。
    @discardableResult
    func undoLastBodyAppend() -> BodyAppendReceipt? {
        loadManuscriptIfNeeded()
        guard let receipt = payload.bodyAppendReceipts.popLast() else { return nil }
        let ns = payload.manuscript as NSString
        let start = max(0, min(receipt.location, ns.length))
        let length = (receipt.text as NSString).length
        let safeLength = max(0, min(length, ns.length - start))
        // 只有内容确实还在原位置才删，避免用户在中间编辑过之后误删。
        let current = ns.substring(with: NSRange(location: start, length: safeLength))
        guard current == receipt.text else {
            payload.bodyAppendReceipts.append(receipt)
            return nil
        }
        payload.manuscript = ns.replacingCharacters(
            in: NSRange(location: start, length: safeLength),
            with: ""
        )
        bodyLoaded = true
        bodyDirty = true
        manuscriptRevision += 1
        rescanChapters()
        payload.lastBodyAppendUndo = receipt
        scheduleSave()
        return receipt
    }

    /// 追加到正文末尾（原版「追加到正文」）。仍记回执，可撤销。
    ///
    /// 末尾插入要先补一个空行再另起一段，避免新段落和上一段粘在一起；
    /// 撤销凭据包含这个分隔符，撤销后不会留下多余空行。
    @discardableResult
    func appendToManuscript(_ text: String) -> BodyAppendReceipt {
        loadManuscriptIfNeeded()
        let paragraph = text.trimmingCharacters(in: .newlines)
        let body = payload.manuscript
        let separator: String
        if body.isEmpty || paragraph.isEmpty {
            separator = ""
        } else if body.hasSuffix("\n\n") {
            separator = ""
        } else if body.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }
        let end = (body as NSString).length
        return insertIntoManuscript(separator + paragraph, at: end)
    }

    /// 整段替换正文（「导入正文」用）。锚点跟着一起清掉，避免落在旧文档的偏移上。
    func replaceManuscript(_ text: String) {
        payload.manuscript = text
        bodyLoaded = true
        bodyDirty = true
        payload.continuationAnchor = nil
        payload.readerOffset = 0
        payload.readerBookmarkOffset = 0
        manuscriptRevision += 1
        rescanChapters()
        scheduleSave()
    }

    /// 外部整份替换 payload 后（例如导入覆盖后刷新会话）重算派生值。
    ///
    /// `payload` 是公开可写的值类型，直接赋值不会经过 `updateManuscript`；
    /// 这里补一次后台重算，避免字数/章节停留在旧书。
    func refreshDerivedValues() {
        // 正文还没按需加载时不做任何派生计算，避免把空串当成全文。
        guard bodyLoaded || !payload.manuscript.isEmpty else { return }
        let snapshot = payload.manuscript
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                (snapshot.count, ChapterScanner.scan(snapshot))
            }.value
            guard let self, self.payload.manuscript == snapshot else { return }
            self.manuscriptCharacterCount = result.0
            if self.payload.chapters.isEmpty {
                self.payload.chapters = result.1
            }
        }
    }

    /// 覆盖导入后，把内存态整体换成磁盘上的新内容。
    ///
    /// 不能只替换 `payload`：正文分页缓存、编辑器窗口、上一次正文快照和挂起保存
    /// 都还指着旧稿，下一次防抖保存会把导入内容盖回去。这里统一复位，并且不写盘
    /// ——磁盘才是导入后的权威来源。
    func replaceLoadedState(project: Project, fileStore: FileStore) {
        saveTask?.cancel()
        saveTask = nil
        chapterScanTask?.cancel()
        chapterScanTask = nil
        saveInFlight = false
        savesQuiesced = false
        resumeSaveWaiters()
        queuedSaveKind = nil
        nextSaveKind = .all
        isReadOnly = false
        bodyLoaded = false
        bodyDirty = false
        lastSavedManuscript = nil
        editorWindow = nil
        isDirty = false

        self.project = project
        payload = fileStore.loadPayload(project.id)
        sourceText = fileStore.loadSource(project.id)
        translations = fileStore.loadTranslations(project.id)

        if let meta = fileStore.loadBodyMeta(project.id) {
            bodyBlocks = meta.blocks
            bodyPageCount = meta.pageCount ?? 0
            bodyUTF16Length = meta.utf16Length
            manuscriptCharacterCount = meta.characterCount
        } else {
            bodyBlocks = nil
            bodyPageCount = 0
            bodyUTF16Length = (payload.manuscript as NSString).length
            manuscriptCharacterCount = payload.manuscript.count
        }
        manuscriptRevision += 1
    }

    /// 插入/撤销/导入后的章节重扫：放后台，别占用户操作这一帧。
    private func rescanChapters() {
        let snapshot = payload.manuscript
        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                (ChapterScanner.scan(snapshot), snapshot.count)
            }.value
            guard let self, self.payload.manuscript == snapshot else { return }
            self.payload.chapters = result.0
            self.manuscriptCharacterCount = result.1
        }
    }

    /// 设置/取消续写锚点（原版「放置续写锚」）。
    ///
    /// 锚点是 UTF-16 偏移：续写时只把正文到锚点之前的部分发给模型，从锚点之后
    /// 接着写。传 nil、或传越界值，都等于恢复「从正文末尾续写」。
    func setContinuationAnchor(_ offset: Int?) {
        let length = manuscriptLength
        if let offset, offset >= 0, offset <= length {
            payload.continuationAnchor = offset
        } else {
            payload.continuationAnchor = nil
        }
        scheduleSave()
    }

    // MARK: - 对话

    @discardableResult
    func addUserMessage(_ text: String) -> ChatMessage {
        let message = ChatMessage(role: .user, content: text)
        payload.messages.append(message)
        scheduleSave()
        return message
    }

    /// 先插入一条空的助手消息，流式增量往它里面写。
    @discardableResult
    func beginAssistantMessage(model: String?) -> ChatMessage {
        let message = ChatMessage(role: .assistant, content: "", model: model)
        payload.messages.append(message)
        return message
    }

    func appendDelta(_ text: String, to messageID: String) {
        guard let index = payload.messages.firstIndex(where: { $0.id == messageID })
        else { return }
        var message = payload.messages[index]
        message.content += text
        payload.messages[index] = message
    }

    func finishAssistantMessage(_ messageID: String, model: String?) {
        guard let index = payload.messages.firstIndex(where: { $0.id == messageID })
        else { return }
        var message = payload.messages[index]
        message.model = model ?? message.model
        payload.messages[index] = message
        scheduleSave()
    }

    func removeMessage(_ messageID: String) {
        payload.messages.removeAll { $0.id == messageID }
        scheduleSave()
    }

    /// 重新生成：把这条助手消息当成新分支，旧内容留在 variants 里。
    func addVariant(to messageID: String) {
        guard let index = payload.messages.firstIndex(where: { $0.id == messageID })
        else { return }
        var message = payload.messages[index]
        message.variants.append("")
        message.selectedVariant = message.variants.count - 1
        payload.messages[index] = message
    }

    func selectVariant(_ variant: Int, for messageID: String) {
        guard let index = payload.messages.firstIndex(where: { $0.id == messageID })
        else { return }
        var message = payload.messages[index]
        guard message.variants.indices.contains(variant) else { return }
        message.selectedVariant = variant
        payload.messages[index] = message
        scheduleSave()
    }

    /// 删除当前展示的版本（原版「删除当前版本」）。
    ///
    /// 还有别的版本时只删这一版；只剩一版时连气泡一起删掉。会话级回退不在这里
    /// 做——原版明确禁止「会话版本不能回退」，能回退的是气泡版本。
    func deleteSelectedVariant(for messageID: String) {
        guard let index = payload.messages.firstIndex(where: { $0.id == messageID })
        else { return }
        var message = payload.messages[index]
        if message.variants.count <= 1 {
            payload.messages.remove(at: index)
        } else {
            let removed = min(max(message.selectedVariant, 0), message.variants.count - 1)
            message.variants.remove(at: removed)
            if message.selectedVariant >= message.variants.count {
                message.selectedVariant = message.variants.count - 1
            }
            payload.messages[index] = message
        }
        scheduleSave()
    }

    /// 把对话回退到某条消息之前（Android 端的「回到这条消息对应的用户指令之前」）。
    func rollbackToMessage(_ messageID: String) {
        guard let index = payload.messages.firstIndex(where: { $0.id == messageID })
        else { return }
        payload.messages.removeSubrange(index..<payload.messages.count)
        scheduleSave()
    }

    /// 记录一次请求快照（「提示词回看」）。
    ///
    /// 只按条数保留 30 条不够：一次发送 56 万字正文的快照就能让 `payload.json`
    /// 膨胀几十 MB，之后的每次写盘都要编码这些历史。这里再加一道 token 上限
    /// （中文约 3 字节/token），至少保留最新一条。
    func recordRequestSnapshot(
        model: String,
        messages: [LLMMessage],
        sourceIds: [String],
        omittedHistoryMessages: Int,
        maxTokens: Int,
        inputBudgetTokens: Int,
        contextWindow: Int,
        estimatedInputTokens: Int? = nil
    ) {
        let snapshot = RequestSnapshot(
            createdAt: Date(),
            modelId: model,
            sourceIds: sourceIds,
            messages: messages,
            estimatedInputTokens: estimatedInputTokens
                ?? TokenEstimator.estimate(messages: messages),
            inputBudgetTokens: inputBudgetTokens,
            modelContextWindowTokens: contextWindow,
            outputReserveTokens: maxTokens,
            omittedHistoryMessages: omittedHistoryMessages
        )
        payload.requestSnapshots.append(snapshot)
        trimRequestSnapshots()
        scheduleSave()
    }

    /// 提示词回看的总量上限（估算 token）。约 60 万中文字，够回看最近几次请求。
    private static let requestSnapshotTokenBudget = 200_000

    private func trimRequestSnapshots() {
        var totalTokens = payload.requestSnapshots.reduce(0) {
            $0 + $1.estimatedInputTokens
        }
        while payload.requestSnapshots.count > 30
            || (totalTokens > Self.requestSnapshotTokenBudget
                && payload.requestSnapshots.count > 1) {
            totalTokens -= payload.requestSnapshots.removeFirst().estimatedInputTokens
        }
    }

    /// 删除单条/多条回看记录。只清审计日志，不影响后续请求。
    func deleteRequestSnapshots(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        payload.requestSnapshots.removeAll { ids.contains($0.id) }
        scheduleSave()
    }

    func clearRequestSnapshots() {
        guard !payload.requestSnapshots.isEmpty else { return }
        payload.requestSnapshots.removeAll()
        scheduleSave()
    }

    var lastUserMessage: ChatMessage? {
        payload.messages.last { $0.role == .user }
    }

    var lastAssistantMessage: ChatMessage? {
        payload.messages.last { $0.role == .assistant }
    }
}

/// 从正文里扫出章节标题。
///
/// 正则取自 Android 端的字符串表，原文是：
/// `^(?:第[零〇一二三四五六七八九十百千万两0-9]+[章节回卷部篇](?:[：:]?[^，,。！？!?；;：:]{0,48})?|…`
enum ChapterScanner {
    private static let pattern = #"^(?:第[零〇一二三四五六七八九十百千万两0-9]+[章节回卷部篇](?:[：:]?[^，,。！？!?；;：:]{0,48})?|[一二三四五六七八九十百]+[、．.]\s*[^，,。！？!?；;：:]{1,48}|序章|楔子|尾声|后记|番外(?:篇)?(?:第?[零〇一二三四五六七八九十百千万两0-9]+)?|Chapter\s+\d+(?:\b.*)?)$"#

    private static let regex = try? NSRegularExpression(pattern: pattern)

    static func scan(_ text: String) -> [Chapter] {
        guard let regex else { return [] }
        let ns = text as NSString
        var chapters: [Chapter] = []
        var lineStart = 0
        while lineStart < ns.length {
            let range = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            let line = ns.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty, line.count <= 60 {
                let candidate = line as NSString
                if regex.firstMatch(
                    in: line,
                    options: [],
                    range: NSRange(location: 0, length: candidate.length)
                ) != nil {
                    chapters.append(Chapter(title: line, location: range.location))
                }
            }
            lineStart = range.location + range.length
            if range.length == 0 { break }
        }
        return chapters
    }
}
