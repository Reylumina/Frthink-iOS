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
            selected = Array(
                session.payload.messages.filter { $0.role == .user }.suffix(12)
            )
        }
        let recentMessages = selected
            .map { $0.content.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !recentMessages.isEmpty else {
            throw WorldRunError(
                message: "还没有可整理的用户消息。先在码字机里提出写作要求，再来更新长期规则。"
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
            if case .truncated = error {
                throw WorldRunError(message: "摘要达到模型输出上限，未替换现有摘要。")
            }
            throw WorldRunError(message: "摘要未更新：\(error.localizedDescription)")
        } catch {
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

}
