import Foundation

/// 场景工作记忆组装器：
/// 从 `WriterPromptBuilder` 拆出动态状态、3+2 伏笔配额及 BM25 早期事实回查。
enum SceneMemoryBuilder {

    /// 统一场景工作记忆块（Single Compact Scene Memory Block）：
    /// 合并在场角色状态/认知边界、待兑现伏笔与端侧 BM25 早期硬事实回查为单一高信噪比只读块，
    /// 与 `body:authoritative` 同处用户上下文侧，既保留 `system` 前缀 KV Cache，又避免对末尾用户指令做 Depth-0 污染。
    static func composeSceneMemoryBlock(
        snapshot: WriterPromptSnapshot,
        effectiveBodyText: String,
        activeCharacters: [CharacterCard],
        offStageSummary: String?,
        activatedWorldbookKeys: [String],
        currentInstruction: String?
    ) -> PromptBlock? {
        var parts: [String] = []

        let snapshotLines = activeCharacters.compactMap { card in
            card.dynamicSnapshot?.renderedSummary(characterName: card.name)
        }
        if !snapshotLines.isEmpty {
            parts.append("【在场角色状态与认知边界】\n" + snapshotLines.joined(separator: "\n"))
        }

        if let offStageSummary, !offStageSummary.isEmpty {
            parts.append("【在档未出场人物（可按需切入打破局面）】\n" + offStageSummary)
        }

        if !snapshot.world.activeEpistemicGaps.isEmpty {
            let gaps = snapshot.world.activeEpistemicGaps.prefix(4).map { "• \($0)" }
            parts.append("【当前认知信息差】\n" + gaps.joined(separator: "\n"))
        }

        let selectedThreads = prioritizedThreads(
            from: snapshot.world.openThreads,
            activeCharacters: activeCharacters
        )
        let threadLines = selectedThreads.map(\.renderedLine)
        if !threadLines.isEmpty {
            parts.append("【待兑现叙事承诺/伏笔】\n" + threadLines.joined(separator: "\n"))
        }

        if snapshot.settings.dynamicContextActivation,
           effectiveBodyText.count < snapshot.manuscript.count {
            let queryTerms = activeCharacters.flatMap { [$0.name] + $0.aliases }
                + activatedWorldbookKeys
            let recalled = ManuscriptIndex.recallHistoricalExcerpts(
                fullManuscript: snapshot.manuscript,
                activeWindowText: effectiveBodyText,
                queryTerms: queryTerms,
                instructionText: currentInstruction ?? "",
                causalLimit: snapshot.continuationAnchor,
                maxResults: 3,
                maxTokens: 500
            )
            if !recalled.isEmpty {
                let recallText = recalled.map(\.text).joined(separator: "\n---\n")
                parts.append("【前文相关事实回查】\n" + recallText)
            }
        }

        guard !parts.isEmpty else { return nil }
        return PromptBlock(
            key: "memory:scene-block",
            category: .authoritativeBody,
            title: "场景工作记忆",
            body: parts.joined(separator: "\n\n")
        )
    }

    /// 3+2 伏笔配额：最多 3 条在场关联伏笔 + 最多 2 条最久未推进的跨线远期伏笔，避免陷入局部舒适区。
    static func prioritizedThreads(
        from threads: [PlotThread],
        activeCharacters: [CharacterCard]
    ) -> [PlotThread] {
        let openThreads = threads.filter { $0.status == .open }
        guard !openThreads.isEmpty else { return [] }
        let activeNames = Set(activeCharacters.flatMap { [$0.name] + $0.aliases })
        let localThreads = openThreads
            .filter { $0.relatedCharacters.contains(where: { activeNames.contains($0) }) }
            .sorted { $0.updatedAt > $1.updatedAt }
        let crossLineThreads = openThreads
            .filter { !$0.relatedCharacters.contains(where: { activeNames.contains($0) }) }
            .sorted { $0.updatedAt < $1.updatedAt }

        var selectedThreads = Array(localThreads.prefix(3))
        let crossLimit = max(2, 5 - selectedThreads.count)
        selectedThreads.append(contentsOf: crossLineThreads.prefix(crossLimit))
        if selectedThreads.count < 5 {
            let pickedIDs = Set(selectedThreads.map(\.id))
            let remaining = localThreads.filter { !pickedIDs.contains($0.id) }
            selectedThreads.append(contentsOf: remaining.prefix(5 - selectedThreads.count))
        }
        return Array(selectedThreads.prefix(5))
    }
}
