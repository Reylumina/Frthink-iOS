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
                    showBranchPill: showBranchPill,
                    alternateBranches: alternateBranches,
                    visibleParentSummary: parentNode?.summary
                )
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
            rows: Array(orderedRows.reversed()),
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
    var externalForkTrigger: Int = 0

    @State private var graph: StoryGraph = StoryGraph.makeInitial()
    @State private var layout: StoryActivePathLayout = StoryActivePathLayout.build(
        graph: StoryGraph.makeInitial()
    )
    @State private var expandedNodeIDs: Set<String> = []
    @State private var showOtherBranches = false
    @State private var pendingCheckoutNode: PlotNode?
    @State private var forkingFromNode: PlotNode?
    @State private var forkBranchName = ""
    @State private var showingAddBeatSheet = false
    @State private var addBeatParentID: String?
    @State private var showingPlantThreadSheet = false
    @State private var errorMessage: String?

    private var liveState: MaterializedNarrativeState? {
        _ = session.narrativeRevision
        return session.narrativeWorkspace?.currentState()
    }

    private var activeThreadCount: Int {
        liveState?.threads.values.filter { !$0.state.isTerminal }.count ?? 0
    }

    private var readyThreadCount: Int {
        liveState?.threads.values.filter { $0.state == .ready }.count ?? 0
    }

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
        .onChange(of: externalForkTrigger) { _, _ in
            if let head = graph.nodes[graph.headNodeID] {
                forkBranchName = ""
                forkingFromNode = head
            }
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
        .alert(
            "新建剧情分支",
            isPresented: Binding.isPresent($forkingFromNode),
            presenting: forkingFromNode
        ) { origin in
            TextField("分支名称（如：夜探支线）", text: $forkBranchName)
            Button("创建分支") {
                forkBranch(from: origin.id, label: forkBranchName)
                forkingFromNode = nil
                forkBranchName = ""
            }
            .disabled(forkBranchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("取消", role: .cancel) {
                forkingFromNode = nil
                forkBranchName = ""
            }
        } message: { origin in
            Text("将在「\(origin.summary.isEmpty ? origin.id : origin.summary)」之后分出一条新支线。")
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
                if let head = graph.nodes[graph.headNodeID] {
                    Button("从当前幕分叉", systemImage: "arrow.triangle.branch") {
                        forkBranchName = ""
                        forkingFromNode = head
                    }
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
                ProspectiveThreadsView(session: session)
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Text("待回收伏笔")
                        .font(Theme.label)
                        .foregroundStyle(.primary)
                    Spacer(minLength: Theme.Spacing.s)
                    if readyThreadCount > 0 {
                        StatusPill(text: "\(readyThreadCount) 可回收", tone: .accent)
                    }
                    Text(activeThreadCount == 0 ? "暂无" : "\(activeThreadCount) 条")
                        .font(Theme.numeric)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: Theme.Layout.rowContentHeight)
            }
        }
    }

    private var timelineSection: some View {
        Section {
            ForEach(Array(layout.rows.enumerated()), id: \.element.id) { index, row in
                nodeRowView(
                    row,
                    isFirst: index == 0,
                    isLast: index == layout.rows.count - 1
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
                title: "当前路径 · \(layout.currentBranchLabel)（\(layout.rows.count) / \(layout.totalNodeCount) 幕）"
            )
        }
    }

    private var otherBranchesSection: some View {
        Section {
            DisclosureGroup("其他分支（\(layout.otherBranchTips.count)）", isExpanded: $showOtherBranches) {
                ForEach(layout.otherBranchTips) { branch in
                    Button {
                        pendingCheckoutNode = branch.tipNode
                    } label: {
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
        }
    }

    private func nodeRowView(
        _ row: StoryActivePathLayout.Row,
        isFirst: Bool,
        isLast: Bool
    ) -> some View {
        let node = row.node
        let isExpanded = expandedNodeIDs.contains(node.id)
        let headNode = graph.nodes[graph.headNodeID]
        let alreadyParentOfHead = headNode?.allParentIDs.contains(node.id) ?? false

        return HStack(alignment: .center, spacing: Theme.Spacing.m) {
            StoryActiveTimelineSlot(
                isFirst: isFirst,
                isLast: isLast,
                isHead: row.isHead,
                hasFork: !row.alternateBranches.isEmpty
            )

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
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
                    Menu {
                        if !row.isHead {
                            Button("切到这里继续写") {
                                pendingCheckoutNode = node
                            }
                        }
                        Button("在此幕后规划下一幕") {
                            addBeatParentID = node.id
                            showingAddBeatSheet = true
                        }
                        Button("从这里新建分支") {
                            forkBranchName = ""
                            forkingFromNode = node
                        }
                        if !row.isHead && !alreadyParentOfHead {
                            Button("并入当前分支") {
                                mergeIntoHead(from: node.id)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(Theme.label)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("节点操作")
                }

                Button {
                    if isExpanded {
                        expandedNodeIDs.remove(node.id)
                    } else {
                        expandedNodeIDs.insert(node.id)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(node.summary.isEmpty ? "初始节点" : node.summary)
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

                if !row.alternateBranches.isEmpty {
                    forkSwitcherPill(for: row)
                }

                if isExpanded {
                    nodeCausalDetails(node, parentSummary: row.visibleParentSummary)
                }
            }
            .padding(.vertical, Theme.Spacing.s)
        }
    }

    private func forkSwitcherPill(for row: StoryActivePathLayout.Row) -> some View {
        let count = row.alternateBranches.count
        let title = row.isHead
            ? "向下延伸 \(count) 条剧情"
            : "另有 \(count) 条分支"

        return Menu {
            ForEach(row.alternateBranches) { branch in
                Button {
                    checkoutNode(branch.tipNode.id)
                } label: {
                    let tipSummary = branch.tipNode.summary.isEmpty
                        ? branch.tipNode.id
                        : branch.tipNode.summary
                    Text("\(branch.branchLabel)（\(branch.beatCount) 幕）· \(tipSummary)")
                }
            }
            Divider()
            Button("从此处新建分支") {
                forkBranchName = ""
                forkingFromNode = row.node
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

    @ViewBuilder
    private func nodeCausalDetails(_ node: PlotNode, parentSummary: String?) -> some View {
        let impacted = graph.downstreamImpactedNodes(of: node.id)
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let parentSummary, !parentSummary.isEmpty {
                Text("承接自：\(parentSummary)")
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
            }
            if !impacted.isEmpty {
                let names = impacted.prefix(3).map { $0.summary.isEmpty ? $0.id : $0.summary }
                Text("后续关联：影响 \(impacted.count) 幕（\(names.joined(separator: " → "))）")
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

    private func reloadGraph() {
        let workspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        graph = workspace.storyGraph
        layout = StoryActivePathLayout.build(graph: graph)
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

    private func forkBranch(from nodeID: String, label: String) {
        do {
            try session.forkNarrativeBranch(
                from: nodeID,
                label: label,
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            reloadGraph()
            store.toast = "已创建分支：\(label.trimmingCharacters(in: .whitespacesAndNewlines))"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func mergeIntoHead(from parentID: String) {
        do {
            try session.addNarrativeCausalEdge(
                from: parentID,
                to: graph.headNodeID,
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            reloadGraph()
            store.toast = "已并入当前分支"
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
