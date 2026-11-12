import Foundation
import SwiftUI

/// 软件占用：`Application Support/Frthink` 的目录大小与项目数。
///
/// 只走文件元数据（不读正文内容），所以能在设置页出现时直接算。
struct SettingsStorageSection: View {
    let store: AppStore

    @State private var bytes: Int64 = 0
    @State private var measured = false

    var body: some View {
        Section {
            AppValueRow(
                title: "目录占用",
                value: measured ? settingsByteText(bytes) : "计算中…"
            )
            AppValueRow(
                title: "书项目",
                value: "\(store.projects.count) 本 · 回收站 \(store.trashedProjects.count) 本"
            )

            Button {
                measure()
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "arrow.clockwise")
                    Text("重新计算")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(minHeight: Theme.Layout.hitTarget)
            }
            .disabled(!measured && bytes == 0)
        } header: {
            AppSectionHeader(title: "软件占用")
        }
        .task { measure() }
    }

    @MainActor
    private func measure() {
        measured = false
        let root = store.fileStore.root
        Task { @MainActor in
            let total = await Task.detached(priority: .utility) {
                SettingsStorageSection.directoryBytes(root)
            }.value
            bytes = total
            measured = true
        }
    }

    static func directoryBytes(_ root: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey,
        ]
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: nil
            )
        else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }
}

/// 全局 Token 消耗：累计估算 + 现存正文的估算量。
struct SettingsTokenUsageSection: View {
    let store: AppStore

    @State private var contentTokens = 0
    @State private var measured = false

    var body: some View {
        Section {
            AppValueRow(
                title: "累计消耗",
                value: settingsTokenText(store.settings.tokenUsageTotal)
            )
            AppValueRow(
                title: "现存正文估算",
                value: measured ? settingsTokenText(contentTokens) : "计算中…"
            )

            Button {
                measureContent()
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "arrow.clockwise")
                    Text("重新统计正文")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(minHeight: Theme.Layout.hitTarget)
            }
        } header: {
            AppSectionHeader(title: "Token 用量")
        }
        .task { measureContent() }
    }

    @MainActor
    private func measureContent() {
        measured = false
        let projects = store.activeProjects
        let files = store.fileStore
        Task { @MainActor in
            let total = await Task.detached(priority: .utility) {
                projects.reduce(0) { partial, project in
                    partial + TokenEstimator.estimate(files.loadPayload(project.id).manuscript)
                }
            }.value
            contentTokens = total
            measured = true
        }
    }
}

/// 清零累计用量：独立一节，和统计数字分开。
struct SettingsTokenResetSection: View {
    let store: AppStore

    @State private var confirmingReset = false

    var body: some View {
        Section {
            DestructiveActionRow(
                title: "清零累计用量",
                systemImage: "arrow.counterclockwise",
                isEnabled: store.settings.tokenUsageTotal > 0
            ) {
                confirmingReset = true
            }
        }
        .confirmationDialog(
            "清零累计 Token 用量？",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("清零", role: .destructive) {
                store.settings.tokenUsageTotal = 0
                store.saveSettings()
                store.toast = "累计用量已清零"
            }
            Button("取消", role: .cancel) {}
        }
    }
}
