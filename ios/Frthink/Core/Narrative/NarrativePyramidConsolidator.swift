import Foundation

/// 分层记忆金字塔滚动巩固器：
/// 将溢出的场拍卡滚动合并为阶段/章节摘要（`closedPlotlines`），
/// 并将溢出的阶段摘要滚动合成为全书卷纲（`volumeOneLiners`），保持上下文常量预算且有确定性离线兜底。
enum NarrativePyramidConsolidator {

    static let sceneCardRollupThreshold = 6
    static let plotlineRollupThreshold = 10
    static let retainedRecentSceneCards = 2
    static let retainedRecentPlotlines = 2

    static func needsSceneRollup(in pyramid: NarrativePyramid) -> Bool {
        pyramid.recentSceneCards.count >= sceneCardRollupThreshold
    }

    static func needsVolumeRollup(in pyramid: NarrativePyramid) -> Bool {
        pyramid.closedPlotlines.count >= plotlineRollupThreshold
    }

    static func pendingSceneCardsForRollup(in pyramid: NarrativePyramid) -> [String] {
        guard needsSceneRollup(in: pyramid) else { return [] }
        let consumeCount = max(1, pyramid.recentSceneCards.count - retainedRecentSceneCards)
        return Array(pyramid.recentSceneCards.prefix(consumeCount))
    }

    static func pendingPlotlinesForRollup(in pyramid: NarrativePyramid) -> [String] {
        guard needsVolumeRollup(in: pyramid) else { return [] }
        let consumeCount = max(1, pyramid.closedPlotlines.count - retainedRecentPlotlines)
        return Array(pyramid.closedPlotlines.prefix(consumeCount))
    }

    static func buildSceneRollupMessages(cards: [String]) -> [LLMMessage] {
        let system = """
        你是一个精准的小说剧情压缩助手。请将多条连续的场拍记录合并为一条紧凑、客观的阶段摘要（不超过 120 字），保留核心事件因果、关键地点与人物关系变化，只输出纯文本单句或两句，不要加项目符号或前缀。
        """
        let user = cards.enumerated().map { idx, text in
            "\(idx + 1). \(text)"
        }.joined(separator: "\n")
        return [.system(system), .user(user)]
    }

    static func buildVolumeRollupMessages(plotlines: [String]) -> [LLMMessage] {
        let system = """
        你是一个精准的小说卷纲压缩助手。请将以下按时间推进的阶段情节合并为一条全书卷纲脉络（不超过 150 字），保留核心主线推进与主要矛盾转折，只输出纯文本，不要加项目符号或多余解释。
        """
        let user = plotlines.enumerated().map { idx, text in
            "\(idx + 1). \(text)"
        }.joined(separator: "\n")
        return [.system(system), .user(user)]
    }

    static func deterministicFallbackSummary(_ items: [String], maxChars: Int) -> String {
        let cleaned = items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty, maxChars > 0 else { return "" }
        let joined = cleaned.joined(separator: "；")
        guard joined.count > maxChars else { return joined }
        let keep = max(1, maxChars - 1)
        return String(joined.prefix(keep)) + "…"
    }

    static func applySceneRollup(
        summary: String,
        consumedCount: Int,
        to pyramid: inout NarrativePyramid
    ) {
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSummary.isEmpty, consumedCount > 0 else { return }
        let removeCount = min(consumedCount, pyramid.recentSceneCards.count)
        if removeCount > 0 {
            pyramid.recentSceneCards.removeFirst(removeCount)
        }
        if !pyramid.closedPlotlines.contains(cleanSummary) {
            pyramid.closedPlotlines.append(cleanSummary)
        }
    }

    static func applyVolumeRollup(
        summary: String,
        consumedCount: Int,
        to pyramid: inout NarrativePyramid
    ) {
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSummary.isEmpty, consumedCount > 0 else { return }
        let removeCount = min(consumedCount, pyramid.closedPlotlines.count)
        if removeCount > 0 {
            pyramid.closedPlotlines.removeFirst(removeCount)
        }
        if !pyramid.volumeOneLiners.contains(cleanSummary) {
            pyramid.volumeOneLiners.append(cleanSummary)
        }
    }
}
