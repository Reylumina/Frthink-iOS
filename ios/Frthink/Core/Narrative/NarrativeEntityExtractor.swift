import Foundation

/// 档案提取器：从正文末尾或指定片区增量提取、更新四类档案（人物、地点、物件、世界观），
/// 与既有实体按 ID 或名称自动对齐合并，保留作者手工调整与冲突历史。
enum NarrativeEntityExtractor {

    static func buildExtractionPayload(
        manuscriptTail: String,
        leadingContext: String = "",
        existingPages: [EntityPage],
        existingFactsByEntity: [String: [WorldFactEvent]] = [:],
        targetKind: EntityKind? = nil,
        includeFacts: Bool = false
    ) -> (messages: [LLMMessage], mapping: NarrativeEntityResolver.ExtractionIDMapping) {
        let kindScopeInstruction: String
        if let targetKind {
            kindScopeInstruction = "本次只需重点提取并完善分类为 `\(targetKind.rawValue)`（\(targetKind.displayName)）的条目。"
        } else {
            kindScopeInstruction = "请区分正文中活跃的四类档案：`character`（人物）、`location`（地点）、`artifact`（物件）与 `lore`（世界观）。"
        }

        let scanText = leadingContext.isEmpty ? manuscriptTail : (leadingContext + "\n" + manuscriptTail)
        let relevantPages = prioritizeExistingPages(
            existingPages.filter { targetKind == nil || $0.kind == targetKind },
            in: scanText,
            limit: 20
        )
        let relevantFacts = collectRelevantFacts(
            for: relevantPages,
            existingFactsByEntity: existingFactsByEntity,
            perEntityLimit: 8
        )
        let mapping = NarrativeEntityResolver.ExtractionIDMapping.build(
            entities: relevantPages,
            facts: relevantFacts
        )

        let schemaLine: String
        let factsInstruction: String
        if includeFacts {
            schemaLine = #"{"entities":[{"id":"","changed":true,"kind":"character|location|artifact|lore","name":"","aliases":[""],"trigger_keywords":[""],"activation_mode":"mentioned|always","identity":"","summary":"","voice_profile":"","hard_boundaries":[""]}],"facts":[{"entity_id":"","attribute":"","value":"","quote":"","retracted":false}],"negated_fact_ids":[""]}"#
            factsInstruction = """
            7. `facts` 专门记录「本段待提取正文」里明确发生的**持久化状态变化**，必须严格使用以下英文属性键名：
               - `character`：`location`（当前位置）、`possession` 或 `possession:<物件>`（持有物）、`condition`（伤势/身体/情绪状态）、`goal`（当前目标）、`status`（当前处境/局势）、`relation:<对象名>`（对某人的关系态度）；
               - `location`：`layout`、`atmosphere`、`access`、`status`；
               - `artifact`：`owner`、`location`、`capability`、`cost`、`status`；
               - `lore`：`rule`、`faction`、`history`、`exception`、`status`。
               严禁把推门、倒茶、质问、转身等**瞬时动作（action）**、修辞比喻或单句试探话术写入 `facts`（瞬时动作记入事件线）。
            8. `facts.entity_id` 必须填现有档案短编号（如 `"E1"`）或本轮 `entities` 中新建条目的 `"NEW:实体名"`，并附上原文逐字短引用 `quote`；没有精确状态变化时 `facts` 返回 `[]`。
            9. 若本段正文明确推翻、完成或使下方「当前近况」里的某条记录过时失效（如已离开旧地点、旧目标已完成、物件已交出），请将对应短编号填入 `negated_fact_ids`（如 `["F1"]`）。
            """
        } else {
            schemaLine = #"{"entities":[{"id":"","changed":true,"kind":"character|location|artifact|lore","name":"","aliases":[""],"trigger_keywords":[""],"activation_mode":"mentioned|always","identity":"","summary":"","voice_profile":"","hard_boundaries":[""]}]}"#
            factsInstruction = ""
        }

        let systemPrompt = """
        你是小说设定整理编辑，负责从正文中提取并更新四类档案\(includeFacts ? "及精确动态事实" : "")。
        \(kindScopeInstruction)
        请只返回一个 JSON 对象，不要附加额外说明：
        \(schemaLine)
        分类与字段分工说明（各字段不得互相重复）：
        - `character`（人物）：有自主行动或视角的角色。`identity` 写核心身份、职务与立场；`summary` 只写**稳定性格、价值观与长期背景**（**不要写入当前位置、瞬时动作或单场处境**，瞬时状态留给 `facts`）；`voice_profile` 只写说话口吻与用词习惯；`hard_boundaries` 写人物底线与不可违背的原则。
        - `location`（地点）：具体的物理场所。`identity` 写位置与所属区域；`summary` 写相对稳定的空间布局与环境特色；`hard_boundaries` 写地形或准入限制；`voice_profile` 留空。
        - `artifact`（物件）：可持有或使用的道具、信物与器物。`identity` 写核心归属或来历；`summary` 写外观特征与核心用途；`hard_boundaries` 写触发条件、代价或损耗限制；`voice_profile` 留空。
        - `lore`（世界观）：世界内的力量体系、宗门势力、社会制度、历史事件或自然法则。不要把戏外作者的写作要求（如视角限制、行文节奏、字数要求、去 AI 味规范）归入 `lore`。`identity` 写所属类别；`summary` 写具体机制与词条内容；`hard_boundaries` 写世界内不可违背的规则与例外，`trigger_keywords` 填正文中提及即可带入该词条的关键词（不要重复填写名称本身）；只有作用于全局的基础铁律才将 `activation_mode` 设为 `"always"`，其余保持 `"mentioned"`。
        整理要求：
        1. 若条目已在下方「现有档案」中出现，请在 `id` 字段填写对应短编号（如 `"E1"`）。若其档案无需更改（或仅触发动态 `facts` 更新），请将 `"changed"` 设为 `false` 或省略；只有发生**持久性设定变化**或明确新信息时，才将 `"changed"` 设为 `true`，并对需要变更的字段输出**融合旧信息后的完整最新快照**，未变化的字段直接留空 `""`（严禁重复抄写旧文或同义叠加）。
        2. 严禁跨分类复用同名档案（例如同名地点与势力必须分开建档）。
        3. 禁止把无归属泛称或临时职务称谓（如「师父」「掌柜」「小二」「侍卫」「黑衣人」「少年」「老者」「路人」）单独建档或写入任何实体的 `aliases`。
        4. 新出现的重要角色、地点、物件或世界观条目可新建档案（`id` 留空，`"changed": true`），内容必须依据「本段待提取正文」，不得把只读前情里已有但本段未再提及的对象重复新建，也不得臆造。
        5. `summary` 控制在一至三句凝练概括（不超过 180 字）；非 `character` 分类禁止填写 `voice_profile`。
        6. 若正文中没有新增或变化的条目，对应数组返回 `[]`。
        \(factsInstruction)
        """

        var userLines: [String] = []
        if !relevantPages.isEmpty {
            userLines.append("【现有档案（对照完整现状决定是否需要变更，引用请填短编号 E1/F1…）】")
            for page in relevantPages {
                userLines.append(
                    contentsOf: formatExistingPagePromptLines(
                        page: page,
                        facts: existingFactsByEntity[page.id] ?? [],
                        mapping: mapping
                    )
                )
            }
        }
        let cleanLeading = leadingContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanLeading.isEmpty {
            userLines.append("【前情参考（只读，仅用于确认人称指代与承接上文，禁止重复抽取）】")
            userLines.append(cleanLeading)
            userLines.append("【本段待提取正文】")
            userLines.append(manuscriptTail)
        } else {
            userLines.append("【正文参考片段】")
            userLines.append(manuscriptTail)
        }

        return (
            messages: [
                .system(systemPrompt),
                .user(userLines.joined(separator: "\n")),
            ],
            mapping: mapping
        )
    }

    static func parseEntitiesAndFacts(
        from raw: String,
        excerpt: String,
        nodeID: String,
        pageIndex: Int = 0,
        baseUTF16Offset: Int = 0,
        existingPages: [EntityPage],
        existingFactsByEntity: [String: [WorldFactEvent]] = [:],
        targetKind: EntityKind? = nil,
        idMapping: NarrativeEntityResolver.ExtractionIDMapping? = nil,
        now: Date = Date()
    ) throws -> (
        upserts: [EntityPage],
        factEvents: [WorldFactEvent],
        added: Int,
        updated: Int,
        ungroundedFactCount: Int
    ) {
        guard let jsonString = NarrativeJSONScanner.extractFirstJSONObject(from: raw) else {
            throw NarrativeDeltaParseError.noJSON
        }
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NarrativeDeltaParseError.invalidStructure("无法解析为设定 JSON 字典")
        }

        let entityResult = try parseEntities(
            from: raw,
            existingPages: existingPages,
            targetKind: targetKind,
            idMapping: idMapping,
            groundingText: excerpt,
            now: now
        )

        var mergedCatalog = Dictionary(uniqueKeysWithValues: existingPages.map { ($0.id, $0) })
        for upsert in entityResult.upserts {
            mergedCatalog[upsert.id] = upsert
        }
        let lookupIndex = NarrativeEntityResolver.EntityLookupIndex(pages: Array(mergedCatalog.values))
        var newEntityRefs: [String: EntityPage] = [:]
        for page in entityResult.upserts {
            let nameKey = NarrativeEntityResolver.normalizeName(page.name)
            if !nameKey.isEmpty, newEntityRefs[nameKey] == nil {
                newEntityRefs[nameKey] = page
            }
            for alias in page.aliases where !NarrativeEntityResolver.isGenericRoleTerm(alias) {
                let aliasKey = NarrativeEntityResolver.normalizeName(alias)
                if !aliasKey.isEmpty, newEntityRefs[aliasKey] == nil {
                    newEntityRefs[aliasKey] = page
                }
            }
        }
        let shouldResolve = !mergedCatalog.isEmpty || !(idMapping?.isEmpty ?? true)
        var ungroundedFactCount = 0
        var factEvents = NarrativeDeltaExtractor.parseFactsArray(
            from: object,
            excerpt: excerpt,
            nodeID: nodeID,
            pageIndex: pageIndex,
            baseUTF16Offset: baseUTF16Offset,
            entityLookup: lookupIndex,
            idMapping: idMapping,
            newEntityRefs: newEntityRefs,
            shouldResolveEntities: shouldResolve,
            now: now,
            ungroundedCount: &ungroundedFactCount
        )
        let negatedEvents = parseNegatedFacts(
            from: object,
            nodeID: nodeID,
            existingFactsByEntity: existingFactsByEntity,
            idMapping: idMapping,
            now: now
        )
        factEvents.append(contentsOf: negatedEvents)

        return (
            upserts: entityResult.upserts,
            factEvents: factEvents,
            added: entityResult.added,
            updated: entityResult.updated,
            ungroundedFactCount: ungroundedFactCount
        )
    }

    static func parseEntities(
        from raw: String,
        existingPages: [EntityPage],
        targetKind: EntityKind? = nil,
        idMapping: NarrativeEntityResolver.ExtractionIDMapping? = nil,
        groundingText: String? = nil,
        now: Date = Date()
    ) throws -> (upserts: [EntityPage], added: Int, updated: Int) {
        guard let jsonString = NarrativeJSONScanner.extractFirstJSONObject(from: raw) else {
            throw NarrativeDeltaParseError.noJSON
        }
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NarrativeDeltaParseError.invalidStructure("无法解析为设定 JSON 字典")
        }

        guard let rawItems = (object["entities"] as? [[String: Any]])
                ?? (object["items"] as? [[String: Any]])
                ?? (object["pages"] as? [[String: Any]]) else {
            throw NarrativeDeltaParseError.invalidStructure("缺少 entities 数组字段")
        }

        let originalByID = Dictionary(uniqueKeysWithValues: existingPages.map { ($0.id, $0) })
        var lookupIndex = NarrativeEntityResolver.EntityLookupIndex(pages: existingPages)
        var usedIDs = Set(originalByID.keys)
        var upsertsByID: [String: EntityPage] = [:]
        var orderedUpsertIDs: [String] = []
        var addedIDs = Set<String>()
        var updatedIDs = Set<String>()

        for item in rawItems {
            let name = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["name", "title"])
            guard !name.isEmpty else { continue }

            let explicitChanged = parseBoolFlag(item["changed"])
            let rawKind = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["kind", "type", "category"])
            let resolvedKind = targetKind ?? parseKind(rawKind) ?? .character
            let rawID = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["id", "entity_id"])
            let incomingAliases = NarrativeEntityResolver.sanitizedAliases(
                parseStringArray(item["aliases"]),
                canonicalName: name
            )
            let incomingTriggerKeywords = parseStringArray(
                item["trigger_keywords"] ?? item["triggerKeywords"] ?? item["keywords"]
            )
            let rawActivation = NarrativeJSONScanner.firstNonEmptyString(
                item,
                keys: ["activation_mode", "activationMode"]
            ).lowercased()
            let parsedActivation: EntityActivationMode =
                rawActivation == "always" ? .always : .mentioned
            let incomingIdentity = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["identity", "role"])
            let incomingSummary = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["summary", "description", "brief"])
            let incomingVoice = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["voice_profile", "voiceProfile", "voice"])
            let incomingBoundaries = parseStringArray(item["hard_boundaries"] ?? item["hardBoundaries"] ?? item["boundaries"])

            let resolution = lookupIndex.resolve(
                rawID: rawID,
                name: name,
                aliases: incomingAliases,
                expectedKind: resolvedKind,
                mapping: idMapping
            )

            switch resolution {
            case .matched(let matchedPage):
                var merged = upsertsByID[matchedPage.id] ?? matchedPage
                let nameKey = NarrativeEntityResolver.normalizeName(name)
                let baseNameKey = NarrativeEntityResolver.normalizeName(merged.name)
                let extraNames = (nameKey != baseNameKey && !NarrativeEntityResolver.isGenericRoleTerm(name))
                    ? [name]
                    : []
                let nextAliases = NarrativeEntityResolver.sanitizedAliases(
                    merged.aliases + incomingAliases + extraNames,
                    canonicalName: merged.name
                )
                let nextKeywords = NarrativeEntityResolver.deduplicatedNonEmptyStrings(
                    merged.triggerKeywords + incomingTriggerKeywords
                )
                if explicitChanged == false
                    && nextAliases == merged.aliases
                    && nextKeywords == merged.triggerKeywords {
                    continue
                }

                merged.aliases = nextAliases
                merged.triggerKeywords = nextKeywords
                if merged.kind == .lore, parsedActivation == .always {
                    merged.activationMode = .always
                }
                if !incomingIdentity.isEmpty {
                    merged.identity = mergeFieldText(
                        existing: merged.identity,
                        incoming: incomingIdentity,
                        explicitChanged: explicitChanged,
                        maxLength: 160,
                        referenceTexts: []
                    )
                }
                if !incomingSummary.isEmpty {
                    let mergedSummary = mergeFieldText(
                        existing: merged.summary,
                        incoming: incomingSummary,
                        explicitChanged: explicitChanged,
                        maxLength: 240,
                        referenceTexts: [merged.identity]
                    )
                    if !mergedSummary.isEmpty {
                        merged.summary = mergedSummary
                    }
                }
                if !incomingVoice.isEmpty, merged.kind == .character {
                    let mergedVoice = mergeFieldText(
                        existing: merged.voiceProfile,
                        incoming: incomingVoice,
                        explicitChanged: explicitChanged,
                        maxLength: 140,
                        referenceTexts: [merged.identity, merged.summary]
                    )
                    if !mergedVoice.isEmpty {
                        merged.voiceProfile = mergedVoice
                    }
                }
                if !incomingBoundaries.isEmpty {
                    merged.hardBoundaries = NarrativeEntityResolver.deduplicatedNonEmptyStrings(
                        merged.hardBoundaries + incomingBoundaries
                    )
                }

                if let baseline = originalByID[merged.id] {
                    let contentChanged = merged.aliases != baseline.aliases
                        || merged.triggerKeywords != baseline.triggerKeywords
                        || merged.activationMode != baseline.activationMode
                        || merged.identity != baseline.identity
                        || merged.summary != baseline.summary
                        || merged.voiceProfile != baseline.voiceProfile
                        || merged.hardBoundaries != baseline.hardBoundaries
                    guard contentChanged else { continue }
                    merged.updatedAt = now
                    updatedIDs.insert(merged.id)
                } else {
                    merged.updatedAt = now
                }

                lookupIndex.register(merged)
                if upsertsByID[merged.id] == nil {
                    orderedUpsertIDs.append(merged.id)
                }
                upsertsByID[merged.id] = merged

            case .ambiguous:
                continue

            case .notFound:
                guard !NarrativeEntityResolver.isGenericRoleTerm(name) else { continue }
                if let cleanGrounding = groundingText?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !cleanGrounding.isEmpty,
                   !isEntityMentionedInGrounding(name: name, aliases: incomingAliases, text: cleanGrounding) {
                    continue
                }

                var candidateID = rawID
                if candidateID.isEmpty
                    || idMapping?.entityShortToReal[candidateID.uppercased()] != nil
                    || !usedIDs.insert(candidateID).inserted {
                    var slugIndex = 0
                    repeat {
                        let seed = slugIndex == 0
                            ? "\(resolvedKind.rawValue):\(name)"
                            : "\(resolvedKind.rawValue):\(name):\(slugIndex)"
                        candidateID = "\(resolvedKind.rawValue)_\(SummaryKey.sha256Hex(seed).prefix(12))"
                        slugIndex += 1
                    } while !usedIDs.insert(candidateID).inserted
                }

                let cleanIdentity = NarrativeEntityResolver.trimToSentenceBoundary(
                    NarrativeEntityResolver.deduplicateCrossFieldText(primary: incomingIdentity, referenceTexts: []),
                    maxLength: 160
                )
                let dedupedSummary = NarrativeEntityResolver.deduplicateCrossFieldText(
                    primary: incomingSummary,
                    referenceTexts: [cleanIdentity]
                )
                let cleanSummary = NarrativeEntityResolver.trimToSentenceBoundary(
                    dedupedSummary.isEmpty ? incomingSummary : dedupedSummary,
                    maxLength: 240
                )
                let rawVoice = resolvedKind == .character ? incomingVoice : ""
                let dedupedVoice = rawVoice.isEmpty
                    ? ""
                    : NarrativeEntityResolver.deduplicateCrossFieldText(
                        primary: rawVoice,
                        referenceTexts: [cleanIdentity, cleanSummary]
                    )
                let cleanVoice = NarrativeEntityResolver.trimToSentenceBoundary(dedupedVoice, maxLength: 140)

                let created = EntityPage(
                    id: candidateID,
                    kind: resolvedKind,
                    name: name,
                    aliases: incomingAliases,
                    triggerKeywords: deduplicatedStrings(incomingTriggerKeywords),
                    activationMode: resolvedKind == .lore ? parsedActivation : .mentioned,
                    summary: cleanSummary,
                    identity: cleanIdentity,
                    voiceProfile: cleanVoice,
                    hardBoundaries: deduplicatedStrings(incomingBoundaries),
                    updatedAt: now
                )
                lookupIndex.register(created)
                orderedUpsertIDs.append(candidateID)
                upsertsByID[candidateID] = created
                addedIDs.insert(candidateID)
            }
        }
        let upserts = orderedUpsertIDs.compactMap { upsertsByID[$0] }
        return (upserts, addedIDs.count, updatedIDs.count)
    }

    // MARK: - 终态实体整理 Pass（仅清理档案与近况，绝不触碰剧情线）

    /// 筛选全书同步后需要执行终态整理的实体：多轮反复修改、活跃近况膨胀、摘要过长或存在跨字段重复。
    static func entitiesNeedingConsolidation(
        pages: [EntityPage],
        factsByEntity: [String: [WorldFactEvent]],
        touchCounts: [String: Int],
        limit: Int = 12
    ) -> [EntityPage] {
        guard !pages.isEmpty, limit > 0 else { return [] }
        return pages
            .filter { page in
                let touches = touchCounts[page.id, default: 0]
                let factCount = factsByEntity[page.id]?.count ?? 0
                return touches >= 2
                    || factCount >= 4
                    || page.summary.count > 220
                    || NarrativeEntityResolver.hasDuplicateSentencesAcrossFields(in: page)
            }
            .sorted { lhs, rhs in
                let lhsScore = touchCounts[lhs.id, default: 0] * 2 + (factsByEntity[lhs.id]?.count ?? 0)
                let rhsScore = touchCounts[rhs.id, default: 0] * 2 + (factsByEntity[rhs.id]?.count ?? 0)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
            .prefix(limit)
            .map { $0 }
    }

    static func buildConsolidationPayload(
        pages: [EntityPage],
        factsByEntity: [String: [WorldFactEvent]]
    ) -> (messages: [LLMMessage], mapping: NarrativeEntityResolver.ExtractionIDMapping) {
        let relevantFacts = collectRelevantFacts(
            for: pages,
            existingFactsByEntity: factsByEntity,
            perEntityLimit: 16
        )
        let mapping = NarrativeEntityResolver.ExtractionIDMapping.build(
            entities: pages,
            facts: relevantFacts
        )

        let systemPrompt = """
        你是谨慎的小说设定整理编辑，对同一轮同步后的实体档案与活跃近况做最终去重整理。
        请只返回一个严格 JSON 对象（不要输出额外说明）：
        {"entities":[{"id":"","changed":true,"identity":"","summary":"","voice_profile":"","hard_boundaries":[""]}],"negated_fact_ids":[""]}
        硬性规范：
        1. 严禁虚构正文中不存在的新设定；必须使用现有短编号（如 `"E1"`、`"F1"`）。
        2. 清除 `identity`、`summary`、`voice_profile` 之间的重复表达与同义复述，修整因拼接导致的断章取义残句；若某实体本就干净无需调整，将该条 `"changed"` 设为 `false` 或省略。
        3. `character.summary` 仅保留稳定性格、价值观与长期背景，将过时的位置/目标/瞬时动作从文本中剔除；各字段若本次无需改动可输出当前干净版本或留空保留原值（但要确保整份字段不互抄）。
        4. 检查每个实体下方带编号的「当前近况」（`F1/F2…`）：把已被后续事件推翻、早已完成、相互矛盾的旧近况，或误记为近况的瞬时动作编号填入 `negated_fact_ids`（例如 `["F1","F3"]`）。
        5. 只处理档案与近况，不要生成或改动剧情线事件。
        """

        var userLines = ["【待整理实体与当前近况（引用请填短编号 E1/F1…）】"]
        for page in pages {
            userLines.append(
                contentsOf: formatExistingPagePromptLines(
                    page: page,
                    facts: factsByEntity[page.id] ?? [],
                    mapping: mapping,
                    factLimit: 16
                )
            )
        }

        return (
            messages: [
                .system(systemPrompt),
                .user(userLines.joined(separator: "\n")),
            ],
            mapping: mapping
        )
    }

    static func parseConsolidationResult(
        from raw: String,
        targetPages: [EntityPage],
        factsByEntity: [String: [WorldFactEvent]],
        idMapping: NarrativeEntityResolver.ExtractionIDMapping,
        nodeID: String,
        now: Date = Date()
    ) throws -> PlotNodeDelta {
        guard let jsonString = NarrativeJSONScanner.extractFirstJSONObject(from: raw) else {
            throw NarrativeDeltaParseError.noJSON
        }
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NarrativeDeltaParseError.invalidStructure("无法解析为整理结果 JSON 字典")
        }

        let targetByID = Dictionary(uniqueKeysWithValues: targetPages.map { ($0.id, $0) })
        let rawEntities = (object["entities"] as? [[String: Any]]) ?? []
        var replacements: [EntityPage] = []

        for item in rawEntities {
            if parseBoolFlag(item["changed"]) == false {
                continue
            }
            let rawID = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["id", "entity_id"])
            guard let resolvedID = idMapping.entityShortToReal[rawID.uppercased()]
                    ?? idMapping.entityShortToReal[rawID]
                    ?? (targetByID[rawID] != nil ? rawID : nil),
                  let baseline = targetByID[resolvedID] else {
                continue
            }

            let rawIdentity = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["identity", "role"])
            let rawSummary = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["summary", "description", "brief"])
            let rawVoice = NarrativeJSONScanner.firstNonEmptyString(item, keys: ["voice_profile", "voiceProfile", "voice"])
            let rawBoundaries = parseStringArray(item["hard_boundaries"] ?? item["hardBoundaries"] ?? item["boundaries"])

            var updated = baseline
            let candidateIdentity = rawIdentity.isEmpty ? baseline.identity : rawIdentity
            updated.identity = NarrativeEntityResolver.trimToSentenceBoundary(
                NarrativeEntityResolver.deduplicateCrossFieldText(primary: candidateIdentity, referenceTexts: []),
                maxLength: 160
            )
            let candidateSummary = rawSummary.isEmpty ? baseline.summary : rawSummary
            let dedupedSummary = NarrativeEntityResolver.deduplicateCrossFieldText(
                primary: candidateSummary,
                referenceTexts: [updated.identity]
            )
            updated.summary = NarrativeEntityResolver.trimToSentenceBoundary(dedupedSummary, maxLength: 240)

            if updated.kind == .character {
                let candidateVoice = rawVoice.isEmpty ? baseline.voiceProfile : rawVoice
                let dedupedVoice = NarrativeEntityResolver.deduplicateCrossFieldText(
                    primary: candidateVoice,
                    referenceTexts: [updated.identity, updated.summary]
                )
                updated.voiceProfile = NarrativeEntityResolver.trimToSentenceBoundary(dedupedVoice, maxLength: 140)
            } else {
                updated.voiceProfile = ""
            }

            if !rawBoundaries.isEmpty {
                updated.hardBoundaries = NarrativeEntityResolver.deduplicatedNonEmptyStrings(rawBoundaries)
            }

            let changed = updated.identity != baseline.identity
                || updated.summary != baseline.summary
                || updated.voiceProfile != baseline.voiceProfile
                || updated.hardBoundaries != baseline.hardBoundaries
            if changed {
                updated.updatedAt = now
                replacements.append(updated)
            }
        }

        let retractedFacts = parseNegatedFacts(
            from: object,
            nodeID: nodeID,
            existingFactsByEntity: factsByEntity,
            idMapping: idMapping,
            now: now
        )

        return PlotNodeDelta(
            entityPageReplacements: replacements,
            factEvents: retractedFacts
        )
    }

    static func parseNegatedFacts(
        from object: [String: Any],
        nodeID: String,
        existingFactsByEntity: [String: [WorldFactEvent]],
        idMapping: NarrativeEntityResolver.ExtractionIDMapping?,
        now: Date = Date()
    ) -> [WorldFactEvent] {
        let rawNegated = parseStringArray(
            object["negated_fact_ids"] ?? object["negatedFactIDs"] ?? object["retracted_fact_ids"]
        )
        guard !rawNegated.isEmpty else { return [] }

        var factByID: [String: WorldFactEvent] = [:]
        for facts in existingFactsByEntity.values {
            for fact in facts where !fact.id.isEmpty {
                factByID[fact.id] = fact
            }
        }
        guard !factByID.isEmpty else { return [] }

        var seenIDs = Set<String>()
        var events: [WorldFactEvent] = []
        for (idx, token) in rawNegated.enumerated() {
            let resolvedID = idMapping?.factShortToReal[token.uppercased()]
                ?? idMapping?.factShortToReal[token]
                ?? token
            guard seenIDs.insert(resolvedID).inserted,
                  let target = factByID[resolvedID] else {
                continue
            }
            events.append(
                WorldFactEvent(
                    id: "\(nodeID)_retract_\(idx)_\(SummaryKey.sha256Hex(target.id).prefix(8))",
                    entityID: target.entityID,
                    attribute: target.attribute,
                    value: target.value,
                    nodeID: nodeID,
                    authority: .canonProseQuote,
                    supersedesEventID: target.id,
                    quoteAnchor: nil,
                    isRetracted: true,
                    createdAt: now
                )
            )
        }
        return events
    }

    static func collectRelevantFacts(
        for pages: [EntityPage],
        existingFactsByEntity: [String: [WorldFactEvent]],
        perEntityLimit: Int
    ) -> [WorldFactEvent] {
        guard perEntityLimit > 0 else { return [] }
        var out: [WorldFactEvent] = []
        for page in pages {
            let facts = (existingFactsByEntity[page.id] ?? [])
                .filter { !$0.isRetracted }
                .sorted { lhs, rhs in
                    if lhs.attribute != rhs.attribute { return lhs.attribute < rhs.attribute }
                    return lhs.id < rhs.id
                }
                .prefix(perEntityLimit)
            out.append(contentsOf: facts)
        }
        return out
    }

    private static func formatExistingPagePromptLines(
        page: EntityPage,
        facts: [WorldFactEvent],
        mapping: NarrativeEntityResolver.ExtractionIDMapping,
        factLimit: Int = 8
    ) -> [String] {
        let shortID = mapping.entityRealToShort[page.id] ?? page.id
        let aliasText = page.aliases.isEmpty ? "" : "（别名：\(page.aliases.joined(separator: "、"))）"
        var lines = ["- \(shortID) | [\(page.kind.rawValue)] \(page.name)\(aliasText)"]
        let cleanIdentity = page.identity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanIdentity.isEmpty {
            lines.append("  \(page.kind.identityLabel)：\(cleanIdentity)")
        }
        let cleanSummary = page.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanSummary.isEmpty {
            lines.append("  \(page.kind.summaryLabel)：\(cleanSummary)")
        }
        if page.kind == .character {
            let cleanVoice = page.voiceProfile.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanVoice.isEmpty {
                lines.append("  说话风格：\(cleanVoice)")
            }
        }
        if !page.hardBoundaries.isEmpty {
            lines.append("  \(page.kind.boundariesLabel)：\(page.hardBoundaries.joined(separator: "；"))")
        }
        let activeFacts = facts
            .filter { !$0.isRetracted }
            .sorted { lhs, rhs in
                if lhs.attribute != rhs.attribute { return lhs.attribute < rhs.attribute }
                return lhs.id < rhs.id
            }
        if !activeFacts.isEmpty {
            let factTokens = activeFacts.prefix(max(0, factLimit)).map { fact in
                let fShort = mapping.factRealToShort[fact.id] ?? fact.id
                return "\(fShort)[\(fact.attribute)]=\(fact.value)"
            }
            lines.append("  当前近况：" + factTokens.joined(separator: "；"))
        }
        return lines
    }

    private static func mergeFieldText(
        existing: String,
        incoming: String,
        explicitChanged: Bool?,
        maxLength: Int,
        referenceTexts: [String]
    ) -> String {
        let cleanExisting = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIncoming.isEmpty else { return cleanExisting }

        let combined: String
        if cleanExisting.isEmpty {
            combined = cleanIncoming
        } else if explicitChanged == true {
            // ACTOR changed=true：正常替换为融合后的最新快照；仅当旧档较长而新输入为极短增量补丁时才去重追加。
            if cleanExisting.count >= 24 && cleanIncoming.count < 12 {
                combined = NarrativeEntityResolver.appendUniqueSentences(cleanExisting, cleanIncoming)
            } else {
                combined = cleanIncoming
            }
        } else {
            let overlaps = cleanIncoming.localizedCaseInsensitiveContains(cleanExisting)
                || cleanExisting.localizedCaseInsensitiveContains(cleanIncoming)
            if cleanIncoming.count >= 18 || overlaps {
                combined = cleanIncoming
            } else {
                combined = NarrativeEntityResolver.appendUniqueSentences(cleanExisting, cleanIncoming)
            }
        }

        let deduped = NarrativeEntityResolver.deduplicateCrossFieldText(
            primary: combined,
            referenceTexts: referenceTexts
        )
        return NarrativeEntityResolver.trimToSentenceBoundary(deduped, maxLength: maxLength)
    }

    private static func parseBoolFlag(_ raw: Any?) -> Bool? {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String {
            switch s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func isEntityMentionedInGrounding(
        name: String,
        aliases: [String],
        text: String
    ) -> Bool {
        let candidates = ([name] + aliases)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !NarrativeEntityResolver.isGenericRoleTerm($0) }
        guard !candidates.isEmpty else { return false }
        let normalizedText = NarrativeEntityResolver.normalizeName(text)
        return candidates.contains { candidate in
            if text.localizedCaseInsensitiveContains(candidate) {
                return true
            }
            let normCandidate = NarrativeEntityResolver.normalizeName(candidate)
            return normCandidate.count >= 2 && normalizedText.contains(normCandidate)
        }
    }

    private static func prioritizeExistingPages(
        _ pages: [EntityPage],
        in manuscriptTail: String,
        limit: Int
    ) -> [EntityPage] {
        guard !pages.isEmpty, limit > 0 else { return [] }
        return pages
            .sorted { lhs, rhs in
                let lhsMentioned = isPageMentioned(lhs, in: manuscriptTail)
                let rhsMentioned = isPageMentioned(rhs, in: manuscriptTail)
                if lhsMentioned != rhsMentioned { return lhsMentioned && !rhsMentioned }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.name < rhs.name
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func isPageMentioned(_ page: EntityPage, in text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let name = page.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, text.localizedCaseInsensitiveContains(name) {
            return true
        }
        return page.aliases.contains { alias in
            let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            return !clean.isEmpty
                && !NarrativeEntityResolver.isGenericRoleTerm(clean)
                && text.localizedCaseInsensitiveContains(clean)
        }
    }

    static func parseKind(_ raw: String) -> EntityKind? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "character", "人物", "角色":
            return .character
        case "location", "地点", "场景":
            return .location
        case "artifact", "物件", "物品", "道具":
            return .artifact
        case "lore", "设定", "规则", "世界观", "体系", "势力", "概念":
            return .lore
        default:
            return nil
        }
    }

    static func parseStringArray(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return deduplicatedStrings(strings)
        }
        if let raw = value as? String {
            let parts = raw
                .replacingOccurrences(of: "，", with: "\n")
                .replacingOccurrences(of: "、", with: "\n")
                .replacingOccurrences(of: ",", with: "\n")
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            return deduplicatedStrings(parts)
        }
        return []
    }

    private static func deduplicatedStrings(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                out.append(trimmed)
            }
        }
        return out
    }
}
