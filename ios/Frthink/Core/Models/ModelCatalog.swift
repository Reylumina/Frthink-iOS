import Foundation

/// 模型目录。
///
/// 模型名称为空时禁止随意推断或沿用过期名称：占位与默认兜底均统一采用
/// **截至 `asOf` 当天各服务商在售的最新模型**。
///
/// `asOf = 2026-11-08` 的依据（DeepSeek 官方 changelog）：
/// - `deepseek-chat` / `deepseek-reasoner` 已于 2026-07-24 弃用；
/// - 现行模型名是 `deepseek-flash`，指向 DeepSeek-V4.1-Flash-1017（2026-10-17）；
/// - `deepseek-v4-pro` 仍在服务，`deepseek-v4-flash` 会路由到 V4.1；
/// - 上下文 1M token，最大输出 384K。
///
/// 此列表仅用于**占位与缺省兜底**。实际发送请求时，优先使用用户配置；
/// 用户未配置时采用该默认值，确保未指定模型时流程仍可正常执行。
enum ModelCatalog {

    /// 目录版本。界面上标注「截至 2026-11-08」，让用户知道这个默认值的时效。
    static let asOf = "2026-11-08"

    /// 各家在 `asOf` 当天的最新模型。
    static func latest(for kind: ProviderKind) -> String? {
        switch kind {
        case .deepseek:
            return "deepseek-flash"
        case .openRouter:
            // 实测 `GET https://openrouter.ai/api/v1/models`：
            // `deepseek/deepseek-v4.1-flash-1017`（created 1792225624，2026-10-17）
            // 比滚动别名 `deepseek/deepseek-v4.1-flash` 更新，取快照版。
            return "deepseek/deepseek-v4.1-flash-1017"
        case .anthropic:
            return "claude-sonnet-4-5"
        case .openAICompatible:
            return nil
        case .openCodeGo:
            return "deepseek-v4.1-flash"
        }
    }

    /// 该模型名是否属于已弃用但仍可路由的历史别名。
    static func isDeprecated(_ model: String) -> Bool {
        let name = model.lowercased()
        return name == "deepseek-chat" || name == "deepseek-reasoner"
    }

    /// 上下文窗口。`deepseek-flash` 与 `deepseek-v4-pro` 都是 1M。
    static func contextWindow(for model: String) -> Int? {
        let name = model.lowercased()
        if name.contains("deepseek") { return 1_000_000 }
        if name.contains("claude") { return 200_000 }
        return nil
    }
}

