// 伏笔管理页：分类展示待回收与已结束伏笔，支持通过「+」弹窗新增伏笔与调整状态。

import Foundation
import SwiftUI

struct ProspectiveThreadsView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession

    @State private var showingPlantSheet = false
    @State private var showTerminal = false
    @State private var errorMessage: String?

    private var liveState: MaterializedNarrativeState? {
        _ = session.narrativeRevision
        return session.narrativeWorkspace?.currentState()
    }

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
        .task {
            _ = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
        }
        .narrativeErrorAlert($errorMessage)
    }

    private var activeThreads: [ProspectiveThread] {
        guard let liveState else { return [] }
        return liveState.threads.values
            .filter { !$0.state.isTerminal }
            .sorted { lhs, rhs in
                let leftRank = stateSortRank(lhs.state)
                let rightRank = stateSortRank(rhs.state)
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.updatedAt > rhs.updatedAt
            }
    }

    private var terminalThreads: [ProspectiveThread] {
        guard let liveState else { return [] }
        return liveState.threads.values
            .filter(\.state.isTerminal)
            .sorted { $0.updatedAt > $1.updatedAt }
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
                    threadRow(thread, allowTransitions: true)
                }
            }
        } header: {
            AppSectionHeader(title: "待回收（\(activeThreads.count)）")
        }
    }

    private var terminalThreadsSection: some View {
        Section {
            DisclosureGroup("已结束（\(terminalThreads.count)）", isExpanded: $showTerminal) {
                ForEach(terminalThreads) { thread in
                    threadRow(thread, allowTransitions: false)
                }
            }
        }
    }

    private func threadRow(_ thread: ProspectiveThread, allowTransitions: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                StatusPill(text: stateLabel(thread.state), tone: stateTone(thread.state))
                StatusPill(
                    text: thread.recurrence == .once ? "一次性" : "多次呼应",
                    tone: .neutral
                )
                Spacer(minLength: 0)
                if allowTransitions {
                    Menu {
                        if thread.state != .ready {
                            Button("标为可回收") {
                                transition(thread: thread, kind: .promoteReady)
                            }
                        }
                        if thread.state != .enacted {
                            Button("标为已展开") {
                                transition(thread: thread, kind: .markEnacted)
                            }
                        }
                        Button("标为已回收") {
                            transition(thread: thread, kind: .markSatisfied)
                        }
                        Button("标为放弃", role: .destructive) {
                            transition(thread: thread, kind: .invalidate)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(Theme.label)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("调整伏笔状态")
                }
            }

            Text(thread.goal)
                .font(Theme.label)
                .foregroundStyle(.primary)

            if !thread.activationCue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("触发时机：\(thread.activationCue)")
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
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

    private func stateLabel(_ lifecycle: ThreadLifecycle) -> String {
        switch lifecycle {
        case .pending: return "已埋下"
        case .ready: return "可回收"
        case .enacted: return "已展开"
        case .satisfied: return "已回收"
        case .invalidated: return "已放弃"
        }
    }

    private func stateTone(_ lifecycle: ThreadLifecycle) -> AppTone {
        switch lifecycle {
        case .pending: return .neutral
        case .ready: return .accent
        case .enacted: return .warning
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
    @State private var errorMessage: String?

    private var trimmedGoal: String {
        goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
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

                Section {
                    Picker("回收方式", selection: $recurrence) {
                        Text("一次性").tag(RecurrenceKind.once)
                        Text("多次呼应").tag(RecurrenceKind.recurring)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    AppSectionHeader(title: "回收方式")
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
        }
    }

    private func plantThread() {
        guard !trimmedGoal.isEmpty else { return }
        let cue = cueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let headID = session.narrativeWorkspace?.storyGraph.headNodeID ?? "root"
        let threadID = "th_\(UUID().uuidString.prefix(8))"
        let event = ProspectiveThreadEvent(
            threadID: threadID,
            kind: .plant,
            goal: trimmedGoal,
            activationCue: cue.isEmpty ? nil : cue,
            recurrence: recurrence,
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
