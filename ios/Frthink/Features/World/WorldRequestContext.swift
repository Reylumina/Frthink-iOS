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

    /// 摘要模型留空时跟随当前服务商；传入 provider 只覆盖本次请求。
    func complete(
        _ messages: [LLMMessage],
        provider providerOverride: ProviderSetting? = nil,
        failOnLength: Bool = false
    ) async throws -> String {
        let target = providerOverride ?? provider
        let request = LLMRequest(
            model: target.resolvedModel,
            messages: messages,
            stream: false,
            temperature: target.temperature,
            maxTokens: max(target.maxTokens, 4096),
            failOnLength: failOnLength
        )
        return try await client.complete(request)
    }
}
