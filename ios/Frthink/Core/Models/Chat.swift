import Foundation

/// 单条对话消息在上下文组装中的参与策略（非破坏性，不影响本地展示与存档）。
enum MessageContextMode: String, Codable, Hashable {
    /// 正常发送完整内容。
    case normal
    /// 发送中性事实摘要，隔离原感官/细节描写对注意力的干扰。
    case summaryOnly
    /// 暂时不发给模型，但仍保留在本地对话流中。
    case excluded
}

/// 码字机里的一条消息。
///
/// 分支/版本用 `variants` 表达：同一条助手回复重新生成时追加一个变体，
/// 切换变体只改 `selectedVariant`，不新增消息。这样正文锚点不会因为
/// 重新生成而失效。
struct ChatMessage: Identifiable, Codable, Hashable {
    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    var id: String
    var role: Role
    var variants: [String]
    var selectedVariant: Int
    var createdAt: Date
    /// 生成该回复所使用的模型名称，便于历史回溯。
    var model: String?
    /// 各版本对应的思考过程（思维链），与 `variants` 下标一一对应；nil 表示未记录。
    var variantReasonings: [String]?
    /// 上下文剪枝策略；缺省为 `.normal`。
    var contextMode: MessageContextMode
    /// 当 `contextMode == .summaryOnly` 时发给模型的中性摘要。
    var prunedSummary: String

    private enum CodingKeys: String, CodingKey {
        case id, role, variants, selectedVariant, createdAt, model, variantReasonings, contextMode, prunedSummary
    }

    var content: String {
        get {
            guard variants.indices.contains(selectedVariant) else { return "" }
            return variants[selectedVariant]
        }
        set {
            if variants.indices.contains(selectedVariant) {
                variants[selectedVariant] = newValue
            } else if variants.isEmpty {
                variants = [newValue]
                selectedVariant = 0
            }
        }
    }

    var reasoning: String? {
        guard let list = variantReasonings,
              list.indices.contains(selectedVariant) else { return nil }
        let text = list[selectedVariant]
        return text.isEmpty ? nil : text
    }

    mutating func setReasoning(_ text: String?, forVariant index: Int) {
        let value = text ?? ""
        if value.isEmpty, variantReasonings == nil { return }
        var list = variantReasonings ?? Array(repeating: "", count: variants.count)
        while list.count < variants.count { list.append("") }
        if list.indices.contains(index) {
            list[index] = value
        }
        variantReasonings = list
    }

    var hasBranches: Bool { variants.count > 1 }

    init(
        id: String = UUID().uuidString,
        role: Role,
        content: String = "",
        createdAt: Date = Date(),
        model: String? = nil,
        variantReasonings: [String]? = nil,
        contextMode: MessageContextMode = .normal,
        prunedSummary: String = ""
    ) {
        self.id = id
        self.role = role
        self.variants = [content]
        self.selectedVariant = 0
        self.createdAt = createdAt
        self.model = model
        self.variantReasonings = variantReasonings
        self.contextMode = contextMode
        self.prunedSummary = prunedSummary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        role = try c.decode(Role.self, forKey: .role)
        variants = try c.decode([String].self, forKey: .variants)
        selectedVariant = try c.decode(Int.self, forKey: .selectedVariant)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        variantReasonings = try c.decodeIfPresent([String].self, forKey: .variantReasonings)
        contextMode = (try? c.decode(MessageContextMode.self, forKey: .contextMode)) ?? .normal
        prunedSummary = (try? c.decode(String.self, forKey: .prunedSummary)) ?? ""
    }
}

/// 译文分段。对应 Android 端 `translation_segments` 表：
/// 主键是 (owner, project, target, sourceHash, segment)。
///
/// `sourceHash` 是原文分段内容的哈希，原文没变就命中缓存，不再请求 LLM。
struct TranslationSegment: Identifiable, Codable, Hashable {
    /// 正文译文目标标记，与 Android 端保持一致。
    static let defaultTarget = "body"

    var id: String
    /// 设备/账号归属，Android 端用 `owner` 区分同一台机器上的多用户隔离。
    var owner: String
    var project: String
    /// 目标语言标记，默认 `body`。
    var target: String
    var sourceHash: String
    var segment: Int
    var payload: String
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, owner, project, target, sourceHash, segment, payload, updatedAt
        // Android 存档用 index/text；只读不写，方便同一份 JSON 两端都能解。
        case index, text
    }

    /// 存档导出与 Android 端共用数据格式：外部数据可能缺失 `updatedAt` 字段，
    /// 缺失时使用当前时间填充，避免因单条时间戳缺失导致整段译文丢失。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        owner = (try? c.decode(String.self, forKey: .owner)) ?? ""
        project = (try? c.decode(String.self, forKey: .project)) ?? ""
        target = (try? c.decode(String.self, forKey: .target)) ?? Self.defaultTarget
        // 兼容旧版持久化的 `"zh-CN"` 与空值，统一归一化为 `"body"`。
        if target.isEmpty || target == "zh-CN" {
            target = Self.defaultTarget
        }
        let hash = (try? c.decode(String.self, forKey: .sourceHash)) ?? ""
        guard !hash.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .sourceHash,
                in: c,
                debugDescription: "译文缺少 sourceHash"
            )
        }
        sourceHash = hash
        segment = (try? c.decode(Int.self, forKey: .segment))
            ?? (try? c.decode(Int.self, forKey: .index))
            ?? 0
        payload = (try? c.decode(String.self, forKey: .payload))
            ?? (try? c.decode(String.self, forKey: .text))
            ?? ""
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }

    /// 内部落盘只写 iOS 键，不把 Android 的 index/text 冗余写进 translations.json。
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(owner, forKey: .owner)
        try c.encode(project, forKey: .project)
        try c.encode(target, forKey: .target)
        try c.encode(sourceHash, forKey: .sourceHash)
        try c.encode(segment, forKey: .segment)
        try c.encode(payload, forKey: .payload)
        try c.encode(updatedAt, forKey: .updatedAt)
    }

    init(
        id: String = UUID().uuidString,
        owner: String,
        project: String,
        target: String = TranslationSegment.defaultTarget,
        sourceHash: String,
        segment: Int,
        payload: String,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.owner = owner
        self.project = project
        self.target = target
        self.sourceHash = sourceHash
        self.segment = segment
        self.payload = payload
        self.updatedAt = updatedAt
    }
}
