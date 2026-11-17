import Foundation

/// 深度蒸馏器：复用 `WorldDigest` 按预算分段，结合语言统计特征、
/// 原著代表性节选抽取与纯文本仿写模板提炼。
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

    /// 复用 `WorldDigest` 从正文前/中/后挑选最具代表性的原著节选（单句或过短碎片不计入）。
    static func selectExemplarPassages(from text: String, maxCount: Int = 3) -> [String] {
        let sentenceEnds = CharacterSet(charactersIn: "。！？!?")
        let chunks = WorldDigest.chunks(of: text, tokenBudget: 400, overlapTokens: 0)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { chunk in
                guard chunk.count >= 200 else { return false }
                let endCount = chunk.unicodeScalars.filter { sentenceEnds.contains($0) }.count
                return endCount >= 3
            }
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

    /// 构造深度蒸馏请求（按模型输入预算截取样章，输出洗练纯文本仿写模板）。
    static func distillMessages(
        sampleText: String,
        fingerprint: LinguisticFingerprint,
        existingTemplate: String,
        inputBudget: Int
    ) -> [LLMMessage] {
        let system = """
        请细读给定的原著片段，参考篇幅与句长统计，整合一份可直接指导续写的中文仿写模板，使后续行文自然凝练、贴合原著神韵且远离模板化套路。
        只写可迁移的写法，不复述人物与事件，不照搬原句；用精炼、克制的书面语撰写，不要解释分析过程，不要写空泛赞美或学术腔。

        用清晰的小标题覆盖以下六个方面：
        - 叙事视角与结构：明确人称、限知边界与视角切换节点，以及单段内部的起承转合与行气贯通。
        - 因果推进与节奏：概括事件因果的隐显脉络、信息铺垫与延迟揭晓，以及长短句错落与段落疏密对张力的调节。
        - 句式用词与意象：结合篇幅统计概括句长分布与断句节律、动词与名词质感、意象取材方向，以及动作、感官、心理描写的分寸与情绪外化手法。
        - 对白与人物推进：概括对话标签取舍与省笔、人物语气留白与言外之意，以及借对白推进关系与暗流的手法。
        - 场景转场与段落收束：概括时空转场的过渡媒介，以及段尾与节末如何收束留白、保留余韵，避免强行议论升华。
        - 应避免的写法：只依据原著笔触指出与之相悖的模板化表达，证据不足的特征不猜测。

        若已有仿写模板非空，在其基础上融合补充新的有效特征，保留原有可用规则。
        """

        let existingNote = existingTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let reserved = TokenEstimator.estimate(system) + TokenEstimator.estimate(existingNote) + 256
        let sampleTokenBudget = max(512, inputBudget - reserved)
        let sampleSlice = TokenEstimator.trimTail(sampleText, toTokens: sampleTokenBudget)

        let user = """
        参考统计：\(fingerprint.summaryLine)

        已有仿写模板（如有则融合去重，无则忽略）：
        \(existingNote.isEmpty ? "无" : existingNote)

        原著样章：
        \(sampleSlice)
        """
        return [.system(system), .user(user)]
    }

    /// 为抽取的原著节选反推简短写作指令，用于写作时构造 Few-Shot 对话示范。
    static func exemplarPromptsMessages(for passages: [String]) -> [LLMMessage] {
        let system = """
        请为下面每段原著节选各反推一条简短的中文写作指令（15至30字），概括该段的情节动作与笔法重心，用于后续上下文示范。
        严格按输入顺序每段输出一行，不要编号、不要引号、不要多余解释。
        """
        let numbered = passages.enumerated().map { idx, text in
            "[\(idx + 1)]\n\(text)"
        }.joined(separator: "\n\n")
        return [.system(system), .user(numbered)]
    }

    /// 解析反推指令列表；若行数不匹配或为空则按位置安全回退。
    static func parseExemplarPrompts(_ raw: String, count: Int) -> [String] {
        let lines = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count == count else { return [] }
        return lines.map { line in
            let cleaned = line.replacingOccurrences(
                of: #"^(\[\d+\]|\d+[\.、\)]|[-•])\s*"#,
                with: "",
                options: .regularExpression
            )
            return String(cleaned.prefix(60))
        }
    }

    /// 从语料库中挑选最多 `maxPairs` 条「仿写样本」，构造固定前置对话示范（user 指令 → assistant 原文）。
    static func fewShotDialoguePairs(
        from corpus: [PromptAssembly.Corpus],
        maxPairs: Int = 2,
        tokenBudget: Int? = nil
    ) -> (messages: [LLMMessage], injectedEntryIDs: Set<String>) {
        guard maxPairs > 0 else { return ([], []) }
        let samples = corpus.filter {
            $0.category == "仿写样本"
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !samples.isEmpty else { return ([], []) }

        var messages: [LLMMessage] = []
        var ids: Set<String> = []
        var usedTokens = 0

        for entry in samples.prefix(maxPairs) {
            let rawTitle = entry.entryName.trimmingCharacters(in: .whitespacesAndNewlines)
            let isPlaceholder = rawTitle.isEmpty || rawTitle.hasPrefix("原著节选") || rawTitle.hasPrefix("原著范文")
            let prompt = isPlaceholder
                ? "请贴合本书文风与叙事节奏继续写作下文。"
                : "写作指令：\(rawTitle)"
            let pairCost = TokenEstimator.estimate(prompt) + TokenEstimator.estimate(entry.text)
            if let tokenBudget, !messages.isEmpty, usedTokens + pairCost > tokenBudget {
                break
            }
            if let tokenBudget, messages.isEmpty, pairCost > tokenBudget {
                break
            }
            messages.append(.user(prompt))
            messages.append(.assistant(entry.text))
            ids.insert(entry.entryID)
            usedTokens += pairCost
        }
        return (messages, ids)
    }
}
