// 伏笔管理页：分类展示待回收与已结束伏笔，支持新增伏笔与调整状态。

import Foundation
import SwiftUI

struct ProspectiveThreadsView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession

    @State private var goalDraft = ""
    @State private var cueDraft = ""
    @State private var recurrence: RecurrenceKind = .once
    @State private var errorMessage: String?

    private var liveState: MaterializedNarrativeState? {
        _ = session.narrativeRevision
        return session.narrativeWorkspace?.currentState()
    }

    var body: some View {
        List {
            plantThreadSection
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

    private var plantThreadSection: some View {
        Section {
            TextField("伏笔内容（如：交出地窖铜匙）", text: $goalDraft, axis: .vertical)
                .font(Theme.label)
                .lineLimit(1...3)

            TextField("回收时机或线索（可选）", text: $cueDraft)
                .font(Theme.labelSmall)

            Picker("回收方式", selection: $recurrence) {
                Text("一次性").tag(RecurrenceKind.once)
                Text("多次呼应").tag(RecurrenceKind.recurring)
            }
            .pickerStyle(.segmented)

            Button("添加伏笔") {
                plantThread()
            }
            .disabled(goalDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            AppSectionHeader(title: "新增伏笔")
        }
    }

    private var activeThreadsSection: some View {
        Section {
            if activeThreads.isEmpty {
                InlineEmptyState(
                    symbol: "flag.2.crossed",
                    message: "暂无待回收的伏笔。"
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
            ForEach(terminalThreads) { thread in
                threadRow(thread, allowTransitions: false)
            }
        } header: {
            AppSectionHeader(title: "已结束（\(terminalThreads.count)）")
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
                    Menu("调整状态") {
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
                    }
                    .font(Theme.labelSmall)
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

    private func plantThread() {
        let goal = goalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        let cue = cueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let headID = session.narrativeWorkspace?.storyGraph.headNodeID ?? "root"
        let threadID = "th_\(UUID().uuidString.prefix(8))"
        let event = ProspectiveThreadEvent(
            threadID: threadID,
            kind: .plant,
            goal: goal,
            activationCue: cue.isEmpty ? nil : cue,
            recurrence: recurrence,
            authority: .authorDirective,
            nodeID: headID
        )
        let delta = PlotNodeDelta(threadEvents: [event])
        do {
            _ = try session.commitNarrativeDelta(
                delta,
                summary: "埋设伏笔：\(String(goal.prefix(16)))",
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            goalDraft = ""
            cueDraft = ""
            store.toast = "已添加伏笔"
        } catch {
            errorMessage = error.localizedDescription
        }
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
