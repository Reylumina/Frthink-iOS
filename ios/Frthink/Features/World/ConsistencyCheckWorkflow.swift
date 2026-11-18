import Foundation

/// 按需触发的一致性审校工作流（不阻塞续写热路径）。
///
/// 结合 `ConStory-Checker` 五维矛盾分类（时间线/人物认知/世界规则/事实细节/视角风格）
/// 与 `Writer-R1` 可观测证据链，对当前末尾片段对照既有动态快照、伏笔与早期历史片段进行核查。
@MainActor
enum ConsistencyCheckWorkflow {

    struct CheckOutcome {
        let issues: [WorldJSON.ConsistencyIssue]

        var summary: String {
            issues.isEmpty
                ? "一致性审校通过：未发现明显前后矛盾。"
                : "一致性审校完成：发现 \(issues.count) 处潜在矛盾。"
        }
    }

    static func checkTail(
        session: ProjectSession,
        store: AppStore,
        tailCodePoints: Int = 3_000
    ) async throws -> CheckOutcome {
        let manuscript = session.manuscript
        guard !manuscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorldRunError(message: "当前正文为空，无法执行一致性审校。")
        }

        let context = try WorldRequestContext.make(store: store)
        let tail = PromptComposer.codePointTail(manuscript, limit: tailCodePoints)
        let activeCards = PromptComposer.activeCharacters(in: session.payload.world)
        let queryTerms = activeCards.flatMap { [$0.name] + $0.aliases }
        let historical = ManuscriptIndex.recallHistoricalExcerpts(
            fullManuscript: manuscript,
            activeWindowText: tail,
            queryTerms: queryTerms,
            maxResults: 4,
            maxTokens: 900
        )

        let messages = buildMessages(
            tailExcerpt: tail,
            historicalExcerpts: historical.map(\.text),
            characters: activeCards,
            openThreads: session.payload.world.openThreads.filter { $0.status == .open }
        )
        let issues = try await context.completeAndParse(
            messages,
            failOnLength: true,
            requestErrorPrefix: "一致性审校请求失败",
            parseErrorPrefix: "一致性审校解析失败",
            parse: WorldJSON.parseConsistencyIssues
        )
        return CheckOutcome(issues: issues)
    }

    static func buildMessages(
        tailExcerpt: String,
        historicalExcerpts: [String],
        characters: [CharacterCard],
        openThreads: [PlotThread]
    ) -> [LLMMessage] {
        let charContext: String = characters.isEmpty
            ? "（暂无角色卡）"
            : characters.map { card in
                var parts = ["• \(card.name)"]
                if !card.identity.isEmpty { parts.append("身份：\(card.identity)") }
                if let snap = card.dynamicSnapshot?.renderedSummary(characterName: card.name) {
                    parts.append(snap)
                }
                return parts.joined(separator: "｜")
            }.joined(separator: "\n")

        let threadContext: String = openThreads.isEmpty
            ? "（暂无未决伏笔）"
            : openThreads.map(\.renderedLine).joined(separator: "\n")

        let historyContext: String = historicalExcerpts.isEmpty
            ? "（无额外历史片段）"
            : historicalExcerpts.joined(separator: "\n---\n")

        let system = """
        你是一个严格的小说连续性审校专家。请对照「既有角色与快照」「未决伏笔」「早期相关正文」，检查「待审校末尾正文」是否存在客观矛盾，并输出严格 JSON 对象（不要输出额外闲聊）：

        {
          "issues": [
            {
              "category": "时间线与逻辑 | 人物认知与记忆 | 世界规则与地理 | 事实细节与称谓 | 视角与文风",
              "severity": "高 | 中 | 低",
              "fact_quote": "既定事实或前文原句证据",
              "contradiction_quote": "待审校正文中的矛盾原句",
              "reason": "矛盾原因说明与最小修改建议"
            }
          ]
        }

        要求：
        1. 只报告有明确文本证据的真矛盾，有意设置的悬念或角色谎言不算矛盾。
        2. 重点核查：角色是否说出了他尚未获知的情报、伤势/持有物/地理位置是否突变、称谓/数字是否前后冲突、人称视角是否突然跳变。
        3. 若未发现任何矛盾，返回 `{"issues": []}`。
        """

        let user = """
        # 既有角色与快照
        \(charContext)

        # 未决伏笔
        \(threadContext)

        # 早期相关正文
        \(historyContext)

        # 待审校末尾正文
        \(tailExcerpt)
        """

        return [.system(system), .user(user)]
    }
}
