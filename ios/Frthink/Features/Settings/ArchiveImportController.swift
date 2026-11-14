// 本文件负责：存档导入的状态机 —— 读文件、解码、写入、覆盖确认。
//
// 读文件、解压、解码与写盘均放在 Task.detached 中执行，避免大备份阻塞主线程；
// 主线程只更新进度和结果。
//
// 流程页由「存档与备份」页推进导航栈，不用 fullScreenCover：文件选取器收起与
// 自定义弹窗转场并发时，后者可能被系统丢弃导致无响应。

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

/// 导入进度：提供可直接展示的进度文本。
enum ArchiveImportStage: Equatable {
    /// `size` 为 0 表示尚未获取到文件大小。
    case reading(size: Int)
    /// 文件在 iCloud 中尚未下载至本地；直接读取可能导致主线程长时间阻塞。
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

    /// 导入前书架中已有项目 ID 集合，用于判断本次操作属于新增还是覆盖。
    private var existingIDs: Set<String> = []
    /// 当前磁盘读写任务；用户退出导入页面时取消，防止后台继续写入。
    private var runTask: Task<Void, Never>?

    init(store: AppStore) {
        self.store = store
    }

    /// 统一承载导入流程中的确认弹窗与结果展示，避免层叠弹出多个模态层。
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

    /// 单书项目导入入口：导入全量备份时亦仅还原书籍项目，保留本地设置。
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

    /// 全量存档导入入口：解析后提示二次确认，确认后写入磁盘并合并设置项。
    func beginFullImport(from url: URL) {
        start { controller in
            let archive = try await controller.load(url: url)
            switch archive {
            case .full(let backup):
                controller.stage = nil
                controller.pendingFullRestore = backup
            case .projects(let payload):
                // 仅包含书项目而无设置项时：按单项目导入逻辑处理，保留本地既有设置。
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

    /// 用户退出导入页：终止当前读写任务，已完整落盘的项目予以保留，确保原子性。
    func cancel() {
        runTask?.cancel()
        runTask = nil
        reset()
    }

    /// 统一的异步任务封装：主线程更新进度、后台读取磁盘，发生异常时跳转至错误页。
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
    /// 针对 iCloud 未下载文件，先确保本地可用再通过 `NSFileCoordinator` 读取，
    /// 防止直接读取导致界面挂起或与同步进程冲突。
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
            try await Task.sleep(for: .milliseconds(250))
        }
        throw FrthinkArchiveError.importUnreadable(
            "文件仍在从 iCloud 下载。请稍后重试，或先把文件下载到本机。"
        )
    }

    /// 逐本写入磁盘，每本完成后在主线程刷新进度。
    ///
    /// 采用暂存目录原子写入机制：
    /// - 写入失败或取消时不会损坏原有项目；
    /// - 覆盖同名项目前暂停旧会话保存逻辑，写入成功后同步刷新内存会话；
    /// - 取消操作时已完整落盘的项目予以保留并刷新书架。
    private func restore(_ backups: [FrthinkArchive.ProjectBackup]) async throws {
        guard !backups.isEmpty else {
            throw FrthinkArchiveError.emptyProjectArchive
        }
        let files = store.fileStore
        let ownerID = store.settings.ownerID
        // 流程结束（成功/失败/取消）均触发书架刷新，确保已写入数据即时可见。
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
                // 磁盘已写入新数据：需同步更新内存会话，防止后续编辑将旧数据回写。
                existingSession?.replaceLoadedState(project: project, fileStore: files)
            } else {
                existingSession?.resumeSaving()
            }
            // 写入中途取消时，确保当前项目状态处于已完全替换或未改动状态，避免产生不完整数据。
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
/// 使用 `NSFileCoordinator` 协调文件读取，避免直接读取云盘或外部提供方文件时发生死锁或无响应；
/// 不支持协调的提供方降级为直接读取。
private enum ArchiveFileReader {
    private static let maxArchiveBytes = FrthinkArchive.maxBytes

    static func read(_ url: URL) throws -> Data {
        do {
            return try SecurityScopedFileReader.read(url, maxBytes: maxArchiveBytes) { _ in
                FrthinkArchiveError.importUnreadable("存档文件过大（超过 300 MB），无法导入")
            }
        } catch let error as FrthinkArchiveError {
            throw error
        } catch {
            throw FrthinkArchiveError.importUnreadable("无法读取文件：\(error.localizedDescription)")
        }
    }
}

// MARK: - 界面
