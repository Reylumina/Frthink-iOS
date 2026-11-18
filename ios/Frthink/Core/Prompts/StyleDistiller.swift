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

    /// 基于「5 维文体风格向量 + MMR 最大边际相关性」从全书抽取最多 5 段多样化原著节选（每段约 400 token）。
    /// 先选最贴近全书风格质心的代表段，再依次选出既贴合本书基调又与已选样本在句法/节奏/对白上尽量正交的段落。
    static func selectExemplarPassages(from text: String, maxCount: Int = 5) -> [String] {
        let sentenceEnds = CharacterSet(charactersIn: "。！？!?")
        func isQualified(_ chunk: String) -> Bool {
            guard chunk.count >= 180 else { return false }
            let endCount = chunk.unicodeScalars.filter { sentenceEnds.contains($0) }.count
            return endCount >= 3
        }

        let chunks = WorldDigest.chunks(of: text, tokenBudget: 400, overlapTokens: 0)
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isQualified)
        guard !chunks.isEmpty else { return [] }
        guard chunks.count > maxCount else { return Array(chunks.prefix(maxCount)) }

        func styleVector(_ chunk: String) -> [Double] {
            let totalChars = max(1, chunk.count)
            var inQuote = false
            var dialogueChars = 0
            var clausePuncts = 0
            for ch in chunk {
                if ch == "“" || ch == "「" {
                    inQuote = true
                } else if ch == "”" || ch == "」" {
                    inQuote = false
                } else if inQuote {
                    dialogueChars += 1
                }
                if "，；、".contains(ch) {
                    clausePuncts += 1
                }
            }

            let paragraphs = chunk.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let sentences = chunk.components(separatedBy: sentenceEnds)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            let sentLengths = sentences.map { Double($0.count) }
            let meanLen = sentLengths.isEmpty
                ? Double(totalChars)
                : sentLengths.reduce(0, +) / Double(sentLengths.count)
            let variance = sentLengths.isEmpty
                ? 0.0
                : sentLengths.reduce(0.0) { $0 + ($1 - meanLen) * ($1 - meanLen) } / Double(sentLengths.count)
            let stdDev = variance.squareRoot()

            let vMeanLen = min(1.0, meanLen / 45.0)
            let vBurstiness = min(1.0, stdDev / 20.0)
            let vCadence = min(1.0, (Double(clausePuncts) / Double(totalChars)) / 0.15)
            let vParaDensity = min(1.0, (Double(paragraphs.count) / (Double(totalChars) / 100.0)) / 2.5)
            let vDialogue = min(1.0, Double(dialogueChars) / Double(totalChars))
            return [vMeanLen, vBurstiness, vCadence, vParaDensity, vDialogue]
        }

        func distance(_ a: [Double], _ b: [Double]) -> Double {
            var sum = 0.0
            for i in 0..<min(a.count, b.count) {
                let d = a[i] - b[i]
                sum += d * d
            }
            return (sum / Double(max(1, a.count))).squareRoot()
        }

        let vectors = chunks.map(styleVector)
        let dims = 5
        var centroid = Array(repeating: 0.0, count: dims)
        for v in vectors {
            for i in 0..<dims { centroid[i] += v[i] }
        }
        for i in 0..<dims { centroid[i] /= Double(vectors.count) }

        var selectedIndices: [Int] = []
        var used: Set<Int> = []

        // 第 1 段：最贴近全书风格质心的饱满代表段，锚定主基调。
        if let first = chunks.indices.max(by: { a, b in
            let sa = (1.0 - distance(vectors[a], centroid)) * min(1.0, Double(chunks[a].count) / 260.0)
            let sb = (1.0 - distance(vectors[b], centroid)) * min(1.0, Double(chunks[b].count) / 260.0)
            return sa < sb
        }) {
            selectedIndices.append(first)
            used.insert(first)
        }

        // 第 2..maxCount 段：MMR（兼顾贴合主基调 + 与已选样本在 5 维向量上最大差异 + 位置分散）。
        while selectedIndices.count < maxCount {
            var bestIdx: Int?
            var bestScore = -Double.infinity
            for idx in chunks.indices where !used.contains(idx) {
                let relevance = 1.0 - distance(vectors[idx], centroid)
                let minStyleGap = selectedIndices.map { distance(vectors[idx], vectors[$0]) }.min() ?? 0.0
                let minPosGap = selectedIndices.map { abs(idx - $0) }.min() ?? chunks.count
                let posBonus = minPosGap >= 2 ? 0.05 : -0.15
                let lenFactor = min(1.0, Double(chunks[idx].count) / 240.0)
                let score = (0.35 * relevance + 0.65 * minStyleGap + posBonus) * lenFactor
                if score > bestScore {
                    bestScore = score
                    bestIdx = idx
                }
            }
            guard let chosen = bestIdx else { break }
            selectedIndices.append(chosen)
            used.insert(chosen)
        }

        return selectedIndices.map { chunks[$0] }
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

    /// 为抽取的原著节选反推纯写作技法指令（严禁包含原著人名、地名与剧情，避免写作时带偏正文衔接）。
    static func exemplarPromptsMessages(
        for passages: [String],
        fingerprint: LinguisticFingerprint? = nil
    ) -> [LLMMessage] {
        let statHint = fingerprint.map { "参考语言统计：\($0.summaryLine)\n" } ?? ""
        let system = """
        \(statHint)请为下面每段原著节选各提炼一条纯写作技法指令（25至45字），只概括该段的句式节奏、描写分寸、视角落点或对白留白技巧。
        严禁出现任何原著人名、地名、具体物品或剧情事件；严格按输入顺序每段输出一行，不要编号、不要引号、不要 Markdown。
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

    /// 从语料库中挑选最多 `maxPairs` 条「仿写样本」，构造固定前置对话示范（明确标注仅参考笔法，不带偏当前正文剧情）。
    static func fewShotDialoguePairs(
        from corpus: [PromptAssembly.Corpus],
        maxPairs: Int = 5,
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
            let technique = isPlaceholder
                ? "保持本书的句式节奏、描写分寸与对白留白。"
                : rawTitle
            let prompt = "【文风示范（仅效仿笔法与语感，勿沿用其中人物与剧情）】\n技法要求：\(technique)"
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
