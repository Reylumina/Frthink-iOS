// 剧情线视图：Focus + Context 线性激活主路径 + 分叉点内联切换 + 伏笔入口。

import Foundation
import SwiftUI

/// Focus + Context 线性主路径布局器：只展开当前激活分支，并在分叉节点汇总可用支线入口。
struct StoryActivePathLayout {

    struct BranchOption: Identifiable {
        let id: String
        let branchLabel: String
        let tipNode: PlotNode
        let beatCount: Int
    }

    struct Row: Identifiable {
        let id: String
        let node: PlotNode
        let isHead: Bool
        let isFirst: Bool
        let isLast: Bool
        let showBranchPill: Bool
        let alternateBranches: [BranchOption]
        let visibleParentSummary: String?
    }

    let rows: [Row]
    let otherBranchTips: [BranchOption]
    let totalNodeCount: Int
    let currentBranchLabel: String

    static func build(graph: StoryGraph) -> StoryActivePathLayout {
        var spineReversed: [PlotNode] = []
        var cursorID: String? = graph.headNodeID
        var visitedSpine: Set<String> = []
        while let id = cursorID, visitedSpine.insert(id).inserted, let node = graph.nodes[id] {
            spineReversed.append(node)
            cursorID = node.parentID
        }
        let activeLineage: [PlotNode] = spineReversed.reversed()

        let activeIDs = Set(activeLineage.map(\.id))

        var childrenByParent: [String: [PlotNode]] = [:]
        for node in graph.nodes.values {
            guard let parentID = node.parentID, graph.nodes[parentID] != nil else { continue }
            childrenByParent[parentID, default: []].append(node)
        }
        for parentID in childrenByParent.keys {
            childrenByParent[parentID]?.sort(by: orderedBefore)
        }

        func resolveBranchOption(from startNode: PlotNode) -> BranchOption {
            var current = startNode
            var beatCount = 1
            var visited: Set<String> = [startNode.id]
            while let candidates = childrenByParent[current.id], !candidates.isEmpty {
                let preferred = candidates.last { $0.branchLabel == current.branchLabel }
                    ?? candidates.last
                guard let next = preferred, visited.insert(next.id).inserted else { break }
                current = next
                beatCount += 1
            }
            let cleanLabel = startNode.branchLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return BranchOption(
                id: "\(startNode.id)->\(current.id)",
                branchLabel: cleanLabel.isEmpty ? "支线" : cleanLabel,
                tipNode: current,
                beatCount: beatCount
            )
        }

        var orderedRows: [Row] = []
        orderedRows.reserveCapacity(activeLineage.count)

        for (index, node) in activeLineage.enumerated() {
            let nextActiveID = (index + 1 < activeLineage.count) ? activeLineage[index + 1].id : nil
            let directChildren = childrenByParent[node.id] ?? []
            let alternateChildren = directChildren.filter { $0.id != nextActiveID }
            let alternateBranches = alternateChildren.map(resolveBranchOption(from:))

            let parentNode = node.parentID.flatMap { graph.nodes[$0] }
            let parentLabel = parentNode?.branchLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let nodeLabel = node.branchLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let showBranchPill = node.id != graph.rootNodeID
                && !nodeLabel.isEmpty
                && nodeLabel != parentLabel

            orderedRows.append(
                Row(
                    id: node.id,
                    node: node,
                    isHead: node.id == graph.headNodeID,
                    isFirst: false,
                    isLast: false,
                    showBranchPill: showBranchPill,
                    alternateBranches: alternateBranches,
                    visibleParentSummary: parentNode?.summary
                )
            )
        }

        let reversedRows = Array(orderedRows.reversed())
        let finalRows: [Row] = reversedRows.enumerated().map { idx, row in
            Row(
                id: row.id,
                node: row.node,
                isHead: row.isHead,
                isFirst: idx == 0,
                isLast: idx == reversedRows.count - 1,
                showBranchPill: row.showBranchPill,
                alternateBranches: row.alternateBranches,
                visibleParentSummary: row.visibleParentSummary
            )
        }

        let leaves = graph.nodes.values
            .filter { (childrenByParent[$0.id] ?? []).isEmpty && !activeIDs.contains($0.id) }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id > rhs.id
            }

        let otherTips: [BranchOption] = leaves.map { leaf in
            var count = 1
            var cursor = leaf.parentID
            var visited: Set<String> = [leaf.id]
            while let parentID = cursor,
                  !activeIDs.contains(parentID),
                  visited.insert(parentID).inserted,
                  let parent = graph.nodes[parentID] {
                count += 1
                cursor = parent.parentID
            }
            let label = leaf.branchLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            return BranchOption(
                id: leaf.id,
                branchLabel: label.isEmpty ? "支线" : label,
                tipNode: leaf,
                beatCount: count
            )
        }

        let headLabel = graph.nodes[graph.headNodeID]?.branchLabel
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "主线"
        return StoryActivePathLayout(
            rows: finalRows,
            otherBranchTips: otherTips,
            totalNodeCount: graph.nodes.count,
            currentBranchLabel: headLabel.isEmpty ? "主线" : headLabel
        )
    }

    private static func orderedBefore(_ lhs: PlotNode, _ rhs: PlotNode) -> Bool {
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }
}

struct StoryGraphView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession
    var embeddedInWorld: Bool = false
    var externalBeatTrigger: Int = 0
    var externalThreadTrigger: Int = 0

    private struct SummaryCounts {
        var activeThreadCount = 0
        var readyThreadCount = 0
        var ongoingEventCount = 0
        var resolvedEventCount = 0
        var eventArcCount = 0
    }

    @State private var graph: StoryGraph = StoryGraph.makeInitial()
    @State private var layout: StoryActivePathLayout = StoryActivePathLayout.build(
        graph: StoryGraph.makeInitial()
    )
    @State private var summaryCounts = SummaryCounts()
    @State private var expandedNodeIDs: Set<String> = []
    @State private var showOtherBranches = false
    @State private var pendingCheckoutNode: PlotNode?
    @State private var showingAddBeatSheet = false
    @State private var addBeatParentID: String?
    @State private var showingPlantThreadSheet = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if embeddedInWorld {
                timelineList
            } else {
                timelineList
                    .navigationTitle("剧情线")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { standaloneToolbar }
            }
        }
        .groupedPageBackground()
        .sensoryFeedback(.selection, trigger: graph.headNodeID) { _, _ in
            store.settings.hapticsEnabled
        }
        .task(id: session.narrativeRevision) {
            reloadGraph()
        }
        .onChange(of: externalBeatTrigger) { _, _ in
            addBeatParentID = nil
            showingAddBeatSheet = true
        }
        .onChange(of: externalThreadTrigger) { _, _ in
            showingPlantThreadSheet = true
        }
        .sheet(isPresented: $showingAddBeatSheet) {
            AddPlotBeatSheet(
                session: session,
                parentNodeID: addBeatParentID
            )
        }
        .sheet(isPresented: $showingPlantThreadSheet) {
            PlantThreadSheet(session: session)
        }
        .narrativeErrorAlert($errorMessage, title: "操作失败")
        .alert(
            "切换到此处继续写？",
            isPresented: Binding.isPresent($pendingCheckoutNode),
            presenting: pendingCheckoutNode
        ) { target in
            Button("切换至此") {
                checkoutNode(target.id)
                pendingCheckoutNode = nil
            }
            Button("取消", role: .cancel) {
                pendingCheckoutNode = nil
            }
        } message: { target in
            Text("后续续写将承接「\(target.summary.isEmpty ? target.id : target.summary)」，不改动现有正文。")
        }
    }

    private var timelineList: some View {
        List {
            threadsSummarySection
            timelineSection
            if !layout.otherBranchTips.isEmpty {
                otherBranchesSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    @ToolbarContentBuilder
    private var standaloneToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("规划下一幕", systemImage: "plus.rectangle.on.rectangle") {
                    addBeatParentID = nil
                    showingAddBeatSheet = true
                }
                Button("新建伏笔", systemImage: "flag") {
                    showingPlantThreadSheet = true
                }
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("新增剧情或伏笔")
        }
    }

    private var threadsSummarySection: some View {
        Section {
            NavigationLink {
                EpisodicEventsView(session: session)
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Text("关键事件")
                        .font(Theme.label)
                        .foregroundStyle(.primary)
                    Spacer(minLength: Theme.Spacing.s)
                    if summaryCounts.eventArcCount > 0 {
                        StatusPill(text: "\(summaryCounts.eventArcCount) 条故事线", tone: .neutral)
                    }
                    Text(
                        summaryCounts.ongoingEventCount == 0 && summaryCounts.resolvedEventCount == 0
                            ? "暂无"
                            : "进行中 \(summaryCounts.ongoingEventCount)，已完结 \(summaryCounts.resolvedEventCount)"
                    )
                    .font(Theme.numericSmall)
                    .foregroundStyle(.secondary)
                }
                .frame(minHeight: Theme.Layout.rowContentHeight)
            }

            NavigationLink {
                ProspectiveThreadsView(session: session)
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Text("待回收伏笔")
                        .font(Theme.label)
                        .foregroundStyle(.primary)
                    Spacer(minLength: Theme.Spacing.s)
                    if summaryCounts.readyThreadCount > 0 {
                        StatusPill(text: "\(summaryCounts.readyThreadCount) 待回收", tone: .accent)
                    }
                    Text(summaryCounts.activeThreadCount == 0 ? "暂无" : "\(summaryCounts.activeThreadCount) 条")
                        .font(Theme.numeric)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: Theme.Layout.rowContentHeight)
            }
        }
    }

    private var timelineSection: some View {
        Section {
            ForEach(layout.rows) { row in
                StoryActiveNodeRow(
                    row: row,
                    isExpanded: expandedNodeIDs.contains(row.node.id),
                    impactedNodes: expandedNodeIDs.contains(row.node.id)
                        ? graph.downstreamImpactedNodes(of: row.node.id)
                        : [],
                    onToggleExpand: { toggleExpanded(row.node.id) },
                    onCheckout: { pendingCheckoutNode = row.node },
                    onCheckoutBranchTip: { checkoutNode($0) },
                    onPlanBeatAfter: {
                        addBeatParentID = row.node.id
                        showingAddBeatSheet = true
                    }
                )
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: Theme.Spacing.l,
                    bottom: 0,
                    trailing: Theme.Spacing.l
                ))
            }
        } header: {
            AppSectionHeader(
                title: "当前路径：\(layout.currentBranchLabel)（\(layout.rows.count) / \(layout.totalNodeCount) 幕）"
            )
        }
    }

    private func toggleExpanded(_ nodeID: String) {
        if expandedNodeIDs.contains(nodeID) {
            expandedNodeIDs.remove(nodeID)
        } else {
            expandedNodeIDs.insert(nodeID)
        }
    }

    private var otherBranchesSection: some View {
        Section {
            DisclosureGroup("其他分支（\(layout.otherBranchTips.count)）", isExpanded: $showOtherBranches) {
                ForEach(layout.otherBranchTips) { branch in
                    StoryBranchTipRow(branch: branch) {
                        pendingCheckoutNode = branch.tipNode
                    }
                }
            }
        }
    }

    private func reloadGraph() {
        let workspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        graph = workspace.storyGraph
        layout = StoryActivePathLayout.build(graph: graph)

        let state = workspace.currentState()
        var counts = SummaryCounts()
        for thread in state.threads.values where !thread.state.isTerminal {
            counts.activeThreadCount += 1
            if thread.state == .ready || thread.state == .enacted {
                counts.readyThreadCount += 1
            }
        }
        var arcs = Set<String>()
        for event in state.episodicEvents.values {
            if event.status == .ongoing {
                counts.ongoingEventCount += 1
            } else {
                counts.resolvedEventCount += 1
            }
            let arc = event.arcTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            if !arc.isEmpty {
                arcs.insert(arc)
            }
        }
        counts.eventArcCount = arcs.count
        summaryCounts = counts
    }

    private func checkoutNode(_ nodeID: String) {
        do {
            try session.checkoutNarrativeNode(
                nodeID,
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            reloadGraph()
            store.toast = "已切换当前进度"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 规划下一幕弹窗：收拢输入体验，避免常驻占屏。
private struct AddPlotBeatSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: ProjectSession
    let parentNodeID: String?

    @State private var summaryDraft = ""
    @State private var errorMessage: String?

    private var trimmedSummary: String {
        summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("规划下一幕内容（如：码头当面拆穿假信）", text: $summaryDraft, axis: .vertical)
                        .font(Theme.label)
                        .lineLimit(2...6)
                } header: {
                    AppSectionHeader(title: "幕次纲要")
                }
            }
            .scrollContentBackground(.hidden)
            .groupedPageBackground()
            .navigationTitle("规划下一幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton(title: "取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton(title: "添加", isEnabled: !trimmedSummary.isEmpty) {
                        saveBeat()
                    }
                }
            }
            .narrativeErrorAlert($errorMessage)
        }
    }

    private func saveBeat() {
        guard !trimmedSummary.isEmpty else { return }
        do {
            try session.addPlotBeat(
                summary: trimmedSummary,
                parentID: parentNodeID,
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            store.toast = "已添加剧情"
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// 单轨时间轴节点绘制：展示当前路径顺序、HEAD 状态与分叉点提示，替代拥挤的多轨彩色网线。
private struct StoryActiveTimelineSlot: View {
    let isFirst: Bool
    let isLast: Bool
    let isHead: Bool
    let hasFork: Bool

    @ScaledMetric(relativeTo: .body) private var slotWidth: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var dotRadius: CGFloat = 4

    var body: some View {
        Color.clear
            .frame(width: slotWidth)
            .background {
                Canvas { context, size in
                    let centerX = size.width * 0.5
                    let midY = size.height * 0.5

                    if !isFirst {
                        var topLine = Path()
                        topLine.move(to: CGPoint(x: centerX, y: 0))
                        topLine.addLine(to: CGPoint(x: centerX, y: midY))
                        context.stroke(topLine, with: .color(Theme.separator), lineWidth: 2)
                    }

                    if !isLast {
                        var bottomLine = Path()
                        bottomLine.move(to: CGPoint(x: centerX, y: midY))
                        bottomLine.addLine(to: CGPoint(x: centerX, y: size.height))
                        context.stroke(bottomLine, with: .color(Theme.separator), lineWidth: 2)
                    }

                    let circleRect = CGRect(
                        x: centerX - dotRadius,
                        y: midY - dotRadius,
                        width: dotRadius * 2,
                        height: dotRadius * 2
                    )
                    let circle = Path(ellipseIn: circleRect)
                    if isHead {
                        context.fill(circle, with: .color(Theme.accent))
                        let ringRect = circleRect.insetBy(dx: -3, dy: -3)
                        context.stroke(
                            Path(ellipseIn: ringRect),
                            with: .color(Theme.accent),
                            lineWidth: 1.5
                        )
                    } else if hasFork {
                        context.fill(circle, with: .color(Theme.groupedCard))
                        context.stroke(circle, with: .color(Theme.accent), lineWidth: 2)
                    } else {
                        context.fill(circle, with: .color(Theme.groupedCard))
                        context.stroke(circle, with: .color(AppTone.neutral.color), lineWidth: 2)
                    }
                }
            }
    }
}

private struct StoryBranchTipRow: View {
    let branch: StoryActivePathLayout.BranchOption
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.s) {
                    StatusPill(text: branch.branchLabel, tone: .neutral)
                    Text("分支共 \(branch.beatCount) 幕")
                        .font(Theme.numericSmall)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text("切换")
                        .font(Theme.labelSmall)
                        .foregroundStyle(Theme.accent)
                }
                Text(branch.tipNode.summary.isEmpty ? branch.tipNode.id : branch.tipNode.summary)
                    .font(Theme.labelSmall)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct StoryActiveNodeRow: View {
    let row: StoryActivePathLayout.Row
    let isExpanded: Bool
    let impactedNodes: [PlotNode]
    let onToggleExpand: () -> Void
    let onCheckout: () -> Void
    let onCheckoutBranchTip: (String) -> Void
    let onPlanBeatAfter: () -> Void

    private var node: PlotNode { row.node }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.m) {
            StoryActiveTimelineSlot(
                isFirst: row.isFirst,
                isLast: row.isLast,
                isHead: row.isHead,
                hasFork: !row.alternateBranches.isEmpty
            )

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                rowHeader
                summaryButton
                if !row.alternateBranches.isEmpty {
                    forkSwitcherPill
                }
                if isExpanded {
                    causalDetails
                }
            }
            .padding(.vertical, Theme.Spacing.s)
        }
    }

    private var rowHeader: some View {
        HStack(spacing: Theme.Spacing.s) {
            if row.isHead {
                StatusPill(text: "当前进度", tone: .accent)
            }
            if row.showBranchPill {
                StatusPill(text: node.branchLabel, tone: .neutral)
            }
            if !node.secondaryCausalParentIDs.isEmpty {
                StatusPill(text: "合流", tone: .success)
            }
            Spacer(minLength: 0)
            actionMenu
        }
    }

    private var actionMenu: some View {
        Menu {
            if !row.isHead {
                Button("切到这里继续写", action: onCheckout)
            }
            Button("在此幕后规划下一幕", action: onPlanBeatAfter)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(Theme.label)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("节点操作")
    }

    private var summaryButton: some View {
        Button(action: onToggleExpand) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(node.summary.isEmpty ? "故事起点" : node.summary)
                    .font(Theme.label)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                if let quote = node.manuscriptAnchor?.quote, !quote.isEmpty {
                    Text("「\(quote)」")
                        .font(Theme.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var forkSwitcherPill: some View {
        let count = row.alternateBranches.count
        let title = row.isHead ? "向下延伸 \(count) 条剧情" : "另有 \(count) 条分支"
        return Menu {
            ForEach(row.alternateBranches) { branch in
                let tipSummary = branch.tipNode.summary.isEmpty ? branch.tipNode.id : branch.tipNode.summary
                Button("\(branch.branchLabel)（\(branch.beatCount) 幕）：\(tipSummary)") {
                    onCheckoutBranchTip(branch.tipNode.id)
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "arrow.triangle.branch")
                Text(title)
                Image(systemName: "chevron.down")
            }
            .font(Theme.badge)
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Capsule().fill(Theme.accentSoft))
        }
        .buttonStyle(.borderless)
    }

    private var causalDetails: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let parentSummary = row.visibleParentSummary, !parentSummary.isEmpty {
                Text("承接自：\(parentSummary)")
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
            }
            if !impactedNodes.isEmpty {
                let names = impactedNodes.prefix(3).map { $0.summary.isEmpty ? $0.id : $0.summary }
                Text("后续关联：影响 \(impactedNodes.count) 幕（\(names.joined(separator: " → "))）")
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
            } else {
                Text("后续关联：已是当前分支末端")
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, Theme.Spacing.xs)
    }
}
