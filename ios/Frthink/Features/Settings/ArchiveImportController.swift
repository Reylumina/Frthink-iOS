// 本文件负责：存档导入的状态机 —— 读文件、解码、写入、覆盖确认。
//
// 读文件、解压、解码与写盘均放在 Task.detached 中执行，避免大备份阻塞主线程；
// 主线程只更新进度和结果。
//
// 流程页由「存档与备份」页推进导航栈，不用 fullScreenCover：文件面板收起和
// 自定义弹层同时发生转场时，系统会静默丢掉后者，表现就是选完文件什么都没发生。

import Foundation
import Observation

/// 用户从文件面板选中的存档。作为导航值，选中文件后直接进入导入页。
enum ArchiveImportKind: Hashable {
    case project
    case full
}

struct ArchiveImportRequest: Identifiable, Hashable {
    let id = UUID()
    let kind: ArchiveImportKind
    let url: URL
}

/// 导入进度。文案直接上屏，不用再翻译。
enum ArchiveImportStage: Equatable {
    /// `size` 为 0 表示还没读到文件大小。
    case reading(size: Int)
    /// 文件在 iCloud 里还没下载到本机；直接读会长时间无响应。
    case downloading
    case decoding
    case restoring(index: Int, total: Int, title: String)
    case mergingSettings

    var title: String {
        switch self {
        case .reading, .downloading, .decoding: return "正在读取备份"
        case .restoring: return "正在写入书项目"
        case .mergingSettings: return "正在合并设置"
        }
    }

    var detail: String {
        switch self {
        case .reading(let size):
            return size > 0 ? "文件 \(settingsByteText(Int64(size)))" : "从文件读取…"
        case .downloading:
            return "文件在 iCloud 中，正在下载…"
        case .decoding:
            return "解压并校验存档结构…"
        case .restoring(let index, let total, let title):
            let safeTitle = title.isEmpty ? Project.untitledTitle : title
            return "第 \(index + 1)/\(total) 本 · \(safeTitle)"
        case .mergingSettings:
            return "预设、技能、世界书与预算…"
        }
    }
}

/// 需要用户确认的「覆盖同名书项目」。
struct PendingProjectImport {
    let projects: [FrthinkArchive.ProjectBackup]
    /// 本机已存在、会被覆盖的书名。
    let overridingTitles: [String]
}

/// 导入完成页的数据。
struct ArchiveImportOutcome {
    let isFull: Bool
    let books: [ArchiveBookSummary]
    let settingsHighlights: [String]

    var totalCharacters: Int { books.reduce(0) { $0 + $1.bodyCharacters } }
    var activeCount: Int { books.filter { !$0.isTrashed }.count }
    var trashedCount: Int { books.count - activeCount }
}

/// 导入流程的状态机。一个入口一个实例，各自独立。
@MainActor
@Observable
final class ArchiveImportController {
    private let store: AppStore

    private(set) var stage: ArchiveImportStage?
    private(set) var outcome: ArchiveImportOutcome?
    private(set) var errorText: String?
    private(set) var pendingProjectImport: PendingProjectImport?
    private(set) var pendingFullRestore: FrthinkArchive.FullBackupPayload?

    /// 导入前书架里已有项目的 id，用来判断这次是新增还是覆盖。
    private var existingIDs: Set<String> = []
    /// 当前这一段读盘/写盘任务；用户退出导入页时取消，避免后台继续写。
    private var runTask: Task<Void, Never>?

    init(store: AppStore) {
        self.store = store
    }

    /// 展示导入流程页。确认弹窗与结果都在这一页里，避免「一个弹层接一个弹层」。
    var isFlowPresented: Bool {
        stage != nil
            || outcome != nil
            || errorText != nil
            || pendingProjectImport != nil
            || pendingFullRestore != nil
    }

    var isBusy: Bool { stage != nil }

    // MARK: - 入口

    /// 导航进入导入页后调用一次，按入口类型开始导入。
    func begin(_ request: ArchiveImportRequest) {
        switch request.kind {
        case .project:
            beginProjectImport(from: request.url)
        case .full:
            beginFullImport(from: request.url)
        }
    }

    /// 「书项目存档」入口。给全量备份也照书项目导入：只写书，不动本机设置。
    func beginProjectImport(from url: URL) {
        start { controller in
            let archive = try await controller.load(url: url)
            let backups = archive.projects
            let overrides = backups
                .filter { controller.existingIDs.contains($0.projectId) }
                .map { $0.title.isEmpty ? Project.untitledTitle : $0.title }
            if overrides.isEmpty {
                try await controller.restore(backups)
            } else {
                controller.stage = nil
                controller.pendingProjectImport = PendingProjectImport(
                    projects: backups,
                    overridingTitles: overrides
                )
            }
        }
    }

    /// 「全量存档」入口。解码后先问一次，再写盘并合并设置。
    func beginFullImport(from url: URL) {
        start { controller in
            let archive = try await controller.load(url: url)
            switch archive {
            case .full(let backup):
                controller.stage = nil
                controller.pendingFullRestore = backup
            case .projects(let payload):
                // 只有书项目、没有设置：按项目导入处理，别清空本机设置。
                let overrides = payload.projects
                    .filter { controller.existingIDs.contains($0.projectId) }
                    .map { $0.title.isEmpty ? Project.untitledTitle : $0.title }
                if overrides.isEmpty {
                    try await controller.restore(payload.projects)
                } else {
                    controller.stage = nil
                    controller.pendingProjectImport = PendingProjectImport(
                        projects: payload.projects,
                        overridingTitles: overrides
                    )
                }
            }
        }
    }

    /// 用户退出导入页：停掉读盘/写盘。已完整写入的书项目保留，不会写半个。
    func cancel() {
        runTask?.cancel()
        runTask = nil
        reset()
    }

    /// 统一的任务外壳：主线程置进度、后台读盘，出错落到错误页。
    private func start(
        _ work: @escaping @MainActor (ArchiveImportController) async throws -> Void
    ) {
        guard !isFlowPresented else { return }
        reset()
        existingIDs = Set(store.projects.map(\.id))
        stage = .reading(size: 0)
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await work(self)
            } catch is CancellationError {
                // 用户主动退出，页面已经由 cancel() 复位。
            } catch {
                self.fail(error)
            }
            self.runTask = nil
        }
    }

    // MARK: - 确认

    func confirmProjectOverride(_ overridePending: PendingProjectImport? = nil) {
        guard let pending = overridePending ?? pendingProjectImport else { return }
        pendingProjectImport = nil
        runConfirmTask { controller in
            try await controller.restore(pending.projects)
        }
    }

    func confirmFullRestore(_ overrideBackup: FrthinkArchive.FullBackupPayload? = nil) {
        guard let backup = overrideBackup ?? pendingFullRestore else { return }
        pendingFullRestore = nil
        runConfirmTask { controller in
            try await controller.restore(backup.projects)
            controller.stage = .mergingSettings
            // 只覆盖存档里明确写出的设置键；供应方、本机 Key 与外观偏好由
            // mergeSettings 保留（Android 备份不含 Key，也没有 iOS 独有字段）。
            let merged = FrthinkArchive.mergeSettings(
                backup.settings,
                into: controller.store.settings,
                archivedKeys: backup.settingsKeyNames
            )
            controller.store.settings = merged
            controller.mergeUniverseEntries(backup.projects)
            controller.store.saveSettings()
            controller.outcome = ArchiveImportOutcome(
                isFull: true,
                books: backup.projects.map(\.importSummary),
                settingsHighlights: backup.settingsHighlights
            )
            controller.stage = nil
        }
    }

    /// 确认后的写盘与首次导入共用同一套完成/失败出口。
    private func runConfirmTask(
        _ work: @escaping @MainActor (ArchiveImportController) async throws -> Void
    ) {
        runTask?.cancel()
        runTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await work(self)
            } catch is CancellationError {
                self.reset()
            } catch {
                self.fail(error)
            }
            self.runTask = nil
        }
    }

    /// 弹窗被系统关掉时只清 pending，不关闭整个导入页。
    func clearPendingProjectImport() {
        pendingProjectImport = nil
    }

    func clearPendingFullRestore() {
        pendingFullRestore = nil
    }

    func dismiss() {
        reset()
    }

    // MARK: - 重活

    /// 读文件 + 解码。两段之间切一次进度文案。
    ///
    /// 文件可能在 iCloud 里还没下载，直接 `Data(contentsOf:)` 会卡几分钟且没有任何
    /// 反馈；这里先确保本地可用，再用 `NSFileCoordinator` 读，避免和 iCloud 同步打架。
    private func load(url: URL) async throws -> FrthinkArchive.AnyArchive {
        stage = .reading(size: 0)
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        try await ensureDownloaded(url)
        let data = try await Task.detached(priority: .userInitiated) {
            try ArchiveFileReader.read(url)
        }.value
        try Task.checkCancellation()
        stage = .reading(size: data.count)
        stage = .decoding
        return try await Task.detached(priority: .userInitiated) {
            try FrthinkArchive.openAny(data)
        }.value
    }

    /// iCloud 文件先请求下载并等它落地；本机文件直接返回。
    private func ensureDownloaded(_ url: URL) async throws {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isUbiquitousItem == true,
              values.ubiquitousItemDownloadingStatus != .current,
              values.ubiquitousItemDownloadingStatus != .downloaded
        else { return }

        stage = .downloading
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            let status = try? url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]
            ).ubiquitousItemDownloadingStatus
            if status == .current || status == .downloaded { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw FrthinkArchiveError.importUnreadable(
            "文件仍在从 iCloud 下载。请稍后重试，或先把文件下载到本机。"
        )
    }

    /// 逐本写盘。每本之间在主线程刷一次进度。
    ///
    /// 每本书先写进 UUID 暂存目录，全部写成功后才整体换进正式目录：
    /// - 写盘失败或取消不会把旧稿换成半个新项目；
    /// - 覆盖同名项目前先让旧会话停手（等当前写盘结束、暂停防抖保存），
    ///   写成功后立刻把内存会话换成新内容，旧会话不会再把旧稿写回去；
    /// - 取消时已经完整写进去的书保留，书架立即刷新。
    private func restore(_ backups: [FrthinkArchive.ProjectBackup]) async throws {
        guard !backups.isEmpty else {
            throw FrthinkArchiveError.emptyProjectArchive
        }
        let files = store.fileStore
        let ownerID = store.settings.ownerID
        // 成功、失败、取消都要刷新书架：已完整写入的书不能等下次启动才出现。
        defer { store.reload() }
        for (index, backup) in backups.enumerated() {
            try Task.checkCancellation()
            stage = .restoring(index: index, total: backups.count, title: backup.title)
            let existingSession = store.cachedSession(for: backup.projectId)
            await existingSession?.quiesceSaves()

            let restoredProject: Project?
            do {
                restoredProject = try await Task.detached(priority: .userInitiated) {
                    try FrthinkArchive.restore(
                        [backup],
                        into: files,
                        ownerID: ownerID
                    ).first
                }.value
            } catch {
                existingSession?.resumeSaving()
                throw error
            }

            if let project = restoredProject {
                // 磁盘已经是新稿：内存会话必须跟着换，否则它还显示旧稿，
                // 下一次编辑会把旧内容盖回导入结果。
                existingSession?.replaceLoadedState(project: project, fileStore: files)
            } else {
                existingSession?.resumeSaving()
            }
            // 取消发生在写盘中途时，这本书要么完整换上了（上一段已处理），
            // 要么根本没动；两种状态都不会留下半个项目。
            try Task.checkCancellation()
        }
        stage = .mergingSettings
        mergeUniverseEntries(backups)
        outcome = ArchiveImportOutcome(
            isFull: false,
            books: backups.map(\.importSummary),
            settingsHighlights: []
        )
        stage = nil
    }

    /// 存档里带的宇宙条目并进全局设置，已有条目不动。
    private func mergeUniverseEntries(_ backups: [FrthinkArchive.ProjectBackup]) {
        let imported = backups.flatMap(\.universeEntries)
        guard !imported.isEmpty else { return }
        let merged = FrthinkArchive.mergedUniverseEntries(
            imported,
            with: store.settings.universeEntries
        )
        guard merged.count != store.settings.universeEntries.count else { return }
        store.settings.universeEntries = merged
        store.saveSettings()
    }

    private func fail(_ error: Error) {
        if error is CancellationError {
            reset()
            return
        }
        stage = nil
        errorText = error.localizedDescription
        store.errorMessage = error.localizedDescription
    }

    private func reset() {
        stage = nil
        outcome = nil
        errorText = nil
        pendingProjectImport = nil
        pendingFullRestore = nil
    }
}

/// 读文件面板给的安全作用域 URL。
///
/// 走 `NSFileCoordinator`：文件提供方（iCloud、第三方网盘）靠它把「正在下载/正在
/// 写入」的状态协调给读取方，直接 `Data(contentsOf:)` 在这些文件上可能永久等待。
/// 不支持协调的提供方退回直接读取。
private enum ArchiveFileReader {
    private static let maxArchiveBytes = 200 * SecurityScopedFileReader.bytesPerMiB

    static func read(_ url: URL) throws -> Data {
        do {
            return try SecurityScopedFileReader.read(url, maxBytes: maxArchiveBytes) { _ in
                FrthinkArchiveError.importUnreadable("存档文件过大（超过 200 MB），无法导入")
            }
        } catch let error as FrthinkArchiveError {
            throw error
        } catch {
            throw FrthinkArchiveError.importUnreadable("无法读取文件：\(error.localizedDescription)")
        }
    }
}

// MARK: - 界面
