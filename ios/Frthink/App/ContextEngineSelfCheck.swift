import Foundation

extension SelfCheck {

    static func runContextEngineChecks() {
        // WorldBook v2 Phase 1：场次瞬态覆盖更新 + P11 目标/记忆统一写入 + 未决伏笔流转
        check("world.stateSyncUpsert") {
            let initialSnap = CharacterDynamicSnapshot(
                location: "青云山门",
                condition: "左臂轻伤",
                possessions: ["旧玉佩"]
            )
            let cards = [CharacterCard(
                name: "林昭",
                goals: "查明师父失踪原因",
                personalMemory: "黑衣人用的是南疆毒",
                dynamicSnapshot: initialSnap
            )]
            let rawSync = """
            {
              "character_snapshots": [
                {
                  "name": "林昭",
                  "location": "洛阳城西客栈",
                  "current_goal": "暗中盯住城主府",
                  "condition": "",
                  "possessions": ["旧玉佩", "密信"],
                  "known_facts": ["城主与南疆有勾结"],
                  "relationship_notes": "对城主起疑戒备",
                  "conflict_note": ""
                }
              ],
              "new_threads": [
                {
                  "title": "密信落款之谜",
                  "obligation": "查清密信末尾半枚印章的主人",
                  "related_characters": ["林昭"]
                }
              ],
              "resolved_threads": ["城门接头暗号"]
            }
            """
            let parsed = try WorldJSON.parseStateSync(rawSync)
            let snapResult = WorldMerge.upsertCharacterSnapshots(
                existing: cards,
                updates: parsed.snapshotUpdates
            )
            let updatedCard = snapResult.cards.first
            let updatedSnap = updatedCard?.dynamicSnapshot
            try expect(updatedSnap?.location == "洛阳城西客栈", "位置应覆盖更新为新地点")
            try expect(updatedSnap?.condition == "左臂轻伤", "未提及瞬态字段应保留旧值")
            try expect(updatedCard?.goals == "暗中盯住城主府", "当前目标应直接覆盖更新到 P11 goals 字段")
            try expect(
                updatedCard?.personalMemory.contains("南疆毒") == true
                    && updatedCard?.personalMemory.contains("城主与南疆有勾结") == true,
                "已知信息应并入 P11 personalMemory 而非丢失"
            )
            try expect(updatedCard?.relationshipAttitudes == "对城主起疑戒备", "关系态度应更新至 P11 字段")

            let existingThreads = [
                PlotThread(title: "城门接头暗号", obligation: "对上暗号进城", status: .open)
            ]
            let threadResult = WorldMerge.mergePlotThreads(
                existing: existingThreads,
                additions: parsed.newThreads,
                resolvedKeys: parsed.resolvedThreads
            )
            try expect(threadResult.addedCount == 1 && threadResult.resolvedCount == 1, "伏笔增删计数异常")
            try expect(
                threadResult.threads.first(where: { $0.title == "城门接头暗号" })?.status == .resolved,
                "已兑现伏笔应标记为 resolved"
            )
            return "瞬态覆盖 / P11 统一写入 / 伏笔流转 ok"
        }

        // WorldBook v2：渐进式披露、单一场景工作记忆块、因果截断与纯净末尾指令
        check("writer.sceneMemoryBlock") {
            let snap = CharacterDynamicSnapshot(location: "客栈二楼", condition: "蓄势待发")
            let onStage = CharacterCard(id: "c_lin", name: "林昭", goals: "等待接头人", dynamicSnapshot: snap)
            let offStage = (0..<4).map {
                CharacterCard(id: "c_off_\($0)", name: "远方配角\($0)", identity: "闲人")
            }
            let thread = PlotThread(
                title: "半枚印章",
                obligation: "揭开印章所属势力",
                relatedCharacters: ["林昭"],
                status: .open
            )
            let resolvedThread = PlotThread(
                title: "旧承诺",
                obligation: "已完结",
                status: .resolved
            )
            var world = WorldBook(characters: [onStage] + offStage, openThreads: [thread, resolvedThread])
            world.activeEpistemicGaps = ["林昭已知密信出自城主府，但店小二尚不知情"]
            world.styleTemplate = "短句冷峻"
            let settings = AppSettings()
            let prepared = WriterPromptBuilder.prepare(
                WriterPromptSnapshot(
                    action: .send(instruction: "林昭推开窗观察街面"),
                    manuscript: "夜色已深，林昭坐在客栈里。",
                    messages: [],
                    world: world,
                    assistantSupplement: "",
                    settings: settings,
                    projectID: "book-state",
                    enabledUniverseEntryIDs: [],
                    bodyPromptSendWhole: false,
                    bodyPromptTailCodePoints: 1_000,
                    continuationAnchor: nil,
                    explicitBodyRange: .full,
                    inputBudget: 16_000
                )
            )
            let systemText = prepared.messages.first(where: { $0.role == "system" })?.content ?? ""
            let lastUser = prepared.messages.last?.content ?? ""
            let sceneBlock = prepared.messages.dropLast().first(where: {
                $0.role == "user" && $0.content.contains("【在场角色状态与认知边界】")
            })?.content ?? ""
            try expect(
                !systemText.contains("半枚印章") && !systemText.contains("客栈二楼"),
                "动态场景工作记忆不应写入 system 前缀破坏缓存"
            )
            try expect(
                !systemText.contains("远方配角0"),
                "超过 3 张人物卡时即便未爆总预算也应过滤未出场配角（L1/L2 渐进式披露）"
            )
            try expect(
                lastUser == "林昭推开窗观察街面",
                "末尾用户指令应保持纯净，不再注入 Depth-0 模板提醒：\(lastUser)"
            )
            try expect(
                sceneBlock.contains("客栈二楼")
                    && sceneBlock.contains("半枚印章")
                    && sceneBlock.contains("远方配角0（闲人）")
                    && sceneBlock.contains("店小二尚不知情")
                    && !sceneBlock.contains("已完结"),
                "场景工作记忆块应包含在场快照、L1 未出场名录、认知信息差与 open 伏笔"
            )

            // 场景动态匹配 Few-Shot：根据当前指令技法意图挑出最贴合的 1-2 条样本
            let combatSample = PromptAssembly.Corpus(
                libraryID: "lib",
                libraryName: "节选",
                entryID: "s_combat",
                entryName: "短句动作交锋与节奏压迫",
                category: "仿写样本",
                text: "刀光一闪。他侧身避开，反手扣住对方手腕。"
            )
            let dialogueSample = PromptAssembly.Corpus(
                libraryID: "lib",
                libraryName: "节选",
                entryID: "s_dlg",
                entryName: "人物对白试探与言外之意留白",
                category: "仿写样本",
                text: "“茶凉了。”他没有抬头。“凉了正好醒神。”"
            )
            let routed = StyleDistiller.fewShotDialoguePairs(
                from: [combatSample, dialogueSample],
                maxPairs: 1,
                queryText: "写一段两人喝茶试探的克制对白"
            )
            try expect(
                routed.injectedEntryIDs == ["s_dlg"],
                "动态 Few-Shot 应优先匹配契合当前场景技法的样本"
            )
            let mismatchFiltered = StyleDistiller.fewShotDialoguePairs(
                from: [dialogueSample],
                maxPairs: 1,
                queryText: "暴雨倾盆而下，他独自穿过荒原石阶，风声灌满长廊，远山灯火熄灭。"
            )
            try expect(
                mismatchFiltered.injectedEntryIDs.isEmpty && mismatchFiltered.messages.isEmpty,
                "纯叙述场景遇到无关键词重合的纯对白样本时应按语域门控过滤"
            )

            // 因果截断（Causal Cutoff）：锚点之后的未来文本不得被 BM25 召回
            let pastChapter = "第一章：林昭在雾港城捡到一枚玄铁令牌。\n"
                + String(repeating: "街巷行人匆匆而过。\n", count: 25)
            let midCurrent = "第五章：林昭正准备前往客栈。"
            let futureSpoiler = "\n第十章未来剧透：其实玄铁令牌是南疆王族信物。"
            let fullBook = pastChapter + midCurrent + futureSpoiler
            let causalEnd = (pastChapter + midCurrent as NSString).length
            let recalledPast = ManuscriptIndex.recallHistoricalExcerpts(
                fullManuscript: fullBook,
                activeWindowText: midCurrent,
                queryTerms: ["林昭", "玄铁令牌", "南疆王族"],
                instructionText: "玄铁令牌是什么",
                causalLimit: causalEnd
            ).map(\.text).joined(separator: "\n")
            try expect(
                recalledPast.contains("雾港城") && !recalledPast.contains("南疆王族信物"),
                "BM25 检索必须遵守因果截断，不得泄漏锚点之后的未来剧情"
            )
            return "渐进式披露 / 因果截断 / SceneMemoryBlock ok"
        }

        // 流式 <think>...</think> 剥离状态机与 Prefill 卡 CoT 注入验证
        check("llm.thinkTagStreamSplitter") {
            var prefillSplitter = ThinkTagStreamSplitter(startsInsideThink: true)
            let p1 = prefillSplitter.push("先让林昭试探</thi")
            let p2 = prefillSplitter.push("nk>\n她推门而入。")
            let p3 = prefillSplitter.finish()
            let prefillEvents = p1 + p2 + p3
            let prefillReasoning = prefillEvents.compactMap {
                if case .reasoning(let s) = $0 { return s }
                return nil
            }.joined()
            let prefillProse = prefillEvents.compactMap {
                if case .delta(let s) = $0 { return s }
                return nil
            }.joined()
            try expect(
                prefillReasoning == "先让林昭试探" && prefillProse == "她推门而入。",
                "Prefill 模式遇到跨 chunk 的 </think> 应精确拆分为 reasoning 与正文 delta"
            )

            var inlineSplitter = ThinkTagStreamSplitter(startsInsideThink: false)
            let iEvents = inlineSplitter.push("<th") + inlineSplitter.push("ink>思考</think>\r\n正文")
                + inlineSplitter.finish()
            let inlineReasoning = iEvents.compactMap {
                if case .reasoning(let s) = $0 { return s }
                return nil
            }.joined()
            let inlineProse = iEvents.compactMap {
                if case .delta(let s) = $0 { return s }
                return nil
            }.joined()
            try expect(
                inlineReasoning == "思考" && inlineProse == "正文",
                "普通流式遇到 <think>...</think> 应自动剥离进 reasoning"
            )

            var settings = AppSettings(
                providers: [
                    ProviderSetting(
                        kind: .gemini,
                        model: "gemini-4-argon",
                        thinkingLevel: .off
                    )
                ],
                prefillCoT: true
            )
            let snap = WriterPromptSnapshot(
                action: .send(instruction: "继续写"),
                manuscript: "",
                messages: [],
                world: WorldBook(),
                assistantSupplement: "",
                settings: settings,
                projectID: "p1",
                enabledUniverseEntryIDs: [],
                bodyPromptSendWhole: true,
                bodyPromptTailCodePoints: 1000,
                continuationAnchor: nil,
                explicitBodyRange: .full,
                inputBudget: 8000
            )
            let geminiPrepared = WriterPromptBuilder.prepare(snap)
            try expect(
                geminiPrepared.messages.last?.role != "assistant",
                "Gemini 等非白名单模型即使开启 prefillCoT 也不得注入末尾 assistant prefill"
            )

            settings.providers = [ProviderSetting(kind: .deepseek, model: "deepseek-flash", thinkingLevel: .off)]
            var dsOffSnap = snap
            dsOffSnap.settings = settings
            let prepared = WriterPromptBuilder.prepare(dsOffSnap)
            try expect(
                ThinkTagStreamSplitter.startsInsideThink(for: prepared.messages),
                "DeepSeek 关闭原生思考且开启 prefillCoT 时，末尾应挂未闭合 <think> assistant 预填充"
            )

            settings.providers = [ProviderSetting(kind: .anthropic, thinkingLevel: .high)]
            var nativeSnap = snap
            nativeSnap.settings = settings
            let nativePrepared = WriterPromptBuilder.prepare(nativeSnap)
            try expect(
                nativePrepared.messages.last?.role != "assistant",
                "Anthropic 原生思考开启时不得附加末尾 assistant prefill"
            )

            settings.providers = [ProviderSetting(kind: .deepseek, thinkingLevel: .high)]
            var dsSnap = snap
            dsSnap.settings = settings
            let dsPrepared = WriterPromptBuilder.prepare(dsSnap)
            let dsLast = dsPrepared.messages.last
            try expect(
                dsLast?.role == "assistant"
                    && dsLast?.isPrefix == true
                    && dsLast?.content.isEmpty == true
                    && !(dsLast?.reasoningContent?.isEmpty ?? true),
                "DeepSeek 思考模式开启 prefillCoT 时，末尾应生成 reasoning_content + prefix: true"
            )
            let dsBody = LLMRequest(
                model: "deepseek-v4-pro",
                messages: dsPrepared.messages,
                stream: true,
                temperature: 0.7,
                maxTokens: 2048
            ).jsonBody(isDeepSeek: true, kind: .deepseek, providerLevel: .high)
            let dsJSON = String(data: dsBody, encoding: .utf8) ?? ""
            try expect(
                dsJSON.contains("\"prefix\":true") && dsJSON.contains("\"reasoning_content\""),
                "DeepSeek 请求体应序列化 prefix:true 与 reasoning_content"
            )

            settings.providers = [
                ProviderSetting(
                    kind: .openCodeGo,
                    model: "kimi-k3.1-pro",
                    thinkingLevel: .high
                )
            ]
            var ocSnap = snap
            ocSnap.settings = settings
            let ocPrepared = WriterPromptBuilder.prepare(ocSnap)
            let ocBody = LLMRequest(
                model: "kimi-k3.1-pro",
                messages: ocPrepared.messages,
                stream: true,
                temperature: 0.7,
                maxTokens: 2048
            ).jsonBody(isDeepSeek: false, kind: .openCodeGo, providerLevel: .high)
            let ocJSON = String(data: ocBody, encoding: .utf8) ?? ""
            try expect(
                ocJSON.contains("\"partial\":true") && ocJSON.contains("\"reasoning_content\""),
                "OpenCode 路由 Kimi 模型开启思考预填充时应序列化 partial:true 与 reasoning_content"
            )

            // 动态场次锚点 + 400 降级剥离 + 非流式 <think> 剥离
            var anchoredSnap = dsSnap
            anchoredSnap.world.characters = [
                CharacterCard(name: "林昭", identity: "剑客", enabled: true)
            ]
            anchoredSnap.world.activeEpistemicGaps = ["林昭尚不知客栈掌柜已换人"]
            anchoredSnap.world.openThreads = [
                PlotThread(title: "玄铁令牌来历", obligation: "揭示信物主人")
            ]
            anchoredSnap.manuscript = "林昭推门走入客栈。"
            let anchoredPrepared = WriterPromptBuilder.prepare(anchoredSnap)
            let anchoredReasoning = anchoredPrepared.messages.last?.reasoningContent ?? ""
            try expect(
                anchoredReasoning.contains("林昭")
                    && anchoredReasoning.contains("客栈掌柜已换人")
                    && anchoredReasoning.contains("玄铁令牌来历"),
                "prefillCoT 应动态注入在场角色、认知差与未收伏笔锚点"
            )

            try expect(
                OpenAICompatibleClient.isUnsupportedPrefill(
                    status: 400,
                    body: #"{"error":{"message":"prefix is not supported"}}"#
                ) && OpenAICompatibleClient.strippingTrailingPrefill(from: ocPrepared.messages)?.last?.role != "assistant",
                "不支持 prefill 的 400 响应应触发末尾预填充剥离降级"
            )

            let nonStreamSplit = ThinkTagStreamSplitter.stripThinkTags(
                from: "<think>\n内部推演</think>\n真正正文内容",
                startsInsideThink: true
            )
            try expect(
                nonStreamSplit.reasoning == "内部推演" && nonStreamSplit.prose == "真正正文内容",
                "非流式 stripThinkTags 应剥离重复开头 <think> 与正文"
            )

            // 独立 Gemini 原生客户端协议与 baseURL 规范化自检
            let normalizedGeminiURL = GeminiClient.normalizedBaseURL(
                "https://generativelanguage.googleapis.com/v1beta/"
            )
            try expect(
                normalizedGeminiURL == "https://generativelanguage.googleapis.com"
                    && ProviderKind.gemini.defaultBaseURL == "https://generativelanguage.googleapis.com"
                    && ModelCatalog.latest(for: .gemini) == "gemini-4-argon",
                "Gemini 独立服务商的域名规范化与默认模型应正确"
            )
            let geminiBody = GeminiClient.requestBody(
                for: LLMRequest(
                    model: "gemini-4-argon",
                    messages: [.system("系统设定"), .user("第一句"), .assistant("回复")],
                    stream: true,
                    temperature: 0.7,
                    maxTokens: 2048
                ),
                providerLevel: .high
            )
            let geminiJSON = String(data: geminiBody, encoding: .utf8) ?? ""
            try expect(
                geminiJSON.contains("\"systemInstruction\"")
                    && geminiJSON.contains("\"model\"")
                    && geminiJSON.contains("\"thinkingConfig\""),
                "Gemini 原生请求体应包含 systemInstruction、model 角色与 thinkingConfig"
            )
            return "ThinkTagStreamSplitter / prefillCoT / DeepSeek & OpenCode & Gemini ok"
        }

        // WorldBook v2 Phase 2：世界书常驻/关键词/1 层递归触发与原序输出
        check("world.worldbookRecursiveTrigger") {
            let entries = [
                WorldbookEntry(id: "w1", title: "世界基调", body: "低魔江湖世界。", activationMode: .constant),
                WorldbookEntry(id: "w2", title: "青云剑", body: "青云剑乃太虚宗镇派神兵。", activationMode: .keyword, keys: ["断剑", "青云剑"]),
                WorldbookEntry(id: "w3", title: "太虚宗", body: "太虚宗位于雪山之巅。", activationMode: .keyword, keys: ["太虚宗"]),
                WorldbookEntry(id: "w4", title: "无关暗器", body: "暴雨梨花针。", activationMode: .keyword, keys: ["梨花针"]),
            ]
            let assemblyBooks = entries.map {
                PromptAssembly.Worldbook(id: $0.id, name: $0.title, content: $0.body)
            }
            let result = DynamicContextSelector.selectWorldbooks(
                assemblyBooks,
                entries: entries,
                activeCharacters: [],
                scanText: "他从怀里摸出那半截断剑。",
                budget: 8_000,
                stickyIDs: []
            )
            let ids = result.books.map(\.id)
            try expect(ids == ["w1", "w2", "w3"], "应保留常驻+直接命中+递归触发并保持原序，实际：\(ids)")
            return "世界书递归触发 \(ids.count) 条 ok"
        }

        // WorldBook v2 Phase 2：端侧 BM25 仅检索未被末尾窗口覆盖的早期历史片段
        check("store.manuscriptBM25Recall") {
            let early = "第一章：林昭在雾港城老码头买下一艘黑木船，船舱暗格里藏着一张泛黄海图。\n"
            let filler = String(repeating: "夜风吹过长街，众人各自沉默赶路。\n", count: 30)
            let recent = "第十章：林昭站在客栈二楼，望着远处海面。"
            let full = early + filler + recent
            let recalled = ManuscriptIndex.recallHistoricalExcerpts(
                fullManuscript: full,
                activeWindowText: recent,
                queryTerms: ["林昭", "海图"],
                instructionText: "林昭取出早年买船时藏起来的东西"
            )
            try expect(!recalled.isEmpty, "应召回早期黑木船与海图设定")
            let combined = recalled.map(\.text).joined(separator: "\n")
            try expect(combined.contains("泛黄海图"), "召回内容应包含早期硬事实")
            try expect(!combined.contains("站在客栈二楼"), "不应重复召回当前末尾窗口已有的片段")
            return "BM25 早期历史召回 \(recalled.count) 段 ok"
        }

        // WorldBook v2 Phase 3：一致性审校五维证据链 JSON 解析
        check("world.consistencyCheckParse") {
            let raw = """
            {
              "issues": [
                {
                  "category": "人物认知与记忆",
                  "severity": "高",
                  "fact_quote": "林昭尚未拆开密信",
                  "contradiction_quote": "林昭脱口说出城主与南疆勾结",
                  "reason": "人物在不知情时提前说出了秘密情报"
                }
              ]
            }
            """
            let issues = try WorldJSON.parseConsistencyIssues(raw)
            try expect(issues.count == 1, "应解析出 1 条一致性矛盾")
            try expect(issues.first?.category == "人物认知与记忆", "类别字段解析错误")
            try expect(issues.first?.severity == "高", "严重度字段解析错误")
            return "一致性审校解析 \(issues.count) 条 ok"
        }

    }
}
