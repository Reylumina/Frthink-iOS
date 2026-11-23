// 每实体独立档案列表页：使用系统搜索与分类筛选查看角色、地点、物件与设定页，并按预聚合计数零开销渲染。

import Foundation
import SwiftUI

struct EntityPagesView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession

    @State private var sortedEntities: [EntityPage] = []
    @State private var factCountsByEntity: [String: Int] = [:]
    @State private var beliefCountsByEntity: [String: Int] = [:]
    @State private var searchText = ""
    @State private var selectedKind: EntityKind?
    @State private var errorMessage: String?

    private let allKinds: [EntityKind] = [.character, .location, .artifact, .lore]

    var body: some View {
        List {
            filterSection
            entitiesSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle("设定档案")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "搜索名称、别名或摘要")
        .task(id: session.narrativeRevision) {
            reloadState()
        }
        .narrativeErrorAlert($errorMessage, title: "读取失败")
    }

    private var filteredEntities: [EntityPage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return sortedEntities.filter { page in
            if let selectedKind, page.kind != selectedKind {
                return false
            }
            guard !query.isEmpty else { return true }
            return page.name.lowercased().contains(query)
                || page.aliases.contains(where: { $0.lowercased().contains(query) })
                || page.summary.lowercased().contains(query)
        }
    }

    private var filterSection: some View {
        Section {
            Picker("分类", selection: $selectedKind) {
                Text("全部").tag(EntityKind?.none)
                ForEach(allKinds, id: \.rawValue) { kind in
                    Text(NarrativeViewSupport.entityKindLabel(kind)).tag(EntityKind?.some(kind))
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var entitiesSection: some View {
        Section {
            if filteredEntities.isEmpty {
                InlineEmptyState(
                    symbol: "person.2.crop.square.stack",
                    message: "没有符合条件的设定。"
                )
            } else {
                ForEach(filteredEntities) { page in
                    NavigationLink {
                        EntityPageDetailView(session: session, entityID: page.id)
                    } label: {
                        entityRow(for: page)
                    }
                }
            }
        } header: {
            AppSectionHeader(title: "共 \(filteredEntities.count) 项")
        }
    }

    private func entityRow(for page: EntityPage) -> some View {
        let factCount = factCountsByEntity[page.id] ?? 0
        let beliefCount = beliefCountsByEntity[page.id] ?? 0

        return VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                Text(page.name)
                    .font(Theme.labelEmphasis)
                    .foregroundStyle(.primary)
                StatusPill(
                    text: NarrativeViewSupport.entityKindLabel(page.kind),
                    tone: .neutral
                )
                if !page.enabled {
                    StatusPill(text: "已停用", tone: .neutral)
                }
                Spacer(minLength: 0)
                if !page.conflictWarnings.isEmpty {
                    StatusPill(
                        text: "\(page.conflictWarnings.count) 条待确认",
                        tone: .warning
                    )
                }
            }

            if !page.aliases.isEmpty {
                Text("别名：" + page.aliases.joined(separator: "、"))
                    .font(Theme.metadata)
                    .foregroundStyle(.secondary)
            }

            if !page.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(page.summary)
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Text("已知事实 \(factCount) 条 · 角色认知 \(beliefCount) 条")
                .font(Theme.numericSmall)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func reloadState() {
        do {
            let state = try NarrativeViewSupport.loadState(session: session, store: store)
            sortedEntities = state.entityPages.values.sorted { lhs, rhs in
                if lhs.conflictWarnings.count != rhs.conflictWarnings.count {
                    return lhs.conflictWarnings.count > rhs.conflictWarnings.count
                }
                if lhs.kind.rawValue != rhs.kind.rawValue {
                    return lhs.kind.rawValue < rhs.kind.rawValue
                }
                return lhs.name < rhs.name
            }

            var factCounts: [String: Int] = [:]
            for fact in state.activeFacts.values where !fact.isRetracted {
                factCounts[fact.entityID, default: 0] += 1
            }
            var beliefCounts: [String: Int] = [:]
            for belief in state.epistemicBeliefs.values {
                beliefCounts[belief.characterID, default: 0] += 1
            }
            factCountsByEntity = factCounts
            beliefCountsByEntity = beliefCounts
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
