// 本文件负责：设置二级页 —— 存档与备份、存储与用量、外观、关于。

import SwiftUI
import UniformTypeIdentifiers

/// 数据 → 存档与备份。
///
/// 导入页与保存面板都挂在这一页，而不是挂在按钮所在的行上：文件面板收起时，
/// 同一视图上立刻再弹一个页面会被系统丢掉，用户看到的就是「选完文件没反应」。
struct SettingsArchivePage: View {
    let store: AppStore

    @State private var pendingImport: ArchiveImportRequest?
    @State private var importer: ArchiveImportController?
    @State private var exportDocument: ArchiveFileDocument?
    @State private var exportFilename = "frthink书项目.frthink"
    @State private var exportToast = ""
    @State private var isExporting = false

    var body: some View {
        Form {
            SettingsProjectArchiveSection(
                store: store,
                onImportPicked: { url in beginImport(.project, url: url) },
                onExportReady: { data, filename in
                    presentExport(data: data, filename: filename, toast: "书项目存档已导出")
                }
            )
            SettingsFullArchiveSection(
                store: store,
                onImportPicked: { url in beginImport(.full, url: url) },
                onExportReady: { data, filename in
                    presentExport(data: data, filename: filename, toast: "全量存档已导出")
                }
            )
        }
        .navigationTitle("存档与备份")
        .navigationBarTitleDisplayMode(.inline)
        .settingsFormColumn()
        .navigationDestination(item: $pendingImport) { request in
            if let importer {
                ArchiveImportFlowView(controller: importer)
                    .task(id: request.id) {
                        importer.begin(request)
                    }
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .data,
            defaultFilename: exportFilename
        ) { result in
            handleExportResult(result)
        }
    }

    @MainActor
    private func beginImport(_ kind: ArchiveImportKind, url: URL) {
        importer = ArchiveImportController(store: store)
        pendingImport = ArchiveImportRequest(kind: kind, url: url)
    }

    @MainActor
    private func presentExport(data: Data, filename: String, toast: String) {
        exportDocument = ArchiveFileDocument(data: data)
        exportFilename = filename
        exportToast = toast
        isExporting = true
    }

    @MainActor
    private func handleExportResult(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            store.toast = exportToast
        case .failure(let error):
            guard !settingsIsUserCancelled(error) else { return }
            store.errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }
}

/// 数据 → 存储与用量。
struct SettingsStoragePage: View {
    let store: AppStore

    var body: some View {
        Form {
            SettingsStorageSection(store: store)
            SettingsTokenUsageSection(store: store)
            SettingsTokenResetSection(store: store)
        }
        .navigationTitle("存储与用量")
        .navigationBarTitleDisplayMode(.inline)
        .settingsFormColumn()
    }
}

/// 外观与交互 → 外观。
struct SettingsAppearancePage: View {
    let store: AppStore

    var body: some View {
        Form {
            SettingsAppearanceSection(store: store)
            SettingsAnimationSection(store: store)
            SettingsHapticsSection(store: store)
        }
        .navigationTitle("外观")
        .navigationBarTitleDisplayMode(.inline)
        .settingsFormColumn()
    }
}

/// 外观与交互 → 关于。
struct SettingsAboutPage: View {
    let store: AppStore

    @State private var selfTestReport: String?

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    Text(Attribution.versionLine)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(Attribution.creditLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(Attribution.portNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Spacing.m)
            }

            #if DEBUG
            Section {
                DisclosureGroup("开发者自检") {
                    Text(selfTestReport ?? "尚未运行")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, Theme.Spacing.xs)
                }
            }
            #endif
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .settingsFormColumn()
        .task {
            #if DEBUG
            selfTestReport = FrthinkArchiveSelfTest.run()
            #endif
        }
    }
}
