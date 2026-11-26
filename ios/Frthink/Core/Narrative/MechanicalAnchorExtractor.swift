import Foundation

/// 纯确定性机械细节定位器：不依赖模型调用，从正文中抽取实体出现、章节/时间标记与计量物件短语，
/// 为低延迟检索和实体回溯提供精确 UTF-16 锚点兜底。
enum MechanicalAnchorExtractor {

    private static let timeRegex = try? NSRegularExpression(
        pattern: "第[零一二三四五六七八九十百千万0-9]+[章回节卷幕]"
    )

    static func extract(
        from text: String,
        knownEntities: [EntityPage],
        pageIndex: Int = 0,
        baseUTF16Offset: Int = 0
    ) -> [MechanicalAnchor] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        var anchors: [MechanicalAnchor] = []
        var occupiedEntityRanges: [NSRange] = []

        // 按名称/别名长度降序扫描已知实体，防止短别名遮蔽完整名称。
        var entityTerms: [(entityID: String, kind: AnchorKind, term: String)] = []
        for page in knownEntities {
            let kind: AnchorKind
            switch page.kind {
            case .character, .lore:
                kind = .entityMention
            case .location:
                kind = .location
            case .artifact:
                kind = .artifactOrCount
            }
            for rawTerm in [page.name] + page.aliases {
                let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                guard term.count >= 2 else { continue }
                entityTerms.append((entityID: page.id, kind: kind, term: term))
            }
        }
        entityTerms.sort { lhs, rhs in
            if lhs.term.count != rhs.term.count { return lhs.term.count > rhs.term.count }
            return lhs.term < rhs.term
        }

        for entry in entityTerms {
            var searchLoc = 0
            while searchLoc < nsText.length {
                let remaining = NSRange(location: searchLoc, length: nsText.length - searchLoc)
                let match = nsText.range(of: entry.term, options: [], range: remaining)
                guard match.location != NSNotFound else { break }
                searchLoc = match.location + max(1, match.length)

                let overlaps = occupiedEntityRanges.contains { existing in
                    NSIntersectionRange(existing, match).length > 0
                }
                guard !overlaps else { continue }
                occupiedEntityRanges.append(match)

                let context = surroundingClause(in: nsText, around: match)
                let span = TextSpanAnchor.make(
                    pageIndex: pageIndex,
                    utf16Start: baseUTF16Offset + match.location,
                    utf16Length: match.length,
                    quote: entry.term,
                    paragraphText: context
                )
                anchors.append(
                    MechanicalAnchor(
                        id: anchorID(kind: entry.kind, utf16Start: span.utf16Start, surface: entry.term),
                        kind: entry.kind,
                        surfaceText: entry.term,
                        canonicalEntityID: entry.entityID,
                        span: span
                    )
                )
            }
        }

        let fullRange = NSRange(location: 0, length: nsText.length)
        if let timeRegex {
            for match in timeRegex.matches(in: text, range: fullRange) {
                let surface = nsText.substring(with: match.range)
                let context = surroundingClause(in: nsText, around: match.range)
                let span = TextSpanAnchor.make(
                    pageIndex: pageIndex,
                    utf16Start: baseUTF16Offset + match.range.location,
                    utf16Length: match.range.length,
                    quote: surface,
                    paragraphText: context
                )
                anchors.append(
                    MechanicalAnchor(
                        id: anchorID(kind: .timeMarker, utf16Start: span.utf16Start, surface: surface),
                        kind: .timeMarker,
                        surfaceText: surface,
                        canonicalEntityID: nil,
                        span: span
                    )
                )
            }
        }

        var seen = Set<String>()
        return anchors
            .filter { seen.insert($0.id).inserted }
            .sorted { lhs, rhs in
                if lhs.span.utf16Start != rhs.span.utf16Start {
                    return lhs.span.utf16Start < rhs.span.utf16Start
                }
                return lhs.id < rhs.id
            }
    }

    static func rebuildIndex(
        fromPages pages: [String],
        knownEntities: [EntityPage],
        pageSize: Int = FileStore.bodyPageSize,
        previousVersion: UInt64 = 0
    ) -> AnchorIndex {
        var allAnchors: [MechanicalAnchor] = []
        var offset = 0
        for (pageIdx, pageText) in pages.enumerated() {
            let extracted = extract(
                from: pageText,
                knownEntities: knownEntities,
                pageIndex: pageIdx,
                baseUTF16Offset: offset
            )
            allAnchors.append(contentsOf: extracted)
            offset += (pageText as NSString).length
        }
        return AnchorIndex(
            version: previousVersion + 1,
            anchors: allAnchors,
            indexedUTF16Length: offset
        )
    }

    static func appendPage(
        _ pageText: String,
        pageIndex: Int,
        baseUTF16Offset: Int,
        knownEntities: [EntityPage],
        to index: inout AnchorIndex
    ) {
        let updatedPageAnchors = extract(
            from: pageText,
            knownEntities: knownEntities,
            pageIndex: pageIndex,
            baseUTF16Offset: baseUTF16Offset
        )
        var merged = index.anchors.filter { $0.span.pageIndex != pageIndex }
        merged.append(contentsOf: updatedPageAnchors)
        merged.sort { lhs, rhs in
            if lhs.span.utf16Start != rhs.span.utf16Start {
                return lhs.span.utf16Start < rhs.span.utf16Start
            }
            return lhs.id < rhs.id
        }
        index.anchors = merged
        index.indexedUTF16Length = max(
            index.indexedUTF16Length,
            baseUTF16Offset + (pageText as NSString).length
        )
        index.version += 1
    }

    private static func anchorID(kind: AnchorKind, utf16Start: Int, surface: String) -> String {
        let hash = String(SummaryKey.sha256Hex("\(kind.rawValue):\(surface)").prefix(8))
        return "\(kind.rawValue)_\(utf16Start)_\(hash)"
    }

    private static func surroundingClause(in nsText: NSString, around range: NSRange) -> String {
        let start = max(0, range.location - 24)
        let end = min(nsText.length, range.location + range.length + 24)
        return nsText.substring(with: NSRange(location: start, length: max(0, end - start)))
    }
}
