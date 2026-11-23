import Foundation

/// 剧情有向无环图（DAG）结构校验与节点寻址错误。
enum StoryGraphError: Error, LocalizedError, Equatable {
    case missingRoot
    case duplicateNodeID(String)
    case missingParent(nodeID: String, parentID: String)
    case cycleDetected(nodeID: String, ancestorID: String)
    case nodeNotFound(String)

    var errorDescription: String? {
        switch self {
        case .missingRoot:
            return "剧情图缺少根节点"
        case .duplicateNodeID(let id):
            return "剧情节点 ID 重复：\(id)"
        case .missingParent(let nodeID, let parentID):
            return "剧情节点 \(nodeID) 引用了不存在的父节点 \(parentID)"
        case .cycleDetected(let nodeID, let ancestorID):
            return "检测到因果环（\(nodeID) -> \(ancestorID)），已拒绝写入"
        case .nodeNotFound(let id):
            return "剧情节点不存在：\(id)"
        }
    }
}

/// 剧情分支节点：记录因果父节点、对应正文位置与单步状态增量，支持任意位置回溯与分叉。
struct PlotNode: Identifiable, Codable, Hashable {
    var id: String
    var parentID: String?
    var secondaryCausalParentIDs: [String]
    var branchLabel: String
    var summary: String
    var manuscriptAnchor: TextSpanAnchor?
    var sourceMessageID: String?
    var delta: PlotNodeDelta
    var createdAt: Date

    var allParentIDs: [String] {
        var result: [String] = []
        if let parentID { result.append(parentID) }
        for extra in secondaryCausalParentIDs where !result.contains(extra) {
            result.append(extra)
        }
        return result
    }

    init(
        id: String = UUID().uuidString,
        parentID: String? = nil,
        secondaryCausalParentIDs: [String] = [],
        branchLabel: String = "主线",
        summary: String = "",
        manuscriptAnchor: TextSpanAnchor? = nil,
        sourceMessageID: String? = nil,
        delta: PlotNodeDelta = PlotNodeDelta(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.parentID = parentID
        self.secondaryCausalParentIDs = secondaryCausalParentIDs
        self.branchLabel = branchLabel
        self.summary = summary
        self.manuscriptAnchor = manuscriptAnchor
        self.sourceMessageID = sourceMessageID
        self.delta = delta
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        parentID = try? c.decodeIfPresent(String.self, forKey: .parentID)
        secondaryCausalParentIDs =
            (try? c.decode([String].self, forKey: .secondaryCausalParentIDs)) ?? []
        branchLabel = (try? c.decode(String.self, forKey: .branchLabel)) ?? "主线"
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        manuscriptAnchor = try? c.decodeIfPresent(TextSpanAnchor.self, forKey: .manuscriptAnchor)
        sourceMessageID = try? c.decodeIfPresent(String.self, forKey: .sourceMessageID)
        delta = (try? c.decode(PlotNodeDelta.self, forKey: .delta)) ?? PlotNodeDelta()
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }
}

/// 按需缓存的节点重放快照，缩短长分支从根节点重演的计算路径。
struct ReplayCheckpoint: Codable, Hashable {
    var nodeID: String
    var state: MaterializedNarrativeState
    var createdAt: Date

    init(
        nodeID: String,
        state: MaterializedNarrativeState,
        createdAt: Date = Date()
    ) {
        self.nodeID = nodeID
        self.state = state
        self.createdAt = createdAt
    }
}

/// 分支剧情有向无环图：管理平行分支拓扑、强制因果无环并提供确定性状态重放。
struct StoryGraph: Codable, Hashable {
    var rootNodeID: String
    var headNodeID: String
    var nodes: [String: PlotNode]
    var checkpoints: [String: ReplayCheckpoint]

    init(
        rootNodeID: String,
        headNodeID: String,
        nodes: [String: PlotNode],
        checkpoints: [String: ReplayCheckpoint] = [:]
    ) {
        self.rootNodeID = rootNodeID
        self.headNodeID = headNodeID
        self.nodes = nodes
        self.checkpoints = checkpoints
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootNodeID = (try? c.decode(String.self, forKey: .rootNodeID)) ?? "root"
        headNodeID = (try? c.decode(String.self, forKey: .headNodeID)) ?? rootNodeID
        nodes = (try? c.decode([String: PlotNode].self, forKey: .nodes)) ?? [:]
        checkpoints = (try? c.decode([String: ReplayCheckpoint].self, forKey: .checkpoints)) ?? [:]
    }

    static func makeInitial(
        rootID: String = "root",
        branchLabel: String = "主线",
        summary: String = "初始节点",
        initialDelta: PlotNodeDelta = PlotNodeDelta(),
        manuscriptAnchor: TextSpanAnchor? = nil,
        now: Date = Date()
    ) -> StoryGraph {
        let root = PlotNode(
            id: rootID,
            parentID: nil,
            secondaryCausalParentIDs: [],
            branchLabel: branchLabel,
            summary: summary,
            manuscriptAnchor: manuscriptAnchor,
            sourceMessageID: nil,
            delta: initialDelta,
            createdAt: now
        )
        return StoryGraph(
            rootNodeID: rootID,
            headNodeID: rootID,
            nodes: [rootID: root],
            checkpoints: [:]
        )
    }

    /// 沿父引用执行三色深度优先遍历，确保全图不存在断链与因果环。
    func validateAcyclic() throws {
        guard nodes[rootNodeID] != nil else {
            throw StoryGraphError.missingRoot
        }

        // 0 = 未访问, 1 = 访问中, 2 = 已完成
        var visitState: [String: Int] = [:]

        func dfs(_ nodeID: String) throws {
            let state = visitState[nodeID] ?? 0
            if state == 2 { return }
            guard let node = nodes[nodeID] else {
                throw StoryGraphError.nodeNotFound(nodeID)
            }
            visitState[nodeID] = 1
            for parentID in node.allParentIDs {
                guard parentID != nodeID else {
                    throw StoryGraphError.cycleDetected(nodeID: nodeID, ancestorID: parentID)
                }
                guard nodes[parentID] != nil else {
                    throw StoryGraphError.missingParent(nodeID: nodeID, parentID: parentID)
                }
                let parentState = visitState[parentID] ?? 0
                if parentState == 1 {
                    throw StoryGraphError.cycleDetected(nodeID: nodeID, ancestorID: parentID)
                }
                if parentState == 0 {
                    try dfs(parentID)
                }
            }
            visitState[nodeID] = 2
        }

        for id in nodes.keys.sorted() {
            if (visitState[id] ?? 0) == 0 {
                try dfs(id)
            }
        }
    }

    mutating func appendNode(_ node: PlotNode, moveHead: Bool = true) throws {
        guard nodes[node.id] == nil else {
            throw StoryGraphError.duplicateNodeID(node.id)
        }
        for parentID in node.allParentIDs {
            if parentID == node.id {
                throw StoryGraphError.cycleDetected(nodeID: node.id, ancestorID: parentID)
            }
            guard nodes[parentID] != nil else {
                throw StoryGraphError.missingParent(nodeID: node.id, parentID: parentID)
            }
        }
        nodes[node.id] = node
        do {
            try validateAcyclic()
        } catch {
            nodes.removeValue(forKey: node.id)
            throw error
        }
        if moveHead {
            headNodeID = node.id
        }
    }

    mutating func addCausalEdge(from parentID: String, to childID: String) throws {
        guard nodes[parentID] != nil else {
            throw StoryGraphError.nodeNotFound(parentID)
        }
        guard var child = nodes[childID] else {
            throw StoryGraphError.nodeNotFound(childID)
        }
        guard parentID != childID else {
            throw StoryGraphError.cycleDetected(nodeID: childID, ancestorID: parentID)
        }
        let oldChild = child
        if !child.allParentIDs.contains(parentID) {
            child.secondaryCausalParentIDs.append(parentID)
            nodes[childID] = child
        }
        do {
            try validateAcyclic()
        } catch {
            nodes[childID] = oldChild
            throw error
        }
        invalidateCheckpoints(reachableFrom: childID)
    }

    mutating func checkout(nodeID: String) throws {
        guard nodes[nodeID] != nil else {
            throw StoryGraphError.nodeNotFound(nodeID)
        }
        headNodeID = nodeID
    }

    /// 计算目标节点祖先闭包的确定性拓扑序列，仅扫描相关祖先链路并在入度校验中同步拦截断链与环。
    func lineage(to targetNodeID: String? = nil) throws -> [PlotNode] {
        guard nodes[rootNodeID] != nil else {
            throw StoryGraphError.missingRoot
        }
        let targetID = targetNodeID ?? headNodeID
        guard nodes[targetID] != nil else {
            throw StoryGraphError.nodeNotFound(targetID)
        }

        var closure = Set<String>()
        var stack = [targetID]
        while let currentID = stack.popLast() {
            guard closure.insert(currentID).inserted else { continue }
            guard let node = nodes[currentID] else {
                throw StoryGraphError.nodeNotFound(currentID)
            }
            for parentID in node.allParentIDs {
                if parentID == currentID {
                    throw StoryGraphError.cycleDetected(nodeID: currentID, ancestorID: parentID)
                }
                guard nodes[parentID] != nil else {
                    throw StoryGraphError.missingParent(nodeID: currentID, parentID: parentID)
                }
                stack.append(parentID)
            }
        }

        var inDegree: [String: Int] = [:]
        var children: [String: [String]] = [:]
        inDegree.reserveCapacity(closure.count)
        for id in closure {
            inDegree[id] = 0
        }
        for id in closure {
            guard let node = nodes[id] else { continue }
            for parentID in node.allParentIDs where closure.contains(parentID) {
                inDegree[id, default: 0] += 1
                children[parentID, default: []].append(id)
            }
        }

        var ready = closure
            .filter { (inDegree[$0] ?? 0) == 0 }
            .compactMap { nodes[$0] }
        sortNodesDeterministically(&ready)

        var ordered: [PlotNode] = []
        ordered.reserveCapacity(closure.count)
        var orderedSet = Set<String>()
        while !ready.isEmpty {
            let current = ready.removeFirst()
            ordered.append(current)
            orderedSet.insert(current.id)
            for childID in children[current.id] ?? [] {
                let remaining = (inDegree[childID] ?? 1) - 1
                inDegree[childID] = remaining
                if remaining == 0, let childNode = nodes[childID] {
                    insertSortedDeterministically(childNode, into: &ready)
                }
            }
        }

        if ordered.count != closure.count {
            let stuckID = closure.first(where: { !orderedSet.contains($0) }) ?? targetID
            let stuckParent = nodes[stuckID]?.allParentIDs.first(where: { !orderedSet.contains($0) }) ?? stuckID
            throw StoryGraphError.cycleDetected(nodeID: stuckID, ancestorID: stuckParent)
        }
        return ordered
    }

    /// 优先复用路径前缀匹配的最近检查点，增量重放至目标节点以重建全量状态。
    func replay(to targetNodeID: String? = nil) throws -> MaterializedNarrativeState {
        let targetID = targetNodeID ?? headNodeID
        let path = try lineage(to: targetID)
        let pathIDs = path.map(\.id)

        if let exact = checkpoints[targetID], exact.state.pathNodeIDs == pathIDs {
            return exact.state
        }

        var startIndex = 0
        var state = NarrativeStateReducer.emptyState(rootNodeID: rootNodeID)
        if !path.isEmpty {
            for index in stride(from: path.count - 1, through: 0, by: -1) {
                let candidateID = path[index].id
                if let checkpoint = checkpoints[candidateID],
                   checkpoint.state.pathNodeIDs == Array(pathIDs.prefix(index + 1)) {
                    state = checkpoint.state
                    startIndex = index + 1
                    break
                }
            }
        }

        if startIndex < path.count {
            for node in path[startIndex...] {
                NarrativeStateReducer.apply(delta: node.delta, nodeID: node.id, to: &state)
            }
        }
        return state
    }

    @discardableResult
    mutating func recordCheckpoint(
        at targetNodeID: String? = nil,
        now: Date = Date()
    ) throws -> ReplayCheckpoint {
        let targetID = targetNodeID ?? headNodeID
        let state = try replay(to: targetID)
        let checkpoint = ReplayCheckpoint(nodeID: targetID, state: state, createdAt: now)
        checkpoints[targetID] = checkpoint
        return checkpoint
    }

    /// 提取尚未绑定正文锚点的当前待写规划节拍，供提示词注入本幕创作目标。
    func plannedBeatSummary(at targetNodeID: String? = nil) -> String? {
        let targetID = targetNodeID ?? headNodeID
        guard let node = nodes[targetID],
              node.id != rootNodeID,
              node.manuscriptAnchor == nil else {
            return nil
        }
        let cleanSummary = node.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSummary.isEmpty, cleanSummary != "初始节点" else { return nil }
        return "[\(node.branchLabel)] \(cleanSummary)"
    }

    /// 沿因果有向无环图向上提取目标节拍的祖先脉络摘要，跨分支汇合场景中可用于精简上下文。
    func causalAncestorSummaries(
        of targetNodeID: String? = nil,
        limit: Int = 8
    ) -> [String] {
        guard limit > 0, let ordered = try? lineage(to: targetNodeID ?? headNodeID) else {
            return []
        }
        let targetID = targetNodeID ?? headNodeID
        var lines: [String] = []
        var seen = Set<String>()
        for node in ordered where node.id != rootNodeID && node.id != targetID {
            let cleanSummary = node.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanSummary.isEmpty, cleanSummary != "初始节点" else { continue }
            let formatted: String
            if let quote = node.manuscriptAnchor?.quote.trimmingCharacters(in: .whitespacesAndNewlines),
               !quote.isEmpty {
                let briefQuote = quote.count > 28 ? String(quote.prefix(28)) + "…" : quote
                formatted = "[\(node.branchLabel)] \(cleanSummary)（\(briefQuote)）"
            } else {
                formatted = "[\(node.branchLabel)] \(cleanSummary)"
            }
            if seen.insert(formatted).inserted {
                lines.append(formatted)
            }
        }
        if lines.count <= limit { return lines }
        return Array(lines.suffix(limit))
    }

    /// 沿因果出边广度优先检索某个历史节拍的下游受影响节点，便于改稿时识别关联后续章节。
    func downstreamImpactedNodes(of nodeID: String) -> [PlotNode] {
        guard nodes[nodeID] != nil else { return [] }
        var forwardChildren: [String: [String]] = [:]
        for node in nodes.values {
            for parentID in node.allParentIDs {
                forwardChildren[parentID, default: []].append(node.id)
            }
        }
        var visited: Set<String> = [nodeID]
        var queue: [String] = forwardChildren[nodeID] ?? []
        var head = 0
        var impacted: [PlotNode] = []
        while head < queue.count {
            let currentID = queue[head]
            head += 1
            guard visited.insert(currentID).inserted,
                  let child = nodes[currentID] else { continue }
            impacted.append(child)
            queue.append(contentsOf: forwardChildren[currentID] ?? [])
        }
        sortNodesDeterministically(&impacted)
        return impacted
    }

    private mutating func invalidateCheckpoints(reachableFrom startID: String) {
        var descendants: [String: [String]] = [:]
        for node in nodes.values {
            for parentID in node.allParentIDs {
                descendants[parentID, default: []].append(node.id)
            }
        }
        var visited = Set<String>()
        var queue = [startID]
        while let current = queue.popLast() {
            guard visited.insert(current).inserted else { continue }
            checkpoints.removeValue(forKey: current)
            queue.append(contentsOf: descendants[current] ?? [])
        }
    }

    private func sortNodesDeterministically(_ list: inout [PlotNode]) {
        list.sort(by: isOrderedBefore)
    }

    private func insertSortedDeterministically(_ node: PlotNode, into list: inout [PlotNode]) {
        let insertIndex = list.firstIndex { !isOrderedBefore($0, node) } ?? list.endIndex
        list.insert(node, at: insertIndex)
    }

    private func isOrderedBefore(_ lhs: PlotNode, _ rhs: PlotNode) -> Bool {
        if lhs.id == rootNodeID, rhs.id != rootNodeID { return true }
        if rhs.id == rootNodeID, lhs.id != rootNodeID { return false }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }
}
