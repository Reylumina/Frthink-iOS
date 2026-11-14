import Foundation

/// 素材归纳：从正文已归纳偏移继续，产出事件卡和文风笔记。
/// 与 `WorldWorkflow`（世界刷新/人物卡）分开，避免两套职责互相牵连。
@MainActor
enum WorldMaterialWorkflow {

    struct EventOutcome {
        let added: Int
        let updated: Int
        let total: Int

        var summary: String {
            if added == 0 && updated == 0 {
                return "本轮没有新的剧情事件。"
            }
            var parts: [String] = []
            if added > 0 { parts.append("新增 \(added) 张事件卡") }
            if updated > 0 { parts.append("补充 \(updated) 张事件卡") }
            return "事件卡抽取完成：" + parts.joined(separator: "，") + "。现在共 \(total) 张。"
        }
    }

    struct NotesOutcome {
        let updated: Bool

        var summary: String {
            updated
                ? "文风笔记已追加。"
                : "本轮没有发现新规则；已有模板和人物卡未被删除或覆盖。"
        }
    }

    // MARK: - 事件卡

    static func extractEvents(
        session: ProjectSession,
        store: AppStore
    ) async throws -> EventOutcome {
        let manuscript = session.manuscript
        guard !manuscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorldRunError(message: "当前正文为空，无法抽取事件卡。")
        }

        let key = "plot-events"
        let offset = Self.materialStart(manuscript, key: key, world: session.payload.world)
        let ns = manuscript as NSString
        guard offset < ns.length else {
            return EventOutcome(added: 0, updated: 0, total: session.payload.world.events.count)
        }
        let context = try WorldRequestContext.make(store: store)
        // 无法解析预算时仍允许抽取：P53 仅作为只读基线，缺省时降级为不附加既有事件上下文。
        let budget = try? PromptBudget.make(
            settings: store.settings,
            model: context.provider.resolvedModel
        )
        let tail = ns.substring(from: offset)
        let isLargeBook = manuscript.unicodeScalars.count >= 500_000
        let chunks: [String]
        if isLargeBook {
            let prefix = Self.largeBookPrefix(tail, budget: budget)
            chunks = prefix.isEmpty ? [] : [prefix]
        } else {
            let allChunks = await Task.detached(priority: .userInitiated) {
                // 剧情素材从已归纳偏移继续，3000 token、无重叠，最多 256 段。
                WorldDigest.chunks(of: tail, tokenBudget: 3_000, overlapTokens: 0)
                    .map(\.text)
            }.value
            chunks = Array(allChunks.prefix(256))
        }
        guard !chunks.isEmpty else {
            return EventOutcome(added: 0, updated: 0, total: session.payload.world.events.count)
        }
        var added = 0
        var updated = 0
        var consumed = 0
        for chunk in chunks {
            try Task.checkCancellation()
            let messages = PromptComposer.eventMessages(
                // 根据输入预算仅保留最近的事件卡，避免提示词线性膨胀。
                existingEvents: Self.promptEvents(
                    session.payload.world.events,
                    budget: Self.eventBaselineBudget(budget: budget, digest: chunk)
                ),
                digest: chunk,
                incremental: !session.payload.world.events.isEmpty
            )
            let events = try await context.completeAndParse(
                messages,
                failOnLength: true,
                requestErrorPrefix: "事件卡抽取请求失败",
                parseErrorPrefix: "事件卡解析失败",
                parse: WorldJSON.parseEvents
            )
            consumed += (chunk as NSString).length
            if !events.isEmpty {
                let result = WorldMerge.mergeEvents(
                    existing: session.payload.world.events,
                    incoming: events
                )
                session.payload.world.events = result.cards
                added += result.added
                updated += result.updated
            }
            // 每段完成即写进度；中途失败时下一轮从下一段继续。
            session.payload.world.materialSourceProgress[key] = Self.materialProgress(
                manuscript: manuscript,
                offset: offset,
                consumed: consumed,
                prompt: PromptLibrary.plotInitialInstruction
                    + PromptLibrary.plotIncrementalInstruction
            )
            session.scheduleSave()
        }

        return EventOutcome(
            added: added,
            updated: updated,
            total: session.payload.world.events.count
        )
    }

    // MARK: - 文风笔记

    static func extractStyleNotes(
        session: ProjectSession,
        store: AppStore
    ) async throws -> NotesOutcome {
        let manuscript = session.manuscript
        guard !manuscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WorldRunError(message: "当前正文为空，无法提炼文风笔记。")
        }

        let key = "imitation"
        let offset = Self.materialStart(manuscript, key: key, world: session.payload.world)
        let ns = manuscript as NSString
        guard offset < ns.length else {
            return NotesOutcome(updated: false)
        }
        let context = try WorldRequestContext.make(store: store)
        let budget = try? PromptBudget.make(
            settings: store.settings,
            model: context.provider.resolvedModel
        )
        let tail = ns.substring(from: offset)
        let isLargeBook = manuscript.unicodeScalars.count >= 500_000
        let chunks: [String]
        if isLargeBook {
            let prefix = Self.largeBookPrefix(tail, budget: budget)
            chunks = prefix.isEmpty ? [] : [prefix]
        } else {
            let allChunks = await Task.detached(priority: .userInitiated) {
                // 素材归纳从已归纳偏移继续，3000 token、无重叠，最多 256 段。
                WorldDigest.chunks(of: tail, tokenBudget: 3_000, overlapTokens: 0)
                    .map(\.text)
            }.value
            chunks = Array(allChunks.prefix(256))
        }
        guard !chunks.isEmpty else {
            return NotesOutcome(updated: false)
        }
        // 合并基准使用本轮执行前的原始笔记，防止合成结果重复叠加中间阶段追加的内容。
        let before = session.payload.world.styleNotes
        var notes: [String] = []
        var consumed = 0
        for chunk in chunks {
            try Task.checkCancellation()
            let raw = try await context.completeOrThrow(
                PromptComposer.segmentStyleNotesMessages(segment: chunk),
                errorPrefix: "文风笔记请求失败"
            )
            consumed += (chunk as NSString).length
            let note = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty, !WorldMerge.isNoAdditions(note) {
                notes.append(note)
                // 先落原文笔记；合成失败时保留笔记但不推进进度。
                session.payload.world.styleNotes = WorldMerge.appendStyleNotes(
                    existing: session.payload.world.styleNotes,
                    incoming: note
                )
                session.scheduleSave()
            }
        }

        let progress = Self.materialProgress(
            manuscript: manuscript,
            offset: offset,
            consumed: consumed,
            prompt: PromptLibrary.segmentStyleNotesInstruction
                + PromptLibrary.styleNotesMergeInstruction
        )

        guard !notes.isEmpty else {
            session.payload.world.materialSourceProgress[key] = progress
            session.scheduleSave()
            return NotesOutcome(updated: false)
        }
        let mergedNote: String
        if notes.count == 1 {
            mergedNote = notes[0]
        } else {
            mergedNote = try await context.completeOrThrow(
                PromptComposer.styleNotesMergeMessages(notes: notes),
                errorPrefix: "文风笔记合并失败"
            )
        }
        let incoming = mergedNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty, !WorldMerge.isNoAdditions(incoming) else {
            session.payload.world.materialSourceProgress[key] = progress
            session.scheduleSave()
            return NotesOutcome(updated: false)
        }

        let merged = WorldMerge.appendStyleNotes(existing: before, incoming: incoming)
        // P42/P43 首次建模板；已有模板走 P44/P45，只追加新增规则。
        let templateBefore = session.payload.world.styleTemplate
        let templateRaw = try await context.completeOrThrow(
            templateBefore.isEmpty
                ? PromptComposer.styleSynthesisMessages(notes: incoming)
                : PromptComposer.styleAppendMessages(
                    existingTemplate: templateBefore,
                    notes: incoming
                ),
            errorPrefix: "仿写模板请求失败"
        )
        let templateText = templateRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        var templateAfter = templateBefore
        if !templateText.isEmpty, !WorldMerge.isNoAdditions(templateText) {
            templateAfter = templateBefore.isEmpty
                ? templateText
                : WorldMerge.appendStyleNotes(
                    existing: templateBefore,
                    incoming: templateText
                )
        }

        session.payload.world.styleNotes = merged
        if templateAfter != templateBefore {
            session.payload.world.styleTemplate = templateAfter
        }
        session.payload.world.materialSourceProgress[key] = progress
        session.scheduleSave()
        return NotesOutcome(updated: true)
    }

    // MARK: - 公共

    /// 素材归纳基于上次处理偏移增量继续；前缀哈希失配则判定正文已修改并重置进度。
    ///
    /// 存档中的 `promptHash` 仅保留兼容性写入，暂不作为失效判定依据，避免跨端哈希口径差异引发非预期重跑。
    static func materialStart(
        _ manuscript: String,
        key: String,
        world: WorldBook
    ) -> Int {
        let ns = manuscript as NSString
        guard let progress = world.materialSourceProgress[key] else { return 0 }
        let offset = min(max(progress.processedUtf16, 0), ns.length)
        guard offset > 0, !progress.prefixHash.isEmpty else { return offset }
        let prefix = ns.substring(to: offset)
        return ContentHash.of(prefix) == progress.prefixHash ? offset : 0
    }

    /// P53「已有剧情梗概（只读）」能占多少输入 token。
    ///
    /// 计算既有事件可占用的上下文预算：扣除分段正文与指令开销，并预留 1024 token 安全余量。
    static func eventBaselineBudget(budget: PromptBudget?, digest: String) -> Int {
        guard let budget else { return 0 }
        let digestTokens = TokenEstimator.estimate(digest)
        let instructionTokens = TokenEstimator.estimate(
            PromptLibrary.plotIncrementalInstruction
                + PromptLibrary.eventContractIncremental
        )
        return max(0, budget.effectiveInputBudget - digestTokens - instructionTokens - 1_024)
    }

    /// 按预算裁剪进 P53 的已有事件。
    ///
    /// 按预算约束逆序选取最新的事件卡并按原序返回；若预算不足以容纳单张卡片则返回空数组。
    static func promptEvents(_ events: [EventCard], budget: Int) -> [EventCard] {
        guard budget > 0, !events.isEmpty else { return [] }
        var kept: [EventCard] = []
        var used = 0
        for event in events.reversed() {
            let cost = TokenEstimator.estimate(PromptComposer.renderEvents([event]))
            if used + cost > budget { break }
            kept.append(event)
            used += cost
        }
        return Array(kept.reversed())
    }

    private static func materialProgress(
        manuscript: String,
        offset: Int,
        consumed: Int,
        prompt: String
    ) -> MaterialSourceProgress {
        let ns = manuscript as NSString
        let end = min(offset + consumed, ns.length)
        let prefix = ns.substring(to: end)
        return MaterialSourceProgress(
            processedUtf16: end,
            prefixHash: ContentHash.of(prefix),
            promptHash: ContentHash.of(prompt)
        )
    }

    /// 大书模式（≥ 50 万码点）：单次取当前上下文可容纳的前缀。
    private static func largeBookPrefix(_ text: String, budget: PromptBudget?) -> String {
        let tokenLimit = max(2_000, (budget?.effectiveInputBudget ?? 24_000) - 2_000)
        guard TokenEstimator.estimate(text) > tokenLimit else { return text }
        var low = 0
        var high = text.count
        var best = ""
        while low <= high {
            let mid = (low + high) / 2
            let end = text.index(text.startIndex, offsetBy: mid)
            let candidate = String(text[..<end])
            if TokenEstimator.estimate(candidate) <= tokenLimit {
                best = candidate
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

}
