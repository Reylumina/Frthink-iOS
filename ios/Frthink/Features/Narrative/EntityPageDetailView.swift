// 设定详情页：提供冲突确认、已知事实与角色认知分离展示，以及富文本档案预览。

import Foundation
import SwiftUI
import UIKit

struct EntityPageDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: ProjectSession
    let entityID: String

    @State private var showMarkdown = false
    @State private var isEditingPage = false
    @State private var showingDeleteConfirm = false
    @State private var showingAddFact = false
    @State private var newFactAttribute = ""
    @State private var newFactValue = ""
    @State private var errorMessage: String?

    private struct WarningItem: Identifiable {
        let index: Int
        let text: String
        var id: String {
            "\(index)_\(SummaryKey.sha256Hex(text).prefix(8))"
        }
    }

    private var liveState: MaterializedNarrativeState? {
        _ = session.narrativeRevision
        return session.narrativeWorkspace?.currentState()
    }

    var body: some View {
        List {
            if let page {
                if !page.conflictWarnings.isEmpty {
                    conflictSection(for: page)
                }
                overviewSection(for: page)
                factsSection
                beliefsSection
                markdownPreviewSection(for: page)
                deleteSection(for: page)
            } else {
                Section {
                    InlineEmptyState(
                        symbol: "person.2.crop.square.stack",
                        message: "未找到该设定。"
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle(page?.name ?? "设定详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if page != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("编辑") {
                        isEditingPage = true
                    }
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
            Button("保存") {
                addManualFact()
            }
            .disabled(
                newFactAttribute.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || newFactValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            Button("取消", role: .cancel) {}
        }
        .deleteConfirmationDialog(
            "删除设定「\(page?.name ?? "")」？",
            isPresented: $showingDeleteConfirm
        ) {
            session.deleteEntityPage(
                id: entityID,
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            store.toast = "已删除设定"
            dismiss()
        }
        .task {
            _ = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
        }
        .narrativeErrorAlert($errorMessage)
    }

    private var page: EntityPage? {
        liveState?.entityPages[entityID]
    }

    private var facts: [WorldFactEvent] {
        liveState?.facts(for: entityID) ?? []
    }

    private var beliefs: [EpistemicBelief] {
        liveState?.beliefs(for: entityID) ?? []
    }

    private func conflictSection(for page: EntityPage) -> some View {
        let items = page.conflictWarnings.enumerated().map { WarningItem(index: $0.offset, text: $0.element) }
        return Section {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack(spacing: Theme.Spacing.s) {
                        StatusPill(text: "有冲突", tone: .warning)
                        Spacer(minLength: 0)
                        Button("保留原设定") {
                            dismissWarning(at: item.index, in: page)
                        }
                        .font(Theme.labelSmall)
                    }
                    Text(item.text)
                        .font(Theme.labelSmall)
                        .foregroundStyle(.primary)
                }
                .padding(.vertical, Theme.Spacing.xs)
            }

            if items.count > 1 {
                Button("全部忽略") {
                    clearAllWarnings(in: page)
                }
                .font(Theme.labelSmall)
            }
        } header: {
            AppSectionHeader(title: "冲突待确认（\(items.count)）")
        }
    }

    private func overviewSection(for page: EntityPage) -> some View {
        Section {
            AppValueRow(
                title: "分类",
                value: NarrativeViewSupport.entityKindLabel(page.kind)
            )
            if !page.aliases.isEmpty {
                AppValueRow(title: "别名", value: page.aliases.joined(separator: "、"))
            }
            if !page.identity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                labeledText(title: "身份定位", value: page.identity)
            }
            if !page.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                labeledText(title: "设定摘要", value: page.summary)
            }
            if !page.voiceProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                labeledText(title: "说话风格", value: page.voiceProfile)
            }
            if !page.hardBoundaries.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("行为底线")
                        .font(Theme.metadata)
                        .foregroundStyle(.secondary)
                    ForEach(Array(page.hardBoundaries.enumerated()), id: \.offset) { _, boundary in
                        Text("• \(boundary)")
                            .font(Theme.labelSmall)
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        } header: {
            AppSectionHeader(title: "基本信息")
        }
    }

    private var factsSection: some View {
        Section {
            if facts.isEmpty {
                Text("暂无记录。")
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(facts) { fact in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        HStack(spacing: Theme.Spacing.s) {
                            Text("\(fact.attribute)：\(fact.value)")
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
                        Button("删除", role: .destructive) {
                            retractFact(fact)
                        }
                    }
                }
            }

            Button("添加事实") {
                newFactAttribute = ""
                newFactValue = ""
                showingAddFact = true
            }
        } header: {
            AppSectionHeader(title: "已知事实（\(facts.count)）")
        }
    }

    private var beliefsSection: some View {
        Section {
            if beliefs.isEmpty {
                Text("暂无记录。")
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(beliefs) { belief in
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
        } header: {
            AppSectionHeader(title: "角色认知（\(beliefs.count)）")
        }
    }

    private func markdownPreviewSection(for page: EntityPage) -> some View {
        let markdown = page.renderedMarkdown(resolvedFacts: facts, beliefs: beliefs)
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

    private func deleteSection(for page: EntityPage) -> some View {
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
                summary: "添加设定事实：\(attr)",
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
                summary: "删除设定事实：\(fact.attribute)",
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
