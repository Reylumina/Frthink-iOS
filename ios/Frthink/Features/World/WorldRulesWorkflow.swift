import Foundation

/// 长期写作规则：读取 P12 日志，按 P54/P55 增量整理。
@MainActor
enum WorldRulesWorkflow {

    struct RulesOutcome {
        let updated: Bool

        var summary: String {
            updated ? "长期规则已更新。" : "长期规则没有变化。"
        }
    }

    // MARK: - 长期规则

    static func updateLongTermRules(
        session: ProjectSession,
        store: AppStore,
        sourceMessages: [ChatMessage]? = nil
    ) async throws -> RulesOutcome {
        let selected: [ChatMessage]
        if let sourceMessages {
            selected = sourceMessages
        } else {
            selected = Self.pendingUserMessages(
                session.payload.messages,
                summarized: session.payload.world.summarizedMessageIDs
            )
        }
        let recentMessages = selected
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !recentMessages.isEmpty else {
            // 已经进过摘要的轮次不再重复发送：连点两次不该把同一批消息再送一遍。
            throw WorldRunError(
                message: session.payload.messages.contains { $0.role == .user }
                    ? "没有新的用户消息可整理；已经整理过的对话不会重复发送。"
                    : "还没有可整理的用户消息。先在码字机里提出写作要求，再来更新长期规则。"
            )
        }

        let context: WorldRequestContext
        do {
            context = try WorldRequestContext.make(store: store)
        } catch let error as LLMError {
            switch error {
            case .notConfigured, .missingAPIKey:
                throw WorldRunError(message: "摘要未发送：尚未配置云 API。")
            default:
                throw WorldRunError(message: "摘要未发送：\(error.localizedDescription)")
            }
        }
        // 摘要模型留空时跟随当前供应方；填了只覆盖这次请求的 model。
        var provider = context.provider
        let summaryModel = store.settings.summaryModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !summaryModel.isEmpty {
            provider.model = summaryModel
        }
        let messages = PromptComposer.longTermRulesMessages(
            existingLog: session.payload.world.longTermRules,
            recentUserMessages: recentMessages
        )
        let budget: PromptBudget
        do {
            budget = try PromptBudget.make(
                settings: store.settings,
                model: provider.resolvedModel
            )
        } catch {
            throw WorldRunError(message: error.localizedDescription)
        }
        let firstTokens = TokenEstimator.estimate(recentMessages[0])
        if firstTokens > budget.effectiveInputBudget {
            throw WorldRunError(
                message: "首条待整理消息超过摘要预算：单条 \(firstTokens) token，上限 \(budget.effectiveInputBudget) token；没有发送请求。"
            )
        }
        let estimated = TokenEstimator.estimate(messages: messages)
        if estimated > budget.effectiveInputBudget {
            throw WorldRunError(
                message: "摘要请求超过预算：估算 \(estimated) token，上限 \(budget.effectiveInputBudget) token；没有发送请求。"
            )
        }
        let raw: String
        do {
            raw = try await context.complete(
                messages,
                provider: provider,
                failOnLength: true
            )
        } catch let error as LLMError {
            if error.isLLMCancellation { throw CancellationError() }
            if case .truncated = error {
                throw WorldRunError(message: "摘要达到模型输出上限，未替换现有摘要。")
            }
            throw WorldRunError(message: "摘要未更新：\(error.localizedDescription)")
        } catch {
            if error.isLLMCancellation { throw CancellationError() }
            throw WorldRunError(message: "摘要未更新：\(error.localizedDescription)")
        }

        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw WorldRunError(
                message: "长期规则更新返回了空响应。",
                rawResponse: raw
            )
        }
        if WorldMerge.isNoAdditions(text) {
            return RulesOutcome(updated: false)
        }
        guard text != session.payload.world.longTermRules else {
            return RulesOutcome(updated: false)
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let keys = selected.map {
            SummaryKey.messageKey(id: $0.id, content: $0.content)
        }
        let changed = session.payload.world.applySummaryUpdate(
            content: text,
            newKeys: keys,
            now: now
        )
        session.scheduleSave()
        return RulesOutcome(updated: changed)
    }

    // MARK: - 输入

    /// 手动「用最近对话更新」只取还没进过摘要的用户消息。
    ///
    /// 以前固定取最后 12 条用户消息：连点两次会把同一批轮次重复送进 P55，
    /// 每次都多一版历史；与自动摘要（`WriterController` 先过滤已摘要 id）的口径也不一致。
    static func pendingUserMessages(
        _ messages: [ChatMessage],
        summarized: [String],
        limit: Int = 12
    ) -> [ChatMessage] {
        let done = Set(summarized)
        return Array(
            messages
                .filter { $0.role == .user && !done.contains($0.id) }
                .suffix(limit)
        )
    }

}
