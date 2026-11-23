// 写作规则管理页与复用区块：浏览生效/已停用规则，通过「+」弹窗新增规则，左滑停用。

import Foundation
import SwiftUI

struct AuthorDirectivesView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession

    @State private var showingAddSheet = false

    var body: some View {
        List {
            AuthorDirectivesListContent(
                session: session,
                showingAddSheet: $showingAddSheet
            )
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle("写作规则")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加写作规则")
            }
        }
        .sheet(isPresented: $showingAddSheet) {
            AddAuthorDirectiveSheet(session: session)
        }
        .task {
            _ = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
        }
    }
}

/// 写作规则列表区块：供独立写作规则页与「世界 → 规则」工作台共用。
struct AuthorDirectivesListContent: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession
    @Binding var showingAddSheet: Bool

    @State private var showSuperseded = false
    @State private var pendingSupersede: AuthorDirective?
    @State private var errorMessage: String?

    private var liveState: MaterializedNarrativeState? {
        _ = session.narrativeRevision
        return session.narrativeWorkspace?.currentState()
    }

    private var activeDirectives: [AuthorDirective] {
        guard let liveState else { return [] }
        return liveState.directiveLedger.directives
            .filter { $0.status == .active }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var supersededDirectives: [AuthorDirective] {
        guard let liveState else { return [] }
        return liveState.directiveLedger.directives
            .filter { $0.status == .superseded }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        Group {
            activeSection
            if !supersededDirectives.isEmpty {
                supersededSection
            }
        }
        .task {
            _ = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
        }
        .narrativeErrorAlert($errorMessage)
        .deleteConfirmationDialog(
            { "停用规则「\(String($0.verbatimRule.prefix(20)))」？" },
            item: $pendingSupersede,
            actionTitle: "停用"
        ) { target in
            supersedeDirective(target)
        }
    }

    private var activeSection: some View {
        Section {
            if activeDirectives.isEmpty {
                InlineEmptyState(
                    symbol: "shield.lefthalf.filled",
                    message: "暂无生效中的写作规则。",
                    actionTitle: "添加写作规则",
                    action: { showingAddSheet = true }
                )
            } else {
                ForEach(activeDirectives) { directive in
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text(directive.verbatimRule)
                            .font(Theme.label)
                            .foregroundStyle(.primary)

                        StatusPill(text: scopeLabel(for: directive.scope), tone: .accent)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("停用", role: .destructive) {
                            pendingSupersede = directive
                        }
                    }
                }
            }
        } header: {
            AppSectionHeader(title: "生效中的写作规则（\(activeDirectives.count)）")
        }
    }

    private var supersededSection: some View {
        Section {
            DisclosureGroup("已停用（\(supersededDirectives.count)）", isExpanded: $showSuperseded) {
                ForEach(supersededDirectives) { directive in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(directive.verbatimRule)
                            .font(Theme.labelSmall)
                            .foregroundStyle(.secondary)
                            .strikethrough()
                        StatusPill(
                            text: "已停用 · \(scopeLabel(for: directive.scope))",
                            tone: .neutral
                        )
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        }
    }

    private func supersedeDirective(_ directive: AuthorDirective) {
        let delta = PlotNodeDelta(
            directiveSupersedes: [DirectiveSupersede(targetID: directive.id)]
        )
        do {
            _ = try session.commitNarrativeDelta(
                delta,
                summary: "停用写作规则",
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            store.toast = "已停用该规则"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scopeLabel(for scope: DirectiveScope) -> String {
        switch scope {
        case .global:
            return "全书"
        case .volume(let id):
            return "卷：\(id)"
        case .branch(let id):
            return "分支：\(id)"
        case .entity(let id):
            let name = liveState?.entityPages[id]?.name ?? id
            return name
        }
    }
}

/// 新增写作规则弹窗：收拢输入与生效范围选择，避免常驻表单挤压主列表。
struct AddAuthorDirectiveSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: ProjectSession

    @State private var ruleDraft = ""
    @State private var scopeKind: ScopeKind = .global
    @State private var selectedEntityID = ""
    @State private var errorMessage: String?

    private enum ScopeKind: String, CaseIterable, Identifiable {
        case global = "全书"
        case branch = "当前分支"
        case entity = "指定设定"

        var id: String { rawValue }
    }

    private var liveState: MaterializedNarrativeState? {
        _ = session.narrativeRevision
        return session.narrativeWorkspace?.currentState()
    }

    private var entityOptions: [EntityPage] {
        (liveState?.entityPages.values.sorted { $0.name < $1.name }) ?? []
    }

    private var availableScopeKinds: [ScopeKind] {
        entityOptions.isEmpty ? [.global, .branch] : ScopeKind.allCases
    }

    private var currentBranchLabel: String {
        guard let workspace = session.narrativeWorkspace else { return "主线" }
        let label = workspace.storyGraph.nodes[workspace.storyGraph.headNodeID]?.branchLabel ?? "主线"
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "主线" : trimmed
    }

    private var trimmedRule: String {
        ruleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("输入需要遵守的写作规则…", text: $ruleDraft, axis: .vertical)
                        .font(Theme.label)
                        .lineLimit(3...8)
                } header: {
                    AppSectionHeader(title: "规则正文")
                }

                Section {
                    Picker("生效范围", selection: $scopeKind) {
                        ForEach(availableScopeKinds) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    if scopeKind == .branch {
                        AppValueRow(title: "绑定分支", value: currentBranchLabel)
                    } else if scopeKind == .entity, !entityOptions.isEmpty {
                        Picker("关联设定", selection: $selectedEntityID) {
                            ForEach(entityOptions) { page in
                                Text(page.name).tag(page.id)
                            }
                        }
                    }
                } header: {
                    AppSectionHeader(title: "生效范围")
                }
            }
            .scrollContentBackground(.hidden)
            .groupedPageBackground()
            .navigationTitle("添加写作规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton(title: "取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton(title: "添加", isEnabled: !trimmedRule.isEmpty) {
                        saveDirective()
                    }
                }
            }
            .task {
                _ = session.ensureNarrativeWorkspace(
                    settingsCorpusLibraries: store.settings.corpusLibraries
                )
                if selectedEntityID.isEmpty, let first = entityOptions.first {
                    selectedEntityID = first.id
                }
            }
            .narrativeErrorAlert($errorMessage)
        }
    }

    private func saveDirective() {
        guard !trimmedRule.isEmpty else { return }
        let scope: DirectiveScope
        switch scopeKind {
        case .global:
            scope = .global
        case .branch:
            scope = .branch(id: currentBranchLabel)
        case .entity:
            scope = selectedEntityID.isEmpty ? .global : .entity(id: selectedEntityID)
        }

        let directive = AuthorDirective(verbatimRule: trimmedRule, scope: scope)
        do {
            _ = try session.commitNarrativeDelta(
                PlotNodeDelta(directiveAdds: [directive]),
                summary: "新增写作规则",
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            store.toast = "已添加写作规则"
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
