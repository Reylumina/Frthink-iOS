import Foundation

/// 素材归纳、文风笔记、剧情梗概与事件卡。
extension PromptComposer {

    // MARK: - §5 素材归纳

    /// 素材归纳（仿写模板 / 剧情梗概两套，`z3` 决定）。
    ///
    /// system：P35 契约（归纳预设 P19 + 内置附录 P36）→ P37 只读基线 → P38 待归纳正文；
    /// user：P39「只返回新增内容」。
    static func materialMessages(
        plot: Bool,
        baseline: String,
        digest: String,
        instruction: String? = nil
    ) -> [LLMMessage] {
        var blocks: [PromptBlock] = []

        // P35 · task:material-contract（locked）
        // 未验证：触发点不明确（§14 第 5 条：契约 = 预设 + 附录 属强推断）
        blocks.append(PromptBlock(
            key: "task:material-contract",
            category: .agentPrompt,
            title: "",
            body: PromptLibrary.materialContract(plot: plot, instruction: instruction),
            locked: true
        ))

        // P37 · task:material-baseline（locked，世界资料）；基线为空时正文取「（暂无）」
        blocks.append(PromptBlock(
            key: "task:material-baseline",
            category: .worldbook,
            title: PromptLibrary.materialBaselineTitle(plot: plot),
            body: baseline.isEmpty
                ? PromptMarkers.baselinePlaceholder.rawValue
                : baseline,
            locked: true
        ))

        // P38 · task:material-body · 待归纳正文（locked，正文）
        blocks.append(PromptBlock(
            key: "task:material-body",
            category: .authoritativeBody,
            title: PromptLibrary.materialBodyTitle,
            body: digest,
            locked: true
        ))

        var messages: [LLMMessage] = []
        let system = systemPrompt(from: blocks)
        if !system.isEmpty { messages.append(.system(system)) }
        // P39 · user 消息
        messages.append(.user(PromptLibrary.incrementalMaterialUserMessage(plot: plot)))
        return messages
    }

    /// 文风笔记抽取 = 素材归纳的仿写模板版（写回 `world.styleNotes`）。
    static func styleNotesMessages(
        existingTemplate: String,
        digest: String,
        instruction: String? = nil
    ) -> [LLMMessage] {
        materialMessages(
            plot: false,
            baseline: existingTemplate,
            digest: digest,
            instruction: instruction
        )
    }

    /// 剧情梗概的素材归纳（§5 的剧情版，`task:world-plot-outline` 任务类型）。
    static func plotMaterialMessages(
        existingPlotOutline: String,
        digest: String,
        instruction: String? = nil
    ) -> [LLMMessage] {
        materialMessages(
            plot: true,
            baseline: existingPlotOutline,
            digest: digest,
            instruction: instruction
        )
    }

    /// 分段文风笔记（P40）。
    static func segmentStyleNotesMessages(segment: String) -> [LLMMessage] {
        [.system(PromptLibrary.segmentStyleNotesInstruction), .user(segment)]
    }

    /// 文风笔记合并（P41）。
    static func styleNotesMergeMessages(notes: [String]) -> [LLMMessage] {
        [.system(PromptLibrary.styleNotesMergeInstruction), .user(notes.joined(separator: "\n\n"))]
    }

    /// 全书文风笔记整合成仿写模板（P42/P43）。
    static func styleSynthesisMessages(notes: String) -> [LLMMessage] {
        [
            .system(
                PromptLibrary.styleSynthesisInstruction
                    + "\n"
                    + PromptLibrary.styleSynthesisOutputInstruction
            ),
            .user(notes),
        ]
    }

    /// 已有模板只读，只追加本轮新增规则（P44/P45）。
    static func styleAppendMessages(
        existingTemplate: String,
        notes: String
    ) -> [LLMMessage] {
        [
            .system(
                PromptLibrary.styleAppendInstruction
                    + "\n"
                    + PromptLibrary.styleAppendOutputInstruction
            ),
            .user(
                PromptLibrary.existingImitationTemplateTitle
                    + "\n"
                    + existingTemplate
                    + "\n\n"
                    + PromptLibrary.styleNotesBlockTitle
                    + "\n"
                    + notes
            ),
        ]
    }

    // MARK: - §7 剧情梗概 / 事件卡

    /// 事件卡抽取。
    ///
    /// system：P48（初次）或 P49（增量）+ P50 或 P51 的 JSON 契约。
    /// user：P52 正文剧情事实 → P53 已有剧情梗概（只读）这两块只读数据。
    ///
    /// 规格 §7 没有定义 user 指令，所以 user 消息只放数据块，不自拟指令。
    static func eventMessages(
        existingEvents: [EventCard],
        digest: String,
        instruction: String? = nil
    ) -> [LLMMessage] {
        let incremental = !existingEvents.isEmpty
        let taskKey = "task:world-plot-outline:" + shortHash(digest)

        let systemBlocks: [PromptBlock] = [
            PromptBlock(
                key: taskKey,
                category: .agentPrompt,
                title: "",
                body: instruction ?? (incremental
                    ? PromptLibrary.plotIncrementalInstruction
                    : PromptLibrary.plotInitialInstruction),
                locked: true
            ),
            // P50/P51 在规格里没有独立块键，属于同一个任务块。
            PromptBlock(
                key: "",
                category: .agentPrompt,
                title: "",
                body: incremental
                    ? PromptLibrary.eventContractIncremental
                    : PromptLibrary.eventContractInitial
            ),
        ]

        var userBlocks: [PromptBlock] = [
            // P52 · 正文剧情事实（块正文 = 本段正文）
            PromptBlock(
                key: "",
                category: .worldbook,
                title: PromptLibrary.plotFactsTitle,
                body: digest
            ),
        ]
        // P53 · task:existing-plot-outline:<哈希前12> · 已有剧情梗概（只读）
        if incremental {
            userBlocks.append(PromptBlock(
                key: "task:existing-plot-outline:" + shortHash(digest),
                category: .worldbook,
                title: PromptLibrary.existingPlotOutlineTitle,
                body: renderEvents(existingEvents)
            ))
        }

        // 正文为空时只发系统侧的指令与契约：不发一个正文为空的「正文剧情事实」块。
        guard !digest.isEmpty else { return [.system(systemPrompt(from: systemBlocks))] }

        return [
            .system(systemPrompt(from: systemBlocks)),
            .user(systemPrompt(from: userBlocks)),
        ]
    }

    // MARK: - §8 长期写作规则日志

    /// 长期规则维护：system 是 P54，user 是 P55 的逐轮拼装。
    static func longTermRulesMessages(existingLog: String, recentUserMessages: [String]) -> [LLMMessage] {
        [
            .system(PromptLibrary.conversationRulesSystem),
            .user(PromptLibrary.longTermRulesUserMessage(
                priorSummary: existingLog,
                turns: recentUserMessages
            )),
        ]
    }

}
