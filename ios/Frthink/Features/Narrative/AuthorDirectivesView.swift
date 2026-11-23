// 写作规则管理页：浏览生效/已停用规则，逐字新增全局或限定实体规则并通过左滑确认停用。

import Foundation
import SwiftUI

struct AuthorDirectivesView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession

    @State private var ruleDraft = ""
    @State private var selectedEntityID = ""
    @State private var scopeKind: ScopeKind = .global
    @State private var pendingSupersede: AuthorDirective?
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

    var body: some View {
        List {
            addRuleSection
            activeDirectivesSection
            if !supersededDirectives.isEmpty {
                supersededDirectivesSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle("写作规则")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            _ = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            if selectedEntityID.isEmpty, let first = entityOptions.first {
                selectedEntityID = first.id
            }
        }
        .narrativeErrorAlert($errorMessage)
        .alert(
            "停用此写作规则？",
            isPresented: Binding.isPresent($pendingSupersede),
            presenting: pendingSupersede
        ) { target in
            Button("停用", role: .destructive) {
                supersedeDirective(target)
                pendingSupersede = nil
            }
            Button("取消", role: .cancel) {
                pendingSupersede = nil
            }
        } message: { target in
            Text("停用后不再影响生成，仍可在下方历史中查看：\(target.verbatimRule)")
        }
    }

    private var currentBranchLabel: String {
        guard let workspace = session.narrativeWorkspace else { return "主线" }
        let label = workspace.storyGraph.nodes[workspace.storyGraph.headNodeID]?.branchLabel ?? "主线"
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "主线" : trimmed
    }

    private var availableScopeKinds: [ScopeKind] {
        entityOptions.isEmpty ? [.global, .branch] : ScopeKind.allCases
    }

    private var entityOptions: [EntityPage] {
        (liveState?.entityPages.values.sorted { $0.name < $1.name }) ?? []
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

    private var addRuleSection: some View {
        Section {
            TextField("输入需要遵守的写作规则…", text: $ruleDraft, axis: .vertical)
                .font(Theme.label)
                .lineLimit(2...6)

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

            Button("添加写作规则") {
                appendDirective()
            }
            .disabled(ruleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            AppSectionHeader(title: "新增写作规则")
        }
    }

    private var activeDirectivesSection: some View {
        Section {
            if activeDirectives.isEmpty {
                InlineEmptyState(
                    symbol: "shield.lefthalf.filled",
                    message: "暂无生效中的写作规则。"
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
            AppSectionHeader(title: "生效中（\(activeDirectives.count)）")
        }
    }

    private var supersededDirectivesSection: some View {
        Section {
            ForEach(supersededDirectives) { directive in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(directive.verbatimRule)
                        .font(Theme.labelSmall)
                        .foregroundStyle(.secondary)
                        .strikethrough()
                    StatusPill(text: "已停用 · \(scopeLabel(for: directive.scope))", tone: .neutral)
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        } header: {
            AppSectionHeader(title: "历史停用（\(supersededDirectives.count)）")
        }
    }

    private func appendDirective() {
        let trimmed = ruleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let scope: DirectiveScope
        switch scopeKind {
        case .global:
            scope = .global
        case .branch:
            scope = .branch(id: currentBranchLabel)
        case .entity:
            if !selectedEntityID.isEmpty {
                scope = .entity(id: selectedEntityID)
            } else {
                scope = .global
            }
        }

        let directive = AuthorDirective(
            verbatimRule: trimmed,
            scope: scope
        )
        let delta = PlotNodeDelta(directiveAdds: [directive])
        do {
            _ = try session.commitNarrativeDelta(
                delta,
                summary: "新增写作规则",
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            ruleDraft = ""
            store.toast = "已添加写作规则"
        } catch {
            errorMessage = error.localizedDescription
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
