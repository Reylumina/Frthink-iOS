// 档案详情页：缓存单实体快照与关联事件，扁平化冲突/事实/认知列表行。

import Foundation
import SwiftUI
import UIKit

struct EntityPageDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: ProjectSession
    let entityID: String

    @State private var page: EntityPage?
    @State private var facts: [WorldFactEvent] = []
    @State private var beliefs: [EpistemicBelief] = []
    @State private var relatedEvents: [EpisodicEvent] = []
    @State private var showMarkdown = false
    @State private var isEditingPage = false
    @State private var showingDeleteConfirm = false
    @State private var showingAddFact = false
    @State private var newFactAttribute = ""
    @State private var newFactValue = ""
    @State private var errorMessage: String?

    private struct IndexedTextItem: Identifiable {
        let index: Int
        let text: String
        var id: String {
            "\(index)_\(SummaryKey.sha256Hex(text).prefix(8))"
        }
    }

    var body: some View {
        List {
            if let page {
                heroHeaderSection(for: page)
                if !page.conflictWarnings.isEmpty {
                    conflictSection(for: page)
                }
                overviewSection(for: page)
                factsSection
                if page.kind == .character || !beliefs.isEmpty {
                    beliefsSection
                }
                if !relatedEvents.isEmpty {
                    relatedEventsSection
                }
                markdownPreviewSection(for: page)
                deleteSection
            } else {
                Section {
                    InlineEmptyState(
                        symbol: "person.2.crop.square.stack",
                        message: "暂未找到这份档案。"
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle(page?.name ?? "档案详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if page != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") { isEditingPage = true }
                }
            }
        }
        .sheet(isPresented: $isEditingPage) {
            if let page {
                EntityPageEditorSheet(
                    session: session,
                    existingPage: page,
                    initialKind: page.kind
                )
            }
        }
        .alert("添加已知事实", isPresented: $showingAddFact) {
            TextField("属性（如：所在地、持有物、状态）", text: $newFactAttribute)
            TextField("事实内容（如：钟楼顶层）", text: $newFactValue)
            Button("保存") { addManualFact() }
                .disabled(
                    newFactAttribute.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || newFactValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            Button("取消", role: .cancel) {}
        }
        .deleteConfirmationDialog(
            "删除档案「\(page?.name ?? "")」？",
            isPresented: $showingDeleteConfirm
        ) {
            session.deleteEntityPage(
                id: entityID,
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            store.toast = "已删除档案"
            dismiss()
        }
        .task(id: session.narrativeRevision) {
            _ = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            reloadSnapshot()
        }
        .narrativeErrorAlert($errorMessage)
    }

    private func reloadSnapshot() {
        guard let state = session.narrativeWorkspace?.currentState(),
              let resolved = state.entityPages[entityID] else {
            page = nil
            facts = []
            beliefs = []
            relatedEvents = []
            return
        }
        page = resolved
        facts = state.facts(for: entityID)
        beliefs = state.beliefs(for: entityID)
        relatedEvents = state.events(for: entityID)
    }

    private func conflictSection(for page: EntityPage) -> some View {
        let items = page.conflictWarnings.enumerated().map {
            IndexedTextItem(index: $0.offset, text: $0.element)
        }
        return Section {
            ForEach(items) { item in
                EntityConflictRow(text: item.text) {
                    dismissWarning(at: item.index, in: page)
                }
            }
            if items.count > 1 {
                Button("全部忽略") { clearAllWarnings(in: page) }
                    .font(Theme.labelSmall)
            }
        } header: {
            AppSectionHeader(title: "冲突待确认（\(items.count)）")
        }
    }

    private func heroHeaderSection(for page: EntityPage) -> some View {
        let subtitle = [
            page.identity.trimmingCharacters(in: .whitespacesAndNewlines),
            page.aliases.isEmpty ? "" : "又称 " + page.aliases.joined(separator: "、"),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")

        return Section {
            HStack(spacing: Theme.Spacing.m) {
                EntityAvatarBadge(kind: page.kind)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(page.name)
                            .font(Theme.heading)
                            .foregroundStyle(.primary)
                        if !page.enabled {
                            StatusPill(text: "已停用", tone: .neutral)
                        } else if page.kind == .lore, page.activationMode == .always {
                            StatusPill(text: "常驻", tone: .accent)
                        }
                    }
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(Theme.labelSmall)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Text(NarrativeViewSupport.entityKindLabel(page.kind))
                            .font(Theme.labelSmall)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    private func overviewSection(for page: EntityPage) -> some View {
        let boundaries = page.hardBoundaries.enumerated().map {
            IndexedTextItem(index: $0.offset, text: $0.element)
        }
        return Section {
            AppValueRow(
                title: "分类",
                value: NarrativeViewSupport.entityKindLabel(page.kind)
            )
            if page.kind == .lore {
                AppValueRow(title: "生效方式", value: page.activationMode.displayName)
            }
            if !page.aliases.isEmpty {
                AppValueRow(title: "别名", value: page.aliases.joined(separator: "、"))
            }
            if !page.triggerKeywords.isEmpty {
                AppValueRow(title: "触发词", value: page.triggerKeywords.joined(separator: "、"))
            }
            if !page.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                labeledText(title: page.kind.identityLabel, value: page.identity)
            }
            if !page.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                labeledText(title: page.kind.summaryLabel, value: page.summary)
            }
            if page.kind == .character,
               !page.voiceProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                labeledText(title: "说话风格", value: page.voiceProfile)
            }
            if !boundaries.isEmpty {
                boundariesBlock(title: page.kind.boundariesLabel, items: boundaries)
            }
        } header: {
            AppSectionHeader(title: "基本信息")
        }
    }

    private func boundariesBlock(title: String, items: [IndexedTextItem]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.metadata)
                .foregroundStyle(.secondary)
            ForEach(items) { item in
                Text("• \(item.text)")
                    .font(Theme.labelSmall)
                    .foregroundStyle(.primary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var factsSection: some View {
        Section {
            if facts.isEmpty {
                Text("写到相关桥段时会自动记下近况与持有物。")
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(facts) { fact in
                    EntityFactRow(fact: fact) {
                        retractFact(fact)
                    }
                }
            }

            Button("添加近况或细节") {
                newFactAttribute = ""
                newFactValue = ""
                showingAddFact = true
            }
        } header: {
            AppSectionHeader(title: "设定与近况（\(facts.count)）")
        }
    }

    private var beliefsSection: some View {
        Section {
            if beliefs.isEmpty {
                Text("暂未记下秘密知情或信息差。")
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(beliefs) { belief in
                    EntityBeliefRow(belief: belief)
                }
            }
        } header: {
            AppSectionHeader(title: "已知与盲区（\(beliefs.count)）")
        }
    }

    private var relatedEventsSection: some View {
        Section {
            ForEach(relatedEvents) { event in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.s) {
                        Text(event.title)
                            .font(Theme.label)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        StatusPill(
                            text: event.status.displayName,
                            tone: event.status == .ongoing ? .accent : .success
                        )
                    }
                    Text(event.formattedSummaryLine)
                        .font(Theme.metadata)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        } header: {
            AppSectionHeader(title: "关联关键事件（\(relatedEvents.count)）")
        }
    }

    private func markdownPreviewSection(for page: EntityPage) -> some View {
        let markdown = page.renderedMarkdown(
            resolvedFacts: facts,
            beliefs: beliefs,
            relatedEvents: relatedEvents
        )
        return Section {
            DisclosureGroup("档案预览", isExpanded: $showMarkdown) {
                MarkdownDocumentView(markdown: markdown)
                    .padding(.vertical, Theme.Spacing.xs)

                Button("复制 Markdown") {
                    UIPasteboard.general.string = markdown
                    store.toast = "已复制设定文本"
                }
                .font(Theme.labelSmall)
            }
        }
    }

    private var deleteSection: some View {
        Section {
            DestructiveActionRow(title: "删除该设定") {
                showingDeleteConfirm = true
            }
        }
    }

    private func labeledText(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.metadata)
                .foregroundStyle(.secondary)
            Text(value)
                .font(Theme.label)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func dismissWarning(at index: Int, in page: EntityPage) {
        guard page.conflictWarnings.indices.contains(index) else { return }
        var updated = page
        updated.conflictWarnings.remove(at: index)
        updated.updatedAt = Date()
        commitPageReplacement(updated, summary: "确认保留实体高权威设定")
    }

    private func clearAllWarnings(in page: EntityPage) {
        var updated = page
        updated.conflictWarnings.removeAll()
        updated.updatedAt = Date()
        commitPageReplacement(updated, summary: "清空实体待确认告警")
    }

    private func addManualFact() {
        let attr = newFactAttribute.trimmingCharacters(in: .whitespacesAndNewlines)
        let val = newFactValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attr.isEmpty, !val.isEmpty else { return }
        let headID = session.narrativeWorkspace?.storyGraph.headNodeID ?? "root"
        let event = WorldFactEvent(
            entityID: entityID,
            attribute: attr,
            value: val,
            nodeID: headID,
            authority: .authorDirective
        )
        do {
            _ = try session.commitNarrativeDelta(
                PlotNodeDelta(factEvents: [event]),
                summary: "添加档案事实：\(attr)",
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            store.toast = "已添加事实"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func retractFact(_ fact: WorldFactEvent) {
        let headID = session.narrativeWorkspace?.storyGraph.headNodeID ?? "root"
        let event = WorldFactEvent(
            entityID: entityID,
            attribute: fact.attribute,
            value: fact.value,
            nodeID: headID,
            authority: .authorDirective,
            supersedesEventID: fact.id,
            isRetracted: true
        )
        do {
            _ = try session.commitNarrativeDelta(
                PlotNodeDelta(factEvents: [event]),
                summary: "删除档案事实：\(fact.attribute)",
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            store.toast = "已删除事实"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitPageReplacement(_ updated: EntityPage, summary: String) {
        let delta = PlotNodeDelta(entityPageReplacements: [updated])
        do {
            _ = try session.commitNarrativeDelta(
                delta,
                summary: summary,
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            store.toast = "已确认"
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct EntityConflictRow: View {
    let text: String
    let onKeep: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                StatusPill(text: "有冲突", tone: .warning)
                Spacer(minLength: 0)
                Button("保留原记录", action: onKeep)
                    .font(Theme.labelSmall)
            }
            Text(text)
                .font(Theme.labelSmall)
                .foregroundStyle(.primary)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}

private struct EntityFactRow: View {
    let fact: WorldFactEvent
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                Text("\(NarrativeViewSupport.humanFactLabel(for: fact.attribute))：\(fact.value)")
                    .font(Theme.label)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                StatusPill(
                    text: NarrativeViewSupport.authorityLabel(fact.authority),
                    tone: NarrativeViewSupport.authorityTone(fact.authority)
                )
            }
            if let quote = fact.quoteAnchor?.quote, !quote.isEmpty {
                Text("原文：「\(quote)」")
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}

private struct EntityBeliefRow: View {
    let belief: EpistemicBelief

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                Text("\(belief.topic)：\(belief.believedTruth)")
                    .font(Theme.label)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                StatusPill(
                    text: belief.knowsSecret ? "已知情" : "不知情",
                    tone: belief.knowsSecret ? .accent : .neutral
                )
            }
            if let quote = belief.quoteAnchor?.quote, !quote.isEmpty {
                Text("原文：「\(quote)」")
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }
}
