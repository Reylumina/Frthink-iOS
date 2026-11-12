import Foundation
import Observation
import UIKit

/// 全局状态：书架、设置、当前打开的会话。
///
/// 只负责「有哪些项目」和「设置」，单个项目的正文/世界书由
/// `ProjectSession` 持有，避免每次输入都触发整个书架刷新。
@MainActor
@Observable
final class AppStore {
    private(set) var projects: [Project] = []
    var settings: AppSettings
    /// 轻提示，UI 读它弹一个 banner 后置 nil。
    var toast: String?
    var errorMessage: String?

    let fileStore: FileStore
    /// 会话缓存。**不参与观察**——它是在 `RootView` 求值 body 时被填充的，
    /// 如果算作被观察属性，写入就会变成「在视图更新期间改状态」。
    @ObservationIgnored private var sessions: [String: ProjectSession] = [:]
    /// 内存警告时释放非当前会话；观察者 token 在 deinit 移除。
    @ObservationIgnored private var memoryObserver: NSObjectProtocol?
    /// 钥匙串读取是跨进程同步调用，设置页每次重绘都会问一遍，很慢。
    /// 这里缓存一份，只在启动、写 Key、保存设置时刷新。
    @ObservationIgnored private var apiKeyCache: [String: String] = [:]
    /// 钥匙串内容变化的可观察计数。缓存本身不参与观察，界面上只读这个数来刷新。
    private(set) var apiKeyRevision = 0

    /// 世界刷新/事件/文风/长期规则任务，按书项目登记。
    ///
    /// 任务句柄原本只挂在 `WorldPane` 的 `@State` 上；切书后视图销毁、任务还在跑，
    /// 被驱逐的旧会话继续写同一个 `payload.json`。切书时这里统一取消。
    @ObservationIgnored private var worldTasks: [String: Task<Void, Never>] = [:]

    init(fileStore: FileStore = FileStore()) {
        self.fileStore = fileStore
        self.settings = fileStore.loadSettings()
        reload()
        refreshAPIKeyCache()
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // 当前会话由 RootView 强引用，从缓存移除不会丢对象；
                // 这样内存警告时能把整份 payload 的额外缓存释放掉。
                await self?.trimSessionCache(keeping: [])
            }
        }
    }

    deinit {
        if let memoryObserver {
            NotificationCenter.default.removeObserver(memoryObserver)
        }
    }

    /// 退到后台/失去活跃前，把防抖窗口里的编辑立刻落盘。
    ///
    /// iOS 进入后台后可能直接终止进程；2 秒防抖等不到就会丢最后一段输入。
    /// 这里等写盘真正结束再返回，给系统留出落盘时间。
    func flushDirtySessions() async {
        for session in sessions.values where session.isDirty {
            await session.saveNowAndWait()
        }
    }

    /// 只保留当前书稿的会话缓存。切书时调用；非当前书先落盘再释放，
    /// 避免多本 56 万字书同时驻留内存，也避免旧会话的挂起保存盖住新书。
    func trimSessionCache(keeping keepIDs: Set<String>) async {
        let evicted = sessions.keys.filter { !keepIDs.contains($0) }
        for id in evicted {
            guard let session = sessions[id] else { continue }
            if session.isDirty {
                await session.saveNowAndWait()
            }
            sessions.removeValue(forKey: id)
        }
    }

    // MARK: - 世界任务

    /// 登记正在跑的世界任务；同一本书同时只允许一个。
    func registerWorldTask(_ task: Task<Void, Never>, for projectID: String) {
        worldTasks[projectID]?.cancel()
        worldTasks[projectID] = task
    }

    /// 任务正常结束或失败时清掉登记。
    func finishWorldTask(for projectID: String) {
        worldTasks[projectID] = nil
    }

    /// 切书/删书时取消该项目在跑的世界任务。
    func cancelWorldTask(for projectID: String) {
        worldTasks[projectID]?.cancel()
        worldTasks[projectID] = nil
    }

    // MARK: - 书架

    func reload() {
        projects = fileStore.loadProjects()
    }

    var activeProjects: [Project] {
        projects.filter { !$0.isTrashed }
    }

    var trashedProjects: [Project] {
        projects.filter { $0.isTrashed }
    }

    /// 新建书稿。落盘失败返回 nil：调用方不应该拿着一个磁盘上不存在的项目去开会话。
    @discardableResult
    func createProject(title: String) -> Project? {
        var p = Project(title: title.isEmpty ? Project.untitledTitle : title)
        p.branchRootId = p.id
        do {
            try fileStore.saveProject(p)
            let payload = ProjectPayload()
            try fileStore.savePayload(payload, projectID: p.id)
            reload()
            let session = attachSaveErrorHandler(ProjectSession(
                project: p,
                payload: payload,
                source: "",
                translations: [],
                store: fileStore
            ))
            sessions[p.id] = session
            return p
        } catch {
            errorMessage = "创建失败：\(error.localizedDescription)"
            return nil
        }
    }

    func openSession(for project: Project) -> ProjectSession {
        if let existing = sessions[project.id] {
            return existing
        }
        let decoded = decodedPayload(
            fileStore.loadPayloadState(project.id),
            project: project
        )
        let session = attachSaveErrorHandler(ProjectSession(
            project: project,
            payload: decoded.payload,
            source: fileStore.loadSource(project.id),
            translations: fileStore.loadTranslations(project.id),
            store: fileStore,
            readOnly: decoded.readOnly
        ))
        sessions[project.id] = session
        return session
    }

    /// 已经解码过的会话。RootView 用它决定要不要显示加载态。
    func cachedSession(for projectID: String) -> ProjectSession? {
        sessions[projectID]
    }

    /// 后台解码整份 payload 再建会话。
    ///
    /// 56 万字的 JSON 解码在主线程做会直接卡住首帧；这里把 IO + 解码丢到后台，
    /// 界面先显示书稿框架和「正在打开」。
    func openSessionAsync(for project: Project) async -> ProjectSession {
        if let existing = sessions[project.id] {
            return existing
        }
        let store = fileStore
        let id = project.id
        let loaded = await Task.detached(priority: .userInitiated) {
            (
                store.loadPayloadState(id),
                store.loadSource(id),
                store.loadTranslations(id)
            )
        }.value

        if let existing = sessions[project.id] {
            return existing
        }
        let decoded = decodedPayload(loaded.0, project: project)
        let session = attachSaveErrorHandler(ProjectSession(
            project: project,
            payload: decoded.payload,
            source: loaded.1,
            translations: loaded.2,
            store: fileStore,
            readOnly: decoded.readOnly
        ))
        sessions[project.id] = session
        return session
    }

    /// 会话落盘失败统一冒泡到全局错误条。
    private func attachSaveErrorHandler(_ session: ProjectSession) -> ProjectSession {
        session.onSaveError = { [weak self] message in
            self?.errorMessage = message
        }
        return session
    }

    /// 缺失按新书处理；损坏按只读处理并上屏原因，避免用空 payload 覆盖原文件。
    private func decodedPayload(
        _ state: FileStore.PayloadLoadState,
        project: Project
    ) -> (payload: ProjectPayload, readOnly: Bool) {
        switch state {
        case .loaded(let payload):
            return (payload, false)
        case .missing:
            return (ProjectPayload(), false)
        case .corrupted:
            errorMessage = "「\(project.title)」的数据无法解密或解析，已按只读打开。请从备份恢复；当前编辑不会写回磁盘。"
            return (ProjectPayload(), true)
        }
    }

    func touch(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var p = projects[idx]
        p.updatedAt = Date()
        p.revision += 1
        projects[idx] = p
        persistProject(p)
    }

    func rename(_ project: Project, to title: String) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var p = projects[idx]
        p.title = title
        p.updatedAt = Date()
        p.revision += 1
        projects[idx] = p
        persistProject(p)
        sessions[p.id]?.project = p
    }

    func setSynopsis(_ project: Project, to text: String) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var p = projects[idx]
        p.synopsis = text
        p.updatedAt = Date()
        projects[idx] = p
        persistProject(p)
    }

    /// 回收站。Android 端是 `trashedAt` 时间戳，不是立即删除。
    func trash(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        cancelWorldTask(for: project.id)
        var p = projects[idx]
        p.trashedAt = Date()
        projects[idx] = p
        persistProject(p)
        sessions[project.id] = nil
    }

    func restore(_ project: Project) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var p = projects[idx]
        p.trashedAt = nil
        projects[idx] = p
        persistProject(p)
    }

    func deleteForever(_ project: Project) {
        cancelWorldTask(for: project.id)
        do {
            try fileStore.deleteProject(project.id)
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
            return
        }
        sessions[project.id] = nil
        reload()
    }

    private func persistProject(_ project: Project) {
        do {
            try fileStore.saveProject(project)
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    /// 创建分支：复制成一个新项目，不是在同一项目内建树。
    ///
    /// 严格照原版 `L1/W0.java:175-246`：
    /// - 标题后缀是 `" · 分支 N"`，N 取**同根下的最大 branchOrder + 1**（不是本项目的 +1）
    /// - `branchRootId` 指向根项目，`branchOrder` 从 1 开始
    /// - **不复制正文**：新分支的稿子是空的，只继承世界/人物等元数据
    @discardableResult
    func duplicate(_ project: Project) -> Project {
        let session = openSession(for: project)

        let maxOrder = projects
            .filter { $0.branchRootId == project.branchRootId }
            .map(\.branchOrder)
            .max() ?? 0
        let newOrder = maxOrder + 1

        var copy = project
        copy.id = UUID().uuidString
        copy.title = project.title + " · 分支 \(newOrder)"
        copy.updatedAt = Date()
        copy.revision = 0
        copy.branchRootId = project.branchRootId
        copy.branchOrder = newOrder
        copy.trashedAt = nil

        var payload = session.payload
        // 正文相关的字段清空，元数据（世界书、人物卡、模板、规则）保留。
        payload.manuscript = ""
        payload.chapters = []
        payload.continuationAnchor = nil

        // 译文主键含 project：分支复制必须重打归属，否则两本书译文主键重合，
        // 导出的备份会被自己的重复校验拒收。
        let translations = session.translations.map { segment in
            var normalized = segment
            normalized.project = copy.id
            return normalized
        }
        do {
            try fileStore.saveProject(copy)
            try fileStore.savePayload(payload, projectID: copy.id)
            try fileStore.saveSource(session.sourceText, projectID: copy.id)
            try fileStore.saveTranslations(translations, projectID: copy.id)
            reload()
            return copy
        } catch {
            errorMessage = "创建分支失败：\(error.localizedDescription)"
            return project
        }
    }

    /// 同一 `branchRootId` 下的兄弟分支。
    func branches(of project: Project) -> [Project] {
        projects
            .filter { $0.branchRootId == project.branchRootId && !$0.isTrashed }
            .sorted { $0.branchOrder < $1.branchOrder }
    }

    // MARK: - 设置

    func saveSettings() {
        do {
            try fileStore.saveSettings(settings)
        } catch {
            errorMessage = "设置保存失败：\(error.localizedDescription)"
        }
        refreshAPIKeyCache()
    }

    func apiKey(for providerID: String) -> String {
        if let cached = apiKeyCache[providerID] { return cached }
        return Keychain.get(Keychain.account(for: providerID)) ?? ""
    }

    func setAPIKey(_ key: String, for providerID: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed, for: Keychain.account(for: providerID))
        apiKeyCache[providerID] = trimmed
        apiKeyRevision += 1
    }

    /// 有没有填过任何一个 Key。设置首页用它决定要不要提示。
    var hasAnyAPIKey: Bool {
        _ = apiKeyRevision
        return settings.providers.contains { !apiKey(for: $0.id).isEmpty }
    }

    /// 供应方列表变化（新增/覆盖）后把缓存补齐。已有缓存不重复读钥匙串。
    func refreshAPIKeyCache() {
        for provider in settings.providers where apiKeyCache[provider.id] == nil {
            apiKeyCache[provider.id] = Keychain.get(Keychain.account(for: provider.id)) ?? ""
        }
    }

    // MARK: - 当前供应方

    func clientForActiveProvider() throws -> any LLMClient {
        guard let provider = settings.activeProvider else {
            throw LLMError.notConfigured
        }
        let key = apiKey(for: provider.id)
        guard !key.isEmpty else {
            throw LLMError.missingAPIKey(provider.kind.displayName)
        }
        return OpenAICompatibleClient(
            baseURL: provider.baseURLForDisplay,
            apiKey: key,
            provider: provider
        )
    }

    /// 翻译任务用的供应方。设置里单独指定了就用它，否则复用当前供应方。
    var translationProvider: ProviderSetting? {
        if !settings.translationProviderID.isEmpty,
           let picked = settings.providers.first(where: { $0.id == settings.translationProviderID }) {
            return picked
        }
        return settings.activeProvider
    }

    func clientForTranslation() throws -> any LLMClient {
        guard let provider = translationProvider else {
            throw LLMError.notConfigured
        }
        let key = apiKey(for: provider.id)
        guard !key.isEmpty else {
            throw LLMError.missingAPIKey(provider.kind.displayName)
        }
        return OpenAICompatibleClient(
            baseURL: provider.baseURLForDisplay,
            apiKey: key,
            provider: provider
        )
    }
}

