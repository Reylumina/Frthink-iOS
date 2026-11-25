// 档案列表页：按人物、地点、物件、世界观分组展示，支持搜索、筛选、手动增删改与正文提取。

import Foundation
import SwiftUI

struct EntityPagesView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession
    var embeddedInWorld: Bool = false
    var externalSelectedKind: Binding<EntityKind?>? = nil
    var externalCreateTrigger: Int = 0
    var externalExtractTrigger: Int = 0

    @State private var sortedEntities: [EntityPage] = []
    @State private var factCountsByEntity: [String: Int] = [:]
    @State private var beliefCountsByEntity: [String: Int] = [:]
    @State private var searchText = ""
    @State private var localSelectedKind: EntityKind?
    @State private var showingCreateSheet = false
    @State private var pendingDeletePage: EntityPage?
    @State private var isExtracting = false
    @State private var extractTrigger = 0
    @State private var errorMessage: String?
    #if DEBUG
    @State private var launchEntityID: String?
    @State private var didApplyLaunchCard = false
    #endif

    private let allKinds: [EntityKind] = [.character, .location, .artifact, .lore]

    private var activeSelectedKind: EntityKind? {
        externalSelectedKind?.wrappedValue ?? localSelectedKind
    }

    private func setSelectedKind(_ kind: EntityKind?) {
        if let externalSelectedKind {
            externalSelectedKind.wrappedValue = kind
        } else {
            localSelectedKind = kind
        }
    }

    private var hasManuscriptContent: Bool {
        session.manuscriptCharacterCount > 0 || session.bodyPageCount > 0
    }

    private var hasEntities: Bool {
        !sortedEntities.isEmpty
    }

    var body: some View {
        Group {
            if embeddedInWorld {
                VStack(spacing: 0) {
                    if hasEntities || !searchText.isEmpty {
                        InlineSearchField(placeholder: "搜索名称、别名或摘要", text: $searchText)
                            .padding(.horizontal, Theme.Spacing.l)
                            .padding(.bottom, Theme.Spacing.xs)
                    }
                    entityList
                }
            } else {
                entityList
                    .searchable(text: $searchText, prompt: "搜索名称、别名或摘要")
                    .navigationTitle("档案")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { standaloneToolbar }
            }
        }
        .groupedPageBackground()
        .sheet(isPresented: $showingCreateSheet) {
            EntityPageEditorSheet(
                session: session,
                initialKind: activeSelectedKind ?? .character
            )
        }
        .deleteConfirmationDialog(
            { "删除档案「\($0.name)」？" },
            item: $pendingDeletePage
        ) { target in
            session.deleteEntityPage(
                id: target.id,
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            store.toast = "已删除档案"
        }
        .task(id: session.narrativeRevision) {
            reloadState()
            #if DEBUG
            applyLaunchCardIfNeeded()
            #endif
        }
        .onChange(of: externalCreateTrigger) { _, _ in
            showingCreateSheet = true
        }
        .onChange(of: externalExtractTrigger) { _, _ in
            extractTrigger &+= 1
        }
        .task(id: extractTrigger) {
            guard extractTrigger > 0 else { return }
            await extractFromManuscript()
        }
        .narrativeErrorAlert($errorMessage, title: "操作失败")
        #if DEBUG
        .navigationDestination(item: $launchEntityID) { id in
            EntityPageDetailView(session: session, entityID: id)
        }
        #endif
    }

    private var entityList: some View {
        List {
            if isExtracting {
                Section {
                    AppStatusLine(kind: .progress, text: "正在从正文提取档案…")
                }
            }
            entitiesSections
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .keyboardDismissOnScroll()
    }

    private var kindSelectionBinding: Binding<EntityKind?> {
        Binding(
            get: { activeSelectedKind },
            set: { setSelectedKind($0) }
        )
    }

    @ToolbarContentBuilder
    private var standaloneToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("按分类筛选", selection: kindSelectionBinding) {
                    Text("全部").tag(EntityKind?.none)
                    ForEach(allKinds, id: \.rawValue) { kind in
                        Text(NarrativeViewSupport.entityKindLabel(kind))
                            .tag(EntityKind?.some(kind))
                    }
                }
            } label: {
                Image(
                    systemName: activeSelectedKind == nil
                        ? "line.3.horizontal.decrease.circle"
                        : "line.3.horizontal.decrease.circle.fill"
                )
            }
            .accessibilityLabel("按分类筛选")

            Menu {
                Button("新建档案", systemImage: "plus") {
                    showingCreateSheet = true
                }
                Button("从正文提取档案", systemImage: "arrow.clockwise") {
                    extractTrigger &+= 1
                }
                .disabled(isExtracting || !hasManuscriptContent)
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("添加档案")
        }
    }

    private var filteredEntities: [EntityPage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sortedEntities.filter { page in
            if let kind = activeSelectedKind, page.kind != kind {
                return false
            }
            guard !query.isEmpty else { return true }
            return page.name.lowercased().contains(query)
                || page.aliases.contains(where: { $0.lowercased().contains(query) })
                || page.triggerKeywords.contains(where: { $0.lowercased().contains(query) })
                || page.summary.lowercased().contains(query)
                || page.identity.lowercased().contains(query)
        }
    }

    @ViewBuilder
    private var entitiesSections: some View {
        let filtered = filteredEntities
        if filtered.isEmpty {
            Section {
                emptyStateView
            }
        } else if let selected = activeSelectedKind {
            Section {
                entityRows(for: filtered)
            } header: {
                HStack {
                    AppSectionHeader(
                        title: "\(NarrativeViewSupport.entityKindLabel(selected))（\(filtered.count)）"
                    )
                    Spacer(minLength: 0)
                    Button("显示全部") {
                        withAnimation(Theme.motionSelection) {
                            setSelectedKind(nil)
                        }
                    }
                    .font(Theme.metadata)
                    .buttonStyle(.borderless)
                }
            }
        } else {
            ForEach(allKinds, id: \.rawValue) { kind in
                let group = filtered.filter { $0.kind == kind }
                if !group.isEmpty {
                    Section {
                        entityRows(for: group)
                    } header: {
                        AppSectionHeader(
                            title: "\(NarrativeViewSupport.entityKindLabel(kind))（\(group.count)）"
                        )
                    }
                }
            }
        }
    }

    private func entityRows(for pages: [EntityPage]) -> some View {
        ForEach(pages) { page in
            NavigationLink {
                EntityPageDetailView(session: session, entityID: page.id)
            } label: {
                entityRow(for: page)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("删除", role: .destructive) {
                    pendingDeletePage = page
                }
                Button(page.enabled ? "停用" : "启用") {
                    toggleEnabled(for: page)
                }
                .tint(page.enabled ? AppTone.warning.color : AppTone.success.color)
            }
        }
    }

    @ViewBuilder
    private var emptyStateView: some View {
        let cleanSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanSearch.isEmpty {
            InlineEmptyState(
                symbol: "magnifyingglass",
                message: "没有匹配的档案。"
            )
        } else if activeSelectedKind != nil {
            InlineEmptyState(
                symbol: "line.3.horizontal.decrease.circle",
                message: "当前分类下暂无档案。",
                actionTitle: "显示全部",
                action: { setSelectedKind(nil) }
            )
        } else if hasManuscriptContent {
            InlineEmptyState(
                symbol: "person.2.crop.square.stack",
                message: "暂无档案，可从正文提取或手动新建。",
                actionTitle: "从正文提取",
                action: { extractTrigger &+= 1 }
            )
        } else {
            InlineEmptyState(
                symbol: "person.2.crop.square.stack",
                message: "暂无档案。",
                actionTitle: "新建档案",
                action: { showingCreateSheet = true }
            )
        }
    }

    private func toggleEnabled(for page: EntityPage) {
        var updated = page
        updated.enabled.toggle()
        updated.updatedAt = Date()
        session.saveEntityPage(
            updated,
            isReplacement: true,
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        store.toast = updated.enabled ? "已启用「\(updated.name)」" : "已停用「\(updated.name)」"
    }

    private func extractFromManuscript() async {
        guard !isExtracting else { return }
        isExtracting = true
        defer { isExtracting = false }
        do {
            let result = try await NarrativeViewSupport.refreshEntitiesFromManuscript(
                session: session,
                store: store,
                targetKind: activeSelectedKind
            )
            if result.added == 0 && result.updated == 0 {
                store.toast = "未发现新的档案变更"
            } else {
                store.toast = "已更新档案：新增 \(result.added) 项，更新 \(result.updated) 项"
            }
        } catch {
            guard !Task.isCancelled, !error.isLLMCancellation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func entityRow(for page: EntityPage) -> some View {
        let factCount = factCountsByEntity[page.id] ?? 0
        let beliefCount = beliefCountsByEntity[page.id] ?? 0
        let cleanSummary = page.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanIdentity = page.identity.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewText = cleanSummary.isEmpty ? cleanIdentity : cleanSummary
        let countsText = nonZeroCountsSummary(
            facts: factCount,
            beliefs: page.kind == .character || beliefCount > 0 ? beliefCount : 0
        )

        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                Text(page.name)
                    .font(Theme.labelEmphasis)
                    .foregroundStyle(.primary)
                if page.kind == .lore, page.activationMode == .always {
                    StatusPill(text: "常驻", tone: .accent)
                }
                if !page.enabled {
                    StatusPill(text: "已停用", tone: .neutral)
                }
                Spacer(minLength: 0)
                if !page.conflictWarnings.isEmpty {
                    StatusPill(
                        text: "\(page.conflictWarnings.count) 条待确认",
                        tone: .warning
                    )
                }
            }

            if !page.aliases.isEmpty {
                Text("别名：" + page.aliases.joined(separator: "、"))
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if !previewText.isEmpty {
                Text(previewText)
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if let countsText {
                Text(countsText)
                    .font(Theme.numericSmall)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func nonZeroCountsSummary(facts: Int, beliefs: Int) -> String? {
        var parts: [String] = []
        if facts > 0 { parts.append("\(facts) 条事实") }
        if beliefs > 0 { parts.append("\(beliefs) 条认知") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func reloadState() {
        do {
            let state = try NarrativeViewSupport.loadState(session: session, store: store)

            var factCounts: [String: Int] = [:]
            for fact in state.activeFacts.values where !fact.isRetracted {
                factCounts[fact.entityID, default: 0] += 1
            }
            var beliefCounts: [String: Int] = [:]
            for belief in state.epistemicBeliefs.values {
                beliefCounts[belief.characterID, default: 0] += 1
            }
            factCountsByEntity = factCounts
            beliefCountsByEntity = beliefCounts

            sortedEntities = state.entityPages.values.sorted { lhs, rhs in
                if lhs.conflictWarnings.count != rhs.conflictWarnings.count {
                    return lhs.conflictWarnings.count > rhs.conflictWarnings.count
                }
                if lhs.enabled != rhs.enabled {
                    return lhs.enabled && !rhs.enabled
                }
                let leftScore = richnessScore(lhs, factCounts: factCounts, beliefCounts: beliefCounts)
                let rightScore = richnessScore(rhs, factCounts: factCounts, beliefCounts: beliefCounts)
                if leftScore != rightScore {
                    return leftScore > rightScore
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func richnessScore(
        _ page: EntityPage,
        factCounts: [String: Int],
        beliefCounts: [String: Int]
    ) -> Int {
        let facts = factCounts[page.id] ?? 0
        let beliefs = beliefCounts[page.id] ?? 0
        let hasSummary = !page.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasIdentity = !page.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return facts + beliefs + (hasSummary ? 1 : 0) + (hasIdentity ? 1 : 0)
    }

    #if DEBUG
    private func applyLaunchCardIfNeeded() {
        guard !didApplyLaunchCard, LaunchArguments.opensWorldCard else { return }
        didApplyLaunchCard = true
        if let first = filteredEntities.first ?? sortedEntities.first {
            launchEntityID = first.id
        }
    }
    #endif
}
