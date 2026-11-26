// 设置二级页「提示词与资料」。
//
// 承载全局写作基准、写作行为开关与长文本模板导航入口。

import SwiftUI
import UIKit

struct SettingsPromptPage: View {
    let store: AppStore

    var body: some View {
        Form {
            promptIntegrationSection
            writingBehaviorSection
            conversationSummarySection
            advancedTemplatesSection
        }
        .settingsFormColumn()
        .navigationTitle("提示词与资料")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 分组

    private var promptIntegrationSection: some View {
        Section {
            NavigationLink {
                PromptManagerPane(store: store)
            } label: {
                SettingsLabelRow(
                    title: "全局预设与技能",
                    detail: "\(store.settings.skills.count) 个技能"
                )
            }

            NavigationLink {
                CorpusPane(store: store) { entry in
                    // 设置页为配置管理入口，取用操作将原句直接写入剪贴板。
                    UIPasteboard.general.string = entry.text
                    store.toast = "已复制原句"
                }
            } label: {
                SettingsLabelRow(
                    title: "语料收集库",
                    detail: "\(store.settings.corpusLibraries.count) 个库"
                )
            }
        } header: {
            AppSectionHeader(title: "全局写作基准")
        }
    }

    private var writingBehaviorSection: some View {
        Section {
            Toggle("启用语料收集库", isOn: settingsBinding(store, \.corpusEnabled))
            Toggle("默认流式输出", isOn: settingsBinding(store, \.streamByDefault))
            Toggle("采纳正文后自动更新世界与伏笔", isOn: settingsBinding(store, \.sleepTimeStateSync))
            Toggle("换场时自动收起前场上下文", isOn: settingsBinding(store, \.autoSceneContextPruning))
            Picker("历史思维链回灌", selection: settingsBinding(store, \.reasoningContextPolicy)) {
                ForEach(ReasoningContextPolicy.allCases) { policy in
                    Text(policy.displayName).tag(policy)
                }
            }
            .pickerStyle(.menu)
        } header: {
            AppSectionHeader(title: "写作行为")
        }
    }

    private var conversationSummarySection: some View {
        Section {
            Toggle(
                "自动总结",
                isOn: settingsBinding(store, \.autoConversationSummary)
            )
            if store.settings.autoConversationSummary {
                Picker("触发阈值", selection: summaryThresholdBinding) {
                    Text("80%").tag(80)
                    Text("90%").tag(90)
                    Text("95%").tag(95)
                }
                .pickerStyle(.menu)
            }
        } header: {
            AppSectionHeader(title: "对话总结")
        }
    }

    private var advancedTemplatesSection: some View {
        Section {
            NavigationLink {
                SettingsLongTermRulesPage(store: store)
            } label: {
                SettingsLabelRow(title: "长期规则摘要")
            }
        } header: {
            AppSectionHeader(title: "高级任务模板")
        }
    }

    private var summaryThresholdBinding: Binding<Int> {
        Binding(
            get: { store.settings.conversationSummaryThresholdPercent },
            set: {
                store.settings.conversationSummaryThresholdPercent = $0
                store.saveSettings()
            }
        )
    }
}
