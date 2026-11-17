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

    /// 从全书按职能互补抽取最多 3 段原著节选：
    /// 第 1 段（800 token）：纯叙事/场景/心理描写；
    /// 第 2 段（800 token）：对白与动作穿插互动；
    /// 第 3 段（1200 token）：后半程综合推进段。
    static func selectExemplarPassages(from text: String, maxCount: Int = 3) -> [String] {
        let sentenceEnds = CharacterSet(charactersIn: "。！？!?")
        func isQualified(_ chunk: String) -> Bool {
            guard chunk.count >= 200 else { return false }
            let endCount = chunk.unicodeScalars.filter { sentenceEnds.contains($0) }.count
            return endCount >= 3
        }

        let chunks800 = WorldDigest.chunks(of: text, tokenBudget: 800, overlapTokens: 0)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isQualified)
        guard !chunks800.isEmpty else { return [] }
        if chunks800.count == 1 || maxCount <= 1 {
            return Array(chunks800.prefix(maxCount))
        }

        func dialogueStats(_ chunk: String) -> (quotes: Int, dialogueShare: Double, puncts: Int) {
            var inQuote = false
            var dialogueChars = 0
            var quotes = 0
            var puncts = 0
            for ch in chunk {
                if ch == "“" || ch == "「" {
                    inQuote = true
                    quotes += 1
                } else if ch == "”" || ch == "」" {
                    inQuote = false
                } else if inQuote {
                    dialogueChars += 1
                }
                if "。！？，；".contains(ch) {
                    puncts += 1
                }
            }
            let share = Double(dialogueChars) / Double(max(1, chunk.count))
            return (quotes, share, puncts)
        }

        // 第 1 段：优先纯叙事/场景/心理段（低对白占比 + 高描写密度）。
        func narrativeScore(_ chunk: String) -> Double {
            let st = dialogueStats(chunk)
            let lowDialogueBonus = st.quotes == 0 ? 20.0 : (st.dialogueShare < 0.15 ? 10.0 : -st.dialogueShare * 25.0)
            let lenFactor = min(1.0, Double(chunk.count) / 450.0)
            return (Double(st.puncts) + lowDialogueBonus) * lenFactor
        }

        // 第 2 段：优先对白与动作叙述均衡穿插的段落（避免纯水台词）。
        func dialogueActionScore(_ chunk: String) -> Double {
            let st = dialogueStats(chunk)
            let balancedBonus: Double
            if st.quotes >= 2 && st.dialogueShare >= 0.15 && st.dialogueShare <= 0.65 {
                balancedBonus = 18.0
            } else if st.quotes >= 1 {
                balancedBonus = 6.0
            } else {
                balancedBonus = 0.0
            }
            let lenFactor = min(1.0, Double(chunk.count) / 450.0)
            return (Double(st.puncts) + balancedBonus) * lenFactor
        }

        var picked: [String] = []
        var usedIndices: Set<Int> = []

        if let firstIdx = chunks800.indices.max(by: { narrativeScore(chunks800[$0]) < narrativeScore(chunks800[$1]) }) {
            picked.append(chunks800[firstIdx])
            usedIndices.insert(firstIdx)
        }

        if maxCount >= 2 {
            let remaining = chunks800.indices.filter { !usedIndices.contains($0) }
            if let secondIdx = remaining.max(by: { dialogueActionScore(chunks800[$0]) < dialogueActionScore(chunks800[$1]) }) {
                picked.append(chunks800[secondIdx])
                usedIndices.insert(secondIdx)
            }
        }

        // 第 3 段：放宽至 1200 token，从后半程选取综合推进段（避免与前两段重复）。
        if maxCount >= 3 {
            let ns = text as NSString
            let tailStart = ns.length / 2
            let tailSlice = tailStart > 0 ? ns.substring(from: tailStart) : text
            let chunks1200 = WorldDigest.chunks(of: tailSlice, tokenBudget: 1200, overlapTokens: 0)
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { chunk in
                    isQualified(chunk) && !picked.contains(where: { chunk.contains($0) || $0.contains(chunk) })
                }
            if let third = chunks1200.max(by: { dialogueActionScore($0) < dialogueActionScore($1) }) {
                picked.append(third)
            } else {
                let remaining = chunks800.indices.filter { !usedIndices.contains($0) }
                if let fallbackThirdIdx = remaining.last {
                    picked.append(chunks800[fallbackThirdIdx])
                }
            }
        }

        return Array(picked.prefix(maxCount))
    }

    /// 构造深度蒸馏请求（总览全书前中后样章，按模型输入预算均衡采样）。
    static func distillMessages(
        sampleText: String,
        fingerprint: LinguisticFingerprint,
        existingTemplate: String,
        inputBudget: Int
    ) -> [LLMMessage] {
        let system = """
        请细读给定的全书代表性样章，参考篇幅与句长统计，整合一份可直接指导续写的中文仿写模板，使后续行文自然凝练、贴合原著神韵且远离模板化套路。
        只写可迁移的写法，不复述人物与事件，不照搬原句；用精炼、克制的书面语撰写，不要解释分析过程，不要写空泛赞美或学术腔。

        请用清晰的中文小标题覆盖以下六个方面，每个小标题单独成行，下面用简洁凝练的短句分条说明（不要使用 > 引用块、+ 号、--- 分割线、代码块或多余的 ** 加粗）：

        叙事视角与结构
        明确人称、限知边界与视角切换节点，以及单段内部的起承转合与行气贯通。

        因果推进与节奏
        概括事件因果的隐显脉络、信息铺垫与延迟揭晓，以及长短句错落与段落疏密对张力的调节。

        句式用词与意象
        结合篇幅统计概括句长分布与断句节律、动词与名词质感、意象取材方向，以及动作、感官、心理描写的分寸与情绪外化手法。

        对白与人物推进
        概括对话标签取舍与省笔、人物语气留白与言外之意，以及借对白推进关系与暗流的手法。

        场景转场与段落收束
        概括时空转场的过渡媒介，以及段尾与节末如何收束留白、保留余韵，避免强行议论升华。

        应避免的写法
        只依据原著笔触指出与之相悖的模板化表达，证据不足的特征不猜测。

        若已有仿写模板非空，在其基础上融合补充新的有效特征，保留原有可用规则。
        """

        let existingNote = existingTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        let reserved = TokenEstimator.estimate(system) + TokenEstimator.estimate(existingNote) + 256
        let sampleTokenBudget = max(512, inputBudget - reserved)
        let sampleSlice = buildOverviewSample(from: sampleText, tokenBudget: sampleTokenBudget)

        let user = """
        参考统计：\(fingerprint.summaryLine)

        已有仿写模板（如有则融合去重，无则忽略）：
        \(existingNote.isEmpty ? "无" : existingNote)

        全书样章：
        \(sampleSlice)
        """
        return [.system(system), .user(user)]
    }

    /// 按输入预算做「全书分层信息密度优选采样」：未超预算时保留全文；
    /// 超预算时把全书切分若干连续区间，在每个区间内挑选兼具对白、句式变化与描写密度的代表段落。
    static func buildOverviewSample(from text: String, tokenBudget: Int) -> String {
        guard TokenEstimator.estimate(text) > tokenBudget else { return text }
        let chunks = WorldDigest.chunks(of: text, tokenBudget: 800, overlapTokens: 0)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !chunks.isEmpty else {
            return TokenEstimator.trimTail(text, toTokens: tokenBudget)
        }

        let maxSegments = max(1, min(chunks.count, tokenBudget / 820))
        func styleRichnessScore(_ chunk: String) -> Double {
            let count = max(1, chunk.count)
            let quoteCount = chunk.filter { $0 == "“" || $0 == "「" }.count
            let sentEndCount = chunk.filter { "。！？!?".contains($0) }.count
            let commaCount = chunk.filter { "，；、".contains($0) }.count
            let paraCount = chunk.split(whereSeparator: \.isNewline).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            // 兼顾对白与叙述混合、句式错落度与分段密度，避免挑中纯干瘪流水账或过短碎片。
            let dialogueBonus = quoteCount > 0 ? min(12.0, Double(quoteCount) * 2.5) : 0.0
            let lengthFactor = min(1.0, Double(count) / 350.0)
            let paceScore = Double(sentEndCount) * 1.4 + Double(commaCount) * 0.35 + Double(paraCount) * 0.8
            return (paceScore + dialogueBonus) * lengthFactor
        }

        var selectedIndices: [Int] = []
        if maxSegments == 1 {
            let best = chunks.indices.max(by: { styleRichnessScore(chunks[$0]) < styleRichnessScore(chunks[$1]) }) ?? 0
            selectedIndices = [best]
        } else {
            for bucket in 0..<maxSegments {
                let start = (bucket * chunks.count) / maxSegments
                let end = max(start + 1, ((bucket + 1) * chunks.count) / maxSegments)
                let clampedEnd = min(chunks.count, end)
                if bucket == 0 {
                    // 首区间优先保留开篇定调（前两段内择优），兼顾首章笔触。
                    let headEnd = min(clampedEnd, start + 2)
                    let best = (start..<headEnd).max(by: { styleRichnessScore(chunks[$0]) < styleRichnessScore(chunks[$1]) }) ?? start
                    selectedIndices.append(best)
                } else {
                    let best = (start..<clampedEnd).max(by: { styleRichnessScore(chunks[$0]) < styleRichnessScore(chunks[$1]) }) ?? start
                    if selectedIndices.last != best {
                        selectedIndices.append(best)
                    }
                }
            }
        }

        var parts: [String] = []
        var usedTokens = 0
        for idx in selectedIndices {
            let pct = Int((Double(idx + 1) / Double(chunks.count) * 100.0).rounded())
            let block = "[全书约 \(pct)% 处]\n\(chunks[idx])"
            let cost = TokenEstimator.estimate(block)
            if !parts.isEmpty && usedTokens + cost > tokenBudget { break }
            parts.append(block)
            usedTokens += cost
        }
        return parts.joined(separator: "\n\n")
    }

    /// 为抽取的原著节选反推「情境指令 + 技法重心」，用于写作时构造高浓度 Few-Shot 对话示范。
    static func exemplarPromptsMessages(
        for passages: [String],
        fingerprint: LinguisticFingerprint? = nil
    ) -> [LLMMessage] {
        let statHint = fingerprint.map { "参考语言统计：\($0.summaryLine)\n" } ?? ""
        let system = """
        \(statHint)请为下面每段原著节选各提炼一条「情境指令 + 技法重心」（30至55字），概括该段的情节动作、句式节奏与描写/对白重心，作为后续模仿写作的对照提示。
        严格按输入顺序每段输出一行，不要编号、不要引号、不要 Markdown 或多余解释。
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
            return String(cleaned.prefix(100))
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
                : "写作指令与技法重心：\(rawTitle)"
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
