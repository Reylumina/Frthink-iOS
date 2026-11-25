// 关键事件页：按故事线分组管理结构化事件因果，缓存列表快照并提取扁平子视图。

import Foundation
import SwiftUI

struct EpisodicEventsView: View {
    private enum FilterScope: String, CaseIterable, Identifiable {
        case ongoing = "进行中"
        case all = "全部"
        case resolved = "已完结"

        var id: String { rawValue }
    }

    private struct ArcGroup: Identifiable {
        let id: String
        let title: String
        let events: [EpisodicEvent]
    }

    @Environment(AppStore.self) private var store
    let session: ProjectSession

    @State private var filterScope: FilterScope = .ongoing
    @State private var arcGroups: [ArcGroup] = []
    @State private var entityNames: [String: String] = [:]
    @State private var editingTarget: EpisodicEvent?
    @State private var showingNewSheet = false
    @State private var hapticTrigger = 0
    @State private var errorMessage: String?

    var body: some View {
        List {
            filterSection
            contentSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .themeAnimation(Theme.motionSelection, value: filterScope)
        .sensoryFeedback(.success, trigger: hapticTrigger) { _, _ in
            store.settings.hapticsEnabled
        }
        .navigationTitle("关键事件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingNewSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建关键事件")
            }
        }
        .sheet(isPresented: $showingNewSheet) {
            EpisodicEventEditorSheet(session: session, existing: nil)
        }
        .sheet(item: $editingTarget) { target in
            EpisodicEventEditorSheet(session: session, existing: target)
        }
        .task(id: session.narrativeRevision) {
            _ = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            reloadSnapshot()
        }
        .onChange(of: filterScope) { _, _ in
            reloadSnapshot()
        }
        .narrativeErrorAlert($errorMessage)
    }

    private var filterSection: some View {
        Section {
            Picker("筛选", selection: $filterScope) {
                ForEach(FilterScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if arcGroups.isEmpty {
            Section {
                InlineEmptyState(
                    symbol: "calendar.badge.clock",
                    message: emptyMessage,
                    actionTitle: "新建事件",
                    action: { showingNewSheet = true }
                )
            }
        } else {
            ForEach(arcGroups) { group in
                Section {
                    ForEach(group.events) { event in
                        EpisodicEventRow(
                            event: event,
                            participantNames: event.participantEntityIDs.compactMap { entityNames[$0] },
                            onEdit: { editingTarget = event },
                            onToggleStatus: {
                                toggleStatus(event, to: event.status == .ongoing ? .resolved : .ongoing)
                            },
                            onDelete: { deleteEvent(event) }
                        )
                    }
                } header: {
                    AppSectionHeader(title: "\(group.title)（\(group.events.count)）")
                }
            }
        }
    }

    private var emptyMessage: String {
        switch filterScope {
        case .ongoing: return "眼下暂无进行中的关键事件，写到关键转折时会自动收进来。"
        case .resolved: return "还没有已收尾的关键事件。"
        case .all: return "暂时还没有记下的关键事件。"
        }
    }

    private func reloadSnapshot() {
        guard let state = session.narrativeWorkspace?.currentState() else {
            arcGroups = []
            entityNames = [:]
            return
        }
        entityNames = state.entityPages.mapValues(\.name)
        let filtered = state.sortedEpisodicEvents().filter { event in
            switch filterScope {
            case .ongoing: return event.status == .ongoing
            case .resolved: return event.status == .resolved
            case .all: return true
            }
        }
        var bucket: [String: [EpisodicEvent]] = [:]
        var orderedArcs: [String] = []
        for event in filtered {
            let cleanArc = event.arcTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = cleanArc.isEmpty ? "主线事件" : cleanArc
            if bucket[key] == nil {
                orderedArcs.append(key)
            }
            bucket[key, default: []].append(event)
        }
        arcGroups = orderedArcs.map { ArcGroup(id: $0, title: $0, events: bucket[$0] ?? []) }
    }

    private func toggleStatus(_ event: EpisodicEvent, to nextStatus: EpisodicEventStatus) {
        let headID = session.narrativeWorkspace?.storyGraph.headNodeID ?? "root"
        var updated = event
        updated.status = nextStatus
        updated.authority = .authorDirective
        updated.nodeID = headID
        updated.updatedAt = Date()
        do {
            _ = try session.commitNarrativeDelta(
                PlotNodeDelta(episodicEvents: [updated]),
                summary: "\(nextStatus.displayName)：\(String(event.title.prefix(16)))",
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            hapticTrigger &+= 1
            store.toast = "已标为\(nextStatus.displayName)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteEvent(_ event: EpisodicEvent) {
        do {
            _ = try session.commitNarrativeDelta(
                PlotNodeDelta(removedEpisodicEventIDs: [event.id]),
                summary: "删除事件：\(String(event.title.prefix(16)))",
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            store.toast = "已删除事件"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct EpisodicEventRow: View {
    let event: EpisodicEvent
    let participantNames: [String]
    let onEdit: () -> Void
    let onToggleStatus: () -> Void
    let onDelete: () -> Void

    private var cleanScene: String {
        event.scene.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanCause: String {
        event.cause.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanDevelopment: String {
        event.development.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var cleanOutcome: String {
        event.outcome.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            headerBar
            detailsButton
        }
        .padding(.vertical, Theme.Spacing.xs)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button(action: onToggleStatus) {
                Label(
                    event.status == .ongoing ? "标为已完结" : "重新打开",
                    systemImage: event.status == .ongoing ? "checkmark.circle" : "arrow.uturn.backward"
                )
            }
            .tint(AppTone.success.color)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删除", role: .destructive, action: onDelete)
        }
    }

    private var headerBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            StatusPill(
                text: event.status.displayName,
                tone: event.status == .ongoing ? .accent : .success
            )
            if !cleanScene.isEmpty {
                Text(cleanScene)
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            actionMenu
        }
    }

    private var actionMenu: some View {
        Menu {
            Button("编辑", action: onEdit)
            Button(event.status == .ongoing ? "标为已完结" : "重新打开", action: onToggleStatus)
            Divider()
            Button("删除事件", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(Theme.label)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("操作关键事件")
    }

    private var detailsButton: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(event.title)
                    .font(Theme.labelEmphasis)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                if !participantNames.isEmpty {
                    Text("相关档案：\(participantNames.joined(separator: "、"))")
                        .font(Theme.metadata)
                        .foregroundStyle(.secondary)
                }
                if !cleanCause.isEmpty {
                    Text("起因：\(cleanCause)")
                        .font(Theme.labelSmall)
                        .foregroundStyle(.secondary)
                }
                if !cleanDevelopment.isEmpty {
                    Text("经过：\(cleanDevelopment)")
                        .font(Theme.labelSmall)
                        .foregroundStyle(.secondary)
                }
                if !cleanOutcome.isEmpty {
                    Text("结果：\(cleanOutcome)")
                        .font(Theme.labelSmall)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct EpisodicEventEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: ProjectSession
    let existing: EpisodicEvent?

    @State private var titleDraft: String
    @State private var arcTitleDraft: String
    @State private var sceneDraft: String
    @State private var causeDraft: String
    @State private var developmentDraft: String
    @State private var outcomeDraft: String
    @State private var status: EpisodicEventStatus
    @State private var selectedEntityIDs: Set<String>
    @State private var availableEntities: [EntityPage]
    @State private var errorMessage: String?

    init(session: ProjectSession, existing: EpisodicEvent?) {
        self.session = session
        self.existing = existing
        _titleDraft = State(initialValue: existing?.title ?? "")
        _arcTitleDraft = State(initialValue: existing?.arcTitle ?? "")
        _sceneDraft = State(initialValue: existing?.scene ?? "")
        _causeDraft = State(initialValue: existing?.cause ?? "")
        _developmentDraft = State(initialValue: existing?.development ?? "")
        _outcomeDraft = State(initialValue: existing?.outcome ?? "")
        _status = State(initialValue: existing?.status ?? .ongoing)
        _selectedEntityIDs = State(initialValue: Set(existing?.participantEntityIDs ?? []))
        _availableEntities = State(initialValue: NarrativeViewSupport.sortedEnabledEntities(from: session))
    }

    private var trimmedTitle: String {
        titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                basicSection
                causalSection
                if !availableEntities.isEmpty {
                    NarrativeEntityPickerSection(
                        title: "相关档案",
                        entities: availableEntities,
                        selectedIDs: $selectedEntityIDs
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .groupedPageBackground()
            .navigationTitle(existing == nil ? "新建关键事件" : "编辑关键事件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton(title: "取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton(title: existing == nil ? "添加" : "保存", isEnabled: !trimmedTitle.isEmpty) {
                        saveEvent()
                    }
                }
            }
            .narrativeErrorAlert($errorMessage)
            .task {
                let workspace = session.ensureNarrativeWorkspace(
                    settingsCorpusLibraries: store.settings.corpusLibraries
                )
                availableEntities = NarrativeViewSupport.sortedEnabledEntities(from: workspace.currentState())
            }
        }
    }

    private var basicSection: some View {
        Section {
            TextField("事件标题（如：雾港码头夜审）", text: $titleDraft)
                .font(Theme.label)
            TextField("所属故事线（可选，如：南疆追查线）", text: $arcTitleDraft)
                .font(Theme.labelSmall)
            TextField("发生地点或场次（可选）", text: $sceneDraft)
                .font(Theme.labelSmall)
            Picker("状态", selection: $status) {
                ForEach(EpisodicEventStatus.allCases, id: \.self) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            AppSectionHeader(title: "基本信息")
        }
    }

    private var causalSection: some View {
        Section {
            TextField("起因（可选）", text: $causeDraft, axis: .vertical)
                .font(Theme.labelSmall)
                .lineLimit(1...4)
            TextField("经过（可选）", text: $developmentDraft, axis: .vertical)
                .font(Theme.labelSmall)
                .lineLimit(1...4)
            TextField("结果或遗留影响（可选）", text: $outcomeDraft, axis: .vertical)
                .font(Theme.labelSmall)
                .lineLimit(1...4)
        } header: {
            AppSectionHeader(title: "因果脉络")
        }
    }

    private func saveEvent() {
        guard !trimmedTitle.isEmpty else { return }
        let headID = session.narrativeWorkspace?.storyGraph.headNodeID ?? "root"
        let knownIDs = Set(availableEntities.map(\.id))
        let preservedExtraIDs = selectedEntityIDs
            .filter { !knownIDs.contains($0) }
            .sorted()
        let orderedParticipantIDs = availableEntities
            .map(\.id)
            .filter { selectedEntityIDs.contains($0) }
            + preservedExtraIDs
        let event = EpisodicEvent(
            id: existing?.id ?? "evt_\(UUID().uuidString.prefix(8))",
            title: trimmedTitle,
            arcTitle: arcTitleDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            scene: sceneDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            participantEntityIDs: orderedParticipantIDs,
            cause: causeDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            development: developmentDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            outcome: outcomeDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            status: status,
            authority: .authorDirective,
            quoteAnchor: existing?.quoteAnchor,
            nodeID: headID,
            updatedAt: Date()
        )
        let removedIDs = existing.map { [$0.id] } ?? []
        let delta = PlotNodeDelta(
            episodicEvents: [event],
            removedEpisodicEventIDs: removedIDs
        )
        do {
            _ = try session.commitNarrativeDelta(
                delta,
                summary: "\(existing == nil ? "新建" : "更新")事件：\(String(trimmedTitle.prefix(16)))",
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            store.toast = existing == nil ? "已添加关键事件" : "关键事件已更新"
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
