import Foundation

/// 基于输入预算与关联度的动态上下文选择器。
///
/// 设计原则：
/// 1. **预算驱动，不用魔法阈值**：只有当人物卡、事件卡或语料库总开销超过当前模型 `inputBudget`
///    的合理份额时才触发筛选与分层压缩；中小体量设定集全量保留，既不误伤质量，也零缓存抖动。
/// 2. **严格保持原有顺序（保 KV Cache）**：所有筛选与压缩均保持数组原始顺序，绝不每轮重排 `system` 顺序。
/// 3. **扫描窗口对齐正文窗口**：直接扫描当前实际发送的 `effectiveBody`、会话历史与本轮指令。
enum DynamicContextSelector {
    static let stickyDurationTurns = 3

    struct SelectionResult {
        let characters: [CharacterCard]
        let matchedCharacterIDs: Set<String>
        let renderedEvents: String
        let matchedEventIDs: Set<String>
        let worldbooks: [PromptAssembly.Worldbook]
        let matchedWorldbookIDs: Set<String>
        let activatedWorldbookKeys: [String]
    }

    /// 构造扫描文本：本轮指令 + 历史消息 + 当前实际发送的正文窗口。
    static func makeScanText(
        instruction: String?,
        messages: [ChatMessage],
        bodyWindow: String
    ) -> String {
        var parts: [String] = []
        if let instruction, !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(instruction)
        }
        for msg in messages {
            let trimmed = msg.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }
        if !bodyWindow.isEmpty {
            parts.append(bodyWindow)
        }
        return parts.joined(separator: "\n")
    }

    static func select(
        world: WorldBook,
        assemblyWorldbooks: [PromptAssembly.Worldbook] = [],
        scanText: String,
        inputBudget: Int,
        stickyCharacterIDs: Set<String>,
        stickyEventIDs: Set<String>,
        stickyWorldbookIDs: Set<String> = [],
        enabled: Bool
    ) -> SelectionResult {
        let allActive = PromptComposer.activeCharacters(in: world)
        guard enabled else {
            return SelectionResult(
                characters: allActive,
                matchedCharacterIDs: Set(allActive.map(\.id)),
                renderedEvents: PromptComposer.renderEvents(world.events),
                matchedEventIDs: Set(world.events.map(\.id)),
                worldbooks: assemblyWorldbooks,
                matchedWorldbookIDs: Set(assemblyWorldbooks.map(\.id)),
                activatedWorldbookKeys: []
            )
        }

        // 各静态资料区各自允许占用的预算上限（占有效输入预算的四分之一），未超标时全量保序发送。
        let sectionBudget = max(1, inputBudget / 4)

        let (selectedChars, matchedCharIDs) = selectCharacters(
            allActive,
            scanText: scanText,
            budget: sectionBudget,
            stickyIDs: stickyCharacterIDs,
            recentEvents: Array(world.events.suffix(2))
        )
        let (renderedEvents, matchedEvtIDs) = selectAndRenderEvents(
            world.events,
            activeCharacters: selectedChars,
            scanText: scanText,
            budget: sectionBudget,
            stickyIDs: stickyEventIDs
        )
        let (selectedBooks, matchedBookIDs, activeKeys) = selectWorldbooks(
            assemblyWorldbooks,
            entries: world.worldbookEntries,
            activeCharacters: selectedChars,
            scanText: scanText,
            budget: sectionBudget,
            stickyIDs: stickyWorldbookIDs
        )
        return SelectionResult(
            characters: selectedChars,
            matchedCharacterIDs: matchedCharIDs,
            renderedEvents: renderedEvents,
            matchedEventIDs: matchedEvtIDs,
            worldbooks: selectedBooks,
            matchedWorldbookIDs: matchedBookIDs,
            activatedWorldbookKeys: activeKeys
        )
    }

    static func selectCharacters(
        _ active: [CharacterCard],
        scanText: String,
        budget: Int,
        stickyIDs: Set<String>,
        recentEvents: [EventCard] = []
    ) -> (cards: [CharacterCard], matchedIDs: Set<String>) {
        let totalTokens = TokenEstimator.estimate(PromptComposer.renderCharacters(active))
        if active.count <= 3 && totalTokens <= budget {
            return (active, Set(active.map(\.id)))
        }

        let recentParticipants = Set(
            recentEvents.flatMap(\.characters)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        var matchedIDs: Set<String> = []
        var kept: [CharacterCard] = []

        // 按原始顺序遍历，绝不打乱 system 前缀顺序；最近事件参与者与黏性角色一并保底。
        for card in active {
            if matchesCharacter(card, in: scanText) {
                matchedIDs.insert(card.id)
                kept.append(card)
            } else if stickyIDs.contains(card.id) || matchesRecentParticipant(card, in: recentParticipants) {
                kept.append(card)
            }
        }

        // 若当前窗口未命中任何角色，回退从前向后保留最多 3 张核心人物卡。
        if kept.isEmpty {
            var used = 0
            for card in active.prefix(3) {
                let cost = TokenEstimator.estimate(PromptLibrary.characterBlock(for: card))
                if !kept.isEmpty && used + cost > budget { break }
                used += cost
                kept.append(card)
            }
            return (kept, matchedIDs)
        }

        // 在场名单超过预算时按原序裁出可容纳条目，防止长场次群戏爆预算。
        if TokenEstimator.estimate(PromptComposer.renderCharacters(kept)) > budget {
            var budgeted: [CharacterCard] = []
            var used = 0
            for card in kept {
                let cost = TokenEstimator.estimate(PromptLibrary.characterBlock(for: card))
                if !budgeted.isEmpty && used + cost > budget { continue }
                used += cost
                budgeted.append(card)
            }
            return (budgeted, matchedIDs)
        }

        return (kept, matchedIDs)
    }

    static func selectAndRenderEvents(
        _ events: [EventCard],
        activeCharacters: [CharacterCard],
        scanText: String,
        budget: Int,
        stickyIDs: Set<String>
    ) -> (rendered: String, matchedIDs: Set<String>) {
        let fullRendered = PromptComposer.renderEvents(events)
        if events.count <= 3 && TokenEstimator.estimate(fullRendered) <= budget {
            return (fullRendered, Set(events.map(\.id)))
        }

        let activeNames = Set(activeCharacters.flatMap { card in
            ([card.name] + card.aliases)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        })

        // 仅保留末尾最多 3 条完整近期事件（L2），其余远期事件默认折叠为 L1 单行脉络。
        let recencyBudget = max(1, budget / 2)
        var recentUsed = 0
        var recentFullIndices: Set<Int> = []
        for idx in events.indices.reversed() {
            if recentFullIndices.count >= 3 { break }
            let single = PromptComposer.renderEvents([events[idx]])
            let cost = TokenEstimator.estimate(single)
            if !recentFullIndices.isEmpty && recentUsed + cost > recencyBudget { break }
            recentUsed += cost
            recentFullIndices.insert(idx)
        }

        var matchedIDs: Set<String> = []
        var fullCards: [EventCard] = []
        var fullOrders: [Int] = []
        var compressedLines: [String] = []

        for (idx, event) in events.enumerated() {
            let order = idx + 1
            let charLinked = event.characters.contains { activeNames.contains($0) }
            let titleHit = !event.title.isEmpty && scanText.localizedCaseInsensitiveContains(event.title)
            if recentFullIndices.contains(idx) || charLinked || titleHit {
                matchedIDs.insert(event.id)
                fullCards.append(event)
                fullOrders.append(order)
            } else if stickyIDs.contains(event.id) {
                fullCards.append(event)
                fullOrders.append(order)
            } else {
                let summary = PromptLibrary.singleLine(
                    event.consequence.isEmpty ? event.development : event.consequence
                )
                let line = summary.isEmpty
                    ? "• 【\(PromptLibrary.singleLine(event.title))】[#\(order)]"
                    : "• 【\(PromptLibrary.singleLine(event.title))】[#\(order)] \(summary)"
                compressedLines.append(line)
            }
        }

        var sections: [String] = []
        if !compressedLines.isEmpty {
            sections.append("【前情脉络】\n" + compressedLines.joined(separator: "\n"))
        }
        if !fullCards.isEmpty {
            sections.append(PromptComposer.renderEvents(fullCards, orders: fullOrders))
        }
        return (sections.joined(separator: "\n\n"), matchedIDs)
    }

    /// 语料库超预算时按关键词重合度筛选，保持原始顺序发送以维护 KV Cache 前缀。
    static func selectCorpus(
        _ entries: [PromptAssembly.Corpus],
        scanText: String,
        budget: Int
    ) -> [PromptAssembly.Corpus] {
        let totalTokens = entries.reduce(0) { $0 + TokenEstimator.estimate($1.text) }
        guard totalTokens > budget else { return entries }

        let scored = entries.enumerated().map { idx, entry -> (index: Int, score: Int, cost: Int) in
            var score = entry.category == "仿写样本" ? 1 : 0
            let tokens = (entry.entryName + " " + entry.category)
                .split { $0.isWhitespace || $0.isPunctuation }
                .map(String.init)
                .filter { $0.count >= 2 }
            for token in tokens where scanText.localizedCaseInsensitiveContains(token) {
                score += 2
            }
            return (idx, score, TokenEstimator.estimate(entry.text))
        }

        var keptIndices: Set<Int> = []
        var used = 0
        for item in scored.sorted(by: {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.index < $1.index
        }) {
            if !keptIndices.isEmpty && used + item.cost > budget { continue }
            used += item.cost
            keptIndices.insert(item.index)
        }
        return entries.enumerated()
            .filter { keptIndices.contains($0.offset) }
            .map(\.element)
    }

    /// 世界书词条动态触发与预算裁剪（支持常驻、关键词触发、1 层递归扫描与 Sticky 粘滞，保持原序）。
    static func selectWorldbooks(
        _ worldbooks: [PromptAssembly.Worldbook],
        entries: [WorldbookEntry],
        activeCharacters: [CharacterCard],
        scanText: String,
        budget: Int,
        stickyIDs: Set<String>
    ) -> (books: [PromptAssembly.Worldbook], matchedIDs: Set<String>, activeKeys: [String]) {
        guard !worldbooks.isEmpty else { return ([], [], []) }
        let entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let activeNamesText = activeCharacters
            .flatMap { [$0.name] + $0.aliases }
            .joined(separator: " ")
        let primaryScan = scanText + "\n" + activeNamesText

        var matchedIDs: Set<String> = []
        var candidateIDs: Set<String> = []
        var firstPassBodies: [String] = []

        // 第一轮：常驻词条直接保留；关键词词条扫描正文/指令/在场角色名。
        for book in worldbooks {
            let meta = entryByID[book.id]
            let mode = meta?.resolvedActivationMode ?? .constant
            if mode == .constant {
                candidateIDs.insert(book.id)
                continue
            }
            if matchesWorldbook(book: book, meta: meta, in: primaryScan) {
                matchedIDs.insert(book.id)
                candidateIDs.insert(book.id)
                firstPassBodies.append(book.content)
            } else if stickyIDs.contains(book.id) {
                candidateIDs.insert(book.id)
            }
        }

        // 第二轮（1 层递归扫描）：已命中词条正文里提到的设定也会激活对应关键词词条。
        if !firstPassBodies.isEmpty {
            let recursiveScan = firstPassBodies.joined(separator: "\n")
            for book in worldbooks where !candidateIDs.contains(book.id) {
                let meta = entryByID[book.id]
                if matchesWorldbook(book: book, meta: meta, in: recursiveScan) {
                    matchedIDs.insert(book.id)
                    candidateIDs.insert(book.id)
                }
            }
        }

        let candidates = worldbooks.filter { candidateIDs.contains($0.id) }
        let totalTokens = candidates.reduce(0) { $0 + TokenEstimator.estimate($1.content) }
        let kept: [PromptAssembly.Worldbook]
        if totalTokens <= budget {
            kept = candidates
        } else {
            // 超预算时优先保留常驻/直接命中与高 order 词条，最终仍按原始数组顺序输出以保 KV Cache。
            let prioritized = candidates.enumerated().sorted { lhs, rhs in
                let lMeta = entryByID[lhs.element.id]
                let rMeta = entryByID[rhs.element.id]
                let lConst = (lMeta?.resolvedActivationMode ?? .constant) == .constant ? 1 : 0
                let rConst = (rMeta?.resolvedActivationMode ?? .constant) == .constant ? 1 : 0
                if lConst != rConst { return lConst > rConst }
                let lHit = matchedIDs.contains(lhs.element.id) ? 1 : 0
                let rHit = matchedIDs.contains(rhs.element.id) ? 1 : 0
                if lHit != rHit { return lHit > rHit }
                let lOrder = lMeta?.order ?? 0
                let rOrder = rMeta?.order ?? 0
                if lOrder != rOrder { return lOrder > rOrder }
                return lhs.offset < rhs.offset
            }
            var keptSet: Set<String> = []
            var used = 0
            for item in prioritized {
                let cost = TokenEstimator.estimate(item.element.content)
                if !keptSet.isEmpty && used + cost > budget { continue }
                used += cost
                keptSet.insert(item.element.id)
            }
            kept = candidates.filter { keptSet.contains($0.id) }
        }

        let activeKeys = kept.flatMap { book -> [String] in
            let meta = entryByID[book.id]
            return [book.name] + (meta?.resolvedKeys ?? [])
        }
        return (kept, matchedIDs, activeKeys)
    }

    private static func matchesWorldbook(
        book: PromptAssembly.Worldbook,
        meta: WorldbookEntry?,
        in text: String
    ) -> Bool {
        let keys = (meta?.resolvedKeys ?? []) + [book.name]
        return keys
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
            .contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func matchesCharacter(_ card: CharacterCard, in text: String) -> Bool {
        let candidates = ([card.name] + card.aliases)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return candidates.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func matchesRecentParticipant(_ card: CharacterCard, in names: Set<String>) -> Bool {
        guard !names.isEmpty else { return false }
        let candidates = ([card.name] + card.aliases)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return candidates.contains { names.contains($0) }
    }
}
