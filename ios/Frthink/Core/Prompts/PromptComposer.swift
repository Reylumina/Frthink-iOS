import Foundation

/// 把世界资料 + 正文按规格 §1 的顺序拼成 messages。
///
/// **顺序就是语义**：§1 那 14 行是产品的装配顺序，改顺序模型行为就变了。
/// 逐条对应关系见 `writingBlocks(_:)` 里的注释。
enum PromptComposer {

    // MARK: - §1 主写作请求的块顺序

    /// 规格 §1 的 14 行顺序表（第 13 行由调用方追加、第 14 行是历史消息，不在这里）。
    ///
    /// 返回顺序：1 项目补充指令 → 2 全局预设 → 3 技能 → 4 审查规则 → 5 宇宙世界书
    /// → 6 仿写模板 → 7 剧情梗概 → 8 语料 → 9 世界书词条 → 10 人物卡
    /// → 11 长期规则摘要 → 12 正文。
    static func writingBlocks(_ assembly: PromptAssembly) -> [PromptBlock] {
        var blocks: [PromptBlock] = []

        // 1 · assistant:project:<projectId> · 智能体指令 · 本书写作助手补充指令 · P02
        if !assembly.projectAssistantInstruction.isEmpty {
            blocks.append(PromptBlock(
                key: "assistant:project:" + assembly.projectID,
                category: .agentPrompt,
                title: "本书写作助手补充指令",
                body: PromptLibrary.render(PromptLibrary.projectAssistantTemplate, [
                    "本书写作助手补充指令正文": assembly.projectAssistantInstruction,
                ])
            ))
        }

        // 2 · preset:global · 全局预设 · 全局预设 · P03
        // P03 没有独立字面量：正文就是用户填写的预设原文，不加任何前后缀。
        if !assembly.globalPreset.isEmpty {
            blocks.append(PromptBlock(
                key: "preset:global",
                category: .preset,
                title: "全局预设",
                body: assembly.globalPreset
            ))
        }

        // 3 · skill:<skillId> · 技能 · 技能：<名称> · P04
        for skill in assembly.skills {
            blocks.append(PromptBlock(
                key: "skill:" + skill.id,
                category: .skill,
                title: "技能：" + skill.name,
                body: PromptLibrary.render(PromptLibrary.skillBlockTemplate, [
                    "技能名": skill.name,
                    "技能内容": skill.content,
                ]),
                hasOwnHeading: true
            ))
        }

        // 4 · preference:style · 技能 · 全局审查规则 · P05
        if !assembly.aiFlavorRules.isEmpty {
            blocks.append(PromptBlock(
                key: "preference:style",
                category: .skill,
                title: "全局审查规则",
                body: PromptLibrary.render(PromptLibrary.stylePreferenceTemplate, [
                    "aiFlavorRules": assembly.aiFlavorRules,
                ])
            ))
        }

        // 5 · universe:<universeId> · 世界资料 · <宇宙名> · P06
        for universe in assembly.universes {
            blocks.append(PromptBlock(
                key: "universe:" + universe.id,
                category: .worldbook,
                title: universe.name,
                body: PromptLibrary.render(PromptLibrary.universeBlockTemplate, [
                    "宇宙名": universe.name,
                    "内容": universe.content,
                ]),
                hasOwnHeading: true
            ))
        }

        // 6 · world:imitation-template · 世界资料 · 本书仿写模板 · P07
        if !assembly.imitationTemplate.isEmpty {
            blocks.append(PromptBlock(
                key: "world:imitation-template",
                category: .worldbook,
                title: "本书仿写模板",
                body: PromptLibrary.render(PromptLibrary.imitationTemplateBlockTemplate, [
                    "仿写模板正文": assembly.imitationTemplate,
                ])
            ))
        }

        // 7 · world:plot-outline · 世界资料 · 剧情梗概 · P08
        if !assembly.plotOutline.isEmpty {
            blocks.append(PromptBlock(
                key: "world:plot-outline",
                category: .worldbook,
                title: "剧情梗概",
                body: PromptLibrary.render(PromptLibrary.plotOutlineBlockTemplate, [
                    "剧情梗概正文": assembly.plotOutline,
                ])
            ))
        }

        // 8 · corpus:<libraryId>:<entryId> · 世界资料 · <语料库名> · <条目名> · P09
        // 「每个库最多 10 条」是取数规则，由调用方裁剪。
        for entry in assembly.corpus {
            blocks.append(PromptBlock(
                key: "corpus:" + entry.libraryID + ":" + entry.entryID,
                category: .worldbook,
                title: entry.libraryName + " · " + entry.entryName,
                body: PromptLibrary.render(PromptLibrary.corpusEntryBlockTemplate, [
                    "语料库名": entry.libraryName,
                    "条目名": entry.entryName,
                    "分类": entry.category,
                    "原句": entry.text,
                ]),
                hasOwnHeading: true
            ))
        }

        // 9 · worldbook:<entryId> · 世界资料 · <词条名> · P10
        // APK 不做空正文过滤（`U2.java:769-777`）：空内容也发 `# 标题` 块。
        for entry in assembly.worldbooks {
            blocks.append(PromptBlock(
                key: "worldbook:" + entry.id,
                category: .worldbook,
                title: entry.name,
                body: PromptLibrary.render(PromptLibrary.worldbookBlockTemplate, [
                    "词条名": entry.name,
                    "词条内容": entry.content,
                ]),
                hasOwnHeading: true
            ))
        }

        // 10 · character:<cardId> · 人物资料 · <人物名> · P11
        for card in assembly.characters {
            blocks.append(PromptBlock(
                key: "character:" + card.id,
                category: .character,
                title: card.name,
                body: PromptLibrary.characterBlock(for: card),
                hasOwnHeading: true
            ))
        }

        // 11 · summary:conversation:<hash前12> · 对话历史 · 长期规则摘要 · P12（locked）
        if !assembly.conversationSummary.isEmpty {
            blocks.append(PromptBlock(
                key: "summary:conversation:" + shortHash(assembly.conversationSummary),
                category: .chatHistory,
                title: "长期规则摘要",
                body: PromptLibrary.render(PromptLibrary.longTermRulesLogBlockTemplate, [
                    "长期规则日志正文": assembly.conversationSummary,
                ]),
                locked: true
            ))
        }

        // 12 · body:authoritative · 正文 · 本书正文（<范围>） · P13
        // 永远在人物卡与长期规则之后、历史消息之前；正文为空时整块不出现。
        if !assembly.body.isEmpty {
            blocks.append(PromptBlock(
                key: "body:authoritative",
                category: .authoritativeBody,
                title: "本书正文（" + assembly.bodyRange.label + "）",
                body: PromptLibrary.render(PromptLibrary.authoritativeBodyTemplate, [
                    "范围": assembly.bodyRange.label,
                    "正文": assembly.body,
                ])
            ))
        }

        return blocks
    }

    /// 把块拼成 system 侧文本。块之间用空行隔开。
    static func systemPrompt(from blocks: [PromptBlock]) -> String {
        blocks.map(\.rendered).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// 主写作请求的 messages：system（块 1–12 + 调用方追加的块）→ 历史消息 → 本轮 user 指令。
    ///
    /// 第 14 行「历史消息」是真正的 messages，不是 system 里的文本。
    static func writingMessages(
        assembly: PromptAssembly,
        history: [LLMMessage],
        userInstruction: String?
    ) -> [LLMMessage] {
        var blocks = writingBlocks(assembly)
        // 13 · 调用方追加的块
        blocks.append(contentsOf: assembly.appendedBlocks)

        var messages: [LLMMessage] = []
        let system = systemPrompt(from: blocks)
        if !system.isEmpty { messages.append(.system(system)) }
        messages.append(contentsOf: history)
        // 本轮用户指令（P15 这类「用户输入」角色）永远在最后。
        if let userInstruction, !userInstruction.isEmpty {
            messages.append(.user(userInstruction))
        }
        return messages
    }

    /// 兼容旧签名：直接给 `WorldBook` 的调用点。
    ///
    /// `bodyRange` 默认按「全文」；调用方把正文裁成末尾一段时要显式传 `.tail(count:)`，
    /// 否则 P13 的范围标注会和实际正文不符。
    static func writingMessages(
        world: WorldBook,
        manuscript: String,
        history: [LLMMessage],
        userInstruction: String?,
        bodyRange: PromptLibrary.BodyRange = .full
    ) -> [LLMMessage] {
        writingMessages(
            assembly: PromptAssembly.from(world: world, manuscript: manuscript, bodyRange: bodyRange),
            history: history,
            userInstruction: userInstruction
        )
    }

    /// 只取 system 侧文本（给需要单看提示词的调用点）。
    static func writingSystemPrompt(world: WorldBook, manuscript: String) -> String {
        systemPrompt(from: writingBlocks(
            PromptAssembly.from(world: world, manuscript: manuscript)
        ))
    }

    // MARK: - §3 续写

    /// 断流后接上：把已生成片段的**最后 2000 个码点**作为 assistant 消息回灌，
    /// 再用 P16 要求从片段末尾继续（`b3/l.java:1963-1975`）。
    ///
    /// 片段为空时没有可回灌的内容，退化成 P15「继续当前最新气泡」。
    static func continueFragmentMessages(
        world: WorldBook,
        manuscript: String,
        history: [LLMMessage],
        fragment: String,
        bodyRange: PromptLibrary.BodyRange = .full
    ) -> [LLMMessage] {
        continueFragmentMessages(
            assembly: PromptAssembly.from(world: world, manuscript: manuscript, bodyRange: bodyRange),
            history: history,
            fragment: fragment
        )
    }

    /// 同上，但接收已经装配好的 `PromptAssembly`（带技能/预设/语料等全局块）。
    static func continueFragmentMessages(
        assembly: PromptAssembly,
        history: [LLMMessage],
        fragment: String
    ) -> [LLMMessage] {
        guard !fragment.isEmpty else {
            return writingMessages(
                assembly: assembly,
                history: history,
                userInstruction: PromptLibrary.continueLatestBubbleInstruction
            )
        }
        var messages = writingMessages(assembly: assembly, history: history, userInstruction: nil)
        messages.append(.assistant(codePointTail(fragment, limit: 2000)))
        messages.append(.user(PromptLibrary.continueLastFragmentInstruction))
        return messages
    }
    // MARK: - 渲染

    /// 参与本轮请求的人物：卡片 enabled + 所属分组 enabled。
    /// 分组被删或 groupId 悬空时按启用处理，避免静默丢卡。
    static func activeCharacters(in world: WorldBook) -> [CharacterCard] {
        // 分组 id 理论上唯一；存档导入可能带重复 id，不能因此崩溃。
        let groupStates = Dictionary(
            world.characterGroups.map { ($0.id, $0.enabled) },
            uniquingKeysWith: { first, _ in first }
        )
        return world.characters.filter { card in
            guard card.enabled ?? true else { return false }
            guard let groupID = card.groupId, !groupID.isEmpty else { return true }
            return groupStates[groupID] ?? true
        }
    }

    /// 人物卡渲染（P11 的块格式 + 逐行空值过滤）。
    static func renderCharacters(_ cards: [CharacterCard]) -> String {
        cards.map(PromptLibrary.characterBlock(for:)).joined(separator: "\n\n")
    }

    /// 事件卡渲染。规格只写「已有事件卡渲染文本」，没给字段标签；沿用字段名对应的中文标签。
    static func renderEvents(_ events: [EventCard]) -> String {
        events.map { event in
            var lines = ["【" + event.title + "】"]
            if !event.scene.isEmpty { lines.append("场景：" + event.scene) }
            if !event.characters.isEmpty {
                lines.append("人物：" + event.characters.joined(separator: "、"))
            }
            if !event.cause.isEmpty { lines.append("起因：" + event.cause) }
            if !event.development.isEmpty { lines.append("经过：" + event.development) }
            if !event.consequence.isEmpty { lines.append("结果：" + event.consequence) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    // MARK: - 工具

    /// 取最后 `limit` 个 **码点**（P16 的 2000 字回灌）。
    static func codePointTail(_ text: String, limit: Int) -> String {
        let scalars = Array(text.unicodeScalars)
        let drop = max(0, scalars.count - limit)
        guard drop > 0 else { return text }
        var result = ""
        result.unicodeScalars.append(contentsOf: scalars[drop...])
        return result
    }

    /// 块键里的「哈希前 12 位」。
    ///
    /// Android 侧用的哈希算法未确认（这个值只做块身份，不进提示词正文），这里用
    /// FNV-1a 64 位取十六进制前 12 位，至少保证同一段文本在同一台设备上稳定。
    static func shortHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(String(hash, radix: 16).prefix(12))
    }

    // MARK: - 历史消息

    /// `ChatMessage` → `LLMMessage`：空内容丢弃，角色直映射。
    /// 写请求组装与上下文占用估算共用这一份规则。
    static func llmMessages(from messages: [ChatMessage]) -> [LLMMessage] {
        messages.compactMap { message -> LLMMessage? in
            let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            switch message.role {
            case .user: return LLMMessage.user(content)
            case .assistant: return LLMMessage.assistant(content)
            case .system: return LLMMessage.system(content)
            }
        }
    }
}

// MARK: - 完整装配：把全局设置与项目负载填进 §1 的 14 个槽位

extension PromptAssembly {

    /// 主写作请求的完整装配。
    ///
    /// `from(world:manuscript:)` 只映射了世界书里那几样；真正上线时要额外带上
    /// 全局设置里的预设/技能/去 AI 味规则、宇宙共享条目、语料库，以及项目级的
    /// 补充指令——少了任何一条，模型拿到的上下文就和原版不一致。
    static func from(
        world: WorldBook,
        manuscript: String,
        assistantSupplement: String,
        settings: AppSettings,
        projectID: String,
        enabledUniverseEntryIDs: [String] = [],
        bodyRange: PromptLibrary.BodyRange = .full
    ) -> PromptAssembly {
        var assembly = PromptAssembly()

        // 1 · 项目级补充指令（P02）
        assembly.projectID = projectID
        assembly.projectAssistantInstruction = assistantSupplement

        // 2 · 全局预设（P03）：正文原样，不加前后缀
        assembly.globalPreset = settings.globalPreset

        // 3 · 技能（P04）：只放启用的，按 `# <名称>\n<内容>` 包
        assembly.skills = settings.skills
            .filter { $0.enabled }
            .map { Skill(id: $0.id, name: $0.name, content: $0.content) }

        // 4 · 去 AI 味规则（P05），标题是「全局审查规则」
        assembly.aiFlavorRules = settings.aiFlavorRules

        // 5 · 宇宙共享世界书（P06）。原版双闸门：条目全局启用 + 当前项目勾选。
        // 旧版把 `settings.enabledUniverseEntryIDs` 当第一道闸门，但那个列表默认空
        // 且界面上不可达，P06 会恒空；现在用条目自己的 `enabled`。
        let projectUniverse = settings.enabledUniverseEntries(
            for: enabledUniverseEntryIDs
        )
        assembly.universes = projectUniverse.map {
            Universe(id: $0.id, name: $0.title, content: $0.body)
        }

        // 6 · 本书仿写模板（P07）
        assembly.imitationTemplate = world.styleTemplate

        // 7 · 剧情梗概（P08）。原版直接渲染事件卡列表
        // （`L1/W2.java:480-484` + `L1/C0604u0.java:78-102`），
        // 数据模型里的 `plotOutline` 字符串在 APK 中没有任何读取点，
        // 这里不再拿它兜底；没有事件卡就不发这一块。
        assembly.plotOutline = PromptComposer.renderEvents(world.events)

        // 8 · 语料条目（P09）：每个启用库最多 10 条。
        // 全局「语料收集库」开关关掉时一律不注入——总开关的语义就是「本次写作不用语料」。
        if settings.corpusEnabled {
            assembly.corpus = settings.corpusLibraries
                .filter { $0.enabled }
                .flatMap { library in
                    library.promptEntries.map { entry in
                        Corpus(
                            libraryID: library.id,
                            libraryName: library.name,
                            entryID: entry.id,
                            entryName: entry.title,
                            category: entry.category,
                            text: entry.text
                        )
                    }
                }
        }

        // 9 · 世界书词条（P10）
        var books: [Worldbook] = []
        books.append(contentsOf: world.worldbookEntries
            .filter { $0.enabled }
            .map { Worldbook(id: $0.id, name: $0.title, content: $0.body) })
        assembly.worldbooks = books

        // 10 · 人物卡（P11）
        assembly.characters = PromptComposer.activeCharacters(in: world)

        // 11 · 长期规则摘要（P12）
        assembly.conversationSummary = world.longTermRules

        // 12 · 权威正文（P13）
        assembly.body = manuscript
        assembly.bodyRange = bodyRange

        return assembly
    }
}
