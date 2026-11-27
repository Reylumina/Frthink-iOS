import CryptoKit
import Foundation

/// 精确原文定位锚点：绑定正文页码、UTF-16 范围、逐字引用与段落哈希，使状态变更与回溯均可定位至原始正文。
struct TextSpanAnchor: Codable, Hashable {
    var pageIndex: Int
    var utf16Start: Int
    var utf16Length: Int
    var quote: String
    var paragraphHash: String

    init(
        pageIndex: Int = 0,
        utf16Start: Int = 0,
        utf16Length: Int = 0,
        quote: String = "",
        paragraphHash: String = ""
    ) {
        self.pageIndex = pageIndex
        self.utf16Start = utf16Start
        self.utf16Length = utf16Length
        self.quote = quote
        self.paragraphHash = paragraphHash
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageIndex = (try? c.decode(Int.self, forKey: .pageIndex)) ?? 0
        utf16Start = (try? c.decode(Int.self, forKey: .utf16Start)) ?? 0
        utf16Length = (try? c.decode(Int.self, forKey: .utf16Length)) ?? 0
        quote = (try? c.decode(String.self, forKey: .quote)) ?? ""
        paragraphHash = (try? c.decode(String.self, forKey: .paragraphHash)) ?? ""
    }

    static func make(
        pageIndex: Int = 0,
        utf16Start: Int,
        utf16Length: Int,
        quote: String,
        paragraphText: String? = nil
    ) -> TextSpanAnchor {
        let basis = (paragraphText ?? quote).trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = String(SummaryKey.sha256Hex(basis).prefix(16))
        return TextSpanAnchor(
            pageIndex: max(0, pageIndex),
            utf16Start: max(0, utf16Start),
            utf16Length: max(0, utf16Length),
            quote: quote,
            paragraphHash: hash
        )
    }
}

/// 三级事实权威等级：确保低权威推断无法覆写高权威设定。
enum AuthorityRank: Int, Codable, Hashable, Comparable {
    /// 后台增量抽取的推断结果
    case inferredByAI = 1
    /// 采纳落盘正文中逐字引用确立的事实
    case canonProseQuote = 2
    /// 作者手动编辑或确认，拥有最高优先级
    case authorDirective = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 作者写作指令的生效作用域。
enum DirectiveScope: Codable, Hashable {
    case global
    case volume(id: String)
    case branch(id: String)
    case entity(id: String)

    func appliesTo(
        volumeID: String? = nil,
        branchID: String? = nil,
        entityIDs: Set<String> = []
    ) -> Bool {
        switch self {
        case .global:
            return true
        case .volume(let id):
            return volumeID == id
        case .branch(let id):
            return branchID == id
        case .entity(let id):
            return entityIDs.contains(id)
        }
    }
}

/// 作者指令状态：废止仅作状态标记，保留事件链可追溯性。
enum DirectiveStatus: String, Codable, Hashable {
    case active
    case superseded
}

/// 单条作者逐字写作规则。按原文持久化，避免摘要改写造成规则损耗。
struct AuthorDirective: Identifiable, Codable, Hashable {
    var id: String
    var verbatimRule: String
    var scope: DirectiveScope
    var sourceNodeID: String?
    var status: DirectiveStatus
    var supersededByID: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        verbatimRule: String,
        scope: DirectiveScope = .global,
        sourceNodeID: String? = nil,
        status: DirectiveStatus = .active,
        supersededByID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.verbatimRule = verbatimRule
        self.scope = scope
        self.sourceNodeID = sourceNodeID
        self.status = status
        self.supersededByID = supersededByID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        verbatimRule = (try? c.decode(String.self, forKey: .verbatimRule)) ?? ""
        scope = (try? c.decode(DirectiveScope.self, forKey: .scope)) ?? .global
        sourceNodeID = try? c.decodeIfPresent(String.self, forKey: .sourceNodeID)
        status = (try? c.decode(DirectiveStatus.self, forKey: .status)) ?? .active
        supersededByID = try? c.decodeIfPresent(String.self, forKey: .supersededByID)
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? createdAt
    }
}

/// 作者逐字规则账本：独立管理全局与局部硬性要求，不随对话历史折叠或摘要。
struct AuthorDirectiveLedger: Codable, Hashable {
    var directives: [AuthorDirective]

    init(directives: [AuthorDirective] = []) {
        self.directives = directives
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        directives = (try? c.decode([AuthorDirective].self, forKey: .directives)) ?? []
    }

    func activeDirectives(
        volumeID: String? = nil,
        branchID: String? = nil,
        entityIDs: Set<String> = []
    ) -> [AuthorDirective] {
        directives
            .filter { directive in
                directive.status == .active
                    && !directive.verbatimRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && directive.scope.appliesTo(
                        volumeID: volumeID,
                        branchID: branchID,
                        entityIDs: entityIDs
                    )
            }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id < rhs.id
            }
    }

    /// 逐字追加规则：仅去除首尾空白，保留完整原意与换行结构；同作用域相同规则不重复插入。
    @discardableResult
    mutating func appendVerbatim(
        _ rule: String,
        scope: DirectiveScope = .global,
        sourceNodeID: String? = nil,
        id: String = UUID().uuidString,
        now: Date = Date()
    ) -> AuthorDirective? {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let existing = directives.first(where: {
            $0.status == .active && $0.scope == scope && $0.verbatimRule == trimmed
        }) {
            return existing
        }
        let directive = AuthorDirective(
            id: id,
            verbatimRule: trimmed,
            scope: scope,
            sourceNodeID: sourceNodeID,
            status: .active,
            supersededByID: nil,
            createdAt: now,
            updatedAt: now
        )
        directives.append(directive)
        return directive
    }

    @discardableResult
    mutating func supersede(
        id targetID: String,
        replacement: AuthorDirective? = nil,
        now: Date = Date()
    ) -> Bool {
        guard let index = directives.firstIndex(where: { $0.id == targetID }) else {
            return false
        }
        var updatedReplacement = replacement
        if let rep = replacement {
            let trimmed = rep.verbatimRule.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                updatedReplacement = nil
            } else if trimmed != rep.verbatimRule {
                var clean = rep
                clean.verbatimRule = trimmed
                updatedReplacement = clean
            }
        }
        directives[index].status = .superseded
        directives[index].supersededByID = updatedReplacement?.id
        directives[index].updatedAt = now
        if let updatedReplacement,
           !directives.contains(where: { $0.id == updatedReplacement.id }) {
            directives.append(updatedReplacement)
        }
        return true
    }

    /// 拼装权威指令提示词片段，直接陈述约束而不附加弱化指令遵守率的免责措辞。
    func renderedAuthorityBlock(
        volumeID: String? = nil,
        branchID: String? = nil,
        entityIDs: Set<String> = []
    ) -> String {
        let active = activeDirectives(
            volumeID: volumeID,
            branchID: branchID,
            entityIDs: entityIDs
        )
        guard !active.isEmpty else { return "" }
        var lines = ["【写作规则（必须严格遵守，不得违反或擅自放宽）】"]
        for (idx, item) in active.enumerated() {
            lines.append("\(idx + 1). \(item.verbatimRule)")
        }
        return lines.joined(separator: "\n")
    }
}

/// 客观世界事实单步事件：记录实体属性变化、来源节点、权威等级与原文引用锚点。
struct WorldFactEvent: Identifiable, Codable, Hashable {
    enum StandardAttribute {
        static let location = "location"
        static let possession = "possession"
        static let condition = "condition"
        static let relation = "relation"
        static let lore = "lore"
        static let goal = "goal"
        static let personality = "personality"
        static let status = "status"
    }

    var id: String
    var entityID: String
    var attribute: String
    var value: String
    var nodeID: String
    var authority: AuthorityRank
    var supersedesEventID: String?
    var quoteAnchor: TextSpanAnchor?
    var isRetracted: Bool
    var createdAt: Date

    var slotKey: String { "\(entityID)\u{1F}\(attribute)" }

    init(
        id: String = UUID().uuidString,
        entityID: String,
        attribute: String,
        value: String,
        nodeID: String,
        authority: AuthorityRank = .canonProseQuote,
        supersedesEventID: String? = nil,
        quoteAnchor: TextSpanAnchor? = nil,
        isRetracted: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.entityID = entityID
        self.attribute = attribute
        self.value = value
        self.nodeID = nodeID
        self.authority = authority
        self.supersedesEventID = supersedesEventID
        self.quoteAnchor = quoteAnchor
        self.isRetracted = isRetracted
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        entityID = (try? c.decode(String.self, forKey: .entityID)) ?? ""
        attribute = (try? c.decode(String.self, forKey: .attribute)) ?? ""
        value = (try? c.decode(String.self, forKey: .value)) ?? ""
        nodeID = (try? c.decode(String.self, forKey: .nodeID)) ?? "root"
        authority = (try? c.decode(AuthorityRank.self, forKey: .authority)) ?? .canonProseQuote
        supersedesEventID = try? c.decodeIfPresent(String.self, forKey: .supersedesEventID)
        quoteAnchor = try? c.decodeIfPresent(TextSpanAnchor.self, forKey: .quoteAnchor)
        isRetracted = (try? c.decode(Bool.self, forKey: .isRetracted)) ?? false
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }
}

/// 角色私有认知状态：与全局客观事实隔离存储，用于约束特定视角下的知情范围与信息差。
struct EpistemicBelief: Identifiable, Codable, Hashable {
    var id: String
    var characterID: String
    var topic: String
    var believedTruth: String
    var knowsSecret: Bool
    var authority: AuthorityRank
    var updatedAtNodeID: String
    var quoteAnchor: TextSpanAnchor?
    var updatedAt: Date

    var slotKey: String { "\(characterID)\u{1F}\(topic)" }

    init(
        id: String = UUID().uuidString,
        characterID: String,
        topic: String,
        believedTruth: String,
        knowsSecret: Bool,
        authority: AuthorityRank = .canonProseQuote,
        updatedAtNodeID: String,
        quoteAnchor: TextSpanAnchor? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.characterID = characterID
        self.topic = topic
        self.believedTruth = believedTruth
        self.knowsSecret = knowsSecret
        self.authority = authority
        self.updatedAtNodeID = updatedAtNodeID
        self.quoteAnchor = quoteAnchor
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        characterID = (try? c.decode(String.self, forKey: .characterID)) ?? ""
        topic = (try? c.decode(String.self, forKey: .topic)) ?? ""
        believedTruth = (try? c.decode(String.self, forKey: .believedTruth)) ?? ""
        knowsSecret = (try? c.decode(Bool.self, forKey: .knowsSecret)) ?? false
        authority = (try? c.decode(AuthorityRank.self, forKey: .authority)) ?? .canonProseQuote
        updatedAtNodeID = (try? c.decode(String.self, forKey: .updatedAtNodeID)) ?? "root"
        quoteAnchor = try? c.decodeIfPresent(TextSpanAnchor.self, forKey: .quoteAnchor)
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }
}

/// 前瞻伏笔生命周期状态，分离「埋设待发」「条件就绪」「已写入场」与「终态」。
enum ThreadLifecycle: String, Codable, Hashable {
    case pending
    case ready
    case enacted
    case satisfied
    case invalidated

    var isTerminal: Bool {
        self == .satisfied || self == .invalidated
    }

    var displayName: String {
        switch self {
        case .pending: return "埋设待发"
        case .ready: return "待回收"
        case .enacted: return "推进中"
        case .satisfied: return "已回收"
        case .invalidated: return "已作废"
        }
    }
}

/// 伏笔触发模式：`.once` 在进入 `.enacted` 后锁定，避免被重复兑现。
enum RecurrenceKind: String, Codable, Hashable {
    case once
    case recurring
}

/// 前瞻伏笔条目：记录触发线索、目标跨度、证据锚点与生命周期状态。
struct ProspectiveThread: Identifiable, Codable, Hashable {
    var id: String
    var goal: String
    var activationCue: String
    var recurrence: RecurrenceKind
    var relatedEntityIDs: [String]
    var intendedHorizonNodeOffset: Int?
    var evidenceAnchors: [TextSpanAnchor]
    var state: ThreadLifecycle
    var authority: AuthorityRank
    var plantedAtNodeID: String
    var updatedAtNodeID: String
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        goal: String,
        activationCue: String = "",
        recurrence: RecurrenceKind = .once,
        relatedEntityIDs: [String] = [],
        intendedHorizonNodeOffset: Int? = nil,
        evidenceAnchors: [TextSpanAnchor] = [],
        state: ThreadLifecycle = .pending,
        authority: AuthorityRank = .canonProseQuote,
        plantedAtNodeID: String = "root",
        updatedAtNodeID: String = "root",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.goal = goal
        self.activationCue = activationCue
        self.recurrence = recurrence
        self.relatedEntityIDs = relatedEntityIDs
        self.intendedHorizonNodeOffset = intendedHorizonNodeOffset
        self.evidenceAnchors = evidenceAnchors
        self.state = state
        self.authority = authority
        self.plantedAtNodeID = plantedAtNodeID
        self.updatedAtNodeID = updatedAtNodeID
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        goal = (try? c.decode(String.self, forKey: .goal)) ?? ""
        activationCue = (try? c.decode(String.self, forKey: .activationCue)) ?? ""
        recurrence = (try? c.decode(RecurrenceKind.self, forKey: .recurrence)) ?? .once
        relatedEntityIDs = (try? c.decode([String].self, forKey: .relatedEntityIDs)) ?? []
        intendedHorizonNodeOffset = try? c.decodeIfPresent(Int.self, forKey: .intendedHorizonNodeOffset)
        evidenceAnchors = (try? c.decode([TextSpanAnchor].self, forKey: .evidenceAnchors)) ?? []
        state = (try? c.decode(ThreadLifecycle.self, forKey: .state)) ?? .pending
        authority = (try? c.decode(AuthorityRank.self, forKey: .authority)) ?? .canonProseQuote
        plantedAtNodeID = (try? c.decode(String.self, forKey: .plantedAtNodeID)) ?? "root"
        updatedAtNodeID = (try? c.decode(String.self, forKey: .updatedAtNodeID)) ?? plantedAtNodeID
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }
}

/// 独立实体页分类。
enum EntityKind: String, Codable, Hashable {
    case character
    case location
    case artifact
    case lore

    var displayName: String {
        switch self {
        case .character: return "人物"
        case .location: return "地点"
        case .artifact: return "物件"
        case .lore: return "世界观"
        }
    }

    var identityLabel: String {
        switch self {
        case .character: return "身份"
        case .location: return "位置与类型"
        case .artifact: return "归属与类型"
        case .lore: return "所属类别"
        }
    }

    var summaryLabel: String {
        switch self {
        case .character: return "性格与处境"
        case .location: return "布局与氛围"
        case .artifact: return "外观与用途"
        case .lore: return "词条内容"
        }
    }

    var boundariesLabel: String {
        switch self {
        case .character: return "行为底线"
        case .location: return "空间限制"
        case .artifact: return "使用代价与限制"
        case .lore: return "核心规则与例外"
        }
    }

    var markdownOverviewHeading: String {
        switch self {
        case .character: return "身份与摘要"
        case .location: return "布局与氛围"
        case .artifact: return "归属与用途"
        case .lore: return "词条概述"
        }
    }
}

/// 档案进入上下文的方式：正文或指令提及时带入，或固定写入静态前缀。
enum EntityActivationMode: String, Codable, Hashable, CaseIterable {
    case mentioned
    case always

    var displayName: String {
        switch self {
        case .mentioned: return "按关键词触发"
        case .always: return "始终生效"
        }
    }
}

/// 按单个实体拆分的独立档案页，支持按需按页读写。
struct EntityPage: Identifiable, Codable, Hashable {
    var id: String
    var kind: EntityKind
    var name: String
    var aliases: [String]
    var triggerKeywords: [String]
    var activationMode: EntityActivationMode
    var summary: String
    var identity: String
    var voiceProfile: String
    var hardBoundaries: [String]
    var currentFactIDs: [String]
    var conflictWarnings: [String]
    var enabled: Bool
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        kind: EntityKind,
        name: String,
        aliases: [String] = [],
        triggerKeywords: [String] = [],
        activationMode: EntityActivationMode = .mentioned,
        summary: String = "",
        identity: String = "",
        voiceProfile: String = "",
        hardBoundaries: [String] = [],
        currentFactIDs: [String] = [],
        conflictWarnings: [String] = [],
        enabled: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.aliases = aliases
        self.triggerKeywords = triggerKeywords
        self.activationMode = kind == .lore ? activationMode : .mentioned
        self.summary = summary
        self.identity = identity
        self.voiceProfile = voiceProfile
        self.hardBoundaries = hardBoundaries
        self.currentFactIDs = currentFactIDs
        self.conflictWarnings = conflictWarnings
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        kind = (try? c.decode(EntityKind.self, forKey: .kind)) ?? .character
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        aliases = (try? c.decode([String].self, forKey: .aliases)) ?? []
        triggerKeywords = (try? c.decode([String].self, forKey: .triggerKeywords)) ?? []
        let decodedActivation = (try? c.decode(EntityActivationMode.self, forKey: .activationMode)) ?? .mentioned
        activationMode = kind == .lore ? decodedActivation : .mentioned
        summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
        identity = (try? c.decode(String.self, forKey: .identity)) ?? ""
        voiceProfile = (try? c.decode(String.self, forKey: .voiceProfile)) ?? ""
        hardBoundaries = (try? c.decode([String].self, forKey: .hardBoundaries)) ?? []
        currentFactIDs = (try? c.decode([String].self, forKey: .currentFactIDs)) ?? []
        conflictWarnings = (try? c.decode([String].self, forKey: .conflictWarnings)) ?? []
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }

    /// 渲染为结构化 Markdown 文档，供实体查看与按需工具读取使用。
    func renderedMarkdown(
        resolvedFacts: [WorldFactEvent],
        beliefs: [EpistemicBelief],
        relatedEvents: [EpisodicEvent] = []
    ) -> String {
        var sections: [String] = ["# \(name)"]
        var metaLines: [String] = []
        if !aliases.isEmpty {
            metaLines.append("- 别名：\(aliases.joined(separator: "、"))")
        }
        if kind == .lore {
            metaLines.append("- 生效方式：\(activationMode.displayName)")
        }
        if !triggerKeywords.isEmpty {
            metaLines.append("- 触发词：\(triggerKeywords.joined(separator: "、"))")
        }
        if !metaLines.isEmpty {
            sections.append(metaLines.joined(separator: "\n"))
        }

        var overview: [String] = []
        let cleanIdentity = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanIdentity.isEmpty { overview.append(cleanIdentity) }
        if !cleanSummary.isEmpty, cleanSummary != cleanIdentity {
            overview.append(cleanSummary)
        }
        if !overview.isEmpty {
            sections.append("## \(kind.markdownOverviewHeading)\n" + overview.joined(separator: "\n"))
        }

        let cleanVoice = voiceProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .character, !cleanVoice.isEmpty {
            sections.append("## 声音档案\n" + cleanVoice)
        }

        if !hardBoundaries.isEmpty {
            let lines = hardBoundaries.map { "- \($0)" }
            sections.append("## \(kind.boundariesLabel)\n" + lines.joined(separator: "\n"))
        }

        let ownFacts = resolvedFacts
            .filter { $0.entityID == id && !$0.isRetracted }
            .sorted { lhs, rhs in
                if lhs.attribute != rhs.attribute { return lhs.attribute < rhs.attribute }
                return lhs.id < rhs.id
            }
        if !ownFacts.isEmpty {
            let lines = ownFacts.map { fact -> String in
                if let quote = fact.quoteAnchor?.quote, !quote.isEmpty {
                    return "- `\(fact.attribute)`: \(fact.value)（原文「\(quote)」）"
                }
                return "- `\(fact.attribute)`: \(fact.value)"
            }
            sections.append("## 当前事实\n" + lines.joined(separator: "\n"))
        }

        let ownBeliefs = beliefs
            .filter { $0.characterID == id }
            .sorted { lhs, rhs in
                if lhs.topic != rhs.topic { return lhs.topic < rhs.topic }
                return lhs.id < rhs.id
            }
        if (kind == .character || !ownBeliefs.isEmpty), !ownBeliefs.isEmpty {
            let lines = ownBeliefs.map { belief in
                let secretTag = belief.knowsSecret ? "已掌握" : "尚未知晓/存在盲区"
                return "- [\(secretTag)] \(belief.topic)：\(belief.believedTruth)"
            }
            sections.append("## 角色认知 B[c]\n" + lines.joined(separator: "\n"))
        }

        if !conflictWarnings.isEmpty {
            let lines = conflictWarnings.map { "- ⚠️ \($0)" }
            sections.append("## 待确认冲突\n" + lines.joined(separator: "\n"))
        }

        if !relatedEvents.isEmpty {
            let lines = relatedEvents.prefix(6).map { "- \($0.formattedSummaryLine)" }
            sections.append("## 关联关键事件\n" + lines.joined(separator: "\n"))
        }

        return sections.joined(separator: "\n\n")
    }
}

/// 关键事件状态：区分仍待推进的进行中事件与因果已闭合的完结事件。
enum EpisodicEventStatus: String, Codable, Hashable, CaseIterable {
    case ongoing
    case resolved

    var displayName: String {
        switch self {
        case .ongoing: return "进行中"
        case .resolved: return "已完结"
        }
    }
}

/// 结构化情节关键事件：桥接零散剧情节拍与高阶金字塔摘要，保留因果链、参与实体与故事线归属。
struct EpisodicEvent: Identifiable, Codable, Hashable {
    var id: String
    var title: String
    var arcTitle: String
    var scene: String
    var participantEntityIDs: [String]
    var cause: String
    var development: String
    var outcome: String
    var status: EpisodicEventStatus
    var authority: AuthorityRank
    var quoteAnchor: TextSpanAnchor?
    var nodeID: String
    var updatedAt: Date

    var formattedSummaryLine: String {
        var header = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanArc = arcTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanArc.isEmpty {
            header += " [\(cleanArc)]"
        }
        let cleanScene = scene.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanScene.isEmpty {
            header += "（\(cleanScene)）"
        }
        var clauses: [String] = []
        let cleanCause = cause.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDev = development.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOutcome = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanCause.isEmpty { clauses.append("起因：\(cleanCause)") }
        if !cleanDev.isEmpty { clauses.append("经过：\(cleanDev)") }
        if !cleanOutcome.isEmpty { clauses.append("结果：\(cleanOutcome)") }
        return clauses.isEmpty ? header : header + "｜" + clauses.joined(separator: "｜")
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        arcTitle: String = "",
        scene: String = "",
        participantEntityIDs: [String] = [],
        cause: String = "",
        development: String = "",
        outcome: String = "",
        status: EpisodicEventStatus = .ongoing,
        authority: AuthorityRank = .canonProseQuote,
        quoteAnchor: TextSpanAnchor? = nil,
        nodeID: String = "root",
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.arcTitle = arcTitle
        self.scene = scene
        self.participantEntityIDs = participantEntityIDs
        self.cause = cause
        self.development = development
        self.outcome = outcome
        self.status = status
        self.authority = authority
        self.quoteAnchor = quoteAnchor
        self.nodeID = nodeID
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        arcTitle = (try? c.decode(String.self, forKey: .arcTitle)) ?? ""
        scene = (try? c.decode(String.self, forKey: .scene)) ?? ""
        participantEntityIDs = (try? c.decode([String].self, forKey: .participantEntityIDs)) ?? []
        cause = (try? c.decode(String.self, forKey: .cause)) ?? ""
        development = (try? c.decode(String.self, forKey: .development)) ?? ""
        outcome = (try? c.decode(String.self, forKey: .outcome)) ?? ""
        status = (try? c.decode(EpisodicEventStatus.self, forKey: .status)) ?? .ongoing
        authority = (try? c.decode(AuthorityRank.self, forKey: .authority)) ?? .canonProseQuote
        quoteAnchor = try? c.decodeIfPresent(TextSpanAnchor.self, forKey: .quoteAnchor)
        nodeID = (try? c.decode(String.self, forKey: .nodeID)) ?? "root"
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }
}

/// 分层叙事时间摘要：由远及近保留卷纲、跨场情节闭包与近期场次卡片。
struct NarrativePyramid: Codable, Hashable {
    var volumeOneLiners: [String]
    var closedPlotlines: [String]
    var recentSceneCards: [String]
    var anchorIndexVersion: UInt64

    init(
        volumeOneLiners: [String] = [],
        closedPlotlines: [String] = [],
        recentSceneCards: [String] = [],
        anchorIndexVersion: UInt64 = 0
    ) {
        self.volumeOneLiners = volumeOneLiners
        self.closedPlotlines = closedPlotlines
        self.recentSceneCards = recentSceneCards
        self.anchorIndexVersion = anchorIndexVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        volumeOneLiners = (try? c.decode([String].self, forKey: .volumeOneLiners)) ?? []
        closedPlotlines = (try? c.decode([String].self, forKey: .closedPlotlines)) ?? []
        recentSceneCards = (try? c.decode([String].self, forKey: .recentSceneCards)) ?? []
        anchorIndexVersion = (try? c.decode(UInt64.self, forKey: .anchorIndexVersion)) ?? 0
    }
}

/// 分层叙事摘要的单步增量补丁。
struct NarrativePyramidPatch: Codable, Hashable {
    var addedVolumeOneLiners: [String]
    var addedClosedPlotlines: [String]
    var addedRecentSceneCards: [String]
    var anchorIndexVersion: UInt64?

    init(
        addedVolumeOneLiners: [String] = [],
        addedClosedPlotlines: [String] = [],
        addedRecentSceneCards: [String] = [],
        anchorIndexVersion: UInt64? = nil
    ) {
        self.addedVolumeOneLiners = addedVolumeOneLiners
        self.addedClosedPlotlines = addedClosedPlotlines
        self.addedRecentSceneCards = addedRecentSceneCards
        self.anchorIndexVersion = anchorIndexVersion
    }
}

/// 机械抽取锚点类别。
enum AnchorKind: String, Codable, Hashable {
    case entityMention
    case location
    case artifactOrCount
    case timeMarker
}

/// 基于确定性规则抽取的原文细节定位点，不消耗模型请求。
struct MechanicalAnchor: Identifiable, Codable, Hashable {
    var id: String
    var kind: AnchorKind
    var surfaceText: String
    var canonicalEntityID: String?
    var span: TextSpanAnchor

    init(
        id: String = UUID().uuidString,
        kind: AnchorKind,
        surfaceText: String,
        canonicalEntityID: String? = nil,
        span: TextSpanAnchor
    ) {
        self.id = id
        self.kind = kind
        self.surfaceText = surfaceText
        self.canonicalEntityID = canonicalEntityID
        self.span = span
    }
}

/// 原文机械定位索引，查询时严格遵守因果偏移截断以防泄露后续正文。
struct AnchorIndex: Codable, Hashable {
    var version: UInt64
    var anchors: [MechanicalAnchor]
    var indexedUTF16Length: Int

    init(
        version: UInt64 = 0,
        anchors: [MechanicalAnchor] = [],
        indexedUTF16Length: Int = 0
    ) {
        self.version = version
        self.anchors = anchors
        self.indexedUTF16Length = indexedUTF16Length
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(UInt64.self, forKey: .version)) ?? 0
        anchors = (try? c.decode([MechanicalAnchor].self, forKey: .anchors)) ?? []
        indexedUTF16Length = (try? c.decode(Int.self, forKey: .indexedUTF16Length)) ?? 0
    }

    func anchors(beforeUTF16 causalLimit: Int?) -> [MechanicalAnchor] {
        guard let causalLimit else { return anchors }
        return anchors.filter { anchor in
            anchor.span.utf16Start + anchor.span.utf16Length <= causalLimit
        }
    }

    func anchors(
        matching query: String,
        beforeUTF16 causalLimit: Int? = nil
    ) -> [MechanicalAnchor] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let scoped = anchors(beforeUTF16: causalLimit)
        guard !needle.isEmpty else { return scoped }
        return scoped.filter { anchor in
            anchor.surfaceText.localizedCaseInsensitiveContains(needle)
                || anchor.span.quote.localizedCaseInsensitiveContains(needle)
        }
    }

    /// 局部正文改写后增量更新锚点：移除受影响窗内旧锚点、平移下游 UTF-16 偏移并仅重抽邻域窗。
    mutating func adjustForEdit(
        range: NSRange,
        replacementUTF16Length: Int,
        updatedText: String,
        knownEntities: [EntityPage]
    ) {
        let nsUpdated = updatedText as NSString
        let editStart = max(0, range.location)
        let editEnd = max(editStart, editStart + max(0, range.length))
        let delta = max(0, replacementUTF16Length) - max(0, range.length)

        var oldWindowStart = max(0, editStart - 40)
        if oldWindowStart > 0 && oldWindowStart < nsUpdated.length {
            let ch = nsUpdated.character(at: oldWindowStart)
            if ch >= 0xDC00 && ch <= 0xDFFF {
                oldWindowStart -= 1
            }
        }
        let oldWindowEnd = editEnd + 40
        var newWindowEnd = min(nsUpdated.length, editStart + max(0, replacementUTF16Length) + 40)
        if newWindowEnd > oldWindowStart && newWindowEnd < nsUpdated.length {
            let tailCh = nsUpdated.character(at: newWindowEnd - 1)
            if tailCh >= 0xD800 && tailCh <= 0xDBFF {
                newWindowEnd -= 1
            }
        }

        let safePageSize = max(1, FileStore.bodyPageSize)
        var preserved: [MechanicalAnchor] = []
        preserved.reserveCapacity(anchors.count)
        for var anchor in anchors {
            let anchorStart = anchor.span.utf16Start
            let anchorEnd = anchorStart + anchor.span.utf16Length
            if anchorEnd > oldWindowStart && anchorStart < oldWindowEnd {
                continue
            }
            if anchorStart >= oldWindowEnd {
                anchor.span.utf16Start = max(0, anchorStart + delta)
                anchor.span.pageIndex = anchor.span.utf16Start / safePageSize
            }
            preserved.append(anchor)
        }

        let windowLen = max(0, newWindowEnd - oldWindowStart)
        let refreshed: [MechanicalAnchor]
        if windowLen > 0 {
            let windowText = nsUpdated.substring(with: NSRange(location: oldWindowStart, length: windowLen))
            refreshed = MechanicalAnchorExtractor.extract(
                from: windowText,
                knownEntities: knownEntities,
                pageIndex: oldWindowStart / FileStore.bodyPageSize,
                baseUTF16Offset: oldWindowStart
            )
        } else {
            refreshed = []
        }

        var seenIDs = Set<String>()
        anchors = (preserved + refreshed)
            .filter { seenIDs.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.span.utf16Start != rhs.span.utf16Start {
                    return lhs.span.utf16Start < rhs.span.utf16Start
                }
                return lhs.id < rhs.id
            }
        version &+= 1
        indexedUTF16Length = nsUpdated.length
    }
}

/// 对话历史分块可逆折叠边界：保留前部前缀稳定性并记录按步恢复存根。
struct ReFoldBoundary: Codable, Hashable {
    var boundaryTurnIndex: Int
    var stride: Int
    var foldedStepNotes: [Int: String]
    var deduplicatedStubs: [Int: String]

    init(
        boundaryTurnIndex: Int = 0,
        stride: Int = 3,
        foldedStepNotes: [Int: String] = [:],
        deduplicatedStubs: [Int: String] = [:]
    ) {
        self.boundaryTurnIndex = max(0, boundaryTurnIndex)
        self.stride = max(1, stride)
        self.foldedStepNotes = foldedStepNotes
        self.deduplicatedStubs = deduplicatedStubs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        boundaryTurnIndex = (try? c.decode(Int.self, forKey: .boundaryTurnIndex)) ?? 0
        stride = max(1, (try? c.decode(Int.self, forKey: .stride)) ?? 3)
        foldedStepNotes = (try? c.decode([Int: String].self, forKey: .foldedStepNotes)) ?? [:]
        deduplicatedStubs = (try? c.decode([Int: String].self, forKey: .deduplicatedStubs)) ?? [:]
    }

    /// 历史消息被删改、撤回或重插后，清理从受影响轮次起的折叠边界与存根，防止错位覆盖后续短消息。
    mutating func invalidate(fromTurnIndex turnIndex: Int) {
        if turnIndex <= 0 {
            boundaryTurnIndex = 0
            foldedStepNotes = [:]
            deduplicatedStubs = [:]
            return
        }
        let safeStride = max(1, stride)
        boundaryTurnIndex = min(boundaryTurnIndex, (turnIndex / safeStride) * safeStride)
        foldedStepNotes = foldedStepNotes.filter { $0.key < boundaryTurnIndex }
        deduplicatedStubs = deduplicatedStubs.filter { $0.key < turnIndex }
    }
}

/// 静态中文文风密度检查报告：记录每千字频次指标与标红原文片段。
struct StyleLintReport: Codable, Hashable {
    var metricsPer1KChars: [String: Double]
    var flaggedSpans: [TextSpanAnchor]
    var checkedAt: Date

    init(
        metricsPer1KChars: [String: Double] = [:],
        flaggedSpans: [TextSpanAnchor] = [],
        checkedAt: Date = Date()
    ) {
        self.metricsPer1KChars = metricsPer1KChars
        self.flaggedSpans = flaggedSpans
        self.checkedAt = checkedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metricsPer1KChars = (try? c.decode([String: Double].self, forKey: .metricsPer1KChars)) ?? [:]
        flaggedSpans = (try? c.decode([TextSpanAnchor].self, forKey: .flaggedSpans)) ?? []
        checkedAt = (try? c.decode(Date.self, forKey: .checkedAt)) ?? Date()
    }
}

/// 深度蒸馏保留资产：存放既有仿写模板、笔记与质心/场景示范节选，便于静态与动态分流装配。
struct PreservedStyleDistillation: Codable, Hashable {
    var styleTemplate: String
    var styleNotes: String
    var centroidExemplar: CorpusEntry?
    var exemplars: [CorpusEntry]

    var isEmpty: Bool {
        styleTemplate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && styleNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && centroidExemplar == nil
            && exemplars.isEmpty
    }

    init(
        styleTemplate: String = "",
        styleNotes: String = "",
        centroidExemplar: CorpusEntry? = nil,
        exemplars: [CorpusEntry] = []
    ) {
        self.styleTemplate = styleTemplate
        self.styleNotes = styleNotes
        self.centroidExemplar = centroidExemplar
        self.exemplars = exemplars
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        styleTemplate = (try? c.decode(String.self, forKey: .styleTemplate)) ?? ""
        styleNotes = (try? c.decode(String.self, forKey: .styleNotes)) ?? ""
        centroidExemplar = try? c.decodeIfPresent(CorpusEntry.self, forKey: .centroidExemplar)
        exemplars = (try? c.decode([CorpusEntry].self, forKey: .exemplars)) ?? []
    }
}
