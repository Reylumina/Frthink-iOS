import Foundation

/// 档案提取器：从正文末尾或指定片区增量提取、更新四类档案（人物、地点、物件、世界观），
/// 与既有实体按 ID 或名称自动对齐合并，保留作者手工调整与冲突历史。
enum NarrativeEntityExtractor {

    static func buildExtractionPayload(
        manuscriptTail: String,
        leadingContext: String = "",
        existingPages: [EntityPage],
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
        let mapping = NarrativeEntityResolver.ExtractionIDMapping.build(entities: relevantPages)

        let schemaLine: String
        let factsInstruction: String
        if includeFacts {
            schemaLine = #"{"entities":[{"id":"","kind":"character|location|artifact|lore","name":"","aliases":[""],"trigger_keywords":[""],"activation_mode":"mentioned|always","identity":"","summary":"","voice_profile":"","hard_boundaries":[""]}],"facts":[{"entity_id":"","attribute":"","value":"","quote":"","retracted":false}]}"#
            factsInstruction = """
            7. `facts` 专门记录「本段待提取正文」里明确写出的精确动态事实（如位置、持有物、伤势、目标、状态，以及按对象拆分的人际关系 `relation:<对象名>`、地点格局/准入、物件归属/用途/代价、世界观铁律/例外）。
            8. `facts.entity_id` 必须填现有档案短编号（如 `"E1"`）或本轮 `entities` 中新建条目的 `"NEW:实体名"`，并附上原文逐字短引用 `quote`；没有精确动态事实时 `facts` 返回 `[]`。
            """
        } else {
            schemaLine = #"{"entities":[{"id":"","kind":"character|location|artifact|lore","name":"","aliases":[""],"trigger_keywords":[""],"activation_mode":"mentioned|always","identity":"","summary":"","voice_profile":"","hard_boundaries":[""]}]}"#
            factsInstruction = ""
        }

        let systemPrompt = """
        你是小说设定整理编辑，负责从正文中提取并更新四类档案\(includeFacts ? "及精确动态事实" : "")。
        \(kindScopeInstruction)
        请只返回一个 JSON 对象，不要附加额外说明：
        \(schemaLine)
        分类说明：
        - `character`（人物）：有自主行动或视角的角色。`identity` 写身份与立场，`summary` 写性格、价值观与当前处境，`voice_profile` 写说话口吻与用词习惯，`hard_boundaries` 写人物底线与不可违背的原则。
        - `location`（地点）：具体的物理场所。`identity` 写位置与所属区域，`summary` 写空间布局、环境氛围与出入口，`hard_boundaries` 写地形或准入限制；`voice_profile` 留空。
        - `artifact`（物件）：可持有或使用的道具、信物与器物。`identity` 写当前持有者或归属，`summary` 写外观、用途与当前状态，`hard_boundaries` 写触发条件、代价或损耗限制；`voice_profile` 留空。
        - `lore`（世界观）：世界内的力量体系、宗门势力、社会制度、历史事件或自然法则。不要把戏外作者的写作要求（如视角限制、行文节奏、字数要求、去 AI 味规范）归入 `lore`。`identity` 写所属类别，`summary` 写具体机制与词条内容，`hard_boundaries` 写世界内不可违背的规则与例外，`trigger_keywords` 填正文中提及即可带入该词条的关键词（不要重复填写名称本身）；只有作用于全局的基础铁律才将 `activation_mode` 设为 `"always"`，其余保持 `"mentioned"`。
        整理要求：
        1. 若条目已在下方「现有档案」中出现，请在 `id` 字段直接填写对应短编号（如 `"E1"`），只补充或修正有原文依据的新信息；若人物身份、性格或处境发生明显变化，请直接输出整合后的最新状态快照，避免新旧冲突语句互相打架。
        2. 严禁跨分类复用同名档案（例如同名地点与势力必须分开建档）。
        3. 禁止把无归属泛称或临时职务称谓（如「师父」「掌柜」「小二」「侍卫」「黑衣人」「少年」「老者」「路人」）单独建档或写入任何实体的 `aliases`。
        4. 新出现的重要角色、地点、物件或世界观条目可新建档案（`id` 留空），内容必须依据「本段待提取正文」，不得把只读前情里已有但本段未再提及的对象重复新建，也不得臆造。
        5. `summary` 用一至三句高度凝练的当前状态概括（不超过 180 字）；非 `character` 分类禁止填写 `voice_profile`。
        6. 若正文中没有新增或变化的条目，对应数组返回 `[]`。
        \(factsInstruction)
        """

        var userLines: [String] = []
        if !relevantPages.isEmpty {
            userLines.append("【现有档案（优先填写短编号 E1/E2…）】")
            for page in relevantPages {
                let shortID = mapping.entityRealToShort[page.id] ?? page.id
                let aliasText = page.aliases.isEmpty ? "" : "（别名：\(page.aliases.joined(separator: "、"))）"
                let brief = !page.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? page.identity.trimmingCharacters(in: .whitespacesAndNewlines)
                    : page.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                let clippedBrief = brief.count > 48 ? String(brief.prefix(48)) + "…" : brief
                let summaryPart = clippedBrief.isEmpty ? "" : "：\(clippedBrief)"
                userLines.append("- \(shortID) | [\(page.kind.rawValue)] \(page.name)\(aliasText)\(summaryPart)")
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
        let factEvents = NarrativeDeltaExtractor.parseFactsArray(
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
                merged.aliases = NarrativeEntityResolver.sanitizedAliases(
                    merged.aliases + incomingAliases + extraNames,
                    canonicalName: merged.name
                )
                merged.triggerKeywords = NarrativeEntityResolver.deduplicatedNonEmptyStrings(
                    merged.triggerKeywords + incomingTriggerKeywords
                )
                if merged.kind == .lore, parsedActivation == .always {
                    merged.activationMode = .always
                }
                if !incomingIdentity.isEmpty {
                    let appendedIdentity = NarrativeEntityResolver.appendUniqueSentences(
                        merged.identity,
                        incomingIdentity
                    )
                    merged.identity = compactMergedField(appendedIdentity, maxLength: 160)
                }
                if !incomingSummary.isEmpty {
                    let appendedSummary = NarrativeEntityResolver.appendUniqueSentences(
                        merged.summary,
                        incomingSummary
                    )
                    merged.summary = compactMergedField(appendedSummary, maxLength: 260)
                }
                if !incomingVoice.isEmpty, merged.kind == .character {
                    let appendedVoice = NarrativeEntityResolver.appendUniqueSentences(
                        merged.voiceProfile,
                        incomingVoice
                    )
                    merged.voiceProfile = compactMergedField(appendedVoice, maxLength: 140)
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
                let created = EntityPage(
                    id: candidateID,
                    kind: resolvedKind,
                    name: name,
                    aliases: incomingAliases,
                    triggerKeywords: deduplicatedStrings(incomingTriggerKeywords),
                    activationMode: resolvedKind == .lore ? parsedActivation : .mentioned,
                    summary: incomingSummary,
                    identity: incomingIdentity,
                    voiceProfile: resolvedKind == .character ? incomingVoice : "",
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

    private static func compactMergedField(_ text: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength, maxLength > 24 else { return trimmed }
        let sentences = NarrativeEntityResolver.splitSentences(trimmed)
        if sentences.count >= 2 {
            let first = sentences[0]
            var keptTail: [String] = []
            var used = first.count
            for sentence in sentences.dropFirst().reversed() {
                let cost = sentence.count + 1
                if !keptTail.isEmpty && used + cost > maxLength { break }
                keptTail.append(sentence)
                used += cost
            }
            let combined = ([first] + keptTail.reversed()).joined(separator: "\n")
            if combined.count <= maxLength {
                return combined
            }
            if let latest = sentences.last, latest.count + 2 <= maxLength {
                return latest
            }
        }
        return String(trimmed.prefix(maxLength))
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
