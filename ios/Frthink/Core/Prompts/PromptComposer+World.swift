import Foundation

/// 世界建立 / 刷新、人物去重与人物卡入库。
extension PromptComposer {

    // MARK: - §4 世界建立 / 世界刷新

    /// 人物卡抽取请求。
    ///
    /// system 侧顺序（`L1/K0.r`）：P17 输出契约 → P18 世界建立要求 → P31 只读增量基线
    /// → P29 分段正文 → P30 已有角色卡；user 侧是 P27（首轮）或 P28（增量）。
    ///
    /// - Parameters:
    ///   - segment: 分段编号与字符范围。调用方拿不到时传 nil：user 消息只发指令本身，
    ///     正文块不加「第 n/m 段」前缀（宁可不写，也不编造编号）。
    ///   - targetCharacter: 单人补卡时的目标角色名（P23）。
    ///   - worldBuildInstruction: 设置里改写过的「世界建立要求」（P18），默认用出厂值。
    static func worldRefreshMessages(
        existingCharacters: [CharacterCard],
        existingStyleTemplate: String,
        digest: String,
        incremental: Bool,
        wholeText: Bool = false,
        segment: PromptLibrary.Segment? = nil,
        targetCharacter: String? = nil,
        worldBuildInstruction: String? = nil
    ) -> [LLMMessage] {
        let segmentSuffix = segment.map { String($0.index) } ?? "1"
        var blocks: [PromptBlock] = []

        // P17 · builtin:task-output-contract · 任务输出格式（locked）
        // 正文是 P20/P21 + P22 (+P23) (+P24) 的契约串，四段之间没有分隔符。
        // 未验证：触发点不明确（§14 第 1 条：正文来源的传参链未逐寄存器跟踪）
        blocks.append(PromptBlock(
            key: PromptLibrary.taskOutputContractKey,
            category: .agentPrompt,
            title: PromptLibrary.taskOutputContractTitle,
            // 原版刷新固定用 P21 精简契约（`U2.java:472`，z3=false）；
            // P20 全量契约在反编译调用点里没人传，不能拿来当刷新默认。
            body: PromptLibrary.characterJSONContract(
                full: false,
                targetCharacter: targetCharacter,
                incremental: incremental
            ),
            locked: true
        ))

        // P18 · setting:world-build-instruction · 世界建立要求（locked）
        let buildInstruction = worldBuildInstruction ?? PromptLibrary.worldBuildInstructionDefault
        if !buildInstruction.isEmpty {
            blocks.append(PromptBlock(
                key: "setting:world-build-instruction",
                category: .agentPrompt,
                title: "世界建立要求",
                body: buildInstruction,
                locked: true
            ))
        }

        // P19 · setting:world-material-instruction · 归纳预设（locked）
        // 只在 task:world-style / task:world-plot-outline 时注入；人物卡抽取不属于这两类，留空。

        // P31 · task:readonly-incremental-baseline · 已有资料（只读去重参考）
        // 未验证：触发点不明确（§14 第 3 条：块正文构成未验证）
        if incremental {
            var baseline: [String] = []
            if !existingCharacters.isEmpty {
                baseline.append(existingCharacters.map(PromptLibrary.characterBaseline).joined(separator: "\n"))
            }
            if !existingStyleTemplate.isEmpty {
                baseline.append(existingStyleTemplate)
            }
            if !baseline.isEmpty {
                blocks.append(PromptBlock(
                    key: PromptLibrary.readonlyIncrementalBaselineKey,
                    category: .worldbook,
                    title: PromptLibrary.readonlyIncrementalBaselineTitle,
                    body: baseline.joined(separator: "\n\n"),
                    locked: true
                ))
            }
        }

        // P29 · task:character-extraction:<哈希前12>:<段序号> · 正文
        // 规格没给 P29 单独的块标题（段落信息在正文首行前缀里），这里用分类名「正文」。
        // 大书模式只发一段完整前缀，不再套「第 n/m 段」的段落头。
        if !digest.isEmpty {
            blocks.append(PromptBlock(
                key: wholeText
                    ? "task:whole-manuscript:" + shortHash(digest)
                    : "task:character-extraction:" + shortHash(digest) + ":" + segmentSuffix,
                category: .authoritativeBody,
                title: "正文",
                body: PromptLibrary.segmentBody(digest, segment: wholeText ? nil : segment),
                locked: true
            ))
        }

        // P30 · task:existing-character-cards:<哈希前12>:<段序号> · 人物资料
        if !existingCharacters.isEmpty {
            blocks.append(PromptBlock(
                key: "task:existing-character-cards:" + shortHash(digest) + ":" + segmentSuffix,
                category: .character,
                title: PromptLibrary.existingCharacterCardsTitle,
                body: existingCharacters.map(PromptLibrary.characterBaseline).joined(separator: "\n"),
                locked: true
            ))
        }

        // user 侧：P27（首轮）或 P28（增量）；大书模式用整篇指令。
        let instruction: String
        if wholeText {
            instruction = PromptLibrary.wholeTextWorldRefreshInstruction
                + (incremental ? PromptLibrary.incrementalRefreshClause : "")
        } else {
            instruction = PromptLibrary.segmentExtractionMessage(
                incremental: incremental,
                segment: segment
            )
        }

        var messages: [LLMMessage] = []
        let system = systemPrompt(from: blocks)
        if !system.isEmpty { messages.append(.system(system)) }
        // P25/P26 是「单次（预算规划）路径」的 user 消息；分段路径用 P27/P28。
        // 两者不叠加，避免同一请求里出现两套整理口径。
        messages.append(.user(instruction))
        return messages
    }

    // MARK: - §4 人物去重

    /// 人物卡创建前的全书去重。
    ///
    /// system：P32 指令 + P33 JSON 契约；user：两个 P34 只读数据块
    /// （待去重人物候选 / 已有卡片身份与别称）。P34 在规格里没有独立块键。
    static func dedupeMessages(
        candidates: [String],
        existingNames: [String]
    ) -> [LLMMessage] {
        let systemBlocks: [PromptBlock] = [
            PromptBlock(
                key: "task:character-identity-consolidation",
                category: .agentPrompt,
                title: "",
                body: PromptLibrary.characterIdentityInstruction,
                locked: true
            ),
            PromptBlock(
                key: "",
                category: .agentPrompt,
                title: "",
                body: PromptLibrary.characterIdentityContract
            ),
        ]

        var userBlocks: [PromptBlock] = [
            PromptBlock(
                key: "",
                category: .character,
                title: PromptLibrary.dedupeCandidatesTitle,
                body: candidates.enumerated().map { "[\($0.offset)] \($0.element)" }.joined(separator: "\n")
            ),
        ]
        if !existingNames.isEmpty {
            userBlocks.append(PromptBlock(
                key: "",
                category: .character,
                title: PromptLibrary.existingCardIdentitiesTitle,
                body: existingNames.map { "- " + $0 }.joined(separator: "\n")
            ))
        }

        return [
            .system(systemPrompt(from: systemBlocks)),
            .user(systemPrompt(from: userBlocks)),
        ]
    }

    // MARK: - §11 人物卡入库

    /// 单条气泡 → 一张人物卡。唯一使用 function calling 的流程：
    /// system 是 P60，user 是气泡原文本身（不加任何前缀或包裹）。
    static func characterIngestMessages(bubble: String) -> [LLMMessage] {
        [.system(PromptLibrary.characterIngestSystem), .user(bubble)]
    }

    /// 0.8.213 `L1/W.smali:423-805` 校验后的 `create_character_card` 工具定义。
    static let createCharacterCardTool = LLMToolDefinition(
        name: "create_character_card",
        description: "将唯一提供的码字机气泡整理为一张人物卡；非标准字段放入自定义词条。",
        parametersJSON: """
        {
          "type": "object",
          "properties": {
            "name": { "type": "string" },
            "identity": { "type": "string" },
            "personality": { "type": "string" },
            "voice": { "type": "string" },
            "goals": { "type": "string" },
            "boundaries": { "type": "string" },
            "personal_memory": { "type": "string" },
            "relationship_attitudes": { "type": "string" },
            "aliases": { "type": "array", "items": { "type": "string" } },
            "custom_entries": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "name": { "type": "string" },
                  "content": { "type": "string" }
                },
                "required": ["name", "content"],
                "additionalProperties": false
              }
            }
          },
          "required": [
            "name", "identity", "personality", "voice", "goals", "boundaries",
            "personal_memory", "relationship_attitudes", "aliases", "custom_entries"
          ],
          "additionalProperties": false
        }
        """
    )

}
