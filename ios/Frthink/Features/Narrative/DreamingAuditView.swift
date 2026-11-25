// 世界核查页：排查角色认知冲突、档案冗长、缺少依据的记录与久未回收的伏笔，
// 支持逐条确认（同步事实、保留信息差、跳转编辑或忽略）及安全项一键整理。

import Foundation
import SwiftUI

struct DreamingAuditView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession

    @State private var report: DreamingAuditReport?
    @State private var isAuditing = false
    @State private var isFlushingPending = false
    @State private var auditTrigger = 0
    @State private var dismissedIDs: Set<String> = []
    @State private var selectedEntityID: String?
    @State private var showingThreads = false
    @State private var errorMessage: String?

    private var pendingSyncCount: Int {
        _ = session.narrativeRevision
        return session.narrativeWorkspace?.pendingSyncNodeIDs.count ?? 0
    }

    private var liveState: MaterializedNarrativeState? {
        _ = session.narrativeRevision
        return session.narrativeWorkspace?.currentState()
    }

    private var visibleFindings: [DreamingFinding] {
        guard let report else { return [] }
        return report.findings.filter { !dismissedIDs.contains($0.id) }
    }

    private var hiddenDismissedCount: Int {
        guard let report else { return 0 }
        return report.findings.filter { dismissedIDs.contains($0.id) }.count
    }

    private var safeCleanableFindings: [DreamingFinding] {
        guard let state = liveState else { return [] }
        return visibleFindings.filter {
            NarrativeViewSupport.isAutoSafeCleanable($0, in: state)
        }
    }

    var body: some View {
        List {
            actionSection
            findingsSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle("世界核查")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(session.narrativeRevision)-\(auditTrigger)") {
            dismissedIDs = NarrativeViewSupport.dismissedAuditFindingIDs(for: session.project.id)
            await runAudit()
        }
        .navigationDestination(item: $selectedEntityID) { id in
            EntityPageDetailView(session: session, entityID: id)
        }
        .navigationDestination(isPresented: $showingThreads) {
            ProspectiveThreadsView(session: session)
        }
        .narrativeErrorAlert($errorMessage, title: "检查失败")
    }

    private var actionSection: some View {
        let safeItems = safeCleanableFindings
        return Section {
            Button {
                auditTrigger &+= 1
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Text(isAuditing ? "正在核查档案与伏笔…" : "重新核查")
                    if isAuditing {
                        Spacer(minLength: 0)
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isAuditing || isFlushingPending)

            if pendingSyncCount > 0 {
                Button {
                    Task { await flushPendingSyncs() }
                } label: {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(isFlushingPending ? "正在补抽待更新正文…" : "补抽待更新正文（\(pendingSyncCount) 幕）")
                        if isFlushingPending {
                            Spacer(minLength: 0)
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isAuditing || isFlushingPending)
            }

            if report != nil {
                Text(summaryText)
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)

                if !safeItems.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Button("一键安全整理（\(safeItems.count) 项）") {
                            applyCleanup(findings: safeItems, toastMessage: nil)
                        }
                        .disabled(isAuditing)

                        Text("仅自动整理过长档案与推进待触发伏笔，不会修改角色认知。")
                            .font(Theme.metadata)
                            .foregroundStyle(.secondary)
                    }
                }

                if hiddenDismissedCount > 0 {
                    Button("恢复已忽略项（\(hiddenDismissedCount) 条）") {
                        restoreDismissed()
                    }
                    .font(Theme.labelSmall)
                }
            }
        } header: {
            AppSectionHeader(title: "核查与整理")
        }
    }

    private var summaryText: String {
        let visible = visibleFindings
        if visible.isEmpty {
            return "未发现待处理的档案冲突或伏笔问题。"
        }
        return "待处理 \(visible.count) 项，可逐条确认或执行安全整理。"
    }

    private var findingsSection: some View {
        let visible = visibleFindings
        return Section {
            if report == nil && isAuditing {
                AppStatusLine(kind: .progress, text: "正在扫描设定与伏笔…")
            } else if visible.isEmpty {
                InlineEmptyState(
                    symbol: "checkmark.shield",
                    message: "暂无待处理项。"
                )
            } else {
                ForEach(visible) { finding in
                    findingRow(finding)
                }
            }
        } header: {
            AppSectionHeader(title: "待处理项（\(visible.count)）")
        }
    }

    private func findingRow(_ finding: DreamingFinding) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                StatusPill(
                    text: severityLabel(finding.severity),
                    tone: severityTone(finding.severity)
                )
                StatusPill(text: kindLabel(finding.kind), tone: .neutral)
                Spacer(minLength: 0)
            }

            Text(finding.title)
                .font(Theme.labelEmphasis)
                .foregroundStyle(.primary)

            Text(finding.detail)
                .font(Theme.labelSmall)
                .foregroundStyle(.secondary)

            if let quote = finding.anchor?.quote, !quote.isEmpty {
                Text("依据：「\(quote)」")
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
            }

            findingActions(for: finding)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    @ViewBuilder
    private func findingActions(for finding: DreamingFinding) -> some View {
        let workspace = session.narrativeWorkspace
        let entityID = resolvedEntityID(for: finding)

        HStack(spacing: Theme.Spacing.m) {
            switch finding.kind {
            case .staleBelief:
                if let workspace, NarrativeViewSupport.canSyncLatestFact(for: finding, workspace: workspace) {
                    Button("同步事实") {
                        applyCleanup(findings: [finding], toastMessage: "已同步角色认知")
                    }
                    .tint(Theme.accent)

                    Button("保留信息差") {
                        dismissFinding(finding, toast: "已保留角色信息差")
                    }
                } else {
                    Button("确认现状") {
                        dismissFinding(finding, toast: "已忽略此提示")
                    }
                }

                if let entityID {
                    Spacer(minLength: 0)
                    Button("查看档案") {
                        selectedEntityID = entityID
                    }
                }

            case .entityPageBloat:
                if let liveState, NarrativeViewSupport.isAutoSafeCleanable(finding, in: liveState) {
                    Button("精简档案") {
                        applyCleanup(findings: [finding], toastMessage: "已精简档案")
                    }
                    .tint(Theme.accent)
                }
                Button("忽略") {
                    dismissFinding(finding, toast: "已忽略此提示")
                }
                Spacer(minLength: 0)
                Button("查看档案") {
                    selectedEntityID = finding.targetID
                }

            case .overdueThread:
                if liveState?.threads[finding.targetID]?.state == .pending {
                    Button("标为可回收") {
                        applyCleanup(findings: [finding], toastMessage: "已标为可回收")
                    }
                    .tint(Theme.accent)
                }
                Button("忽略") {
                    dismissFinding(finding, toast: "已忽略此提示")
                }
                Spacer(minLength: 0)
                Button("查看伏笔") {
                    showingThreads = true
                }

            case .ungroundedFact:
                Button("确认保留") {
                    dismissFinding(finding, toast: "已保留该记录")
                }
                if let entityID {
                    Spacer(minLength: 0)
                    Button("查看档案") {
                        selectedEntityID = entityID
                    }
                }
            }
        }
        .font(Theme.labelSmall)
        .buttonStyle(.borderless)
        .padding(.top, Theme.Spacing.xs)
    }

    private func resolvedEntityID(for finding: DreamingFinding) -> String? {
        switch finding.kind {
        case .entityPageBloat:
            return finding.targetID
        case .staleBelief, .ungroundedFact:
            if let characterID = liveState?.epistemicBeliefs[finding.targetID]?.characterID {
                return characterID
            }
            if let range = finding.targetID.range(of: "\u{1F}") {
                return String(finding.targetID[..<range.lowerBound])
            }
            return nil
        case .overdueThread:
            return nil
        }
    }

    private func runAudit() async {
        guard !isAuditing else { return }
        isAuditing = true
        defer { isAuditing = false }
        do {
            report = try await ConsistencyCheckWorkflow.runOfflineDreamingAsync(
                session: session,
                store: store
            )
        } catch {
            guard !Task.isCancelled, !error.isLLMCancellation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func flushPendingSyncs() async {
        guard !isFlushingPending else { return }
        isFlushingPending = true
        defer { isFlushingPending = false }
        do {
            let flushed = try await NarrativeCommitCoordinator.flushPendingSyncs(
                session: session,
                store: store
            )
            store.toast = flushed > 0 ? "已补抽 \(flushed) 幕设定增量" : "暂无可补抽内容"
        } catch {
            guard !Task.isCancelled, !error.isLLMCancellation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func applyCleanup(findings: [DreamingFinding], toastMessage: String?) {
        do {
            let cleaned = try ConsistencyCheckWorkflow.applyDreamingCleanup(
                findings: findings,
                session: session,
                store: store
            )
            if let toastMessage {
                store.toast = cleaned > 0 ? toastMessage : "暂无变更"
            } else {
                store.toast = cleaned > 0 ? "已安全整理 \(cleaned) 项" : "没有可自动整理的内容"
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func dismissFinding(_ finding: DreamingFinding, toast: String) {
        NarrativeViewSupport.dismissAuditFinding(finding.id, projectID: session.project.id)
        dismissedIDs.insert(finding.id)
        store.toast = toast
    }

    private func restoreDismissed() {
        NarrativeViewSupport.clearDismissedAuditFindings(for: session.project.id)
        dismissedIDs.removeAll()
        store.toast = "已恢复全部核查项"
    }

    private func severityLabel(_ severity: DreamingIssueSeverity) -> String {
        switch severity {
        case .high: return "高"
        case .medium: return "中"
        case .low: return "低"
        }
    }

    private func severityTone(_ severity: DreamingIssueSeverity) -> AppTone {
        switch severity {
        case .high: return .danger
        case .medium: return .warning
        case .low: return .neutral
        }
    }

    private func kindLabel(_ kind: DreamingIssueKind) -> String {
        switch kind {
        case .staleBelief: return "认知冲突"
        case .entityPageBloat: return "档案过长"
        case .overdueThread: return "久未回收"
        case .ungroundedFact: return "缺少依据"
        }
    }
}
