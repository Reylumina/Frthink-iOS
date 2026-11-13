import Foundation

/// 宇宙层：跨书项目共享的设定与预设。
///
/// 和「世界」的区别在数据归属上——世界的资料只属于一本书
/// （`ProjectPayload.world`），宇宙资料属于全局（`AppSettings.universeEntries`），
/// 每本书单独决定启用哪几条（`ProjectPayload.enabledUniverseEntryIDs`）。
///
/// 原版的证据：设置项 `settings.universeWorldbooks`、状态
/// `DreamUiState.enabledUniverseEntryIds`，页面文案
/// 「全局预设、共享世界书与 Skill」「每本书仍需单独启用」。
struct UniverseEntry: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// 全局预设：一段通用的写作/讨论前提。
        case preset
        /// 共享世界书：可被多本书同时引用的设定。
        case worldbook
        /// Skill：一段可复用的指令模板。
        case skill

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .preset: return "全局预设"
            case .worldbook: return "共享世界书"
            case .skill: return "Skill"
            }
        }
    }

    var id: String
    var title: String
    var body: String
    var kind: Kind
    /// 全局开关：关掉后所有书都不再注入；每本书的勾选仍单独保存。
    var enabled: Bool
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        title: String,
        body: String = "",
        kind: Kind = .worldbook,
        enabled: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.kind = kind
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    /// 旧存档没有 `enabled` 键；原版默认启用，缺省按 true 解码。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = (try? c.decode(String.self, forKey: .title)) ?? ""
        body = (try? c.decode(String.self, forKey: .body)) ?? ""
        kind = (try? c.decode(Kind.self, forKey: .kind)) ?? .worldbook
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, body, kind, enabled, updatedAt
    }
}
