import Foundation

/// 译文分段：把原文切成「一段」翻译单元，并给出 `ContentHash` 缓存键。
///
/// 切法参考 Android 端：先按空行分块，块内按句末标点断句；太短的句子并进上一段
/// 以免请求数爆炸，超长的段落再按标点截断。同一段原文每次切出来的结果都一样，
/// 所以按 `ContentHash.of(segment)` 就能稳定命中缓存。
enum TranslationSegmenter {

    /// 目标语言固定 zh-CN（Android 端目前只有这一种）。
    static let target = TranslationSegment.defaultTarget

    /// 一个待翻译单元。`hash` 是 `ContentHash.of(text)`，缓存命中和落盘都用它。
    struct PlannedSegment: Identifiable, Hashable {
        let index: Int
        let text: String
        let hash: String

        var id: String { "\(index)-\(hash)" }
    }

    /// 单段上限。太长模型容易截断，太短请求数太多。
    private static let maxSegmentLength = 600
    /// 低于这个长度的句子并进相邻段一起翻。
    private static let minSegmentLength = 40
    /// 句末标点。`.`/`;`/`!`/`?` 照顾英文原文。
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

    /// 已存译文整理成 `sourceHash -> payload` 查表；同 hash 取 `updatedAt` 最新的那条。
    /// 查表不看 `owner`：原文和译文都在这台机器上，设置被重置、ownerID 换了也照样
    /// 能复用；只有写入时才用当前的 ownerID。
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
                    // 收尾的引号/括号跟上一句走，然后整句结束。
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

    /// 中文标点直接贴，英文句号后面补一个空格。
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
