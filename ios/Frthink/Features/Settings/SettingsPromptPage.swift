// 本文件负责：设置二级页「提示词与资料」，以及三级页「世界建立要求」。
//
// 二级页只做入口与开关；长文编辑进三级页，避免把整段提示词塞在设置列表里。

import SwiftUI
import UIKit

struct SettingsPromptPage: View {
    let store: AppStore

    var body: some View {
        Form {
            promptIntegrationSection
            writingBehaviorSection
            worldBuildSection
            conversationSummarySection
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
                    title: "技能与预设",
                    detail: "\(store.settings.skills.count) 个技能"
                )
            }

            NavigationLink {
                CorpusPane(store: store) { entry in
                    // 设置页只是管理入口，没有「拿去写作」的落点；
                    // 点取用就把原句放进剪贴板，比一个空动作清楚。
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
            AppSectionHeader(title: "提示词集成")
        }
    }

    private var writingBehaviorSection: some View {
        Section {
            Toggle("启用语料收集库", isOn: settingsBinding(store, \.corpusEnabled))
            Toggle("默认流式输出", isOn: settingsBinding(store, \.streamByDefault))
        } header: {
            AppSectionHeader(title: "写作行为")
        }
    }

    private var worldBuildSection: some View {
        Section {
            NavigationLink {
                WorldBuildEditorPage(store: store)
            } label: {
                SettingsLabelRow(
                    title: "世界建立要求",
                    detail: worldBuildDetail
                )
            }
        } header: {
            AppSectionHeader(title: "世界建立")
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
            NavigationLink {
                SettingsLongTermRulesPage(store: store)
            } label: {
                SettingsLabelRow(title: "长期规则摘要")
            }
        } header: {
            AppSectionHeader(title: "对话总结")
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

    private var worldBuildDetail: String {
        store.settings.worldBuildInstruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty ? "出厂值" : "自定义"
    }
}

/// 三级页：世界建立要求（P18）正文。
///
/// 每 600ms 合并落盘一次，离开页面强制保存，避免逐字重写整份 settings.json。
struct WorldBuildEditorPage: View {
    let store: AppStore

    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var saveTask: Task<Void, Never>?
    @State private var showingDefault = false
    @State private var confirmingReset = false

    init(store: AppStore) {
        self.store = store
        _text = State(initialValue: store.settings.worldBuildInstruction)
    }

    var body: some View {
        AppTextEditor(
            text: $text,
            placeholder: "世界建立时的额外要求",
            minHeight: 240,
            expands: true
        )
        .padding(Theme.Spacing.l)
        .pageBackground()
        .navigationTitle("世界建立要求")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("查看出厂要求") { showingDefault = true }
                    Button("恢复出厂值", role: .destructive) { confirmingReset = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多操作")
                SheetConfirmButton(title: "完成") { close() }
            }
        }
        .onChange(of: text) { _, _ in
            scheduleSave()
        }
        .onDisappear { flush() }
        .sheet(isPresented: $showingDefault) {
            WorldBuildDefaultSheet(text: PromptLibrary.worldBuildInstructionDefault)
        }
        .confirmationDialog(
            "恢复出厂值？",
            isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("恢复出厂值", role: .destructive) { resetToDefault() }
            Button("取消", role: .cancel) {}
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    private func close() {
        flush()
        dismiss()
    }

    private func flush() {
        saveTask?.cancel()
        saveTask = nil
        commit()
    }

    @MainActor
    private func commit() {
        guard store.settings.worldBuildInstruction != text else { return }
        store.settings.worldBuildInstruction = text
        store.saveSettings()
    }

    @MainActor
    private func resetToDefault() {
        text = ""
        store.settings.worldBuildInstruction = ""
        store.saveSettings()
        store.toast = "已恢复出厂值"
    }
}

/// 只读出厂要求，避免在编辑框里放一整段长占位文字。
struct WorldBuildDefaultSheet: View {
    let text: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(Theme.reply)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.l)
            }
            .pageBackground()
            .navigationTitle("出厂要求")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SheetCloseButton(title: "完成") { dismiss() }
                }
            }
        }
    }
}
