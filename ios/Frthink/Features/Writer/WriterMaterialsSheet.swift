// 写作资料浮层：展示项目正文、人物卡与世界书体量，以及注入提示词的相关资料。

import SwiftUI

struct WriterMaterialsSheet: View {
    let session: ProjectSession

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                bookSection
                promptMaterialsSection
                continuationSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .groupedPageBackground()
            .navigationTitle("写作资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var bookSection: some View {
        Section {
            AppValueRow(
                title: "正文",
                value: "\(session.manuscriptCharacterCount.formatted()) 字"
            )
            AppValueRow(
                title: "章节",
                value: "\(session.payload.chapters.count) 章"
            )
            AppValueRow(
                title: "人物卡",
                value: "\(session.payload.world.characters.count) 张"
            )
            AppValueRow(
                title: "世界书",
                value: "\(session.payload.world.worldbookEntries.count) 条"
            )
            AppValueRow(
                title: "事件卡",
                value: "\(session.payload.world.events.count) 张"
            )
            AppValueRow(
                title: "原文",
                value: session.sourceText.isEmpty
                    ? "未导入"
                    : "\(session.sourceText.count.formatted()) 字"
            )
        } header: {
            AppSectionHeader(title: "这本书")
        }
    }

    private var promptMaterialsSection: some View {
        Section {
            materialLink(
                title: "世界状态",
                symbol: "globe.asia.australia",
                text: session.payload.world.currentState
            )
            materialLink(
                title: "仿写模板",
                symbol: "doc.on.doc",
                text: session.payload.world.styleTemplate
            )
            materialLink(
                title: "剧情梗概",
                symbol: "list.bullet.rectangle",
                text: session.payload.world.plotOutline
            )
            materialLink(
                title: "长期写作规则",
                symbol: "text.badge.checkmark",
                text: session.payload.world.longTermRules
            )
            materialLink(
                title: "项目补充指令",
                symbol: "text.append",
                text: session.payload.assistantSupplement
            )
        } header: {
            AppSectionHeader(title: "会写进提示词")
        }
    }

    private var continuationSection: some View {
        Section {
            AppValueRow(
                title: "正文发送范围",
                value: session.payload.bodyPromptSendWhole
                    ? "整篇正文"
                    : "末尾 \(session.payload.bodyPromptTailCodePoints.formatted()) 字"
            )
            if let anchor = session.payload.continuationAnchor {
                AppValueRow(title: "续写锚点", value: "第 \(anchor.formatted()) 字处")
            } else {
                AppValueRow(title: "续写锚点", value: "正文末尾")
            }
            AppValueRow(
                title: "提示词回看",
                value: "\(session.payload.requestSnapshots.count) 条记录"
            )
        } header: {
            AppSectionHeader(title: "续写")
        }
    }

    private func materialLink(
        title: String,
        symbol: String,
        text: String
    ) -> some View {
        NavigationLink {
            MaterialTextDetail(title: title, text: text)
        } label: {
            AppSettingsRow(
                title: title,
                symbol: symbol,
                detail: materialDetail(text)
            )
        }
    }

    private func materialDetail(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "未填写"
            : "\(text.count) 字"
    }
}

/// 资料全文只读预览视图，支持文本选择。
private struct MaterialTextDetail: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Group {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("未填写")
                        .font(Font.subheadline)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(text)
                        .font(Theme.prose)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Theme.Spacing.l)
        }
        .pageBackground()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
