// 本文件负责：长期规则摘要的查看、全文编辑与恢复上一版。
// 自动摘要的触发与请求在 `WorldRulesWorkflow`，这里只处理展示与手改。

import Foundation
import SwiftUI

// MARK: - 长期规则

/// 三级页：当前书的长期规则摘要。默认只读，可进编辑页手改或恢复上一版。
struct SettingsLongTermRulesPage: View {
    let store: AppStore

    @State private var selectedProjectID: String?
    @State private var session: ProjectSession?
    @State private var rules = ""
    @State private var updatedAt: Int64 = 0
    @State private var revisionCount = 0
    @State private var pendingRestore = false
    @State private var reloadGeneration = 0

    var body: some View {
        Form {
            Section {
                Picker("当前书", selection: $selectedProjectID) {
                    ForEach(store.activeProjects) { project in
                        Text(project.title.isEmpty ? Project.untitledTitle : project.title)
                            .tag(Optional(project.id))
                    }
                }
                .pickerStyle(.menu)

                if rules.isEmpty {
                    InlineEmptyState(
                        symbol: "doc.plaintext",
                        message: "还没有长期规则"
                    )
                } else {
                    Text(rules)
                        .font(Theme.reply)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                NavigationLink {
                    LongTermRulesEditorPage(initialText: rules) { text in
                        Task { await save(text) }
                    }
                } label: {
                    Label("编辑摘要", systemImage: "square.and.pencil")
                }
                .disabled(selectedProject == nil)

                if updatedAt > 0 {
                    AppValueRow(title: "上次更新", value: updatedText)
                }
            } header: {
                AppSectionHeader(title: "当前摘要")
            }

            Section {
                DestructiveActionRow(
                    title: "恢复上一版",
                    systemImage: "arrow.uturn.backward",
                    isEnabled: revisionCount > 0
                ) {
                    pendingRestore = true
                }
            }
        }
        .settingsFormColumn()
        .navigationTitle("长期规则摘要")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.activeProjects.count) {
            if selectedProjectID == nil {
                selectedProjectID = store.activeProjects.first?.id
            }
            await reloadRules()
        }
        .onChange(of: selectedProjectID) { oldValue, newValue in
            guard oldValue != nil, oldValue != newValue else { return }
            Task { await reloadRules() }
        }
        .confirmationDialog(
            "恢复上一版摘要？",
            isPresented: $pendingRestore,
            titleVisibility: .visible
        ) {
            Button("恢复", role: .destructive) {
                Task { await restore() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var selectedProject: Project? {
        store.activeProjects.first { $0.id == selectedProjectID }
            ?? store.activeProjects.first
    }

    private var updatedText: String {
        let date = Date(timeIntervalSince1970: TimeInterval(updatedAt) / 1000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// 走会话读，刚改完还在防抖窗口里时也能看到最新内容。
    @MainActor
    private func reloadRules() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        guard let project = selectedProject else {
            session = nil
            rules = ""
            updatedAt = 0
            revisionCount = 0
            return
        }
        let loaded = await store.openSessionAsync(for: project)
        guard generation == reloadGeneration else { return }
        session = loaded
        let world = loaded.payload.world
        rules = world.longTermRules.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedAt = world.summaryUpdatedAt
        revisionCount = world.summaryPreviousRevisions.count
    }

    @MainActor
    private func sessionForCurrentProject() async -> ProjectSession? {
        guard let project = selectedProject else { return nil }
        if let session, session.project.id == project.id { return session }
        let loaded = await store.openSessionAsync(for: project)
        session = loaded
        return loaded
    }

    @MainActor
    private func save(_ text: String) async {
        guard let session = await sessionForCurrentProject() else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let changed = session.payload.world.applySummaryUpdate(
            content: text,
            newKeys: [],
            now: now
        )
        if changed {
            session.scheduleSave()
            store.toast = "摘要已保存"
        } else {
            store.toast = "摘要没有变化"
        }
        await reloadRules()
    }

    @MainActor
    private func restore() async {
        guard let session = await sessionForCurrentProject() else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        guard session.payload.world.restorePreviousSummary(now: now) else {
            store.toast = "没有可恢复的历史版本"
            return
        }
        session.scheduleSave()
        store.toast = "已恢复上一个摘要版本"
        await reloadRules()
    }
}

/// 长期规则全文编辑。长文不用 sheet；保存后由上一页写回摘要元数据。
struct LongTermRulesEditorPage: View {
    let initialText: String
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saved = false

    init(initialText: String, onSave: @escaping (String) -> Void) {
        self.initialText = initialText
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        AppTextEditor(text: $text, placeholder: "长期规则", minHeight: 240, expands: true)
            .padding(Theme.Spacing.l)
            .pageBackground()
            .navigationTitle("编辑摘要")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton(title: "保存") {
                        onSave(trimmedText)
                        saved = true
                        dismiss()
                    }
                }
            }
            .onDisappear {
                // 只有「保存」没有「取消」：左滑返回时自动存下改动（包括清空）。
                guard !saved, trimmedText != initialText else { return }
                onSave(trimmedText)
            }
    }
}
