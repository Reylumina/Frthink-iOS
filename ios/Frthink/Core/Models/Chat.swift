import Foundation

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
    /// 生成这条回复时用的模型，便于回看。
    var model: String?

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

    var hasBranches: Bool { variants.count > 1 }

    init(
        id: String = UUID().uuidString,
        role: Role,
        content: String = "",
        createdAt: Date = Date(),
        model: String? = nil
    ) {
        self.id = id
        self.role = role
        self.variants = [content]
        self.selectedVariant = 0
        self.createdAt = createdAt
        self.model = model
    }
}

/// 译文分段。对应 Android 端 `translation_segments` 表：
/// 主键是 (owner, project, target, sourceHash, segment)。
///
/// `sourceHash` 是原文分段内容的哈希，原文没变就命中缓存，不再请求 LLM。
struct TranslationSegment: Identifiable, Codable, Hashable {
    var id: String
    /// 设备/账号归属，Android 端用 `owner` 区分同一台机器上的多用户隔离。
    var owner: String
    var project: String
    /// 目标语言，目前只有 `zh-CN`。
    var target: String
    var sourceHash: String
    var segment: Int
    var payload: String
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        owner: String,
        project: String,
        target: String = "zh-CN",
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
