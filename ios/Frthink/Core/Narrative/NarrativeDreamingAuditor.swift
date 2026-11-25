import Foundation

/// 离线记忆审计发现的问题类别。
enum DreamingIssueKind: String, Codable, Hashable {
    case staleBelief
    case entityPageBloat
    case overdueThread
    case ungroundedFact
}

/// 离线记忆审计问题严重度，按优先级从高到低排序展示与建议清理。
enum DreamingIssueSeverity: Int, Codable, Hashable, Comparable {
    case low = 1
    case medium = 2
    case high = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 离线记忆审计命中的单条可操作发现。
struct DreamingFinding: Identifiable, Codable, Hashable {
    var id: String
    var kind: DreamingIssueKind
    var severity: DreamingIssueSeverity
    var targetID: String
    var title: String
    var detail: String
    var anchor: TextSpanAnchor?
    var suggestedAction: String

    init(
        id: String,
        kind: DreamingIssueKind,
        severity: DreamingIssueSeverity,
        targetID: String,
        title: String,
        detail: String,
        anchor: TextSpanAnchor? = nil,
        suggestedAction: String
    ) {
        self.id = id
        self.kind = kind
        self.severity = severity
        self.targetID = targetID
        self.title = title
        self.detail = detail
        self.anchor = anchor
        self.suggestedAction = suggestedAction
    }
}

/// 离线记忆审计汇总报告，包含所有结构化问题与人类可读摘要。
struct DreamingAuditReport: Codable, Hashable {
    var findings: [DreamingFinding]
    var auditedNodeID: String
    var auditedAt: Date
    var summary: String

    init(
        findings: [DreamingFinding] = [],
        auditedNodeID: String,
        auditedAt: Date = Date(),
        summary: String
    ) {
        self.findings = findings
        self.auditedNodeID = auditedNodeID
        self.auditedAt = auditedAt
        self.summary = summary
    }
}

/// 离线记忆审计与压缩器：
/// 对照分支剧情图当前头节点的物化状态与正文原页，排查过时认知、实体页膨胀、无凭据推断与超时伏笔，
/// 并通过向剧情图追加确定性整理节点完成安全清理。
enum NarrativeDreamingAuditor {

    private static let summaryLengthLimit = 400
    private static let summaryCompactTarget = 360
    private static let hardBoundaryCountLimit = 12
    private static let activeFactCountLimit = 16
    private static let conflictWarningTrimLimit = 2
    private static let readyThreadAgeThreshold = 6
    private static let pendingThreadAgeThreshold = 12

    static func audit(
        workspace: NarrativeWorkspace,
        manuscriptPages: [String] = [],
        now: Date = Date()
    ) throws -> DreamingAuditReport {
        let headID = workspace.storyGraph.headNodeID
        let state = workspace.currentState()
        let lineage = try workspace.storyGraph.lineage(to: headID)

        var depthByNodeID: [String: Int] = [:]
        depthByNodeID.reserveCapacity(lineage.count)
        for (idx, node) in lineage.enumerated() {
            depthByNodeID[node.id] = idx
        }
        let headDepth = max(0, lineage.count - 1)

        var findings: [DreamingFinding] = []
        findings.append(
            contentsOf: auditBeliefs(
                state: state,
                depthByNodeID: depthByNodeID,
                manuscriptPages: manuscriptPages
            )
        )
        findings.append(contentsOf: auditEntityPages(state: state))
        findings.append(
            contentsOf: auditThreads(
                state: state,
                depthByNodeID: depthByNodeID,
                headDepth: headDepth
            )
        )

        findings.sort { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
            return lhs.targetID < rhs.targetID
        }

        return DreamingAuditReport(
            findings: findings,
            auditedNodeID: headID,
            auditedAt: now,
            summary: makeSummary(findings: findings)
        )
    }

    /// 针对选定审计发现直接向现状三账本施加单步整理归约，不在情节因果图中制造设定管理噪点节点。
    @discardableResult
    static func applyCleanup(
        findings: [DreamingFinding],
        workspace: inout NarrativeWorkspace,
        now: Date = Date()
    ) throws -> Int {
        guard !findings.isEmpty else { return 0 }
        let headID = workspace.storyGraph.headNodeID
        let state = workspace.currentState()
        let lineage = try workspace.storyGraph.lineage(to: headID)

        var depthByNodeID: [String: Int] = [:]
        for (idx, node) in lineage.enumerated() {
            depthByNodeID[node.id] = idx
        }

        let cleanupNodeID = "cleanup_\(UUID().uuidString)"
        var replacementsByEntity: [String: EntityPage] = [:]
        var alignedBeliefsBySlot: [String: EpistemicBelief] = [:]
        var threadEventsByID: [String: ProspectiveThreadEvent] = [:]
        var cleanedCount = 0

        for finding in findings {
            switch finding.kind {
            case .entityPageBloat:
                guard var page = replacementsByEntity[finding.targetID] ?? state.entityPages[finding.targetID] else {
                    continue
                }
                let trimmed = compactEntityPage(&page, now: now)
                if trimmed {
                    replacementsByEntity[page.id] = page
                    cleanedCount += 1
                }

            case .staleBelief:
                guard let belief = state.epistemicBeliefs[finding.targetID],
                      let latestFact = matchingLatestFact(
                          for: belief,
                          in: state,
                          depthByNodeID: depthByNodeID
                      )
                else {
                    continue
                }
                let aligned = EpistemicBelief(
                    id: belief.id,
                    characterID: belief.characterID,
                    topic: belief.topic,
                    believedTruth: latestFact.value,
                    knowsSecret: true,
                    authority: max(belief.authority, latestFact.authority),
                    updatedAtNodeID: cleanupNodeID,
                    quoteAnchor: latestFact.quoteAnchor,
                    updatedAt: now
                )
                alignedBeliefsBySlot[belief.slotKey] = aligned
                cleanedCount += 1

            case .overdueThread:
                guard let thread = state.threads[finding.targetID],
                      thread.state == .pending,
                      threadEventsByID[thread.id] == nil
                else {
                    continue
                }
                let event = ProspectiveThreadEvent(
                    threadID: thread.id,
                    kind: .promoteReady,
                    authority: max(thread.authority, .canonProseQuote),
                    nodeID: cleanupNodeID,
                    createdAt: now
                )
                threadEventsByID[thread.id] = event
                cleanedCount += 1

            case .ungroundedFact:
                continue
            }
        }

        let replacements = replacementsByEntity.values.sorted { $0.id < $1.id }
        let beliefs = alignedBeliefsBySlot.values.sorted { $0.slotKey < $1.slotKey }
        let threadEvents = threadEventsByID.values.sorted { $0.threadID < $1.threadID }
        guard !replacements.isEmpty || !beliefs.isEmpty || !threadEvents.isEmpty else {
            return 0
        }

        let delta = PlotNodeDelta(
            entityPageReplacements: replacements,
            epistemicBeliefs: beliefs,
            threadEvents: threadEvents
        )
        workspace.applyLedgerDelta(delta, sourceNodeID: headID)
        return cleanedCount
    }

    static func matchingLatestFact(
        for belief: EpistemicBelief,
        in state: MaterializedNarrativeState,
        depthByNodeID: [String: Int]
    ) -> WorldFactEvent? {
        let beliefDepth = depthByNodeID[belief.updatedAtNodeID] ?? 0

        if let exactFact = state.activeFacts[belief.slotKey],
           !exactFact.isRetracted,
           let factDepth = depthByNodeID[exactFact.nodeID],
           factDepth > beliefDepth,
           exactFact.value != belief.believedTruth {
            return exactFact
        }

        let cleanTopic = belief.topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTruth = belief.believedTruth.trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates = state.facts(for: belief.characterID).compactMap { fact -> (fact: WorldFactEvent, depth: Int)? in
            guard !fact.isRetracted,
                  fact.authority >= .canonProseQuote,
                  let factDepth = depthByNodeID[fact.nodeID],
                  factDepth > beliefDepth,
                  fact.value != belief.believedTruth else {
                return nil
            }
            let rawAttr = fact.attribute.trimmingCharacters(in: .whitespacesAndNewlines)
            let attrBody: String
            if let colonRange = rawAttr.range(of: ":") {
                attrBody = String(rawAttr[colonRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                attrBody = rawAttr
            }

            let topicHitsFact = cleanTopic.count >= 2 && (
                rawAttr.localizedCaseInsensitiveContains(cleanTopic)
                    || (!attrBody.isEmpty && attrBody.localizedCaseInsensitiveContains(cleanTopic))
                    || fact.value.localizedCaseInsensitiveContains(cleanTopic)
            )
            let attrHitsBelief = attrBody.count >= 2 && (
                cleanTopic.localizedCaseInsensitiveContains(attrBody)
                    || cleanTruth.localizedCaseInsensitiveContains(attrBody)
            )
            guard topicHitsFact || attrHitsBelief else { return nil }
            return (fact, factDepth)
        }

        return candidates.max { lhs, rhs in
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            if lhs.fact.createdAt != rhs.fact.createdAt { return lhs.fact.createdAt < rhs.fact.createdAt }
            return lhs.fact.id < rhs.fact.id
        }?.fact
    }

    // MARK: - 分类审计

    private static func auditBeliefs(
        state: MaterializedNarrativeState,
        depthByNodeID: [String: Int],
        manuscriptPages: [String]
    ) -> [DreamingFinding] {
        var out: [DreamingFinding] = []
        let sortedBeliefs = state.epistemicBeliefs.values.sorted { $0.slotKey < $1.slotKey }

        for belief in sortedBeliefs {
            let charName = state.entityPages[belief.characterID]?.name ?? belief.characterID

            if let latestFact = matchingLatestFact(
                for: belief,
                in: state,
                depthByNodeID: depthByNodeID
            ) {
                out.append(
                    DreamingFinding(
                        id: stableID(prefix: "stale_conflict", key: belief.slotKey),
                        kind: .staleBelief,
                        severity: .high,
                        targetID: belief.slotKey,
                        title: "「\(charName)」认知与最新事实冲突（\(belief.topic)）",
                        detail: "认知停留在「\(belief.believedTruth)」，后续正文已确立「\(latestFact.value)」。",
                        anchor: latestFact.quoteAnchor ?? belief.quoteAnchor,
                        suggestedAction: "同步角色认知至最新客观事实"
                    )
                )
                continue
            }

            if !manuscriptPages.isEmpty,
               let quote = belief.quoteAnchor?.quote.trimmingCharacters(in: .whitespacesAndNewlines),
               !quote.isEmpty,
               !manuscriptPages.contains(where: { $0.contains(quote) }) {
                out.append(
                    DreamingFinding(
                        id: stableID(prefix: "stale_quote", key: belief.slotKey),
                        kind: .staleBelief,
                        severity: .medium,
                        targetID: belief.slotKey,
                        title: "「\(charName)」认知引用原文已失效（\(belief.topic)）",
                        detail: "原引用片段「\(quote)」在当前正文中已不存在，角色知情状态可能失真。",
                        anchor: belief.quoteAnchor,
                        suggestedAction: "人工核对角色当前是否仍持有该认知"
                    )
                )
                continue
            }

            if belief.authority == .inferredByAI, belief.quoteAnchor == nil {
                out.append(
                    DreamingFinding(
                        id: stableID(prefix: "ungrounded_belief", key: belief.slotKey),
                        kind: .ungroundedFact,
                        severity: .low,
                        targetID: belief.slotKey,
                        title: "「\(charName)」存在缺少原文依据的记录（\(belief.topic)）",
                        detail: "当前记录「\(belief.believedTruth)」缺少正文原文依据。",
                        anchor: nil,
                        suggestedAction: "确认是否保留该记录或在正文中补充依据"
                    )
                )
            }
        }
        return out
    }

    private static func auditEntityPages(state: MaterializedNarrativeState) -> [DreamingFinding] {
        var out: [DreamingFinding] = []
        let sortedPages = state.entityPages.values.sorted { $0.id < $1.id }

        for page in sortedPages {
            let activeFactCount = state.facts(for: page.id)
                .filter { !$0.attribute.hasPrefix("relation:") && !$0.attribute.hasPrefix("memory:") }
                .count
            let duplicateBoundaries = hasDuplicateStrings(page.hardBoundaries)

            var reasons: [String] = []
            if page.summary.count > summaryLengthLimit {
                reasons.append("摘要长度 \(page.summary.count) 字（超过 \(summaryLengthLimit)）")
            }
            if page.conflictWarnings.count >= 3 {
                reasons.append("积压 \(page.conflictWarnings.count) 条冲突提示")
            }
            if duplicateBoundaries || page.hardBoundaries.count > hardBoundaryCountLimit {
                reasons.append("行为底线冗余（共 \(page.hardBoundaries.count) 条）")
            }
            if activeFactCount > activeFactCountLimit {
                reasons.append("已知事实达到 \(activeFactCount) 条（超过 \(activeFactCountLimit)）")
            }

            guard !reasons.isEmpty else { continue }
            out.append(
                DreamingFinding(
                    id: stableID(prefix: "bloat", key: page.id),
                    kind: .entityPageBloat,
                    severity: .medium,
                    targetID: page.id,
                    title: "「\(page.name)」档案过长",
                    detail: reasons.joined(separator: "；") + "。",
                    anchor: nil,
                    suggestedAction: "精简摘要、合并重复底线并清理旧冲突提示"
                )
            )
        }
        return out
    }

    private static func auditThreads(
        state: MaterializedNarrativeState,
        depthByNodeID: [String: Int],
        headDepth: Int
    ) -> [DreamingFinding] {
        var out: [DreamingFinding] = []
        let activeThreads = state.threads.values
            .filter { !$0.state.isTerminal }
            .sorted { $0.id < $1.id }

        for thread in activeThreads {
            let plantedDepth = depthByNodeID[thread.plantedAtNodeID] ?? 0
            let ageNodes = max(0, headDepth - plantedDepth)

            if let horizon = thread.intendedHorizonNodeOffset, ageNodes > horizon {
                out.append(
                    DreamingFinding(
                        id: stableID(prefix: "overdue_horizon", key: thread.id),
                        kind: .overdueThread,
                        severity: .high,
                        targetID: thread.id,
                        title: "伏笔「\(thread.goal)」已超出预期回收跨度",
                        detail: "已推进 \(ageNodes) 幕，超过预设跨度（\(horizon) 幕）。",
                        anchor: thread.evidenceAnchors.last,
                        suggestedAction: "尽快安排回收，或标记为可回收／放弃"
                    )
                )
            } else if (thread.state == .ready && ageNodes >= readyThreadAgeThreshold)
                        || (thread.state == .pending && ageNodes >= pendingThreadAgeThreshold) {
                let threshold = thread.state == .ready ? readyThreadAgeThreshold : pendingThreadAgeThreshold
                out.append(
                    DreamingFinding(
                        id: stableID(prefix: "overdue_stalled", key: thread.id),
                        kind: .overdueThread,
                        severity: .medium,
                        targetID: thread.id,
                        title: "伏笔「\(thread.goal)」久未推进",
                        detail: "停留在当前状态已达 \(ageNodes) 幕（建议跨度 \(threshold) 幕）。",
                        anchor: thread.evidenceAnchors.last,
                        suggestedAction: thread.state == .pending ? "可先标为「可回收」以提示后续呼应" : "建议在近期章节中安排回收"
                    )
                )
            }
        }
        return out
    }

    // MARK: - 清理与统计辅助

    private static func compactEntityPage(_ page: inout EntityPage, now: Date) -> Bool {
        var changed = false

        if page.summary.count > summaryCompactTarget {
            page.summary = String(page.summary.prefix(summaryCompactTarget))
            changed = true
        }

        let cleanBoundaries = deduplicatedStrings(page.hardBoundaries)
        let cappedBoundaries = Array(cleanBoundaries.prefix(hardBoundaryCountLimit))
        if cappedBoundaries != page.hardBoundaries {
            page.hardBoundaries = cappedBoundaries
            changed = true
        }

        let trimmedWarnings = Array(
            deduplicatedStrings(page.conflictWarnings).suffix(conflictWarningTrimLimit)
        )
        if trimmedWarnings != page.conflictWarnings {
            page.conflictWarnings = trimmedWarnings
            changed = true
        }

        if changed {
            page.updatedAt = now
        }
        return changed
    }

    private static func hasDuplicateStrings(_ items: [String]) -> Bool {
        var seen = Set<String>()
        for raw in items {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || !seen.insert(clean).inserted {
                return true
            }
        }
        return false
    }

    private static func deduplicatedStrings(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, seen.insert(clean).inserted else { continue }
            out.append(clean)
        }
        return out
    }

    private static func stableID(prefix: String, key: String) -> String {
        let digest = String(SummaryKey.sha256Hex(key).prefix(12))
        return "\(prefix)_\(digest)"
    }

    private static func makeSummary(findings: [DreamingFinding]) -> String {
        guard !findings.isEmpty else {
            return "核查完成，档案、角色认知与伏笔均无异常。"
        }
        let highCount = findings.filter { $0.severity == .high }.count
        let mediumCount = findings.filter { $0.severity == .medium }.count
        let lowCount = findings.filter { $0.severity == .low }.count
        return "发现 \(findings.count) 项待处理（高 \(highCount) / 中 \(mediumCount) / 低 \(lowCount)）。"
    }
}
