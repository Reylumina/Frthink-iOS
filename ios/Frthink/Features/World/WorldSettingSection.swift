// 本文件负责：「世界」概览分栏 —— 刷新入口与本书资料计数。

import SwiftUI
import Foundation

struct WorldSettingSection: View {
    @Bindable var session: ProjectSession
    var isBusy: Bool
    /// 任何世界任务在跑时都禁用入口，避免点了没反馈。
    var isActionDisabled: Bool = false
    var onRefreshIncremental: () -> Void
    var onRefreshFull: () -> Void
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
            Button("增量刷新") { onRefreshIncremental() }
            Button("从头整理（重新分析全部正文）") { onRefreshFull() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 刷新

    private var refreshSection: some View {
        Section {
            Button {
                showingRefreshOptions = true
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    if isBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(Font.footnote)
                            .foregroundStyle(Theme.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("刷新人物卡")
                            .font(Font.body)
                            .foregroundStyle(.primary)
                        Text(refreshStatusLine)
                            .font(Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: Theme.Spacing.s)
                    if !isActionDisabled {
                        Image(systemName: "chevron.down")
                            .font(Font.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isActionDisabled)
            .accessibilityLabel("刷新人物卡")
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
                symbol: "person.2",
                tab: .characters
            )
            materialRow(
                "世界书",
                value: "\(session.payload.world.worldbookEntries.count) 条",
                symbol: "books.vertical",
                tab: .worldbook
            )
            materialRow(
                "事件卡",
                value: "\(session.payload.world.events.count) 张",
                symbol: "list.bullet.rectangle",
                tab: .events
            )
            materialRow(
                "剧情梗概",
                value: plotOutlineValue,
                symbol: "text.alignleft",
                tab: .rules
            )
            materialRow(
                "文风笔记",
                value: "\(WorldRuleTextKind.lineCount(of: session.payload.world.styleNotes)) 行",
                symbol: "text.magnifyingglass",
                tab: .rules
            )
            materialRow(
                "仿写模板",
                value: styleTemplateValue,
                symbol: "doc.text",
                tab: .rules
            )
            materialRow(
                "长期写作规则",
                value: WorldRuleTextKind.longTermRules.valueLabel(in: session.payload.world),
                symbol: "list.bullet",
                tab: .rules
            )
        } header: {
            AppSectionHeader(title: "这本书的资料")
        }
    }

    private var plotOutlineValue: String {
        let world = session.payload.world
        let empty = world.plotOutline
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !empty { return "已建立" }
        return world.events.isEmpty ? "未建立" : "由事件卡渲染"
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
        tab: WorldTab
    ) -> some View {
        Button {
            onOpenTab(tab)
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: symbol)
                    .font(Font.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
                Text(title)
                    .font(Font.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: Theme.Spacing.s)
                Text(value)
                    .font(Theme.numeric)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(Font.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 状态

    private var refreshStatusLine: String {
        if isBusy {
            return "正在刷新人物卡，完成前可以先去别的分栏"
        }
        let world = session.payload.world
        let total = session.manuscriptCharacterCount
        if let date = world.lastRefreshedAt {
            let stamp = date.formatted(date: .abbreviated, time: .shortened)
            // 大书模式按码点推进，进度不是「段」而是「字」。
            if world.analysisSourceCodePointCount >= WorldDigest.wholeTextCodePointThreshold {
                let total = world.analysisSourceCodePointCount
                let done = min(max(world.refreshedUpTo, 0), total)
                if world.analysisWorldRefreshComplete {
                    return "上次刷新人物卡：\(stamp) · 已分析全部 \(total.formatted()) 字"
                }
                return "上次刷新人物卡：\(stamp) · 已分析 \(done.formatted())/\(total.formatted()) 字"
            }
            let segmentCount = world.analysisSegmentCount
            let done = world.completedAnalysisSegments.count
            if segmentCount > 0 {
                if done >= segmentCount {
                    return "上次刷新人物卡：\(stamp) · 已完成全部 \(segmentCount) 段"
                }
                return "上次刷新人物卡：\(stamp) · 已完成 \(done)/\(segmentCount) 段"
            }
            if total == 0 {
                return "上次刷新人物卡：\(stamp)"
            }
            return "上次刷新人物卡：\(stamp) · 当前正文 \(total.formatted()) 字"
        }
        return total == 0 ? "还没有刷新过人物卡" : "还没有刷新过人物卡 · 当前正文 \(total.formatted()) 字"
    }
}
