// 剧情线视图：展示剧情进度、分支与合流关系，以及后续关联幕提示。

import Foundation
import SwiftUI

/// 分支轨道纯计算布局器：将纯情节有向无环图映射为适合竖屏浏览的多轨道行布局。
struct StoryGraphRailLayout {

    struct Row: Identifiable {
        let id: String
        let node: PlotNode
        let lane: Int
        let laneCount: Int
        let isHead: Bool
        let isOnActiveLineage: Bool
        let passThroughLanes: Set<Int>
        let incomingAboveLanes: Set<Int>
        let outgoingBelowLanes: Set<Int>
        let branchToParentLane: Int?
        let mergeParentLanes: [Int]
        let visibleParentSummary: String?
    }

    let rows: [Row]
    let totalNodeCount: Int

    static func build(graph: StoryGraph) -> StoryGraphRailLayout {
        let activeLineageIDs = Set(
            (try? graph.lineage(to: graph.headNodeID).map(\.id)) ?? [graph.headNodeID]
        )

        let depths = computeDepths(in: graph)
        let sortedNodes = graph.nodes.values.sorted { lhs, rhs in
            let leftDepth = depths[lhs.id] ?? 0
            let rightDepth = depths[rhs.id] ?? 0
            if leftDepth != rightDepth { return leftDepth > rightDepth }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.id > rhs.id
        }

        var rowIndexByID: [String: Int] = [:]
        for (idx, node) in sortedNodes.enumerated() {
            rowIndexByID[node.id] = idx
        }

        let rootLabel = graph.nodes[graph.rootNodeID]?.branchLabel ?? "主线"
        var laneByBranch: [String: Int] = [rootLabel: 0]
        var nextLane = 1
        for node in sortedNodes.reversed() {
            let label = node.branchLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = label.isEmpty ? rootLabel : label
            if laneByBranch[key] == nil {
                laneByBranch[key] = nextLane
                nextLane += 1
            }
        }
        let maxDisplayLanes = min(max(1, nextLane), 4)
        let laneForNode: (PlotNode) -> Int = { node in
            let label = node.branchLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = laneByBranch[label.isEmpty ? rootLabel : label] ?? 0
            if raw == 0 { return 0 }
            guard maxDisplayLanes > 1 else { return 0 }
            return 1 + ((raw - 1) % (maxDisplayLanes - 1))
        }

        var passThrough: [Int: Set<Int>] = [:]
        var incomingAbove: [Int: Set<Int>] = [:]
        var outgoingBelow: [Int: Set<Int>] = [:]
        var mergeLanesByID: [String: [Int]] = [:]

        for (childIdx, node) in sortedNodes.enumerated() {
            let childLane = laneForNode(node)
            if let parentID = node.parentID,
               let parentIdx = rowIndexByID[parentID],
               let parentNode = graph.nodes[parentID] {
                let parentLane = laneForNode(parentNode)
                if parentIdx > childIdx {
                    incomingAbove[parentIdx, default: []].insert(parentLane)
                    if childLane == parentLane {
                        outgoingBelow[childIdx, default: []].insert(childLane)
                    }
                    if parentIdx - childIdx > 1 {
                        for k in (childIdx + 1)..<parentIdx {
                            passThrough[k, default: []].insert(parentLane)
                        }
                    }
                }
            }

            var mergeLanes: [Int] = []
            for secID in node.secondaryCausalParentIDs {
                guard let secIdx = rowIndexByID[secID],
                      let secNode = graph.nodes[secID] else { continue }
                let secLane = laneForNode(secNode)
                mergeLanes.append(secLane)
                if secIdx > childIdx {
                    incomingAbove[secIdx, default: []].insert(secLane)
                    if secIdx - childIdx > 1 {
                        for k in (childIdx + 1)..<secIdx {
                            passThrough[k, default: []].insert(secLane)
                        }
                    }
                }
            }
            if !mergeLanes.isEmpty {
                mergeLanesByID[node.id] = mergeLanes
            }
        }

        let rows: [Row] = sortedNodes.enumerated().map { idx, node in
            let lane = laneForNode(node)
            let parentNode = node.parentID.flatMap { graph.nodes[$0] }
            let branchParentLane: Int? = parentNode.flatMap { pNode in
                let pLane = laneForNode(pNode)
                return pLane == lane ? nil : pLane
            }

            return Row(
                id: node.id,
                node: node,
                lane: lane,
                laneCount: maxDisplayLanes,
                isHead: node.id == graph.headNodeID,
                isOnActiveLineage: activeLineageIDs.contains(node.id),
                passThroughLanes: passThrough[idx] ?? [],
                incomingAboveLanes: incomingAbove[idx] ?? [],
                outgoingBelowLanes: outgoingBelow[idx] ?? [],
                branchToParentLane: branchParentLane,
                mergeParentLanes: mergeLanesByID[node.id] ?? [],
                visibleParentSummary: parentNode?.summary
            )
        }

        return StoryGraphRailLayout(
            rows: rows,
            totalNodeCount: graph.nodes.count
        )
    }

    private static func computeDepths(in graph: StoryGraph) -> [String: Int] {
        var children: [String: [String]] = [:]
        for node in graph.nodes.values {
            for parentID in node.allParentIDs {
                children[parentID, default: []].append(node.id)
            }
        }
        var depthByID: [String: Int] = [graph.rootNodeID: 0]
        var queue: [String] = [graph.rootNodeID]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            let nextDepth = (depthByID[current] ?? 0) + 1
            for childID in children[current] ?? [] {
                if nextDepth > (depthByID[childID] ?? -1) {
                    depthByID[childID] = nextDepth
                    queue.append(childID)
                }
            }
        }
        return depthByID
    }
}

struct StoryGraphView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession

    @State private var graph: StoryGraph = StoryGraph.makeInitial()
    @State private var layout: StoryGraphRailLayout = StoryGraphRailLayout.build(
        graph: StoryGraph.makeInitial()
    )
    @State private var expandedNodeIDs: Set<String> = []
    @State private var pendingCheckoutNode: PlotNode?
    @State private var forkingFromNode: PlotNode?
    @State private var forkBranchName = ""
    @State private var newBeatSummary = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            planBeatSection
            nodesSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle("剧情线")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.narrativeRevision) {
            reloadGraph()
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
            Text("后续续写将承接「\(target.summary.isEmpty ? target.id : target.summary)」继续推进，不会修改现有正文和规则。")
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

    private var planBeatSection: some View {
        Section {
            AppValueRow(
                title: "当前位置",
                value: graph.nodes[graph.headNodeID]?.summary ?? graph.headNodeID
            )
            TextField("规划下一幕（如：码头当面拆穿假信）", text: $newBeatSummary)
                .font(Theme.label)
            Button("添加一幕") {
                addPlotBeat()
            }
            .disabled(newBeatSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            AppSectionHeader(title: "剧情进度（共 \(layout.totalNodeCount) 幕）")
        }
    }

    private var nodesSection: some View {
        Section {
            ForEach(layout.rows) { row in
                nodeRowView(row)
                    .listRowInsets(EdgeInsets(
                        top: 0,
                        leading: Theme.Spacing.l,
                        bottom: 0,
                        trailing: Theme.Spacing.l
                    ))
            }
        } header: {
            AppSectionHeader(title: "脉络与分支")
        }
    }

    private func nodeRowView(_ row: StoryGraphRailLayout.Row) -> some View {
        let node = row.node
        let isExpanded = expandedNodeIDs.contains(node.id)
        let headNode = graph.nodes[graph.headNodeID]
        let alreadyParentOfHead = headNode?.allParentIDs.contains(node.id) ?? false

        return HStack(alignment: .center, spacing: Theme.Spacing.m) {
            StoryGraphRailSlot(row: row)

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.s) {
                    StatusPill(
                        text: node.branchLabel,
                        tone: row.isHead ? .accent : (row.isOnActiveLineage ? .success : .neutral)
                    )
                    if row.isHead {
                        StatusPill(text: "当前", tone: .accent)
                    }
                    if !node.secondaryCausalParentIDs.isEmpty {
                        StatusPill(text: "合流", tone: .success)
                    }
                    Spacer(minLength: 0)
                    Menu("操作") {
                        if !row.isHead {
                            Button("切到这里继续写") {
                                pendingCheckoutNode = node
                            }
                        }
                        Button("从这里分叉") {
                            forkBranchName = ""
                            forkingFromNode = node
                        }
                        if !row.isHead && !alreadyParentOfHead {
                            Button("并入当前线") {
                                mergeIntoHead(from: node.id)
                            }
                        }
                    }
                    .font(Theme.labelSmall)
                }

                Button {
                    if isExpanded {
                        expandedNodeIDs.remove(node.id)
                    } else {
                        expandedNodeIDs.insert(node.id)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(node.summary.isEmpty ? node.id : node.summary)
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

                if isExpanded {
                    nodeCausalDetails(node, parentSummary: row.visibleParentSummary)
                }
            }
            .padding(.vertical, Theme.Spacing.s)
        }
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
                Text("后续关联：已是最新一幕")
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
        layout = StoryGraphRailLayout.build(graph: graph)
    }

    private func addPlotBeat() {
        let clean = newBeatSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        do {
            try session.addPlotBeat(
                summary: clean,
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            newBeatSummary = ""
            reloadGraph()
            store.toast = "已添加剧情"
        } catch {
            errorMessage = error.localizedDescription
        }
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
            store.toast = "已并入当前剧情线"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct StoryGraphRailSlot: View {
    let row: StoryGraphRailLayout.Row
    @ScaledMetric(relativeTo: .body) private var laneWidth: CGFloat = 14

    var body: some View {
        let count = max(1, row.laneCount)
        let width = CGFloat(count) * laneWidth
        Color.clear
            .frame(width: width)
            .background {
                StoryGraphRailView(row: row)
            }
    }
}

private struct StoryGraphRailView: View {
    let row: StoryGraphRailLayout.Row

    @ScaledMetric(relativeTo: .body) private var nodeRadius: CGFloat = 4

    private let railColors: [Color] = [
        .accentColor,
        .orange,
        .green,
        .indigo,
    ]

    var body: some View {
        let count = max(1, row.laneCount)
        Canvas { context, size in
            let midY = size.height * 0.5
            let xForLane: (Int) -> CGFloat = { lane in
                (CGFloat(lane) + 0.5) * (size.width / CGFloat(count))
            }

            for lane in row.passThroughLanes {
                var path = Path()
                let x = xForLane(lane)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(color(for: lane).opacity(0.45)), lineWidth: 2)
            }

            for lane in row.incomingAboveLanes {
                var path = Path()
                let x = xForLane(lane)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: midY))
                context.stroke(path, with: .color(color(for: lane)), lineWidth: 2)
            }

            for lane in row.outgoingBelowLanes {
                var path = Path()
                let x = xForLane(lane)
                path.move(to: CGPoint(x: x, y: midY))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(color(for: lane)), lineWidth: 2)
            }

            let centerX = xForLane(row.lane)
            if let parentLane = row.branchToParentLane {
                let targetX = xForLane(parentLane)
                var curve = Path()
                curve.move(to: CGPoint(x: centerX, y: midY))
                curve.addCurve(
                    to: CGPoint(x: targetX, y: size.height),
                    control1: CGPoint(x: centerX, y: size.height * 0.85),
                    control2: CGPoint(x: targetX, y: midY)
                )
                context.stroke(curve, with: .color(color(for: row.lane)), lineWidth: 2)
            }

            for mergeLane in row.mergeParentLanes {
                let targetX = xForLane(mergeLane)
                var curve = Path()
                curve.move(to: CGPoint(x: centerX, y: midY))
                curve.addCurve(
                    to: CGPoint(x: targetX, y: size.height),
                    control1: CGPoint(x: centerX, y: size.height * 0.85),
                    control2: CGPoint(x: targetX, y: midY)
                )
                context.stroke(
                    curve,
                    with: .color(color(for: mergeLane).opacity(0.75)),
                    style: StrokeStyle(lineWidth: 2, dash: [4, 3])
                )
            }

            let circleRect = CGRect(
                x: centerX - nodeRadius,
                y: midY - nodeRadius,
                width: nodeRadius * 2,
                height: nodeRadius * 2
            )
            let circle = Path(ellipseIn: circleRect)
            let nodeColor = color(for: row.lane)
            if row.isOnActiveLineage || row.isHead {
                context.fill(circle, with: .color(nodeColor))
            } else {
                context.fill(circle, with: .color(Theme.groupedCard))
                context.stroke(circle, with: .color(nodeColor), lineWidth: 2)
            }

            if row.isHead {
                let ringRect = circleRect.insetBy(dx: -3, dy: -3)
                context.stroke(
                    Path(ellipseIn: ringRect),
                    with: .color(nodeColor),
                    lineWidth: 1.5
                )
            }
        }
    }

    private func color(for lane: Int) -> Color {
        railColors[abs(lane) % railColors.count]
    }
}
