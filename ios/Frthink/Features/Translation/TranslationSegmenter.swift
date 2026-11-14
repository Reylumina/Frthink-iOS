import Foundation

/// 译文分段处理：将原文拆分为翻译单元，并计算对应的 `ContentHash` 缓存键。
///
/// 分段策略：优先按空行分块，块内按句末标点切分；较短句子与前段合并以控制请求频次，
/// 超长文本按标点进一步截断。相同原文切分结果确定，基于 `ContentHash.of(segment)` 实现稳定缓存命中。
enum TranslationSegmenter {

    /// 正文译文目标标记。
    static let target = TranslationSegment.defaultTarget

    /// 一个待翻译单元。`hash` 是 `ContentHash.of(text)`，缓存命中和落盘都用它。
    struct PlannedSegment: Identifiable, Hashable {
        let index: Int
        let text: String
        let hash: String

        var id: String { "\(index)-\(hash)" }
    }

    /// 单段字符数上限，平衡模型输出完整性与调用频次。
    private static let maxSegmentLength = 600
    /// 最小段落字符阈值，低于此长度将并入相邻段落合并翻译。
    private static let minSegmentLength = 40
    /// 句末标点集合，包含中英文常用终止符号。
    private static let sentenceEnders: Set<Character> = [
        "。", "！", "？", "…", "；", ".", "!", "?", ";",
    ]
    /// 跟在句末标点后面、仍属于同一句的收尾符号。
    private static let trailingClosers: Set<Character> = [
        "”", "’", "」", "』", "）", ")", "》", "】", "\"", "'",
    ]

    // MARK: - 入口

    static func plan(for text: String) -> [PlannedSegment] {
        segments(from: text).enumerated().map { pair in
            PlannedSegment(
                index: pair.offset,
                text: pair.element,
                hash: ContentHash.of(pair.element)
            )
        }
    }

    static func segments(from text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }

        var sentences: [String] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                sentences.append(contentsOf: splitSentences(trimmed))
            }
        }

        var result: [String] = []
        for merged in mergeShortSentences(sentences) {
            result.append(contentsOf: capLength(merged))
        }
        return result
    }

    /// 汇总已保存译文为 `sourceHash -> payload` 索引字典；相同哈希保留 `updatedAt` 最新记录。
    /// 检索忽略 `owner`：本地译文在设置重置或账号更迭后保持可复用性，仅写入操作绑定当前 ownerID。
    static func cache(from translations: [TranslationSegment], project: String) -> [String: String] {
        var map: [String: String] = [:]
        for item in translations.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            guard item.project == project, item.target == target else { continue }
            let payload = item.payload.trimmingCharacters(in: .whitespacesAndNewlines)
            if payload.isEmpty { continue }
            map[item.sourceHash] = payload
        }
        return map
    }

    // MARK: - 断句

    private static func splitSentences(_ block: String) -> [String] {
        var result: [String] = []
        var current = ""
        var justEnded = false

        for character in block {
            if character == "\n" {
                flush(&current, into: &result)
                justEnded = false
                continue
            }
            if justEnded {
                if trailingClosers.contains(character) {
                    // 后置引号/括号合并至当前句尾，结束当前分句。
                    current.append(character)
                    flush(&current, into: &result)
                    justEnded = false
                    continue
                }
                flush(&current, into: &result)
                justEnded = false
            }
            current.append(character)
            if sentenceEnders.contains(character) {
                justEnded = true
            }
        }
        flush(&current, into: &result)
        return result
    }

    private static func flush(_ current: inout String, into result: inout [String]) {
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result.append(trimmed)
        }
        current = ""
    }

    // MARK: - 合并与截断

    private static func mergeShortSentences(_ sentences: [String]) -> [String] {
        var result: [String] = []
        var buffer = ""
        for sentence in sentences {
            if buffer.isEmpty {
                buffer = sentence
                continue
            }
            let bufferTooShort = buffer.count < minSegmentLength
            let sentenceTooShort = sentence.count < 12 && buffer.count < maxSegmentLength
            if bufferTooShort || sentenceTooShort {
                buffer = join(buffer, sentence)
            } else {
                result.append(buffer)
                buffer = sentence
            }
        }
        if !buffer.isEmpty {
            result.append(buffer)
        }
        return result
    }

    /// 拼接两段文本：中文字符直接连接，西文字符间插入单空格。
    private static func join(_ first: String, _ second: String) -> String {
        guard let last = first.last, let next = second.first else { return first + second }
        if last.isWhitespace || next.isWhitespace { return first + second }
        if isWideCharacter(last) || isWideCharacter(next) { return first + second }
        return first + " " + second
    }

    private static func isWideCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return scalar.value >= 0x2E80
    }

    private static func capLength(_ text: String) -> [String] {
        if text.count <= maxSegmentLength {
            return [text]
        }
        var result: [String] = []
        var current = ""
        var length = 0
        for character in text {
            current.append(character)
            length += 1
            if length >= maxSegmentLength, isBreakCharacter(character) {
                flush(&current, into: &result)
                length = 0
            }
        }
        flush(&current, into: &result)
        return result
    }

    private static func isBreakCharacter(_ character: Character) -> Bool {
        sentenceEnders.contains(character)
            || character == "，"
            || character == ","
            || character == "、"
            || character == " "
            || character == "\n"
    }
}
