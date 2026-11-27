import Foundation
import NaturalLanguage

/// 实体解析、短序号映射、泛称过滤、句级追加与候选去重的纯本地确定性辅助工具。
enum NarrativeEntityResolver {

    /// 高频无归属称谓与泛称词表：单独出现时不建独立档案，也不写入实体别名以防跨角色串线。
    static let genericRoleTerms: Set<String> = [
        "师父", "师傅", "师兄", "师姐", "师弟", "师妹", "掌门", "掌柜",
        "小二", "店小二", "侍卫", "守卫", "护卫", "黑衣人", "蒙面人",
        "老者", "老人", "少年", "少女", "男子", "女子", "青年", "妇人",
        "父亲", "母亲", "父皇", "母后", "陛下", "殿下", "大人", "老爷",
        "夫人", "小姐", "公子", "姑娘", "老板", "大夫", "郎中", "船夫",
        "车夫", "路人", "旁人",
    ]

    private static let pronounTerms: Set<String> = [
        "他", "她", "它", "我", "你", "您", "他们", "她们", "它们", "我们", "你们", "众人",
    ]

    private static let comparisonPunctuation: Set<Character> = [
        "；", ";", "，", ",", "。", "！", "!", "？", "?", "、",
        "\n", "\r", "\t", " ", "#", "-", "*",
        "“", "”", "\"", "‘", "’", "（", "(", "）", ")", "【", "[", "】", "]",
        "：", ":", "—", "…",
    ]

    private static let sentenceTerminators: Set<Character> = [
        "。", "！", "？", "!", "?", "；", ";",
    ]

    private static let trailingClosers: Set<Character> = [
        "”", "」", "』", "’", "）", ")", "\"", "'", "】", "]",
    ]

    /// 名称归一化：去首尾与内部全部空白、统一小写并折叠常见全半角符号。
    static func normalizeName(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text.lowercased() {
            if ch.isWhitespace || ch == "\u{3000}" { continue }
            switch ch {
            case "（": out.append("(")
            case "）": out.append(")")
            case "－", "—", "–": out.append("-")
            default: out.append(ch)
            }
        }
        return out
    }

    static func isGenericRoleTerm(_ text: String) -> Bool {
        let key = normalizeName(text)
        guard !key.isEmpty else { return true }
        return genericRoleTerms.contains(key) || pronounTerms.contains(key)
    }

    /// 过滤空串、主名本身与无归属泛称，并按归一化键保序去重。
    static func sanitizedAliases(_ aliases: [String], canonicalName: String) -> [String] {
        let canonicalKey = normalizeName(canonicalName)
        var seen: Set<String> = canonicalKey.isEmpty ? [] : [canonicalKey]
        var result: [String] = []
        for raw in aliases {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalizeName(trimmed)
            guard !key.isEmpty,
                  !isGenericRoleTerm(trimmed),
                  seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    static func deduplicatedNonEmptyStrings(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out
    }

    // MARK: - 句级去重追加

    /// 旧内容只读：新内容按换行与句末标点切句，剔除旧文本已包含的句子后追加，防止覆盖历史设定与因果。
    static func appendUniqueSentences(
        _ existing: String,
        _ incoming: String,
        separator: String = "\n"
    ) -> String {
        let oldText = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let newText = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty else { return existing }
        guard !oldText.isEmpty else { return newText }

        let oldKey = comparisonKey(oldText)
        var seen = Set<String>()
        var additions: [String] = []
        for piece in splitSentences(newText) {
            let key = comparisonKey(piece)
            guard !key.isEmpty, !oldKey.contains(key), seen.insert(key).inserted else { continue }
            additions.append(piece)
        }
        guard !additions.isEmpty else { return existing }
        let block = separator.isEmpty ? joinParagraph(additions) : additions.joined(separator: separator)
        return oldText + "\n" + block
    }

    private static func comparisonKey(_ text: String) -> String {
        text.lowercased().filter {
            !$0.isWhitespace && !comparisonPunctuation.contains($0)
        }
    }

    /// 使用系统 `NLTokenizer(unit: .sentence)` 断句（保留换行分段优先），避免小数点、省略号或引号嵌套误切。
    static func splitSentences(_ text: String) -> [String] {
        let paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { return [] }

        var sentences: [String] = []
        for para in paragraphs {
            let tokenizer = NLTokenizer(unit: .sentence)
            tokenizer.string = para
            var paraSentences: [String] = []
            tokenizer.enumerateTokens(in: para.startIndex..<para.endIndex) { range, _ in
                let piece = String(para[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !piece.isEmpty else { return true }
                if !paraSentences.isEmpty, piece.allSatisfy({ trailingClosers.contains($0) }) {
                    paraSentences[paraSentences.count - 1] += piece
                } else {
                    paraSentences.append(piece)
                }
                return true
            }
            if paraSentences.isEmpty {
                sentences.append(para)
            } else {
                sentences.append(contentsOf: paraSentences)
            }
        }
        return sentences
    }

    private static func joinParagraph(_ sentences: [String]) -> String {
        var out = ""
        for sentence in sentences {
            if !out.isEmpty, let last = out.last,
               !sentenceTerminators.contains(last), !trailingClosers.contains(last) {
                out.append("。")
            }
            out.append(sentence)
        }
        return out
    }

    /// 按完整句子顺序裁剪长度，避免抽取或展示时跳掉中间句造成断章取义。
    static func trimToSentenceBoundary(_ text: String, maxLength: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxLength, maxLength > 0 else { return trimmed }
        let sentences = splitSentences(trimmed)
        guard !sentences.isEmpty else { return String(trimmed.prefix(maxLength)) }

        var kept: [String] = []
        var used = 0
        for sentence in sentences {
            let cost = kept.isEmpty ? sentence.count : (sentence.count + 1)
            if used + cost > maxLength {
                break
            }
            kept.append(sentence)
            used += cost
        }
        if !kept.isEmpty {
            return joinParagraph(kept)
        }
        let first = sentences[0]
        let slice = String(first.prefix(maxLength))
        let softBreaks: Set<Character> = ["，", ",", "；", ";", "、", "：", ":"]
        if let breakIdx = slice.lastIndex(where: { softBreaks.contains($0) }),
           slice.distance(from: slice.startIndex, to: breakIdx) >= maxLength / 2 {
            return String(slice[..<breakIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return slice
    }

    /// 清除字段自身重复句，并剔除已在对照字段中完整出现的句子（防止身份、性格、声线互抄）。
    static func deduplicateCrossFieldText(
        primary: String,
        referenceTexts: [String]
    ) -> String {
        let cleanPrimary = primary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPrimary.isEmpty else { return "" }
        let refKeys = referenceTexts
            .map { comparisonKey($0) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        var kept: [String] = []
        for sentence in splitSentences(cleanPrimary) {
            let key = comparisonKey(sentence)
            guard !key.isEmpty else { continue }
            let coveredByRef = refKeys.contains { $0.contains(key) }
            guard !coveredByRef, seen.insert(key).inserted else { continue }
            kept.append(sentence)
        }
        guard !kept.isEmpty else { return "" }
        return joinParagraph(kept)
    }

    /// 判断实体档案是否存在句内重复或跨字段（identity / summary / voiceProfile）重复句。
    static func hasDuplicateSentencesAcrossFields(in page: EntityPage) -> Bool {
        var seen = Set<String>()
        let fields = [page.identity, page.summary, page.voiceProfile]
        for field in fields {
            for sentence in splitSentences(field) {
                let key = comparisonKey(sentence)
                guard !key.isEmpty else { continue }
                if !seen.insert(key).inserted {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - 请求级 Short-ID 映射

    struct ExtractionIDMapping: Hashable {
        var entityShortToReal: [String: String]
        var entityRealToShort: [String: String]
        var eventShortToReal: [String: String]
        var eventRealToShort: [String: String]
        var threadShortToReal: [String: String]
        var threadRealToShort: [String: String]
        var factShortToReal: [String: String] = [:]
        var factRealToShort: [String: String] = [:]

        var isEmpty: Bool {
            entityShortToReal.isEmpty
                && eventShortToReal.isEmpty
                && threadShortToReal.isEmpty
                && factShortToReal.isEmpty
        }

        static func build(
            entities: [EntityPage],
            events: [EpisodicEvent] = [],
            threads: [ProspectiveThread] = [],
            facts: [WorldFactEvent] = []
        ) -> ExtractionIDMapping {
            var eShortToReal: [String: String] = [:]
            var eRealToShort: [String: String] = [:]
            for (idx, entity) in entities.enumerated() where !entity.id.isEmpty {
                let short = "E\(idx + 1)"
                eShortToReal[short] = entity.id
                eRealToShort[entity.id] = short
            }

            var evShortToReal: [String: String] = [:]
            var evRealToShort: [String: String] = [:]
            for (idx, event) in events.enumerated() where !event.id.isEmpty {
                let short = "EV\(idx + 1)"
                evShortToReal[short] = event.id
                evRealToShort[event.id] = short
            }

            var tShortToReal: [String: String] = [:]
            var tRealToShort: [String: String] = [:]
            for (idx, thread) in threads.enumerated() where !thread.id.isEmpty {
                let short = "T\(idx + 1)"
                tShortToReal[short] = thread.id
                tRealToShort[thread.id] = short
            }

            var fShortToReal: [String: String] = [:]
            var fRealToShort: [String: String] = [:]
            for (idx, fact) in facts.enumerated() where !fact.id.isEmpty {
                let short = "F\(idx + 1)"
                fShortToReal[short] = fact.id
                fRealToShort[fact.id] = short
            }

            return ExtractionIDMapping(
                entityShortToReal: eShortToReal,
                entityRealToShort: eRealToShort,
                eventShortToReal: evShortToReal,
                eventRealToShort: evRealToShort,
                threadShortToReal: tShortToReal,
                threadRealToShort: tRealToShort,
                factShortToReal: fShortToReal,
                factRealToShort: fRealToShort
            )
        }
    }

    // MARK: - 歧义感知实体查找表

    enum EntityLookupResult: Equatable {
        case matched(EntityPage)
        case ambiguous([EntityPage])
        case notFound
    }

    struct EntityLookupIndex {
        private(set) var byID: [String: EntityPage] = [:]
        private var byNormalizedName: [EntityKind: [String: [EntityPage]]] = [:]
        private var byNormalizedAlias: [EntityKind: [String: [EntityPage]]] = [:]
        private var globalByNormalizedName: [String: [EntityPage]] = [:]
        private var globalByNormalizedAlias: [String: [EntityPage]] = [:]

        init(pages: [EntityPage]) {
            for page in pages {
                register(page)
            }
        }

        mutating func register(_ page: EntityPage) {
            guard !page.id.isEmpty else { return }
            if let old = byID[page.id] {
                removeFromBuckets(old)
            }
            byID[page.id] = page

            let nameKey = NarrativeEntityResolver.normalizeName(page.name)
            if !nameKey.isEmpty {
                Self.appendUnique(page, into: &byNormalizedName[page.kind, default: [:]][nameKey, default: []])
                Self.appendUnique(page, into: &globalByNormalizedName[nameKey, default: []])
            }
            for alias in page.aliases {
                let aliasKey = NarrativeEntityResolver.normalizeName(alias)
                guard !aliasKey.isEmpty,
                      aliasKey != nameKey,
                      !NarrativeEntityResolver.isGenericRoleTerm(alias) else { continue }
                Self.appendUnique(page, into: &byNormalizedAlias[page.kind, default: [:]][aliasKey, default: []])
                Self.appendUnique(page, into: &globalByNormalizedAlias[aliasKey, default: []])
            }
        }

        func resolve(
            rawID: String? = nil,
            name: String? = nil,
            aliases: [String] = [],
            expectedKind: EntityKind? = nil,
            mapping: ExtractionIDMapping? = nil,
            newEntityRefs: [String: EntityPage] = [:]
        ) -> EntityLookupResult {
            let cleanID = (rawID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanID.isEmpty {
                if let realID = mapping?.entityShortToReal[cleanID.uppercased()],
                   let mapped = byID[realID] {
                    return .matched(mapped)
                }
                if cleanID.lowercased().hasPrefix("new:") {
                    let refName = String(cleanID.dropFirst(4))
                    let refKey = NarrativeEntityResolver.normalizeName(refName)
                    if !refKey.isEmpty, let created = newEntityRefs[refKey] {
                        return .matched(created)
                    }
                }
                if let exactByID = byID[cleanID] {
                    return .matched(exactByID)
                }
            }

            let cleanName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveName = cleanName.isEmpty ? cleanID : cleanName
            let nameKey = NarrativeEntityResolver.normalizeName(effectiveName)

            if !nameKey.isEmpty, let created = newEntityRefs[nameKey] {
                if expectedKind == nil || created.kind == expectedKind {
                    return .matched(created)
                }
            }

            if let expectedKind {
                return resolveWithExpectedKind(
                    expectedKind: expectedKind,
                    effectiveName: effectiveName,
                    nameKey: nameKey,
                    aliases: aliases
                )
            }

            if !nameKey.isEmpty {
                if let nameHits = globalByNormalizedName[nameKey], !nameHits.isEmpty {
                    return uniqueOrAmbiguous(nameHits)
                }
                if !NarrativeEntityResolver.isGenericRoleTerm(effectiveName),
                   let aliasHits = globalByNormalizedAlias[nameKey],
                   !aliasHits.isEmpty {
                    return uniqueOrAmbiguous(aliasHits)
                }
            }

            return .notFound
        }

        private func resolveWithExpectedKind(
            expectedKind: EntityKind,
            effectiveName: String,
            nameKey: String,
            aliases: [String]
        ) -> EntityLookupResult {
            if !nameKey.isEmpty {
                if let nameHits = byNormalizedName[expectedKind]?[nameKey], !nameHits.isEmpty {
                    return uniqueOrAmbiguous(nameHits)
                }
                if !NarrativeEntityResolver.isGenericRoleTerm(effectiveName),
                   let aliasHits = byNormalizedAlias[expectedKind]?[nameKey],
                   !aliasHits.isEmpty {
                    return uniqueOrAmbiguous(aliasHits)
                }
            }

            var reverseMatches: [String: EntityPage] = [:]
            for alias in aliases {
                let aliasKey = NarrativeEntityResolver.normalizeName(alias)
                guard !aliasKey.isEmpty,
                      !NarrativeEntityResolver.isGenericRoleTerm(alias) else { continue }
                for match in byNormalizedName[expectedKind]?[aliasKey] ?? [] {
                    reverseMatches[match.id] = match
                }
                for match in byNormalizedAlias[expectedKind]?[aliasKey] ?? [] {
                    reverseMatches[match.id] = match
                }
            }
            if !reverseMatches.isEmpty {
                return uniqueOrAmbiguous(Array(reverseMatches.values))
            }
            return .notFound
        }

        private func uniqueOrAmbiguous(_ hits: [EntityPage]) -> EntityLookupResult {
            var unique: [EntityPage] = []
            var seen = Set<String>()
            for item in hits where seen.insert(item.id).inserted {
                unique.append(item)
            }
            if unique.count == 1, let first = unique.first {
                return .matched(first)
            }
            if unique.count > 1 {
                return .ambiguous(unique)
            }
            return .notFound
        }

        private static func appendUnique(_ page: EntityPage, into bucket: inout [EntityPage]) {
            if let existingIndex = bucket.firstIndex(where: { $0.id == page.id }) {
                bucket[existingIndex] = page
            } else {
                bucket.append(page)
            }
        }

        private mutating func removeFromBuckets(_ page: EntityPage) {
            let nameKey = NarrativeEntityResolver.normalizeName(page.name)
            if !nameKey.isEmpty {
                byNormalizedName[page.kind]?[nameKey]?.removeAll { $0.id == page.id }
                globalByNormalizedName[nameKey]?.removeAll { $0.id == page.id }
            }
            for alias in page.aliases {
                let aliasKey = NarrativeEntityResolver.normalizeName(alias)
                guard !aliasKey.isEmpty else { continue }
                byNormalizedAlias[page.kind]?[aliasKey]?.removeAll { $0.id == page.id }
                globalByNormalizedAlias[aliasKey]?.removeAll { $0.id == page.id }
            }
        }
    }

    // MARK: - 按分类隔离的候选实体去重收口

    struct EntityDedupeSuggestion: Equatable {
        var sourceID: String
        var targetID: String
        var canonicalName: String
        var extraAliases: [String]
    }

    static func buildDedupeMessages(
        kind: EntityKind,
        candidates: [EntityPage],
        existing: [EntityPage]
    ) -> (messages: [LLMMessage], candidateIDs: [String], existingIDs: [String])? {
        let sameKindCandidates = candidates.filter { $0.kind == kind && !$0.id.isEmpty }
        let sameKindExisting = existing.filter { $0.kind == kind && !$0.id.isEmpty }
        guard sameKindCandidates.count >= 2 || (!sameKindCandidates.isEmpty && !sameKindExisting.isEmpty) else {
            return nil
        }

        let rankedExisting = prioritizeExistingForDedupe(
            sameKindExisting,
            against: sameKindCandidates,
            limit: 40
        )

        let candidateIDs = sameKindCandidates.map(\.id)
        let existingIDs = rankedExisting.map(\.id)

        let systemPrompt = """
        你是小说设定实体去重助手。请严格核对「本轮新增候选」之间、以及候选与「已有档案」之间是否指代同一现实对象或同一人物。
        请只返回一个 JSON 对象：
        {"resolutions":[{"id":0,"duplicate_candidate_id":-1,"merge_with_new_id":-1,"canonical_name":"","aliases":[]}]}
        硬性规则：
        1. 每个候选 `id`（0 到 \(sameKindCandidates.count - 1)）必须且仅出现一次。
        2. 仅当确认为同一实体（例如本名与别称、简称、头衔变体，且身份描述兼容）时才合并；名称相似但实为不同个体或不确定时，必须保持 `duplicate_candidate_id: -1` 且 `merge_with_new_id: -1`。
        3. 若命中「已有档案」，填写其 `candidate_id` 到 `duplicate_candidate_id`，并将 `merge_with_new_id` 设为 `-1`；不要修改已有档案名称。
        4. 若与「已有档案」均不同，但与更小序号的本轮候选为同一实体，将 `duplicate_candidate_id` 设为 `-1`，并将 `merge_with_new_id` 设为该更小序号 `id`。
        5. 禁止把无归属泛称（如师父、黑衣人、掌柜）作为合并依据。
        """

        var userLines: [String] = ["【实体分类】\(kind.displayName)（\(kind.rawValue)）", "【本轮新增候选】"]
        for (idx, page) in sameKindCandidates.enumerated() {
            userLines.append("- id=\(idx) | \(formatPageLine(page))")
        }
        if !rankedExisting.isEmpty {
            userLines.append("【已有档案（只读参考）】")
            for (idx, page) in rankedExisting.enumerated() {
                userLines.append("- candidate_id=\(idx) | \(formatPageLine(page))")
            }
        } else {
            userLines.append("【已有档案（只读参考）】无")
        }

        return (
            messages: [.system(systemPrompt), .user(userLines.joined(separator: "\n"))],
            candidateIDs: candidateIDs,
            existingIDs: existingIDs
        )
    }

    static func parseDedupeResponse(
        from raw: String,
        candidateIDs: [String],
        existingIDs: [String]
    ) -> [EntityDedupeSuggestion]? {
        guard !candidateIDs.isEmpty,
              let jsonString = NarrativeJSONScanner.extractFirstJSONObject(from: raw),
              let data = jsonString.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = (object["resolutions"] as? [[String: Any]])
                ?? (object["entity_resolutions"] as? [[String: Any]])
                ?? (object["items"] as? [[String: Any]])
        else {
            return nil
        }

        var rawByIndex: [Int: (dupExisting: Int, mergeNew: Int, canonical: String, aliases: [String])] = [:]
        for item in list {
            guard let id = parseInt(item["id"]),
                  candidateIDs.indices.contains(id),
                  rawByIndex[id] == nil else {
                continue
            }
            let dupExisting = parseInt(item["duplicate_candidate_id"] ?? item["duplicateCandidateId"]) ?? -1
            let mergeNew = parseInt(item["merge_with_new_id"] ?? item["mergeWithNewId"]) ?? -1
            if dupExisting >= 0, !existingIDs.indices.contains(dupExisting) {
                return nil
            }
            if mergeNew >= 0, (!candidateIDs.indices.contains(mergeNew) || mergeNew == id) {
                return nil
            }
            let canonical = NarrativeJSONScanner.firstNonEmptyString(
                item,
                keys: ["canonical_name", "canonicalName", "name"]
            )
            let aliases = parseStringArray(item["aliases"])
            rawByIndex[id] = (dupExisting, mergeNew, canonical, aliases)
        }

        guard rawByIndex.count == candidateIDs.count else {
            return nil
        }

        var suggestions: [EntityDedupeSuggestion] = []
        for idx in candidateIDs.indices {
            guard let entry = rawByIndex[idx] else { continue }
            if entry.dupExisting >= 0 {
                let targetID = existingIDs[entry.dupExisting]
                let sourceID = candidateIDs[idx]
                if sourceID != targetID {
                    suggestions.append(
                        EntityDedupeSuggestion(
                            sourceID: sourceID,
                            targetID: targetID,
                            canonicalName: "",
                            extraAliases: entry.aliases
                        )
                    )
                }
                continue
            }

            if entry.mergeNew >= 0 {
                // 沿着候选内部合并链向上追溯最终目标（支持多跳或指向已并入已有档案的候选），防止环路。
                var cursor = entry.mergeNew
                var visited: Set<Int> = [idx]
                var resolvedExistingTarget: String?
                while visited.insert(cursor).inserted, let parent = rawByIndex[cursor] {
                    if parent.dupExisting >= 0 {
                        resolvedExistingTarget = existingIDs[parent.dupExisting]
                        break
                    }
                    if parent.mergeNew >= 0 {
                        cursor = parent.mergeNew
                    } else {
                        break
                    }
                }
                let targetID = resolvedExistingTarget ?? candidateIDs[cursor]
                let sourceID = candidateIDs[idx]
                if sourceID != targetID {
                    suggestions.append(
                        EntityDedupeSuggestion(
                            sourceID: sourceID,
                            targetID: targetID,
                            canonicalName: resolvedExistingTarget == nil ? entry.canonical : "",
                            extraAliases: entry.aliases
                        )
                    )
                }
            }
        }
        return suggestions
    }

    static func mergeEntityPage(
        into target: EntityPage,
        from source: EntityPage,
        preferredName: String? = nil,
        extraAliases: [String] = [],
        now: Date = Date()
    ) -> EntityPage {
        var merged = target
        if let preferred = preferredName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !preferred.isEmpty,
           !isGenericRoleTerm(preferred),
           normalizeName(preferred) != normalizeName(target.name) {
            merged.name = preferred
        }

        let extraNames = [target.name, source.name].filter {
            normalizeName($0) != normalizeName(merged.name)
        }
        merged.aliases = sanitizedAliases(
            target.aliases + source.aliases + extraNames + extraAliases,
            canonicalName: merged.name
        )
        merged.triggerKeywords = deduplicatedNonEmptyStrings(
            target.triggerKeywords + source.triggerKeywords
        )
        if merged.kind == .lore, source.activationMode == .always {
            merged.activationMode = .always
        }
        merged.identity = appendUniqueSentences(target.identity, source.identity)
        merged.summary = appendUniqueSentences(target.summary, source.summary)
        if merged.kind == .character {
            merged.voiceProfile = appendUniqueSentences(target.voiceProfile, source.voiceProfile)
        }
        merged.hardBoundaries = deduplicatedNonEmptyStrings(
            target.hardBoundaries + source.hardBoundaries
        )
        merged.conflictWarnings = deduplicatedNonEmptyStrings(
            target.conflictWarnings + source.conflictWarnings
        )
        merged.currentFactIDs = deduplicatedNonEmptyStrings(
            target.currentFactIDs + source.currentFactIDs
        )
        merged.enabled = target.enabled || source.enabled
        merged.updatedAt = max(target.updatedAt, max(source.updatedAt, now))
        return merged
    }

    // MARK: - 内部辅助

    private static func prioritizeExistingForDedupe(
        _ existing: [EntityPage],
        against candidates: [EntityPage],
        limit: Int
    ) -> [EntityPage] {
        guard existing.count > limit else {
            return existing.sorted { $0.updatedAt > $1.updatedAt }
        }
        let candidateChars = Set(
            candidates.flatMap { [$0.name] + $0.aliases }
                .flatMap { Array(normalizeName($0)) }
        )
        return existing
            .sorted { lhs, rhs in
                let lhsChars = Set(normalizeName(lhs.name))
                let rhsChars = Set(normalizeName(rhs.name))
                let lhsOverlap = lhsChars.intersection(candidateChars).count
                let rhsOverlap = rhsChars.intersection(candidateChars).count
                if lhsOverlap != rhsOverlap { return lhsOverlap > rhsOverlap }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.id < rhs.id
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func formatPageLine(_ page: EntityPage) -> String {
        let aliasText = page.aliases.isEmpty ? "" : "（别名：\(page.aliases.joined(separator: "、"))）"
        let anchorSource = !page.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? page.identity
            : page.summary
        let cleanAnchor = anchorSource
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "；")
        let clippedAnchor = cleanAnchor.count > 80 ? String(cleanAnchor.prefix(80)) + "…" : cleanAnchor
        return clippedAnchor.isEmpty
            ? "\(page.name)\(aliasText)"
            : "\(page.name)\(aliasText)：\(clippedAnchor)"
    }

    private static func parseInt(_ raw: Any?) -> Int? {
        if let n = raw as? Int { return n }
        if let n = raw as? NSNumber { return n.intValue }
        if let s = raw as? String {
            return Int(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func parseStringArray(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return deduplicatedNonEmptyStrings(strings)
        }
        if let raw = value as? String {
            let parts = raw
                .replacingOccurrences(of: "，", with: "\n")
                .replacingOccurrences(of: "、", with: "\n")
                .replacingOccurrences(of: ",", with: "\n")
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            return deduplicatedNonEmptyStrings(parts)
        }
        return []
    }
}
