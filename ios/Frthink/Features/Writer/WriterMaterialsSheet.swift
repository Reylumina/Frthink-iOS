// 写作资料浮层：展示项目正文、设定档案、剧情线与伏笔体量，以及注入提示词的相关资料。

import SwiftUI

struct WriterMaterialsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let session: ProjectSession

    private var liveState: MaterializedNarrativeState? {
        _ = session.narrativeRevision
        return session.narrativeWorkspace?.currentState()
    }

    private var entityCount: Int {
        liveState?.entityPages.count ?? 0
    }

    private var plotNodeCount: Int {
        _ = session.narrativeRevision
        return session.narrativeWorkspace?.storyGraph.nodes.count ?? 0
    }

    private var activeThreadCount: Int {
        liveState?.threads.values.filter { !$0.state.isTerminal }.count ?? 0
    }

    private var activeDirectivesText: String {
        let lines = (liveState?.directiveLedger.activeDirectives() ?? [])
            .map(\.verbatimRule)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return lines.joined(separator: "\n")
    }

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
            .task {
                _ = session.ensureNarrativeWorkspace(
                    settingsCorpusLibraries: store.settings.corpusLibraries
                )
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
                title: "设定档案",
                value: "\(entityCount) 项"
            )
            AppValueRow(
                title: "剧情线",
                value: "\(plotNodeCount) 幕"
            )
            AppValueRow(
                title: "待回收伏笔",
                value: "\(activeThreadCount) 条"
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
        let activeRuleCount = liveState?.directiveLedger.activeDirectives().count ?? 0
        let activeStyleTemplate = session.narrativeWorkspace?.preservedStyle.styleTemplate
            ?? session.payload.world.styleTemplate
        return Section {
            materialLink(
                title: "仿写模板",
                symbol: "doc.on.doc",
                text: activeStyleTemplate,
                detailOverride: materialDetail(activeStyleTemplate),
                rendersMarkdown: true
            )
            materialLink(
                title: "写作规则",
                symbol: "shield.lefthalf.filled",
                text: activeDirectivesText,
                detailOverride: activeRuleCount == 0 ? "未填写" : "\(activeRuleCount) 条"
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
            if let boundary = session.payload.sceneBoundaryOffset, boundary > 0 {
                AppValueRow(title: "换场起点", value: "第 \(boundary.formatted()) 字起")
            } else {
                AppValueRow(title: "换场起点", value: "不限")
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
        text: String,
        detailOverride: String,
        rendersMarkdown: Bool = false
    ) -> some View {
        NavigationLink {
            MaterialTextDetail(
                title: title,
                text: text,
                rendersMarkdown: rendersMarkdown
            )
        } label: {
            AppSettingsRow(
                title: title,
                symbol: symbol,
                detail: detailOverride
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
    var rendersMarkdown: Bool = false

    var body: some View {
        ScrollView {
            Group {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("未填写")
                        .font(Font.subheadline)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if rendersMarkdown {
                    MarkdownDocumentView(markdown: text)
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
