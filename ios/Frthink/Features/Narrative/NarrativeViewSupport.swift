// 叙事管理页面共用状态读取、领域映射与统一错误弹窗修饰器。

import Foundation
import SwiftUI

@MainActor
enum NarrativeViewSupport {

    static func loadState(
        session: ProjectSession,
        store: AppStore
    ) throws -> MaterializedNarrativeState {
        let workspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        return workspace.currentState()
    }

    static func authorityLabel(_ authority: AuthorityRank) -> String {
        switch authority {
        case .authorDirective: return "手动设定"
        case .canonProseQuote: return "正文记录"
        case .inferredByAI: return "自动提取"
        }
    }

    static func authorityTone(_ authority: AuthorityRank) -> AppTone {
        switch authority {
        case .authorDirective: return .accent
        case .canonProseQuote: return .success
        case .inferredByAI: return .warning
        }
    }

    static func entityKindLabel(_ kind: EntityKind) -> String {
        kind.displayName
    }

    enum EntityRefreshError: LocalizedError {
        case emptyManuscript
        case emptyInput

        var errorDescription: String? {
            switch self {
            case .emptyManuscript:
                return "当前正文为空，暂无可用于提取档案的内容。"
            case .emptyInput:
                return "当前文本为空，暂无可用于提取档案的内容。"
            }
        }
    }

    static func refreshEntitiesFromManuscript(
        session: ProjectSession,
        store: AppStore,
        targetKind: EntityKind? = nil
    ) async throws -> (added: Int, updated: Int) {
        let projectID = session.project.id
        let canReadByPage = session.canReadByPage
        let pageCount = session.bodyPageCount
        let fileStore = store.fileStore
        let fallbackManuscript = (canReadByPage && pageCount > 0) ? nil : session.manuscript

        let manuscriptTail = await Task.detached(priority: .userInitiated) {
            let pages = ProjectSession.loadManuscriptPages(
                projectID: projectID,
                canReadByPage: canReadByPage,
                bodyPageCount: pageCount,
                fileStore: fileStore,
                fallbackManuscript: fallbackManuscript
            )
            let combined = pages.suffix(3).joined()
            return PromptComposer.codePointTail(combined, limit: 6_000)
        }.value

        guard !manuscriptTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EntityRefreshError.emptyManuscript
        }
        return try await refreshEntitiesFromText(
            manuscriptTail,
            session: session,
            store: store,
            targetKind: targetKind
        )
    }

    static func refreshEntitiesFromText(
        _ text: String,
        session: ProjectSession,
        store: AppStore,
        targetKind: EntityKind? = nil
    ) async throws -> (added: Int, updated: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw EntityRefreshError.emptyInput
        }
        guard let provider = store.narrativeSyncProvider else {
            throw LLMError.notConfigured
        }
        let client = try store.clientForNarrativeSync()
        let workspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        let currentState = workspace.currentState()
        let existingPages = Array(currentState.entityPages.values)
        let existingFactsByEntity = Dictionary(
            grouping: currentState.activeFacts.values.filter { !$0.isRetracted },
            by: \.entityID
        )
        let excerpt = PromptComposer.codePointTail(trimmed, limit: 6_000)

        let extractionPayload = NarrativeEntityExtractor.buildExtractionPayload(
            manuscriptTail: excerpt,
            existingPages: existingPages,
            existingFactsByEntity: existingFactsByEntity,
            targetKind: targetKind
        )
        let request = LLMRequest(
            model: provider.resolvedModel,
            messages: extractionPayload.messages,
            stream: false,
            temperature: 0.2,
            maxTokens: max(provider.maxTokens, 2_048),
            thinking: false,
            failOnLength: true
        )
        let raw = try await client.complete(request)
        try Task.checkCancellation()

        let parsed = try NarrativeEntityExtractor.parseEntities(
            from: raw,
            existingPages: existingPages,
            targetKind: targetKind,
            idMapping: extractionPayload.mapping
        )
        if !parsed.upserts.isEmpty {
            _ = try session.commitNarrativeDelta(
                PlotNodeDelta(entityPageReplacements: parsed.upserts),
                summary: "更新档案",
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
        }
        return (parsed.added, parsed.updated)
    }

    // MARK: - 核查与规则同步辅助

    private static let dismissedAuditPrefix = "frthink.narrative.auditDismissed."

    static func dismissedAuditFindingIDs(for projectID: String) -> Set<String> {
        let key = dismissedAuditPrefix + projectID
        let list = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(list)
    }

    static func dismissAuditFinding(_ findingID: String, projectID: String) {
        let key = dismissedAuditPrefix + projectID
        var set = dismissedAuditFindingIDs(for: projectID)
        guard set.insert(findingID).inserted else { return }
        UserDefaults.standard.set(Array(set).sorted(), forKey: key)
    }

    static func clearDismissedAuditFindings(for projectID: String) {
        UserDefaults.standard.removeObject(forKey: dismissedAuditPrefix + projectID)
    }

    /// 精确匹配会被 `NarrativeDreamingAuditor.applyCleanup` 安全修改且不触碰角色认知的条目。
    static func isAutoSafeCleanable(
        _ finding: DreamingFinding,
        in state: MaterializedNarrativeState
    ) -> Bool {
        switch finding.kind {
        case .entityPageBloat:
            guard let page = state.entityPages[finding.targetID] else { return false }
            let hasDuplicateBoundaries = Set(page.hardBoundaries.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }).count < page.hardBoundaries.count
            return page.summary.count > 360
                || hasDuplicateBoundaries
                || page.hardBoundaries.count > 12
                || page.conflictWarnings.count > 2
        case .overdueThread:
            return state.threads[finding.targetID]?.state == .pending
        case .staleBelief, .ungroundedFact:
            return false
        }
    }

    /// 判断 `staleBelief` 是否存在更深剧情节点上的最新事实可供单条同步。
    static func canSyncLatestFact(
        for finding: DreamingFinding,
        workspace: NarrativeWorkspace
    ) -> Bool {
        guard finding.kind == .staleBelief else { return false }
        let state = workspace.currentState()
        guard let belief = state.epistemicBeliefs[finding.targetID],
              let lineage = try? workspace.storyGraph.lineage(to: workspace.storyGraph.headNodeID)
        else {
            return false
        }
        var depthByNodeID: [String: Int] = [:]
        for (idx, node) in lineage.enumerated() {
            depthByNodeID[node.id] = idx
        }
        return NarrativeDreamingAuditor.matchingLatestFact(
            for: belief,
            in: state,
            depthByNodeID: depthByNodeID
        ) != nil
    }

    /// 将手动归纳出的 `longTermRules` 文本逐条同步为全局 `AuthorDirective`（保留既有不重复）。
    @discardableResult
    static func syncLongTermRulesToDirectives(
        session: ProjectSession,
        store: AppStore
    ) -> Int {
        let raw = session.payload.world.longTermRules.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw != "暂无长期规则。" else { return 0 }

        let workspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        let activeGlobalRules = workspace.currentState().directiveLedger.directives
            .filter { $0.status == .active && $0.scope == .global }
            .flatMap { directive -> [String] in
                directive.verbatimRule
                    .split(whereSeparator: \.isNewline)
                    .map { stripRuleBullet(String($0)) }
                    .filter { !$0.isEmpty }
            }
        var existingSet = Set(activeGlobalRules)

        var additions: [AuthorDirective] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let clean = stripRuleBullet(String(line))
            guard !clean.isEmpty, existingSet.insert(clean).inserted else { continue }
            additions.append(AuthorDirective(verbatimRule: clean, scope: .global))
        }
        guard !additions.isEmpty else { return 0 }
        _ = try? session.commitNarrativeDelta(
            PlotNodeDelta(directiveAdds: additions),
            summary: "同步归纳规则",
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        return additions.count
    }

    private static func stripRuleBullet(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["- ", "* ", "• "] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return text
    }

    /// 一次性按分类与名称排序返回全部已启用档案，供编辑弹窗在初始化时缓存。
    static func sortedEnabledEntities(from session: ProjectSession) -> [EntityPage] {
        (session.narrativeWorkspace?.currentState().entityPages.values.filter(\.enabled) ?? [])
            .sorted { lhs, rhs in
                if lhs.kind.rawValue != rhs.kind.rawValue {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                return lhs.name < rhs.name
            }
    }

    static func sortedEnabledEntities(from state: MaterializedNarrativeState?) -> [EntityPage] {
        (state?.entityPages.values.filter(\.enabled) ?? [])
            .sorted { lhs, rhs in
                if lhs.kind.rawValue != rhs.kind.rawValue {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                return lhs.name < rhs.name
            }
    }

    /// 将内部英文属性槽位转换为自然可读的中文标签，去除工具感。
    static func humanFactLabel(for attribute: String) -> String {
        let trimmed = attribute.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("relation:") {
            let target = String(trimmed.dropFirst("relation:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return target.isEmpty ? "关系" : "对\(target)"
        }
        if lower.hasPrefix("possession:") {
            let target = String(trimmed.dropFirst("possession:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return target.isEmpty ? "持有" : "持有·\(target)"
        }
        if lower.hasPrefix("condition:") {
            let target = String(trimmed.dropFirst("condition:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return target.isEmpty ? "近况" : "近况·\(target)"
        }
        if lower.hasPrefix("custom:") {
            let name = String(trimmed.dropFirst("custom:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "补充设定" : name
        }
        if lower.hasPrefix("memory:") {
            return "往事"
        }
        switch lower {
        case "location": return "所在"
        case "possession": return "持有"
        case "condition": return "近况"
        case "goal": return "心念目标"
        case "status": return "眼下状态"
        case "relation": return "人际"
        case "personality": return "性情"
        case "layout": return "格局"
        case "atmosphere": return "氛围"
        case "access": return "出入"
        case "owner": return "归属"
        case "capability": return "功用"
        case "cost": return "代价"
        case "rule": return "铁律"
        case "faction": return "势力"
        case "history": return "渊源"
        case "exception": return "例外"
        case "lore": return "设定"
        default: return trimmed
        }
    }
}

/// 档案默认圆形徽章：遵循 DESIGN.md §1.4，以 44pt 系统亮色实底圆与白色符号区分四类档案。
struct EntityAvatarBadge: View {
    let kind: EntityKind
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 44

    private var tintColor: Color {
        switch kind {
        case .character: return .indigo
        case .location: return .teal
        case .artifact: return .orange
        case .lore: return .purple
        }
    }

    private var symbol: String {
        switch kind {
        case .character: return "person.fill"
        case .location: return "mappin.and.ellipse"
        case .artifact: return "shippingbox.fill"
        case .lore: return "book.closed.fill"
        }
    }

    var body: some View {
        ZStack {
            Circle().fill(tintColor)
            Image(systemName: symbol)
                .font(.body.weight(.medium))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 扁平化多选档案列表区块：复用于关键事件与伏笔编辑弹窗，消除深层嵌套并在标题实时显示已选数量。
struct NarrativeEntityPickerSection: View {
    let title: String
    let entities: [EntityPage]
    @Binding var selectedIDs: Set<String>

    private var headerTitle: String {
        selectedIDs.isEmpty ? "\(title)（可选）" : "\(title)（已选 \(selectedIDs.count)）"
    }

    var body: some View {
        Section {
            ForEach(entities) { page in
                EntityOptionRow(
                    page: page,
                    isSelected: selectedIDs.contains(page.id),
                    onToggle: { toggle(page.id) }
                )
            }
        } header: {
            AppSectionHeader(title: headerTitle)
        }
    }

    private func toggle(_ entityID: String) {
        if selectedIDs.contains(entityID) {
            selectedIDs.remove(entityID)
        } else {
            selectedIDs.insert(entityID)
        }
    }
}

private struct EntityOptionRow: View {
    let page: EntityPage
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Theme.Spacing.s) {
                Text(page.name)
                    .font(Theme.labelSmall)
                    .foregroundStyle(.primary)
                StatusPill(text: page.kind.displayName, tone: .neutral)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(Theme.labelSmall)
                        .foregroundStyle(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension Binding where Value == Bool {
    static func isPresent<T>(_ optional: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { optional.wrappedValue != nil },
            set: { if !$0 { optional.wrappedValue = nil } }
        )
    }
}

private struct NarrativeErrorAlertModifier: ViewModifier {
    let title: String
    @Binding var errorMessage: String?

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding.isPresent($errorMessage)) {
            Button("好", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

extension View {
    func narrativeErrorAlert(
        _ errorMessage: Binding<String?>,
        title: String = "操作失败"
    ) -> some View {
        modifier(NarrativeErrorAlertModifier(title: title, errorMessage: errorMessage))
    }
}
