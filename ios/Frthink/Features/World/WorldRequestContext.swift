import Foundation

/// 世界任务共用的一次性请求上下文：当前服务商、客户端与统一请求参数。
///
/// 各 workflow 只关心 messages 和是否拦截截断，不再各自拼 `LLMRequest`
/// 或重复取 activeProvider，减少世界刷新/素材/规则之间的耦合。
struct WorldRequestContext {
    let client: any LLMClient
    let provider: ProviderSetting

    @MainActor
    static func make(store: AppStore) throws -> Self {
        guard let provider = store.settings.activeProvider else {
            throw LLMError.notConfigured
        }
        let client = try store.clientForActiveProvider()
        return Self(client: client, provider: provider)
    }

    /// 世界任务统一的请求参数：输出预算至少 4096，截断按 `failOnLength` 处理。
    ///
    /// 去重这类自己发请求的步骤也走这里，避免各写一个 `maxTokens`（曾经是 2048，
    /// 大候选批的 JSON 会在输出上限处被截断）。
    static func request(
        provider: ProviderSetting,
        messages: [LLMMessage],
        failOnLength: Bool
    ) -> LLMRequest {
        LLMRequest(
            model: provider.resolvedModel,
            messages: messages,
            stream: false,
            temperature: provider.temperature,
            maxTokens: max(provider.maxTokens, 4_096),
            failOnLength: failOnLength
        )
    }

    /// 摘要模型留空时跟随当前服务商；传入 provider 只覆盖本次请求。
    func complete(
        _ messages: [LLMMessage],
        provider providerOverride: ProviderSetting? = nil,
        failOnLength: Bool = false
    ) async throws -> String {
        let target = providerOverride ?? provider
        return try await client.complete(
            Self.request(
                provider: target,
                messages: messages,
                failOnLength: failOnLength
            )
        )
    }
}
