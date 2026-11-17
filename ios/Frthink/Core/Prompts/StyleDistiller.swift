import Foundation

/// 深度文风蒸馏器：复用 `WorldDigest` 按预算分段，结合语言指纹统计、
/// 原著代表性段落抽取（Few-Shot）与 5 维结构化风格提炼，以及二阶段「去 AI 味精修」。
enum StyleDistiller {

    struct LinguisticFingerprint {
        let averageSentenceLength: Double
        let shortSentenceRatio: Double
        let dialogueRatio: Double
        let averageParagraphLength: Double

        var summaryLine: String {
            let avgSent = String(format: "%.1f", averageSentenceLength)
            let shortPct = Int((shortSentenceRatio * 100).rounded())
            let dlgPct = Int((dialogueRatio * 100).rounded())
            let avgPara = Int(averageParagraphLength.rounded())
            return "句均 \(avgSent) 字｜短句(≤10字)占比 \(shortPct)%｜对白占比 \(dlgPct)%｜段均 \(avgPara) 字"
        }
    }

    /// 分析文本的客观语言指纹。
    static func analyzeFingerprint(_ text: String) -> LinguisticFingerprint {
        let paragraphs = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else {
            return LinguisticFingerprint(
                averageSentenceLength: 0,
                shortSentenceRatio: 0,
                dialogueRatio: 0,
                averageParagraphLength: 0
            )
        }

        let sentenceSeparators = CharacterSet(charactersIn: "。！？!?；;")
        var sentenceLengths: [Int] = []
        var totalChars = 0
        var dialogueChars = 0
        var inQuote = false

        for para in paragraphs {
            totalChars += para.count
            for ch in para {
                if ch == "“" || ch == "「" {
                    inQuote = true
                } else if ch == "”" || ch == "」" {
                    inQuote = false
                } else if inQuote {
                    dialogueChars += 1
                }
            }
            let parts = para.components(separatedBy: sentenceSeparators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for s in parts {
                sentenceLengths.append(s.count)
            }
        }

        let sentCount = max(1, sentenceLengths.count)
        let avgSent = Double(sentenceLengths.reduce(0, +)) / Double(sentCount)
        let shortCount = sentenceLengths.filter { $0 <= 10 }.count
        let shortRatio = Double(shortCount) / Double(sentCount)
        let dlgRatio = totalChars > 0 ? Double(dialogueChars) / Double(totalChars) : 0
        let avgPara = Double(totalChars) / Double(paragraphs.count)

        return LinguisticFingerprint(
            averageSentenceLength: avgSent,
            shortSentenceRatio: shortRatio,
            dialogueRatio: dlgRatio,
            averageParagraphLength: avgPara
        )
    }

    /// 复用 `WorldDigest` 从正文前/中/后挑选最具代表性的原著片段作为 Few-Shot 范文。
    static func selectExemplarPassages(from text: String, maxCount: Int = 3) -> [String] {
        let chunks = WorldDigest.chunks(of: text, tokenBudget: 400, overlapTokens: 0)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !chunks.isEmpty else { return [] }
        guard chunks.count > maxCount else { return chunks }

        func score(_ chunk: String) -> Double {
            let hasQuote = chunk.contains("“") || chunk.contains("「")
            let punctCount = chunk.filter { "。！？，；".contains($0) }.count
            return Double(punctCount) + (hasQuote ? 10.0 : 0.0)
        }

        let bucketSize = max(1, chunks.count / maxCount)
        var picked: [String] = []
        for idx in 0..<maxCount {
            let start = idx * bucketSize
            guard start < chunks.count else { break }
            let end = (idx == maxCount - 1) ? chunks.count : min(chunks.count, start + bucketSize)
            if let best = chunks[start..<end].max(by: { score($0) < score($1) }) {
                picked.append(best)
            }
        }
        return picked
    }

    /// 构造深度风格指纹蒸馏请求（按模型输入预算截取样章，不写死固定字数）。
    static func distillMessages(
        sampleText: String,
        fingerprint: LinguisticFingerprint,
        existingTemplate: String,
        inputBudget: Int
    ) -> [LLMMessage] {
        let system = """
        请根据给定的原著片段和语言统计特征，整合一份可直接指导续写的中文仿写模板。
        只写可迁移的写法规则，不复述剧情、不照搬原句、不写空泛评价（如“文笔优美”“节奏紧凑”），不要解释分析过程。

        输出格式要求（严格遵守）：
        1. 只输出纯文本，严禁使用 Markdown（不要 #、**、*、列表符 -、代码块或数字编号）。
        2. 严格使用以下六个原版小标题分段，每个小标题单独占一行，下面用简洁平实的中文写可迁移规则：

        叙事视角与结构
        明确人称、限知或全知视角、视角切换规则，以及段落结构与单段内部的起承转合习惯。

        因果推进与节奏
        说明事件因果如何递进、冲突展开与信息释放的快慢节奏，以及长短句切换、段落切分如何配合节奏。

        句式用词与意象
        结合统计特征说明句长分布与断句习惯、高频偏好词性、意象来源、动作/感官/心理描写的比例及心理呈现方式，并说明修辞克制点。

        对白与人物推进
        说明对话标签写法与省略时机、人物语气留白与潜台词处理，以及如何通过对话推进信息与人物关系。

        场景转场与段落收束
        说明场景或时间切换的衔接手法，以及段落结尾和片段末尾的收束与留白习惯。

        应避免的写法
        只基于原著笔触列出与本文风相悖的表达习惯，证据不足的特征不猜测。

        3. 若已有仿写模板非空，在其基础上补充或融合新的有效特征，保留原有有用规则，不要无故删减。
        """

        let existingNote = existingTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let reserved = TokenEstimator.estimate(system) + TokenEstimator.estimate(existingNote) + 256
        let sampleTokenBudget = max(512, inputBudget - reserved)
        let sampleSlice = TokenEstimator.trimTail(sampleText, toTokens: sampleTokenBudget)

        let user = """
        【统计指纹】
        \(fingerprint.summaryLine)

        【已有仿写模板（如有则增量融合去重，空则忽略）】
        \(existingNote.isEmpty ? "无" : existingNote)

        【原著样章片段】
        \(sampleSlice)
        """
        return [.system(system), .user(user)]
    }

    /// 构造「风格与审查精修」请求：严格依据用户配置的「仿写模板」与「去 AI 味规则」重写草稿。
    static func polishMessages(
        draft: String,
        styleTemplate: String,
        aiFlavorRules: String
    ) -> [LLMMessage] {
        let system = """
        你是小说编辑，负责按用户的「仿写风格指纹」与「全局审查规则（去 AI 味规则）」对初稿执行精修。
        保留原草稿的全部剧情事件、人物动作与对话信息，只优化表达方式：
        1. 严格遵循下方用户提供的仿写风格指纹与全局审查规则；
        2. 保持叙事节奏与句式结构贴合目标文风，消除空洞概括与多余说教；
        3. 直接输出精修后的正文，不要解释或加前后缀。
        """

        var constraints: [String] = []
        let style = styleTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        if !style.isEmpty {
            constraints.append("【仿写风格指纹】\n\(style)")
        }
        let flavor = aiFlavorRules.trimmingCharacters(in: .whitespacesAndNewlines)
        if !flavor.isEmpty {
            constraints.append("【全局审查规则】\n\(flavor)")
        }
        let constraintBlock = constraints.isEmpty ? "" : constraints.joined(separator: "\n\n") + "\n\n"
        let user = "\(constraintBlock)【待精修草稿】\n\(draft)"
        return [.system(system), .user(user)]
    }
}
