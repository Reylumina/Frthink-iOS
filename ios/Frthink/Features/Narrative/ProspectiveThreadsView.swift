// 伏笔管理页：分类展示待回收与已结束伏笔，缓存列表快照并提取扁平子视图。

import Foundation
import SwiftUI

struct ProspectiveThreadsView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession

    @State private var activeThreads: [ProspectiveThread] = []
    @State private var terminalThreads: [ProspectiveThread] = []
    @State private var entityNames: [String: String] = [:]
    @State private var showingPlantSheet = false
    @State private var showTerminal = false
    @State private var hapticTrigger = 0
    @State private var errorMessage: String?

    var body: some View {
        List {
            activeThreadsSection
            if !terminalThreads.isEmpty {
                terminalThreadsSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .themeAnimation(Theme.motionLayout, value: activeThreads.count)
        .sensoryFeedback(.success, trigger: hapticTrigger) { _, _ in
            store.settings.hapticsEnabled
        }
        .navigationTitle("伏笔")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingPlantSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加伏笔")
            }
        }
        .sheet(isPresented: $showingPlantSheet) {
            PlantThreadSheet(session: session)
        }
        .task(id: session.narrativeRevision) {
            _ = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            reloadSnapshot()
        }
        .narrativeErrorAlert($errorMessage)
    }

    private var activeThreadsSection: some View {
        Section {
            if activeThreads.isEmpty {
                InlineEmptyState(
                    symbol: "flag.2.crossed",
                    message: "暂无待回收的伏笔。",
                    actionTitle: "添加伏笔",
                    action: { showingPlantSheet = true }
                )
            } else {
                ForEach(activeThreads) { thread in
                    ProspectiveThreadRow(
                        thread: thread,
                        relatedNames: thread.relatedEntityIDs.compactMap { entityNames[$0] },
                        allowTransitions: true,
                        onTransition: { kind in transition(thread: thread, kind: kind) }
                    )
                }
            }
        } header: {
            AppSectionHeader(title: "未完结（\(activeThreads.count)）")
        }
    }

    private var terminalThreadsSection: some View {
        Section {
            DisclosureGroup("已结束（\(terminalThreads.count)）", isExpanded: $showTerminal) {
                ForEach(terminalThreads) { thread in
                    ProspectiveThreadRow(
                        thread: thread,
                        relatedNames: thread.relatedEntityIDs.compactMap { entityNames[$0] },
                        allowTransitions: false,
                        onTransition: { _ in }
                    )
                }
            }
        }
    }

    private func reloadSnapshot() {
        guard let state = session.narrativeWorkspace?.currentState() else {
            activeThreads = []
            terminalThreads = []
            entityNames = [:]
            return
        }
        entityNames = state.entityPages.mapValues(\.name)
        var active: [ProspectiveThread] = []
        var terminal: [ProspectiveThread] = []
        for thread in state.threads.values {
            if thread.state.isTerminal {
                terminal.append(thread)
            } else {
                active.append(thread)
            }
        }
        activeThreads = active.sorted { lhs, rhs in
            let leftRank = stateSortRank(lhs.state)
            let rightRank = stateSortRank(rhs.state)
            if leftRank != rightRank { return leftRank < rightRank }
            return lhs.updatedAt > rhs.updatedAt
        }
        terminalThreads = terminal.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func transition(
        thread: ProspectiveThread,
        kind: ProspectiveThreadEvent.Kind
    ) {
        let headID = session.narrativeWorkspace?.storyGraph.headNodeID ?? "root"
        let event = ProspectiveThreadEvent(
            threadID: thread.id,
            kind: kind,
            authority: .authorDirective,
            nodeID: headID
        )
        let delta = PlotNodeDelta(threadEvents: [event])
        do {
            _ = try session.commitNarrativeDelta(
                delta,
                summary: "更新伏笔状态：\(String(thread.goal.prefix(16)))",
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            hapticTrigger &+= 1
            store.toast = "伏笔状态已更新"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stateSortRank(_ lifecycle: ThreadLifecycle) -> Int {
        switch lifecycle {
        case .ready: return 0
        case .enacted: return 1
        case .pending: return 2
        case .satisfied: return 3
        case .invalidated: return 4
        }
    }
}

private struct ProspectiveThreadRow: View {
    let thread: ProspectiveThread
    let relatedNames: [String]
    let allowTransitions: Bool
    let onTransition: (ProspectiveThreadEvent.Kind) -> Void

    private var cleanCue: String {
        thread.activationCue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            headerBar

            Text(thread.goal)
                .font(Theme.label)
                .foregroundStyle(.primary)

            if thread.state == .enacted {
                Text("已在正文中呼应，可确认完结")
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
            }
            if !relatedNames.isEmpty {
                Text("关联档案：\(relatedNames.joined(separator: "、"))")
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
            }
            if !cleanCue.isEmpty {
                Text("触发时机：\(cleanCue)")
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
            }
            if let quote = thread.evidenceAnchors.last?.quote.trimmingCharacters(in: .whitespacesAndNewlines),
               !quote.isEmpty {
                Text("原文：「\(quote)」")
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if allowTransitions {
                Button {
                    onTransition(.markSatisfied)
                } label: {
                    Label("标为已回收", systemImage: "checkmark.circle")
                }
                .tint(AppTone.success.color)
            }
        }
    }

    private var headerBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            StatusPill(text: stateLabel, tone: stateTone)
            StatusPill(
                text: thread.recurrence == .once ? "一次性" : "多次呼应",
                tone: .neutral
            )
            Spacer(minLength: 0)
            if allowTransitions {
                transitionMenu
            }
        }
    }

    private var transitionMenu: some View {
        Menu {
            if thread.state == .pending {
                Button("标为待回收") { onTransition(.promoteReady) }
            }
            Button("标为已回收") { onTransition(.markSatisfied) }
            Button("标为放弃", role: .destructive) { onTransition(.invalidate) }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(Theme.label)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("调整伏笔状态")
    }

    private var stateLabel: String {
        switch thread.state {
        case .pending: return "潜伏"
        case .ready, .enacted: return "待回收"
        case .satisfied: return "已回收"
        case .invalidated: return "已放弃"
        }
    }

    private var stateTone: AppTone {
        switch thread.state {
        case .pending: return .neutral
        case .ready, .enacted: return .accent
        case .satisfied: return .success
        case .invalidated: return .danger
        }
    }
}

/// 新建伏笔弹窗：由伏笔页或剧情工作台触发，避免常驻大表单占满首屏。
struct PlantThreadSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: ProjectSession

    @State private var goalDraft = ""
    @State private var cueDraft = ""
    @State private var recurrence: RecurrenceKind = .once
    @State private var selectedEntityIDs: Set<String> = []
    @State private var availableEntities: [EntityPage]
    @State private var errorMessage: String?

    init(session: ProjectSession) {
        self.session = session
        _availableEntities = State(initialValue: NarrativeViewSupport.sortedEnabledEntities(from: session))
    }

    private var trimmedGoal: String {
        goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                contentSection
                recurrenceSection
                if !availableEntities.isEmpty {
                    NarrativeEntityPickerSection(
                        title: "关联档案",
                        entities: availableEntities,
                        selectedIDs: $selectedEntityIDs
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .groupedPageBackground()
            .navigationTitle("添加伏笔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton(title: "取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton(title: "添加", isEnabled: !trimmedGoal.isEmpty) {
                        plantThread()
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

    private var contentSection: some View {
        Section {
            TextField("伏笔内容（如：交出地窖铜匙）", text: $goalDraft, axis: .vertical)
                .font(Theme.label)
                .lineLimit(2...5)

            TextField("回收时机或线索（可选）", text: $cueDraft, axis: .vertical)
                .font(Theme.labelSmall)
                .lineLimit(1...3)
        } header: {
            AppSectionHeader(title: "伏笔内容")
        }
    }

    private var recurrenceSection: some View {
        Section {
            Picker("回收方式", selection: $recurrence) {
                Text("一次性").tag(RecurrenceKind.once)
                Text("多次呼应").tag(RecurrenceKind.recurring)
            }
            .pickerStyle(.menu)
        } header: {
            AppSectionHeader(title: "回收方式")
        }
    }

    private func plantThread() {
        guard !trimmedGoal.isEmpty else { return }
        let cue = cueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let headID = session.narrativeWorkspace?.storyGraph.headNodeID ?? "root"
        let threadID = "th_\(UUID().uuidString.prefix(8))"
        let orderedRelatedIDs = availableEntities
            .map(\.id)
            .filter { selectedEntityIDs.contains($0) }
        let event = ProspectiveThreadEvent(
            threadID: threadID,
            kind: .plant,
            goal: trimmedGoal,
            activationCue: cue.isEmpty ? nil : cue,
            recurrence: recurrence,
            relatedEntityIDs: orderedRelatedIDs.isEmpty ? nil : orderedRelatedIDs,
            authority: .authorDirective,
            nodeID: headID
        )
        do {
            _ = try session.commitNarrativeDelta(
                PlotNodeDelta(threadEvents: [event]),
                summary: "埋设伏笔：\(String(trimmedGoal.prefix(16)))",
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            store.toast = "已添加伏笔"
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
