import Foundation

/// 单段正文增量状态同步（WorldBook v2）：
/// 仅读取刚写完的正文片段 + 已有角色基线/未决伏笔，输出覆盖式快照与伏笔增删，
/// 不触发全书 256 段扫描，避免角色设定在长篇写作中越写越脱节。
@MainActor
enum StateSyncWorkflow {

    private static var sleepTasks: [String: Task<Void, Never>] = [:]

    /// 采纳正文后在后台静默调度 Sleep-Time 状态与伏笔同步（防抖 1.5s，不阻塞写作、不弹错误打扰）。
    static func scheduleSleepTimeSync(
        excerpt: String,
        session: ProjectSession,
        store: AppStore
    ) {
        guard store.settings.sleepTimeStateSync else { return }
        let trimmed = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 40 else { return }
        guard !session.payload.world.characters.isEmpty
                || !session.payload.world.openThreads.isEmpty else {
            return
        }

        let projectID = session.project.id
        sleepTasks[projectID]?.cancel()
        sleepTasks[projectID] = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            _ = try? await syncExcerpt(trimmed, session: session, store: store)
            if !Task.isCancelled {
                sleepTasks[projectID] = nil
            }
        }
    }

    /// 取消挂起的后台 Sleep-Time 同步（例如用户刚点插入又立即撤销）。
    static func cancelSleepTimeSync(projectID: String) {
        sleepTasks[projectID]?.cancel()
        sleepTasks[projectID] = nil
    }

    struct SyncOutcome {
        let updatedCharacters: Int
        let conflictCharacters: Int
        let addedThreads: Int
        let resolvedThreads: Int

        var summary: String {
            if updatedCharacters == 0 && addedThreads == 0 && resolvedThreads == 0 {
                return "状态同步完成：本段没有需要更新的动态状态或伏笔。"
            }
            var parts: [String] = []
            if updatedCharacters > 0 { parts.append("更新 \(updatedCharacters) 位角色动态快照") }
            if conflictCharacters > 0 { parts.append("\(conflictCharacters) 处设定冲突待确认") }
            if addedThreads > 0 { parts.append("新增 \(addedThreads) 条未决伏笔") }
            if resolvedThreads > 0 { parts.append("兑现 \(resolvedThreads) 条伏笔") }
            return "状态同步完成：" + parts.joined(separator: "，") + "。"
        }
    }

    /// 对给定正文片段（如最新采纳段落或末尾片段）执行一次增量状态同步。
    static func syncExcerpt(
        _ excerpt: String,
        session: ProjectSession,
        store: AppStore
    ) async throws -> SyncOutcome {
        let trimmed = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WorldRunError(message: "同步片段为空，请先写入或选择正文内容。")
        }

        let context = try WorldRequestContext.make(store: store)
        let activeCards = PromptComposer.activeCharacters(in: session.payload.world)
        let openThreads = session.payload.world.openThreads.filter { $0.status == .open }

        let messages = buildMessages(
            excerpt: trimmed,
            characters: activeCards,
            openThreads: openThreads
        )
        let payload = try await context.completeAndParse(
            messages,
            failOnLength: true,
            requestErrorPrefix: "状态同步请求失败",
            parseErrorPrefix: "状态同步解析失败",
            parse: WorldJSON.parseStateSync
        )

        let snapResult = WorldMerge.upsertCharacterSnapshots(
            existing: session.payload.world.characters,
            updates: payload.snapshotUpdates
        )
        session.payload.world.characters = snapResult.cards

        let threadResult = WorldMerge.mergePlotThreads(
            existing: session.payload.world.openThreads,
            additions: payload.newThreads,
            resolvedKeys: payload.resolvedThreads
        )
        session.payload.world.openThreads = threadResult.threads

        if !payload.epistemicGaps.isEmpty {
            let combined = WorldMerge.uniqueStrings(payload.epistemicGaps + session.payload.world.activeEpistemicGaps)
            session.payload.world.activeEpistemicGaps = Array(combined.prefix(4))
        }

        if snapResult.updatedCount > 0 || threadResult.addedCount > 0 || threadResult.resolvedCount > 0 || !payload.epistemicGaps.isEmpty {
            session.scheduleSave()
        }

        return SyncOutcome(
            updatedCharacters: snapResult.updatedCount,
            conflictCharacters: snapResult.conflictCount,
            addedThreads: threadResult.addedCount,
            resolvedThreads: threadResult.resolvedCount
        )
    }

    /// 按时间顺序分段扫描全书正文，补全早期章节埋下的未决伏笔与人物演进状态。
    static func syncFullManuscript(
        session: ProjectSession,
        store: AppStore,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> SyncOutcome {
        let fullText = session.manuscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else {
            throw WorldRunError(message: "当前书稿为空，无法扫描全书伏笔。")
        }
        let chunkBudget = max(1_500, min(4_000, store.settings.promptBudgetTokens / 3))
        let chunks = WorldDigest.chunks(of: fullText, tokenBudget: chunkBudget, overlapTokens: 120)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !chunks.isEmpty else {
            throw WorldRunError(message: "未切分出可扫描的正文片段。")
        }

        var totalUpdated = 0
        var totalConflicts = 0
        var totalAdded = 0
        var totalResolved = 0
        for (idx, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            onProgress?(idx + 1, chunks.count)
            let step = try await syncExcerpt(chunk, session: session, store: store)
            totalUpdated += step.updatedCharacters
            totalConflicts = max(totalConflicts, step.conflictCharacters)
            totalAdded += step.addedThreads
            totalResolved += step.resolvedThreads
        }
        return SyncOutcome(
            updatedCharacters: totalUpdated,
            conflictCharacters: totalConflicts,
            addedThreads: totalAdded,
            resolvedThreads: totalResolved
        )
    }

    static func buildMessages(
        excerpt: String,
        characters: [CharacterCard],
        openThreads: [PlotThread]
    ) -> [LLMMessage] {
        let charLines: String = characters.isEmpty
            ? "（暂无已建人物卡）"
            : characters.map { card in
                var line = "• \(card.name)"
                if !card.aliases.isEmpty {
                    line += "（别称：\(card.aliases.joined(separator: "、"))）"
                }
                let goal = card.goals.trimmingCharacters(in: .whitespacesAndNewlines)
                if !goal.isEmpty {
                    line += "｜当前目标：\(goal)"
                }
                if let snap = card.dynamicSnapshot?.renderedSummary(characterName: card.name) {
                    line += " -> \(snap)"
                }
                return line
            }.joined(separator: "\n")

        let threadLines: String = openThreads.isEmpty
            ? "（暂无未决伏笔）"
            : openThreads.map(\.renderedLine).joined(separator: "\n")

        let system = """
        你是一个精准的小说叙事状态追踪器。请仅根据「本段新正文」中明确发生的变化，输出严格 JSON 对象，不要输出任何额外解释或 Markdown 围栏以外的文字。

        JSON 结构：
        {
          "character_snapshots": [
            {
              "name": "已有角色名",
              "location": "本段结束时的最新位置（未变化可留空）",
              "current_goal": "当前最新目标（未变化可留空）",
              "condition": "最新身心/伤势/情绪状态（未变化可留空）",
              "possessions": ["当前明确持有的关键物品，没有则空数组"],
              "known_facts": ["本段新获知的关键秘密或信息，没有则空数组"],
              "relationship_notes": "对他人态度的新变化（未变化可留空）",
              "conflict_note": "若本段与既有角色姓名、硬设定或已知事实明显矛盾，简要写明矛盾点；无矛盾留空"
            }
          ],
          "new_threads": [
            {
              "title": "简短伏笔标题",
              "obligation": "后续必须兑现的承诺、线索或悬念",
              "related_characters": ["相关角色名"]
            }
          ],
          "resolved_threads": ["本段已经明确兑现或收束的已有伏笔标题"],
          "epistemic_gaps": ["读者或甲已知、但乙尚不知情的关键信息差，没有则空数组"]
        }

        要求：
        1. `character_snapshots` 只更新已有角色卡中的角色，且只填本段体现出的最新状态（覆盖语义，不复述旧历史）。
        2. `new_threads` 只记录尚未解决、需要后续交代的悬念/约定，不要记录大纲已写的普通流水账。
        3. 若本段未发生状态变化，对应数组返回 `[]`。
        """

        let user = """
        # 已有角色与当前快照
        \(charLines)

        # 当前未决伏笔
        \(threadLines)

        # 本段新正文
        \(excerpt)
        """

        return [.system(system), .user(user)]
    }
}
