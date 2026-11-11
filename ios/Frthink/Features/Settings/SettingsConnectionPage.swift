// 本文件负责：设置二级页「连接与模型」—— 当前AI服务商、AI服务商列表、翻译模型、生成参数入口。
//
// 层级刻意压平：本页只做「看当前 / 选当前 / 进编辑」，具体参数都进三级页。
// 这样一屏最多一个主操作（测试连接），AI服务商再多也不会把页面撑成表单。

import SwiftUI
import UIKit

struct SettingsConnectionPage: View {
    let store: AppStore

    @State private var editingProvider: ProviderSetting?
    @State private var isTesting = false
    @State private var testMessage: String?
    @State private var testFailed = false
    /// 钥匙串缓存变化后顶一下刷新。
    @State private var keyRevision = 0

    var body: some View {
        List {
            currentSection
            providersSection
            translationSection
            summarySection
            advancedSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("连接与模型")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingProvider) { provider in
            ProviderEditorView(store: store, provider: provider) {
                keyRevision += 1
            }
        }
    }

    // MARK: - 当前使用

    private var currentSection: some View {
        Section {
            HStack(spacing: Theme.Spacing.m) {
                if let provider = store.settings.activeProvider {
                    ProviderIcon(
                        kind: provider.kind,
                        tint: hasActiveKey ? Theme.accent : .orange
                    )
                } else {
                    IconTile(
                        symbol: "bolt.horizontal.circle",
                        tint: .orange
                    )
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(activeProviderName)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Theme.Spacing.s)
                StatusPill(
                    text: hasActiveKey ? "可用" : "缺 Key",
                    tone: hasActiveKey ? .success : .warning
                )
            }

            Button {
                testActiveConnection()
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.horizontal")
                            .font(.footnote.weight(.semibold))
                    }
                    Text(isTesting ? "正在测试…" : "测试连接")
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 36)
            }
            .disabled(isTesting || store.settings.activeProvider == nil)

            if let testMessage {
                AppStatusLine(
                    kind: testFailed ? .failure : .success,
                    text: testMessage
                )
                .listRowSeparator(.hidden)
            }
        } header: {
            AppSectionHeader(title: "当前使用")
        }
    }

    // MARK: - AI服务商

    private var providersSection: some View {
        Section {
            ForEach(store.settings.providers) { provider in
                ConnectionProviderRow(
                    provider: provider,
                    isActive: isActive(provider),
                    onEdit: { editingProvider = provider },
                    onSetActive: { setActive(provider) }
                )
            }
        } header: {
            AppSectionHeader(title: "AI服务商")
        }
    }

    // MARK: - 翻译模型

    private var translationSection: some View {
        Section {
            NavigationLink {
                TranslationProviderPicker(store: store)
            } label: {
                AppSettingsRow(
                    title: "翻译模型",
                    symbol: "character.bubble",
                    detail: translationModelShortLabel
                )
            }
        } header: {
            AppSectionHeader(title: "翻译任务")
        }
    }

    // MARK: - 生成参数

    private var summarySection: some View {
        Section {
            NavigationLink {
                SettingsSummaryModelPage(store: store)
            } label: {
                AppSettingsRow(
                    title: "摘要模型",
                    symbol: "text.append",
                    detail: summaryModelShortLabel
                )
            }
        } header: {
            AppSectionHeader(title: "摘要任务")
        }
    }

    private var advancedSection: some View {
        Section {
            NavigationLink {
                SettingsModelResponsePage(store: store)
            } label: {
                AppSettingsRow(
                    title: "全局模型响应",
                    symbol: "dial.medium",
                    detail: String(format: "%.2f", store.settings.defaultTemperature)
                )
            }
            NavigationLink {
                SettingsContextBudgetPage(store: store)
            } label: {
                AppSettingsRow(
                    title: "长上下文预算",
                    symbol: "gauge.with.dots.needle.33percent",
                    detail: outputBudgetShortLabel
                )
            }
        } header: {
            AppSectionHeader(title: "生成参数")
        }
    }

    // MARK: - 小件

    @MainActor
    private func isActive(_ provider: ProviderSetting) -> Bool {
        store.settings.activeProviderID == provider.id
    }

    @MainActor
    private var hasActiveKey: Bool {
        _ = keyRevision
        guard let provider = store.settings.activeProvider else { return false }
        return !store.apiKey(for: provider.id).isEmpty
    }

    @MainActor
    private var activeProviderName: String {
        guard let provider = store.settings.activeProvider else { return "尚未选择AI服务商" }
        let model = provider.resolvedModel
        return "\(provider.kind.displayName) · \(model.isEmpty ? "未填写模型" : model)"
    }

    private var translationModelShortLabel: String {
        guard !store.settings.translationProviderID.isEmpty,
              let provider = store.settings.providers.first(where: {
                  $0.id == store.settings.translationProviderID
              })
        else { return "跟随当前" }
        return provider.model.isEmpty ? provider.kind.displayName : provider.model
    }

    private var summaryModelShortLabel: String {
        let model = store.settings.summaryModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return model.isEmpty ? "跟随当前" : model
    }

    private var outputBudgetShortLabel: String {        let value = store.settings.reservedOutputTokens
        guard value > 0 else { return "跟随模型" }
        if value >= 1_000 {
            return "输出 \(Int((Double(value) / 1_000).rounded()))K"
        }
        return "输出 \(value)"
    }

    // MARK: - 动作

    @MainActor
    private func setActive(_ provider: ProviderSetting) {
        store.settings.activeProviderID = provider.id
        store.saveSettings()
        store.toast = "当前AI服务商：\(provider.kind.displayName)"
    }

    @MainActor
    private func testActiveConnection() {
        guard !isTesting else { return }
        isTesting = true
        testMessage = nil
        testFailed = false
        Task { @MainActor in
            do {
                let client = try store.clientForActiveProvider()
                try await client.testConnection()
                testMessage = "连接成功，当前模型可用。"
                testFailed = false
            } catch {
                testMessage = error.localizedDescription
                testFailed = true
            }
            isTesting = false
        }
    }
}

/// 三级页：翻译任务用哪个AI服务商。
///
/// 只有「跟随当前」与各个具体AI服务商；选中即写入并返回，不再需要保存按钮。
struct TranslationProviderPicker: View {
    let store: AppStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                row(
                    title: "跟随当前AI服务商",
                    selected: store.settings.translationProviderID.isEmpty
                ) {
                    select("")
                }
            }

            Section("指定AI服务商") {
                ForEach(store.settings.providers) { provider in
                    row(
                        kind: provider.kind,
                        title: provider.model.isEmpty
                            ? provider.kind.displayName
                            : "\(provider.kind.displayName) · \(provider.model)",
                        selected: store.settings.translationProviderID == provider.id
                    ) {
                        select(provider.id)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("翻译模型")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(
        kind: ProviderKind? = nil,
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                if let kind {
                    ProviderIcon(kind: kind, size: 24)
                }
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: Theme.Spacing.s)

                if selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
            .frame(minHeight: 36)
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func select(_ providerID: String) {
        store.settings.translationProviderID = providerID
        store.saveSettings()
        dismiss()
    }
}

// MARK: - AI服务商行

/// AI服务商列表的一行：点按进编辑，左滑设为当前。
private struct ConnectionProviderRow: View {
    let provider: ProviderSetting
    let isActive: Bool
    let onEdit: () -> Void
    let onSetActive: () -> Void

    var body: some View {
        Button(action: onEdit) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                ProviderIcon(
                    kind: provider.kind,
                    tint: isActive ? Theme.accent : .secondary
                )
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(provider.kind.displayName)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        if isActive {
                            StatusPill(text: "当前")
                        }
                        if !provider.enabled {
                            StatusPill(text: "已停用")
                        }
                    }

                    Text(provider.model.isEmpty ? "未填写模型" : provider.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: Theme.Spacing.s)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, Theme.Spacing.xs)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            if !isActive {
                Button("设为当前") { onSetActive() }
                    .tint(Theme.accent)
            }
        }
        .contextMenu {
            Button("编辑") { onEdit() }
            if !isActive {
                Button("设为当前AI服务商") { onSetActive() }
            }
        }
    }

}
