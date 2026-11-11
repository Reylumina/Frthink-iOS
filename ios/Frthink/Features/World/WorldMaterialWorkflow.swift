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
        let tail = ns.substring(from: offset)
        let allChunks = await Task.detached(priority: .userInitiated) {
            // 原版剧情素材从已归纳偏移继续，3000 token、无重叠，最多 256 段。
            WorldDigest.chunks(of: tail, tokenBudget: 3_000, overlapTokens: 0)
        }.value
        let chunks = Array(allChunks.prefix(256))
        guard !chunks.isEmpty else {
            return EventOutcome(added: 0, updated: 0, total: session.payload.world.events.count)
        }

        let context = try WorldRequestContext.make(store: store)
        var added = 0
        var updated = 0
        var consumed = 0
        for chunk in chunks {
            try Task.checkCancellation()
            let messages = PromptComposer.eventMessages(
                existingEvents: session.payload.world.events,
                digest: chunk
            )
            let raw: String
            do {
                raw = try await context.complete(messages)
            } catch {
                throw WorldRunError(
                    message: "事件卡抽取请求失败：\(error.localizedDescription)"
                )
            }
            let events: [EventCard]
            do {
                events = try WorldJSON.parseEvents(raw)
            } catch {
                throw WorldRunError(
                    message: "事件卡解析失败：\(error.localizedDescription)",
                    rawResponse: raw
                )
            }
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
        let tail = ns.substring(from: offset)
        let allChunks = await Task.detached(priority: .userInitiated) {
            // 原版素材归纳从已归纳偏移继续，3000 token、无重叠，最多 256 段。
            WorldDigest.chunks(of: tail, tokenBudget: 3_000, overlapTokens: 0)
        }.value
        let chunks = Array(allChunks.prefix(256))
        guard !chunks.isEmpty else {
            return NotesOutcome(updated: false)
        }

        let context = try WorldRequestContext.make(store: store)
        var notes: [String] = []
        var consumed = 0
        for chunk in chunks {
            try Task.checkCancellation()
            let raw: String
            do {
                raw = try await context.complete(
                    PromptComposer.segmentStyleNotesMessages(segment: chunk)
                )
            } catch {
                throw WorldRunError(
                    message: "文风笔记请求失败：\(error.localizedDescription)"
                )
            }
            consumed += (chunk as NSString).length
            let note = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty, !WorldMerge.isNoAdditions(note) {
                notes.append(note)
                // 先落原文笔记；合成不在本轮成功也不丢已提炼内容。
                session.payload.world.styleNotes = WorldMerge.appendStyleNotes(
                    existing: session.payload.world.styleNotes,
                    incoming: note
                )
            }
            session.scheduleSave()
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
            do {
                mergedNote = try await context.complete(
                    PromptComposer.styleNotesMergeMessages(notes: notes)
                )
            } catch {
                throw WorldRunError(
                    message: "文风笔记合并失败：\(error.localizedDescription)"
                )
            }
        }
        let incoming = mergedNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incoming.isEmpty, !WorldMerge.isNoAdditions(incoming) else {
            session.payload.world.materialSourceProgress[key] = progress
            session.scheduleSave()
            return NotesOutcome(updated: false)
        }

        let before = session.payload.world.styleNotes
        let merged = WorldMerge.appendStyleNotes(existing: before, incoming: incoming)

        // P42/P43 首次建模板；已有模板走 P44/P45，只追加新增规则。
        let templateBefore = session.payload.world.styleTemplate
        let templateRaw: String
        do {
            templateRaw = try await context.complete(
                templateBefore.isEmpty
                    ? PromptComposer.styleSynthesisMessages(notes: incoming)
                    : PromptComposer.styleAppendMessages(
                        existingTemplate: templateBefore,
                        notes: incoming
                    )
            )
        } catch {
            throw WorldRunError(
                message: "仿写模板请求失败：\(error.localizedDescription)"
            )
        }
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

    /// 素材归纳从上次偏移继续；前缀哈希对不上说明正文改过，从头再来。
    private static func materialStart(
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

}
