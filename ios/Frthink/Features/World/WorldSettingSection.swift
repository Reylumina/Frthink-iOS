// 本文件负责：「世界」概览分栏 —— 刷新入口与本书资料计数。

import SwiftUI
import Foundation

struct WorldSettingSection: View {
    @Bindable var session: ProjectSession
    var isBusy: Bool
    /// 任何世界任务在跑时都禁用入口，避免点了没反馈。
    var isActionDisabled: Bool = false
    var onRefresh: () -> Void
    var onRefreshFull: () -> Void
    /// 刷新中从概览行直接停止，不再另占一行状态条。
    var onStop: () -> Void = {}
    /// 点资料计数直接切到对应分栏（人物卡/世界书/事件卡/规则）。
    var onOpenTab: (WorldTab) -> Void = { _ in }

    @State private var showingRefreshOptions = false

    var body: some View {
        List {
            refreshSection
            materialSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .confirmationDialog(
            "刷新人物卡",
            isPresented: $showingRefreshOptions,
            titleVisibility: .visible
        ) {
            Button("刷新人物卡") { onRefresh() }
            Button("从头整理（重新分析全部正文）") { onRefreshFull() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 刷新

    /// 状态行只占一行：图标在文字前，状态/动作在行尾（DESIGN §5.1）。
    /// 不放解释性副标题（§8.2），也不放 chevron——这一行不是导航。
    private var refreshSection: some View {
        Section {
            HStack(spacing: Theme.Spacing.s) {
                Button {
                    showingRefreshOptions = true
                } label: {
                    HStack(spacing: Theme.Spacing.m) {
                        if isBusy {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: Theme.Layout.iconTileSize, height: Theme.Layout.iconTileSize)
                        } else {
                            IconTile(symbol: "arrow.triangle.2.circlepath", tint: .green, filled: true)
                        }
                        Text("刷新人物卡")
                            .font(Theme.label)
                            .foregroundStyle(.primary)
                        Spacer(minLength: Theme.Spacing.s)
                        if !isBusy {
                            StatusPill(
                                text: refreshStatus.text,
                                tone: refreshStatus.tone
                            )
                        }
                    }
                    .frame(minHeight: Theme.Layout.hitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isActionDisabled)
                .accessibilityLabel("刷新人物卡")

                if isBusy {
                    Button("停止") { onStop() }
                        .font(Font.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                        .frame(minWidth: Theme.Layout.hitTarget, minHeight: Theme.Layout.hitTarget)
                }
            }
        } header: {
            AppSectionHeader(title: "人物卡整理")
        }
    }

    // MARK: - 这本书的资料

    private var materialSection: some View {
        Section {
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
                symbol: "list.bullet.rectangle",
                tint: .orange,
                tab: .events
            )
            materialRow(
                "文风笔记",
                value: "\(WorldRuleTextKind.lineCount(of: session.payload.world.styleNotes)) 行",
                symbol: "text.magnifyingglass",
                tint: .purple,
                tab: .rules
            )
            materialRow(
                "仿写模板",
                value: styleTemplateValue,
                symbol: "doc.text",
                tint: .pink,
                tab: .rules
            )
            materialRow(
                "长期写作规则",
                value: WorldRuleTextKind.longTermRules.valueLabel(in: session.payload.world),
                symbol: "list.bullet",
                tint: .teal,
                tab: .rules
            )
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
                // §2.4：行首用系统设置那种实底方块，每类资料固定一个色相。
                SettingsLabelRow(title: title, symbol: symbol, symbolTint: tint, detail: value)
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 状态

    /// 行尾状态只留一句能扫的：未整理 / 已整理 / 未完成（§5.1、§8.2）。
    private var refreshStatus: (text: String, tone: AppTone) {
        let world = session.payload.world
        guard world.lastRefreshedAt != nil else {
            return (text: "未整理", tone: .neutral)
        }
        return isRefreshIncomplete(world)
            ? (text: "未完成", tone: .warning)
            : (text: "已整理", tone: .neutral)
    }

    /// 上次刷新是否还有没整理完的段（大书模式看码点进度，分段模式看段数）。
    private func isRefreshIncomplete(_ world: WorldBook) -> Bool {
        if world.analysisSourceCodePointCount >= WorldDigest.wholeTextCodePointThreshold {
            return !world.analysisWorldRefreshComplete
        }
        let total = world.analysisSegmentCount
        guard total > 0 else { return false }
        let done = Set(
            world.completedAnalysisSegments.filter { $0 >= 0 && $0 < total }
        ).count
        return done < total
    }
}
