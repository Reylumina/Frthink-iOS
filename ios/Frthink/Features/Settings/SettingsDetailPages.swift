// 设置二级页：存档与备份、存储与用量、外观及关于。

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 数据 → 存档与备份。
///
/// 导入与保存面板挂载在当前根视图，避免因文件选择器收起转场冲突导致后续弹窗被系统丢弃。
struct SettingsArchivePage: View {
    let store: AppStore

    @State private var isPickingImportFile = false
    @State private var activeImportKind: ArchiveImportKind = .project
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
                onPickFile: {
                    activeImportKind = .project
                    isPickingImportFile = true
                },
                onExportReady: { data, filename in
                    presentExport(data: data, filename: filename, toast: "书项目存档已导出")
                }
            )
            SettingsFullArchiveSection(
                store: store,
                onPickFile: {
                    activeImportKind = .full
                    isPickingImportFile = true
                },
                onExportReady: { data, filename in
                    presentExport(data: data, filename: filename, toast: "全量存档已导出")
                }
            )
        }
        .sheet(isPresented: $isPickingImportFile) {
            ArchiveDocumentPicker(allowedContentTypes: [.item]) { result in
                isPickingImportFile = false
                let kind = activeImportKind
                switch result {
                case .failure(let error):
                    guard !settingsIsUserCancelled(error) else { return }
                    store.errorMessage = "读取存档失败：\(error.localizedDescription)"
                case .success(let localURL):
                    // 让出 sheet 收起转场，再推入导入进度页读取本地沙盒副本。
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(200))
                        beginImport(kind, url: localURL)
                    }
                }
            }
            .ignoresSafeArea()
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .data,
            defaultFilename: exportFilename
        ) { result in
            handleExportResult(result)
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

/// 借助 UIKit `asCopy: true` 让系统直接拷贝所选文件到沙盒临时目录，规避 SwiftUI `.fileImporter` 的安全作用域权限失效与容器冲突。
private struct ArchiveDocumentPicker: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    let onComplete: (Result<URL, Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: allowedContentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: (Result<URL, Error>) -> Void

        init(onComplete: @escaping (Result<URL, Error>) -> Void) {
            self.onComplete = onComplete
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let sourceURL = urls.first else {
                onComplete(.failure(CocoaError(.userCancelled)))
                return
            }
            do {
                let stagedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("frthink-import-\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
                if FileManager.default.fileExists(atPath: stagedURL.path) {
                    try FileManager.default.removeItem(at: stagedURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
                onComplete(.success(stagedURL))
            } catch {
                onComplete(.failure(error))
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onComplete(.failure(CocoaError(.userCancelled)))
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
