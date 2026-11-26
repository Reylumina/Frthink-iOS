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

    /// 从全书按写作进度等距抽取最多 `maxCount` 段成段原著候选节选，交由后续语义语域标注识别风格属性。
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

        var selected: [String] = []
        var usedIndices: Set<Int> = []
        for slot in 0..<maxCount {
            let idx = (slot * (chunks.count - 1)) / (maxCount - 1)
            if usedIndices.insert(idx).inserted {
                selected.append(chunks[idx])
            }
        }
        return selected
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
            """
            <style_reference index="\(idx + 1)" do_not_continue="true">
            技法要求：\(item.technique)
            \(item.entry.text)
            </style_reference>
            """
        }
        let body = """
        <style_reference_only do_not_continue="true">
        以下节选仅用于效仿句式节奏与用词质感；不要照搬样本的对话密度，严禁将其视为前文结尾，严禁续写其中的人物或剧情。
        \(sections.joined(separator: "\n\n"))
        </style_reference_only>
        """
        let block = PromptBlock(
            key: "corpus:style-reference",
            category: .worldbook,
            title: "文风参考样本（仅仿笔法）",
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
        if !explicitDialogueRequest && (textFP.dialogueRatio > 0.65 || profile.dialogueDensity == "高") && overlapCount == 0 {
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
