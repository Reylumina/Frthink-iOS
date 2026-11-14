import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 书项目存档

/// 单本书的导出 / 导入。
///
/// 这一块只负责选文件；导入页和保存面板由 `SettingsArchivePage` 持有。
struct SettingsProjectArchiveSection: View {
    let store: AppStore
    let onPickFile: () -> Void
    let onExportReady: (Data, String) -> Void

    @State private var selectedProjectID: String?
    @State private var isPreparingExport = false

    var body: some View {
        Section {
            Picker("书项目", selection: $selectedProjectID) {
                ForEach(store.activeProjects) { project in
                    Text(project.title.isEmpty ? Project.untitledTitle : project.title)
                        .tag(Optional(project.id))
                }
            }
            .pickerStyle(.menu)

            Button {
                prepareExport()
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    if isPreparingExport {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.footnote.weight(.semibold))
                    }
                    Text(isPreparingExport ? "正在打包…" : "导出书项目")
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.Layout.controlHeight)
            }
            .disabled(store.activeProjects.isEmpty || isPreparingExport)

            Button {
                onPickFile()
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.footnote.weight(.semibold))
                    Text("导入书项目存档")
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.Layout.controlHeight)
            }
        } header: {
            AppSectionHeader(title: "书项目存档")
        }
        .task(id: store.activeProjects.count) {
            if selectedProjectID == nil {
                selectedProjectID = store.activeProjects.first?.id
            }
        }
    }

    private var selectedProject: Project? {
        store.activeProjects.first { $0.id == selectedProjectID }
            ?? store.activeProjects.first
    }

    @MainActor
    private func prepareExport() {
        guard let project = selectedProject else {
            store.errorMessage = "书架里还没有书项目"
            return
        }
        isPreparingExport = true
        // 先将挂起的编辑变更同步落盘，再从磁盘读取全文，避免阻塞主线程并确保获取最新改动。
        let session = store.cachedSession(for: project.id)
        let files = store.fileStore
        let universeEntries = store.settings.universeEntries
        Task { @MainActor in
            do {
                await session?.saveNowAndWait()
                let data = try await Task.detached(priority: .userInitiated) {
                    let backup = FrthinkArchive.ProjectBackup(
                        project: project,
                        payload: try files.loadVerifiedFullPayload(project.id),
                        sourceText: files.loadSource(project.id),
                        translations: files.loadTranslations(project.id),
                        universeEntries: universeEntries
                    )
                    return try FrthinkArchive.makeProjectArchive([backup])
                }.value
                onExportReady(data, FrthinkArchive.filename(kind: .project))
            } catch {
                store.errorMessage = error.localizedDescription
            }
            isPreparingExport = false
        }
    }

}

// MARK: - 全量存档

/// 全量存档 · .frthink：全部项目 + 设置（不含 API 信息）。
struct SettingsFullArchiveSection: View {
    let store: AppStore
    let onPickFile: () -> Void
    let onExportReady: (Data, String) -> Void

    @State private var isPreparingExport = false

    var body: some View {
        Section {
            AppValueRow(
                title: "项目",
                value: "\(store.projects.count) 个 · 回收站 \(store.trashedProjects.count) 个"
            )

            Button {
                prepareExport()
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    if isPreparingExport {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "archivebox")
                            .font(.footnote.weight(.semibold))
                    }
                    Text(isPreparingExport ? "正在打包…" : "导出全部书项目")
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.Layout.controlHeight)
            }
            .disabled(store.projects.isEmpty || isPreparingExport)

            Button {
                onPickFile()
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.footnote.weight(.semibold))
                    Text("导入全量存档")
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Theme.Layout.controlHeight)
            }
        } header: {
            AppSectionHeader(title: "全部项目")
        }
    }

    @MainActor
    private func prepareExport() {
        guard !store.projects.isEmpty else {
            store.errorMessage = "书架里还没有书项目"
            return
        }
        isPreparingExport = true
        let projects = store.projects
        // 全量导出采用流式读取已落盘文件，避免全量项目驻留内存，确保导出数据的一致性。
        let sessions = projects.compactMap { store.cachedSession(for: $0.id) }
        let files = store.fileStore
        let settings = store.settings
        let universeEntries = store.settings.universeEntries
        Task { @MainActor in
            do {
                for session in sessions {
                    await session.saveNowAndWait()
                }
                let data = try await Task.detached(priority: .userInitiated) {
                    let backups = try projects.map { project in
                        FrthinkArchive.ProjectBackup(
                            project: project,
                            payload: try files.loadVerifiedFullPayload(project.id),
                            sourceText: files.loadSource(project.id),
                            translations: files.loadTranslations(project.id),
                            universeEntries: universeEntries
                        )
                    }
                    return try FrthinkArchive.makeFullArchive(
                        settings: settings,
                        projects: backups
                    )
                }.value
                onExportReady(data, FrthinkArchive.filename(kind: .full))
            } catch {
                store.errorMessage = error.localizedDescription
            }
            isPreparingExport = false
        }
    }

}
