// 本文件负责：设置首页 —— 只做「分类导航」，具体功能都收进二级页。
//
// 一级一屏看完，六个分类各占一行；每行给一句当前状态，点进去才展开该分类。
// 缺 API Key 时首行本身变成提醒，不再额外插一条重复入口。

import SwiftUI

/// 设置二级分类。用值驱动导航，CI 截图可以通过启动参数直接落到某一页。
enum SettingsCategory: String, Hashable, CaseIterable {
    case connection
    case prompts
    case archive
    case storage
    case appearance
    case about
}

/// 供 CI 截图 / 深链使用的三级页。正常流程仍从二级页点进去。
enum SettingsEditorRoute: String, Hashable {
    case provider = "provider"
    case worldBuild = "worldbuild"
    case modelResponse = "modelresponse"
    case contextBudget = "contextbudget"

    var category: SettingsCategory {
        switch self {
        case .provider, .modelResponse, .contextBudget: return .connection
        case .worldBuild: return .prompts
        }
    }
}

struct SettingsView: View {
    private let store: AppStore

    /// 启动参数 `-settingsPage connection` 直接落到二级页；`-settingsEditor`
    /// 再往下到三级页。两者都只给 CI 截图用，正常启动没有。
    @State private var path = NavigationPath()
    @State private var previewProvider: ProviderSetting?

    init(store: AppStore) {
        self.store = store
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    NavigationLink(value: SettingsCategory.connection) {
                        connectionRow
                    }
                    NavigationLink(value: SettingsCategory.prompts) {
                        AppSettingsRow(
                            title: "提示词与资料",
                            symbol: "text.book.closed",
                            symbolTint: .purple,
                            symbolFilled: true,
                            detail: "\(store.settings.skills.count) 个技能"
                        )
                    }
                    NavigationLink(value: SettingsCategory.archive) {
                        AppSettingsRow(
                            title: "存档与备份",
                            symbol: "externaldrive",
                            symbolTint: .indigo,
                            symbolFilled: true,
                            detail: "\(store.projects.count) 本"
                        )
                    }
                    NavigationLink(value: SettingsCategory.storage) {
                        AppSettingsRow(
                            title: "存储与用量",
                            symbol: "chart.bar",
                            symbolTint: .orange,
                            symbolFilled: true
                        )
                    }
                    NavigationLink(value: SettingsCategory.appearance) {
                        AppSettingsRow(
                            title: "外观与交互",
                            symbol: "paintbrush",
                            symbolTint: .pink,
                            symbolFilled: true,
                            detail: store.settings.theme.displayName
                        )
                    }
                    NavigationLink(value: SettingsCategory.about) {
                        AppSettingsRow(
                            title: "关于",
                            symbol: "info.circle",
                            symbolTint: .green,
                            symbolFilled: true,
                            detail: Attribution.versionLine
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .settingsFormColumn()
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.large)
            .preferredColorScheme(store.settings.theme.colorScheme)
            .navigationDestination(for: SettingsCategory.self) { category in
                destination(for: category)
            }
            .navigationDestination(for: SettingsEditorRoute.self) { route in
                editorDestination(for: route)
            }
            .sheet(item: $previewProvider) { provider in
                ProviderEditorView(store: store, provider: provider) {
                    previewProvider = nil
                }
            }
        }
        .onAppear {
            // 首次进入就带参数：把二级/三级页推进去（只做一次）。
            guard path.isEmpty else { return }
            if let editor = SettingsView.launchEditor {
                path.append(editor.category)
                switch editor {
                case .provider:
                    previewProvider = store.settings.activeProvider
                        ?? store.settings.providers.first
                case .worldBuild, .modelResponse, .contextBudget:
                    path.append(editor)
                }
            } else if let launch = SettingsView.launchCategory {
                path.append(launch)
            }
        }
    }

    private var connectionRow: some View {
        HStack(spacing: Theme.Spacing.m) {
            IconTile(
                symbol: hasKey ? "point.3.connected.trianglepath.dotted" : "key.fill",
                tint: .blue,
                filled: true
            )

            Text("连接与模型")
                .font(Theme.label)
                .foregroundStyle(.primary)

            Spacer(minLength: Theme.Spacing.s)

            if hasKey {
                Text(activeModelShort)
                    .font(Theme.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            } else {
                StatusPill(text: "未配置", tone: .warning)
            }
        }
        .contentShape(Rectangle())
        .frame(minHeight: Theme.Layout.hitTarget)
    }

    private var hasKey: Bool {
        store.hasAnyAPIKey
    }

    private var activeModelShort: String {
        guard let provider = store.settings.activeProvider else { return "未选择" }
        let model = provider.resolvedModel
        return model.isEmpty ? provider.kind.displayName : model
    }

    @ViewBuilder
    private func destination(for category: SettingsCategory) -> some View {
        switch category {
        case .connection:
            SettingsConnectionPage(store: store)
        case .prompts:
            SettingsPromptPage(store: store)
        case .archive:
            SettingsArchivePage(store: store)
        case .storage:
            SettingsStoragePage(store: store)
        case .appearance:
            SettingsAppearancePage(store: store)
        case .about:
            SettingsAboutPage(store: store)
        }
    }

    @ViewBuilder
    private func editorDestination(for route: SettingsEditorRoute) -> some View {
        switch route {
        case .provider:
            // 正常流程用 sheet；走到这里说明是异常深链，退回连接页。
            SettingsConnectionPage(store: store)
        case .worldBuild:
            WorldBuildEditorPage(store: store)
        case .modelResponse:
            SettingsModelResponsePage(store: store)
        case .contextBudget:
            SettingsContextBudgetPage(store: store)
        }
    }

    private static var launchCategory: SettingsCategory? {
        LaunchArguments.settingsPage.flatMap(SettingsCategory.init(rawValue:))
    }

    private static var launchEditor: SettingsEditorRoute? {
        LaunchArguments.settingsEditor.flatMap {
            SettingsEditorRoute(rawValue: $0.lowercased())
        }
    }
}
