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

    var body: some View {
        List {
            refreshSection
            materialSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
    }

    // MARK: - 刷新

    private var refreshSection: some View {
        Section {
            Menu {
                Button {
                    onRefreshIncremental()
                } label: {
                    Label("增量刷新人物卡", systemImage: "arrow.triangle.2.circlepath")
                }
                Button {
                    onRefreshFull()
                } label: {
                    Label(
                        "从头整理人物卡（本轮最多 \(WorldDigest.maxChunksPerRun) 段）",
                        systemImage: "arrow.counterclockwise"
                    )
                }
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    if isBusy {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(Font.footnote)
                            .foregroundStyle(Theme.accent)
                    }
                    Text(refreshStatusLine)
                        .font(Font.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Theme.Spacing.s)
                    if !isActionDisabled {
                        Image(systemName: "chevron.up.chevron.down")
                            .font(Font.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .disabled(isActionDisabled)
            .accessibilityLabel("刷新人物卡")
        } header: {
            AppSectionHeader(title: "刷新人物卡")
        } footer: {
            Text("只从正文整理人物卡。事件卡、剧情梗概、文风笔记和仿写模板在各自分栏单独更新。")
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
        } header: {
            AppSectionHeader(title: "这本书的资料")
        } footer: {
            Text("事件卡用「从正文抽取」，文风笔记用「从正文提炼」，长期规则用「用最近对话更新」。")
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
