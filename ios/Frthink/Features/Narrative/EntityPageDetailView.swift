// 设定详情页：提供冲突确认、已知事实与角色认知分离展示，以及纯文本预览。

import Foundation
import SwiftUI

struct EntityPageDetailView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession
    let entityID: String

    @State private var showMarkdown = false
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
            } else {
                Section {
                    Text("未找到该设定。")
                        .font(Theme.labelSmall)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle(page?.name ?? "设定详情")
        .navigationBarTitleDisplayMode(.inline)
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
                }
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
        Section {
            DisclosureGroup("查看纯文本", isExpanded: $showMarkdown) {
                Text(page.renderedMarkdown(resolvedFacts: facts, beliefs: beliefs))
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.vertical, Theme.Spacing.xs)
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
