// 写作规则管理页与复用区块：缓存规则快照、扁平化列表行与弹窗，消除按键重排。

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

    @State private var activeDirectives: [AuthorDirective] = []
    @State private var supersededDirectives: [AuthorDirective] = []
    @State private var entityNames: [String: String] = [:]
    @State private var showSuperseded = false
    @State private var pendingSupersede: AuthorDirective?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            activeSection
            if !supersededDirectives.isEmpty {
                supersededSection
            }
        }
        .task(id: session.narrativeRevision) {
            _ = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            reloadSnapshot()
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
                    ActiveDirectiveRow(
                        directive: directive,
                        scopeLabel: scopeLabel(for: directive.scope),
                        onSupersede: { pendingSupersede = directive }
                    )
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
                    SupersededDirectiveRow(
                        directive: directive,
                        scopeLabel: scopeLabel(for: directive.scope)
                    )
                }
            }
        }
    }

    private func reloadSnapshot() {
        guard let state = session.narrativeWorkspace?.currentState() else {
            activeDirectives = []
            supersededDirectives = []
            entityNames = [:]
            return
        }
        entityNames = state.entityPages.mapValues(\.name)
        var active: [AuthorDirective] = []
        var superseded: [AuthorDirective] = []
        for item in state.directiveLedger.directives {
            switch item.status {
            case .active:
                active.append(item)
            case .superseded:
                superseded.append(item)
            }
        }
        activeDirectives = active.sorted { $0.createdAt > $1.createdAt }
        supersededDirectives = superseded.sorted { $0.updatedAt > $1.updatedAt }
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
            return entityNames[id] ?? id
        }
    }
}

private struct ActiveDirectiveRow: View {
    let directive: AuthorDirective
    let scopeLabel: String
    let onSupersede: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(directive.verbatimRule)
                .font(Theme.label)
                .foregroundStyle(.primary)

            StatusPill(text: scopeLabel, tone: .accent)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("停用", role: .destructive, action: onSupersede)
        }
    }
}

private struct SupersededDirectiveRow: View {
    let directive: AuthorDirective
    let scopeLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(directive.verbatimRule)
                .font(Theme.labelSmall)
                .foregroundStyle(.secondary)
                .strikethrough()
            StatusPill(text: "已停用 · \(scopeLabel)", tone: .neutral)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

/// 新增写作规则弹窗：初始化时缓存实体列表与当前分支名，避免每次按键重复排序。
struct AddAuthorDirectiveSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: ProjectSession

    @State private var ruleDraft = ""
    @State private var scopeKind: ScopeKind = .global
    @State private var selectedEntityID = ""
    @State private var entityOptions: [EntityPage]
    @State private var errorMessage: String?

    private enum ScopeKind: String, CaseIterable, Identifiable {
        case global = "全书"
        case branch = "当前分支"
        case entity = "指定设定"

        var id: String { rawValue }
    }

    init(session: ProjectSession) {
        self.session = session
        let options = NarrativeViewSupport.sortedEnabledEntities(from: session)
        _entityOptions = State(initialValue: options)
        _selectedEntityID = State(initialValue: options.first?.id ?? "")
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
                ruleSection
                scopeSection
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
                let workspace = session.ensureNarrativeWorkspace(
                    settingsCorpusLibraries: store.settings.corpusLibraries
                )
                if entityOptions.isEmpty {
                    entityOptions = NarrativeViewSupport.sortedEnabledEntities(from: workspace.currentState())
                }
                if selectedEntityID.isEmpty, let first = entityOptions.first {
                    selectedEntityID = first.id
                }
            }
            .narrativeErrorAlert($errorMessage)
        }
    }

    private var ruleSection: some View {
        Section {
            TextField("输入需要遵守的写作规则…", text: $ruleDraft, axis: .vertical)
                .font(Theme.label)
                .lineLimit(3...8)
        } header: {
            AppSectionHeader(title: "规则正文")
        }
    }

    private var scopeSection: some View {
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
