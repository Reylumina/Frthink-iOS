import Foundation

/// 世界任务共用的一次性请求上下文：当前服务商、客户端与统一请求参数。
///
/// 统一构建 `LLMRequest` 与获取 activeProvider，各工作流专注于上下文消息与截断控制。
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
    /// 统一调用此处，确保 `maxTokens` 满足大批量 JSON 结构输出需求。
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

    func completeOrThrow(
        _ messages: [LLMMessage],
        provider providerOverride: ProviderSetting? = nil,
        failOnLength: Bool = false,
        errorPrefix: String
    ) async throws -> String {
        do {
            let raw = try await complete(
                messages,
                provider: providerOverride,
                failOnLength: failOnLength
            )
            try Task.checkCancellation()
            return raw
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if error.isLLMCancellation { throw CancellationError() }
            throw WorldRunError(message: "\(errorPrefix)：\(error.localizedDescription)")
        }
    }

    func completeAndParse<T>(
        _ messages: [LLMMessage],
        provider providerOverride: ProviderSetting? = nil,
        failOnLength: Bool = true,
        requestErrorPrefix: String,
        parseErrorPrefix: String,
        parse: (String) throws -> T
    ) async throws -> T {
        let raw = try await completeOrThrow(
            messages,
            provider: providerOverride,
            failOnLength: failOnLength,
            errorPrefix: requestErrorPrefix
        )
        do {
            return try parse(raw)
        } catch {
            throw WorldRunError(
                message: "\(parseErrorPrefix)：\(error.localizedDescription)",
                rawResponse: raw
            )
        }
    }
}
