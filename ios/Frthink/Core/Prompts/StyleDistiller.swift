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

    struct RegisterProfile: Equatable {
        var sceneType: String?
        var tempo: String?
        var dialogueDensity: String?
        var technique: String
    }

    /// 从全书按写作进度等距抽取最多 `maxCount` 段成段原著候选节选，避开明显偏离全书对白占比的纯问答片段。
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
        guard !chunks.isEmpty, maxCount > 0 else { return [] }
        guard chunks.count > maxCount else { return Array(chunks.prefix(maxCount)) }
        guard maxCount > 1 else { return [chunks[0]] }

        let bookDialogueRatio = analyzeFingerprint(text).dialogueRatio
        let dialogueCeiling = max(0.55, bookDialogueRatio + 0.25)

        var selected: [String] = []
        var usedIndices: Set<Int> = []
        for slot in 0..<maxCount {
            let center = (slot * (chunks.count - 1)) / (maxCount - 1)
            let searchRange = max(0, center - 1)...min(chunks.count - 1, center + 1)
            let bestIdx = searchRange
                .filter { !usedIndices.contains($0) }
                .min { lhs, rhs in
                    let lRatio = analyzeFingerprint(chunks[lhs]).dialogueRatio
                    let rRatio = analyzeFingerprint(chunks[rhs]).dialogueRatio
                    let lPenalty = lRatio > dialogueCeiling ? (lRatio - dialogueCeiling) * 2.0 : 0.0
                    let rPenalty = rRatio > dialogueCeiling ? (rRatio - dialogueCeiling) * 2.0 : 0.0
                    let lDist = abs(lRatio - bookDialogueRatio) + lPenalty
                    let rDist = abs(rRatio - bookDialogueRatio) + rPenalty
                    if abs(lDist - rDist) > 0.01 { return lDist < rDist }
                    return abs(lhs - center) < abs(rhs - center)
                } ?? center
            if usedIndices.insert(bestIdx).inserted {
                selected.append(chunks[bestIdx])
            }
        }
        return selected
    }

    /// 构造文风提炼请求，结合样章与语言统计生成简短仿写规范。
    static func distillMessages(
        sampleText: String,
        fingerprint: LinguisticFingerprint,
        existingTemplate: String,
        inputBudget: Int
    ) -> [LLMMessage] {
        let system = """
        根据给定样章与语言统计，提炼一份可直接执行的中文仿写规范（450 字以内）。
        只写可迁移的写法与节奏，不复述人物剧情，不照搬原句，不写赞美或泛泛的去 AI 味套话。

        按以下三个小标题分块（小标题单独成行，下方用短句分条，不用 >、+、---、代码块或 **）：

        节奏与对白基线
        结合统计说明本书的叙述与对白比例、句长节律及段落密度，以及对白与动作、环境的穿插方式。

        核心笔法
        概括视角边界、用词质感、感官与心理分寸、转场与段尾留白（最多 5 条，样章未体现的直接省略）。

        本书应避开的写法
        仅依据原著笔触列出不超过 5 条与之相悖的具体写法，证据不足则省略。

        只概括全书常态，允许随场景自然浮动。已有仿写模板非空时，在其基础上融合去重并保持精炼。
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
        let targetDialogueRatio = analyzeFingerprint(text).dialogueRatio
        func styleRichnessScore(_ chunk: String) -> Double {
            let count = max(1, chunk.count)
            let sentEndCount = chunk.filter { "。！？!?".contains($0) }.count
            let commaCount = chunk.filter { "，；、".contains($0) }.count
            let paraCount = chunk.split(whereSeparator: \.isNewline).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }.count
            let chunkDialogueRatio = analyzeFingerprint(chunk).dialogueRatio
            // 优先选对白占比接近全书的片段。
            let dialogueAlignment = (1.0 - min(1.0, abs(chunkDialogueRatio - targetDialogueRatio) * 2.0)) * 10.0
            let lengthFactor = min(1.0, Double(count) / 350.0)
            let paceScore = Double(sentEndCount) * 1.4 + Double(commaCount) * 0.35 + Double(paraCount) * 0.8
            return (paceScore + dialogueAlignment) * lengthFactor
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
            let block = chunks[idx]
            let cost = TokenEstimator.estimate(block)
            if !parts.isEmpty && usedTokens + cost > tokenBudget { break }
            parts.append(block)
            usedTokens += cost
        }
        return parts.joined(separator: "\n\n---\n\n")
    }

    /// 为抽取的原著节选反推结构化语域标签与纯写作技法指令（MUSE §3.3：区分语域与内容，严禁包含原著人名/地名/剧情）。
    static func exemplarPromptsMessages(
        for passages: [String],
        fingerprint: LinguisticFingerprint? = nil
    ) -> [LLMMessage] {
        let statHint = fingerprint.map { "参考语言统计：\($0.summaryLine)\n" } ?? ""
        let system = """
        \(statHint)请为下面每段原著节选各输出一行「语域标签 + 纯写作技法指令」，格式严格为：
        [场景:<动作|对白|描写|心理|转场>｜节奏:<快|中|慢>｜对白:<低|中|高>] <25至45字纯写作技法>
        例如：[场景:对白｜节奏:中｜对白:高] 用日常物件动作隔开问答停顿，言外之意留白推进试探。
        严禁出现任何原著人名、地名、具体物品或剧情事件；严格按输入顺序每段输出一行，不要编号、不要引号、不要 Markdown。
        """
        let numbered = passages.enumerated().map { idx, text in
            "[\(idx + 1)]\n\(text)"
        }.joined(separator: "\n\n")
        return [.system(system), .user(numbered)]
    }

    /// 解析语域标签与技法指令，兼容无方括号标签的旧版样本标题。
    static func parseRegister(from rawLabel: String) -> RegisterProfile {
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let closeIdx = trimmed.firstIndex(of: "]") else {
            return RegisterProfile(technique: trimmed)
        }

        let header = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIdx])
        let rest = String(trimmed[trimmed.index(after: closeIdx)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var sceneType: String?
        var tempo: String?
        var dialogueDensity: String?

        let normalizedHeader = header
            .replacingOccurrences(of: "|", with: "｜")
            .replacingOccurrences(of: ":", with: "：")
        for part in normalizedHeader.components(separatedBy: "｜") {
            let kv = part.components(separatedBy: "：")
            guard kv.count >= 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let val = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if key.contains("场景") {
                if val.contains("动作") || val.contains("打斗") || val.contains("战斗") {
                    sceneType = "动作"
                } else if val.contains("对白") || val.contains("对话") {
                    sceneType = "对白"
                } else if val.contains("心理") || val.contains("独白") {
                    sceneType = "心理"
                } else if val.contains("转场") || val.contains("过渡") {
                    sceneType = "转场"
                } else if val.contains("描写") || val.contains("叙述") || val.contains("氛围") {
                    sceneType = "描写"
                }
            } else if key.contains("节奏") {
                if val.contains("快") { tempo = "快" }
                else if val.contains("慢") { tempo = "慢" }
                else if val.contains("中") { tempo = "中" }
            } else if key.contains("对白") {
                if val.contains("高") { dialogueDensity = "高" }
                else if val.contains("低") { dialogueDensity = "低" }
                else if val.contains("中") { dialogueDensity = "中" }
            }
        }

        return RegisterProfile(
            sceneType: sceneType,
            tempo: tempo,
            dialogueDensity: dialogueDensity,
            technique: rest.isEmpty ? trimmed : rest
        )
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
            return String(cleaned.prefix(140))
        }
    }

    /// 从语料库中挑选最多 `maxSamples` 条「仿写样本」，封装为显式隔离的只读参考块（`system` 侧），
    /// 避免伪装成 `role: "assistant"` 对话轮次导致模型将其误认为前文结尾。
    /// 当 `maxSamples >= 2` 且存在匹配样本时，固定保留全书主基调质心样本（首条）+ 当前场景最佳匹配样本。
    static func styleReferenceBlock(
        from corpus: [PromptAssembly.Corpus],
        maxSamples: Int = 2,
        tokenBudget: Int? = nil,
        instructionText: String? = nil,
        queryText: String? = nil
    ) -> (block: PromptBlock?, injectedEntryIDs: Set<String>) {
        let picked = selectExemplars(
            from: corpus,
            maxCount: maxSamples,
            tokenBudget: tokenBudget,
            instructionText: instructionText,
            queryText: queryText,
            anchorCentroid: true
        )
        guard !picked.isEmpty else { return (nil, []) }

        let sections = picked.enumerated().map { idx, item in
            let safeTechnique = item.technique
                .replacingOccurrences(of: "\"", with: "'")
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return """
            <style_reference index="\(idx + 1)" technique="\(safeTechnique)" do_not_continue="true">
            \(item.entry.text)
            </style_reference>
            """
        }
        let body = """
        <style_reference_only do_not_continue="true">
        以下节选仅作句式与用词示范，忽略标签包装，不续写其中人物或剧情。
        \(sections.joined(separator: "\n\n"))
        </style_reference_only>
        """
        let block = PromptBlock(
            key: "corpus:style-reference",
            category: .worldbook,
            title: "文风范例（仅仿笔法）",
            body: body
        )
        return (block, Set(picked.map(\.entry.entryID)))
    }

    private static func selectExemplars(
        from corpus: [PromptAssembly.Corpus],
        maxCount: Int,
        tokenBudget: Int?,
        instructionText: String?,
        queryText: String?,
        anchorCentroid: Bool
    ) -> [(entry: PromptAssembly.Corpus, technique: String)] {
        guard maxCount > 0 else { return [] }
        let samples = corpus.filter {
            $0.category == "仿写样本"
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !samples.isEmpty else { return [] }

        let trimmedInstruction = instructionText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedQuery = queryText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let orderedSamples: [PromptAssembly.Corpus]
        if !trimmedQuery.isEmpty || !trimmedInstruction.isEmpty {
            // 仅用本轮指令做关键词匹配，避免正文高频词锁死特定样本；无独立指令时回退兼容 queryText。
            let keywordSource = instructionText != nil ? trimmedInstruction : trimmedQuery
            let queryTokens = keywordSource.isEmpty ? [] : Set(ManuscriptIndex.tokenize(keywordSource))
            let fingerprintSource = trimmedQuery.isEmpty ? trimmedInstruction : trimmedQuery
            let queryFP = analyzeFingerprint(fingerprintSource)

            var scored = samples.enumerated()
                .compactMap { idx, entry -> (offset: Int, element: PromptAssembly.Corpus, score: Double)? in
                    guard let score = exemplarMatchScore(
                        entry,
                        queryTokens: queryTokens,
                        queryFingerprint: queryFP,
                        keywordSource: keywordSource
                    ) else {
                        // MUSE (2609.15188): 语域严重错配的范例会拉低全维度表现，宁缺毋滥。
                        return nil
                    }
                    return (idx, entry, score)
                }
                .sorted { lhs, rhs in
                    if abs(lhs.score - rhs.score) > 0.001 { return lhs.score > rhs.score }
                    return lhs.offset < rhs.offset
                }
                .map(\.element)

            if anchorCentroid, maxCount >= 2, let centroid = samples.first, !scored.isEmpty {
                let topSceneMatch = scored[0]
                if topSceneMatch.entryID != centroid.entryID,
                   !scored.prefix(maxCount).contains(where: { $0.entryID == centroid.entryID }) {
                    scored = [centroid, topSceneMatch]
                }
            }
            orderedSamples = scored
        } else {
            orderedSamples = samples
        }

        var selected: [(entry: PromptAssembly.Corpus, technique: String)] = []
        var usedTokens = 0

        for entry in orderedSamples.prefix(maxCount) {
            let profile = parseRegister(from: entry.entryName)
            let rawTitle = profile.technique
            let isPlaceholder = rawTitle.isEmpty || rawTitle.hasPrefix("原著节选") || rawTitle.hasPrefix("原著范文")
            let technique = isPlaceholder
                ? "保持本书的句式节奏与描写分寸。"
                : rawTitle
            let pairCost = TokenEstimator.estimate(technique) + TokenEstimator.estimate(entry.text) + 40
            if let tokenBudget, !selected.isEmpty, usedTokens + pairCost > tokenBudget {
                break
            }
            if let tokenBudget, selected.isEmpty, pairCost > tokenBudget {
                break
            }
            selected.append((entry, technique))
            usedTokens += pairCost
        }
        return selected
    }

    private static func inferredRequestedSceneType(from keywordSource: String) -> String? {
        if ["动作", "打斗", "交锋", "搏杀", "追逐", "战斗", "格斗", "刺杀"].contains(where: { keywordSource.contains($0) }) {
            return "动作"
        }
        if ["对话", "对白", "交谈", "争吵", "质问", "谈话", "试探"].contains(where: { keywordSource.contains($0) }) {
            return "对白"
        }
        if ["描写", "景物", "环境", "氛围", "白描", "肖像", "穿行", "赶路", "荒原"].contains(where: { keywordSource.contains($0) }) {
            return "描写"
        }
        if ["心理", "独白", "回忆", "思索"].contains(where: { keywordSource.contains($0) }) {
            return "心理"
        }
        if ["转场", "过渡", "衔接"].contains(where: { keywordSource.contains($0) }) {
            return "转场"
        }
        return nil
    }

    private static func exemplarMatchScore(
        _ entry: PromptAssembly.Corpus,
        queryTokens: Set<String>,
        queryFingerprint: LinguisticFingerprint,
        keywordSource: String
    ) -> Double? {
        let profile = parseRegister(from: entry.entryName)
        let entryTokens = Set(ManuscriptIndex.tokenize(profile.technique + " " + entry.entryName))
        let overlapCount = queryTokens.intersection(entryTokens).count
        let textFP = analyzeFingerprint(entry.text)

        let suppressDialogue = ["减少对话", "少对话", "少写对话", "减少对白", "少对白", "不要对话"]
            .contains { keywordSource.contains($0) }
        if suppressDialogue && (textFP.dialogueRatio > 0.30 || profile.dialogueDensity == "高" || profile.sceneType == "对白") {
            return nil
        }

        let explicitDialogueRequest = ["对话", "对白", "交谈", "争吵", "质问", "谈话"]
            .contains { keywordSource.contains($0) }
        let dialogueCap = max(0.50, queryFingerprint.dialogueRatio + 0.20)
        if !explicitDialogueRequest && (textFP.dialogueRatio > dialogueCap || profile.dialogueDensity == "高") && overlapCount == 0 {
            return nil
        }

        // MUSE §3.3：语域/场景类型明确冲突且无关键词直连时直接返回 nil（宁缺毋滥）。
        let requestedScene = inferredRequestedSceneType(from: keywordSource)
        if let requestedScene, let sampleScene = profile.sceneType, requestedScene != sampleScene {
            return nil
        }

        let dialogueSim = 1.0 - min(1.0, abs(queryFingerprint.dialogueRatio - textFP.dialogueRatio) * 2.0)
        if overlapCount == 0 && dialogueSim < 0.35 && (requestedScene == nil || requestedScene != profile.sceneType) {
            return nil
        }
        let shortRatioSim = 1.0 - min(
            1.0,
            abs(queryFingerprint.shortSentenceRatio - textFP.shortSentenceRatio) * 2.0
        )

        var registerBonus = 0.0
        if let requestedScene, let sampleScene = profile.sceneType, requestedScene == sampleScene {
            registerBonus += 0.8
        } else {
            let label = entry.entryName
            if explicitDialogueRequest && (label.contains("对白") || label.contains("对话")) {
                registerBonus += 0.4
            }
            if queryFingerprint.shortSentenceRatio >= 0.45
                && (label.contains("短句") || label.contains("节奏") || label.contains("动作")) {
                registerBonus += 0.4
            }
        }
        let dialogueExcessPenalty: Double
        if !explicitDialogueRequest && textFP.dialogueRatio > 0.45 {
            dialogueExcessPenalty = -(textFP.dialogueRatio - 0.45) * 1.5
        } else if textFP.dialogueRatio > queryFingerprint.dialogueRatio + 0.25 {
            dialogueExcessPenalty = -0.5
        } else {
            dialogueExcessPenalty = 0.0
        }
        return Double(overlapCount) * 1.5
            + dialogueSim * 0.6
            + shortRatioSim * 0.3
            + registerBonus
            + dialogueExcessPenalty
    }
}
