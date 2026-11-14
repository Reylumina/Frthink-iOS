// 本文件负责：「世界」概览分栏 —— 刷新入口与本书资料计数。

import SwiftUI
import Foundation

struct WorldSettingSection: View {
    @Bindable var session: ProjectSession
    /// 点资料计数直接切到对应分栏（人物卡/世界书/事件卡/规则）。
    var onOpenTab: (WorldTab) -> Void = { _ in }

    var body: some View {
        // 刷新入口只留在「人物」分栏：同一页两处都能刷新，用户要先分辨
        // 「这一行刷新的是谁」。概览只负责计数与跳转。
        List {
            materialSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
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
