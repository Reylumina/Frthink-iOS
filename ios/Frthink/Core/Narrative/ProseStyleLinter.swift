import Foundation

/// 中文旁白去 AI 味密度检查的每千字阈值基线（严格豁免对白引号内部文字）。
struct StyleLintThresholds: Codable, Hashable {
    var hollowPronounsPer1K: Double = 4.0
    var demonstrativeClutterPer1K: Double = 6.0
    var contrastiveNegationPer1K: Double = 1.5
    var narrationEmDashPer1K: Double = 3.0
    var minimumNarrationChars: Int = 40

    static let literaryP90 = StyleLintThresholds()
}

/// 纯本地确定性中文文风检查器：不发起模型调用，按旁白密度定位模板化句式，
/// 自动跳过双引号、直角引号与双直角引号包裹的人物对白。
enum ProseStyleLinter {

    private struct RuleSpec {
        let key: String
        let regex: NSRegularExpression?
        let threshold: (StyleLintThresholds) -> Double
    }

    private static let rules: [RuleSpec] = [
        RuleSpec(
            key: "hollow_pronouns",
            regex: try? NSRegularExpression(
                pattern: "某种程度|某种|一种难以|一丝|一抹|仿佛某种|不由得|不禁|莫名地"
            ),
            threshold: { $0.hollowPronounsPer1K }
        ),
        RuleSpec(
            key: "demonstrative_clutter",
            regex: try? NSRegularExpression(
                pattern: "这个|那个|这些|那些|这一刻|那一刻|这种|那种"
            ),
            threshold: { $0.demonstrativeClutterPer1K }
        ),
        RuleSpec(
            key: "contrastive_negation",
            regex: try? NSRegularExpression(
                pattern: "(?:不是|并非)[^。！？\\n]{1,28}(?:而是|却只是)|与其说[^。！？\\n]{1,20}不如说"
            ),
            threshold: { $0.contrastiveNegationPer1K }
        ),
        RuleSpec(
            key: "narration_em_dash",
            regex: try? NSRegularExpression(pattern: "——"),
            threshold: { $0.narrationEmDashPer1K }
        ),
    ]

    /// 提取严格位于对话引号之外的连续 UTF-16 旁白区间；遇到换行符时重置未闭合引号以防误吞后文。
    static func narrationRanges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        let length = nsText.length
        guard length > 0 else { return [] }

        var ranges: [NSRange] = []
        var expectedClosers: [unichar] = []
        var segmentStart: Int? = 0

        for idx in 0..<length {
            let ch = nsText.character(at: idx)
            if ch == 0x000A {
                expectedClosers.removeAll(keepingCapacity: true)
                if segmentStart == nil {
                    segmentStart = idx
                }
                continue
            }

            if let top = expectedClosers.last, ch == top {
                expectedClosers.removeLast()
                if expectedClosers.isEmpty {
                    segmentStart = idx + 1
                }
                continue
            }

            let closingQuote: unichar?
            switch ch {
            case 0x201C: // “
                closingQuote = 0x201D
            case 0x300C: // 「
                closingQuote = 0x300D
            case 0x300E: // 『
                closingQuote = 0x300F
            case 0x0022: // "
                closingQuote = 0x0022
            default:
                closingQuote = nil
            }

            if let closer = closingQuote {
                if expectedClosers.isEmpty, let start = segmentStart, idx > start {
                    ranges.append(NSRange(location: start, length: idx - start))
                }
                segmentStart = nil
                expectedClosers.append(closer)
            } else if expectedClosers.isEmpty, segmentStart == nil {
                segmentStart = idx
            }
        }

        if expectedClosers.isEmpty, let start = segmentStart, length > start {
            ranges.append(NSRange(location: start, length: length - start))
        }
        return ranges
    }

    static func lint(
        _ text: String,
        pageIndex: Int = 0,
        baseUTF16Offset: Int = 0,
        thresholds: StyleLintThresholds = .literaryP90,
        now: Date = Date()
    ) -> StyleLintReport {
        let nsText = text as NSString
        let nRanges = narrationRanges(in: text)

        var narrationCharCount = 0
        for range in nRanges {
            let slice = nsText.substring(with: range)
            narrationCharCount += slice.unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }.count
        }

        var metricsPer1K: [String: Double] = [:]
        var collectedSpans: [TextSpanAnchor] = []
        var seenSpanKeys = Set<String>()

        for rule in rules {
            guard let regex = rule.regex else { continue }
            var matchedRanges: [NSRange] = []
            for range in nRanges {
                let matches = regex.matches(in: text, range: range)
                for m in matches {
                    matchedRanges.append(m.range)
                }
            }

            let per1K = narrationCharCount > 0
                ? Double(matchedRanges.count) * 1_000.0 / Double(narrationCharCount)
                : 0.0
            metricsPer1K[rule.key] = per1K

            if narrationCharCount >= thresholds.minimumNarrationChars,
               per1K > rule.threshold(thresholds) {
                for mRange in matchedRanges {
                    let key = "\(mRange.location):\(mRange.length)"
                    guard seenSpanKeys.insert(key).inserted else { continue }
                    let quote = nsText.substring(with: mRange)
                    let ctxStart = max(0, mRange.location - 16)
                    let ctxEnd = min(nsText.length, mRange.location + mRange.length + 16)
                    let context = nsText.substring(
                        with: NSRange(location: ctxStart, length: max(0, ctxEnd - ctxStart))
                    )
                    collectedSpans.append(
                        TextSpanAnchor.make(
                            pageIndex: pageIndex,
                            utf16Start: baseUTF16Offset + mRange.location,
                            utf16Length: mRange.length,
                            quote: quote,
                            paragraphText: context
                        )
                    )
                }
            }
        }

        let sortedSpans = collectedSpans.sorted { lhs, rhs in
            if lhs.utf16Start != rhs.utf16Start { return lhs.utf16Start < rhs.utf16Start }
            return lhs.utf16Length < rhs.utf16Length
        }

        return StyleLintReport(
            metricsPer1KChars: metricsPer1K,
            flaggedSpans: Array(sortedSpans.prefix(50)),
            checkedAt: now
        )
    }
}
