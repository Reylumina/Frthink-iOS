// 本文件负责：「世界」概览分栏 —— 刷新入口与本书资料计数。

import SwiftUI
import Foundation

struct WorldSettingSection: View {
    let session: ProjectSession
    /// 点资料计数直接切到对应分栏（人物卡/世界书/事件卡/规则）。
    var onOpenTab: (WorldTab) -> Void = { _ in }
    @State private var showLegacyMaterials = false

    var body: some View {
        List {
            storySection
            checkSection
            materialSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
    }

    // MARK: - 旧版资料

    private var materialSection: some View {
        Section {
            DisclosureGroup("旧版资料", isExpanded: $showLegacyMaterials) {
            materialRow(
                "人物卡",
                value: "\(session.payload.world.characters.count) 张",
                symbol: "person.text.rectangle",
                tint: .blue,
                tab: .characters
            )
            materialRow(
                "世界书",
                value: "\(session.payload.world.worldbookEntries.count) 条",
                symbol: "books.vertical",
                tint: .indigo,
                tab: .worldbook
            )
            materialRow(
                "事件卡",
                value: "\(session.payload.world.events.count) 张",
                symbol: "calendar",
                tint: .orange,
                tab: .events
            )
            materialRow(
                "文风笔记",
                value: "\(WorldRuleTextKind.lineCount(of: session.payload.world.styleNotes)) 行",
                symbol: "paintbrush.pointed",
                tint: .purple,
                tab: .rules
            )
            materialRow(
                "仿写模板",
                value: styleTemplateValue,
                symbol: "doc.on.doc",
                tint: .pink,
                tab: .rules
            )
            materialRow(
                "长期写作规则",
                value: WorldRuleTextKind.longTermRules.valueLabel(in: session.payload.world),
                symbol: "checklist",
                tint: .teal,
                tab: .rules
            )
            }
        }
    }

    // MARK: - 故事设定

    private var storySection: some View {
        let workspace = session.narrativeWorkspace
        let directivesValue = workspace.map { "\($0.directives.activeDirectives().count) 条" } ?? "未加载"
        let entitiesValue = workspace.map { "\($0.entityPages.count) 项" } ?? "未加载"
        let nodesValue = workspace.map { "\($0.storyGraph.nodes.count) 幕" } ?? "未加载"
        let threadsValue = workspace.map {
            $0.hasLiveLedgers ? "\($0.threads.values.filter { !$0.state.isTerminal }.count) 条待回收" : "查看"
        } ?? "未加载"

        return Section {
            NavigationLink {
                EntityPagesView(session: session)
            } label: {
                AppSettingsRow(
                    title: "设定档案",
                    symbol: "person.2.crop.square.stack",
                    symbolTint: .blue,
                    symbolFilled: true,
                    detail: entitiesValue
                )
            }
            NavigationLink {
                AuthorDirectivesView(session: session)
            } label: {
                AppSettingsRow(
                    title: "写作规则",
                    symbol: "shield.lefthalf.filled",
                    symbolTint: .teal,
                    symbolFilled: true,
                    detail: directivesValue
                )
            }
            NavigationLink {
                ProspectiveThreadsView(session: session)
            } label: {
                AppSettingsRow(
                    title: "伏笔",
                    symbol: "flag.2.crossed",
                    symbolTint: .orange,
                    symbolFilled: true,
                    detail: threadsValue
                )
            }
            NavigationLink {
                StoryGraphView(session: session)
            } label: {
                AppSettingsRow(
                    title: "剧情线",
                    symbol: "arrow.triangle.branch",
                    symbolTint: .indigo,
                    symbolFilled: true,
                    detail: nodesValue
                )
            }
        } header: {
            AppSectionHeader(title: "故事设定")
        }
    }

    // MARK: - 检查

    private var checkSection: some View {
        let workspace = session.narrativeWorkspace
        let lintValue: String = {
            guard let lint = workspace?.latestStyleLint else { return "未检查" }
            return lint.flaggedSpans.isEmpty ? "自然" : "\(lint.flaggedSpans.count) 处可润色"
        }()

        return Section {
            NavigationLink {
                StyleLintCardView(session: session)
            } label: {
                AppSettingsRow(
                    title: "文风检查",
                    symbol: "wand.and.stars",
                    symbolTint: .purple,
                    symbolFilled: true,
                    detail: lintValue
                )
            }
            NavigationLink {
                DreamingAuditView(session: session)
            } label: {
                AppSettingsRow(
                    title: "设定核查",
                    symbol: "checkmark.shield",
                    symbolTint: .green,
                    symbolFilled: true,
                    detail: "冲突与伏笔"
                )
            }
        } header: {
            AppSectionHeader(title: "检查")
        }
    }

    private var styleTemplateValue: String {
        session.payload.world.styleTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "未建立" : "已建立"
    }

    private func materialRow(
        _ title: String,
        value: String,
        symbol: String,
        tint: Color,
        tab: WorldTab
    ) -> some View {
        Button {
            onOpenTab(tab)
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                // 这一屏是分类入口，使用带实底方块的设置行，与设置一级列表保持一致。
                AppSettingsRow(
                    title: title,
                    symbol: symbol,
                    symbolTint: tint,
                    symbolFilled: true,
                    detail: value
                )
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
