// 规则工作台：统一收纳「仿写模板」（支持文风提炼、富文本预览与编辑）与结构化「写作规则」。

import Foundation
import SwiftUI
import UIKit

/// 规则编辑页的草稿与外部（AI 提炼）写入之间的同步判定。
///
/// 页面打开时 `draft == baseline`；仅在草稿未发生变动时接收外部更新，防止覆盖本地编辑内容。
enum WorldRuleDraftSync: Equatable {
    case adoptExternal
    case keepDraft

    static func decision(draft: String, baseline: String) -> Self {
        draft == baseline ? .adoptExternal : .keepDraft
    }
}

struct WorldRulesHubView: View {
    @Bindable var session: ProjectSession
    var isDistillingStyle: Bool = false
    var isActionDisabled: Bool = false
    var externalCreateTrigger: Int = 0
    var onDistillStyle: (_ refreshTemplate: Bool) -> Void

    @State private var showingAddRuleSheet = false

    private var trimmedTemplate: String {
        session.payload.world.styleTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasManuscriptContent: Bool {
        session.manuscriptCharacterCount > 0 || session.bodyPageCount > 0
    }

    var body: some View {
        List {
            styleTemplateSection
            AuthorDirectivesListContent(
                session: session,
                showingAddSheet: $showingAddRuleSheet
            )
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .sheet(isPresented: $showingAddRuleSheet) {
            AddAuthorDirectiveSheet(session: session)
        }
        .onChange(of: externalCreateTrigger) { _, _ in
            showingAddRuleSheet = true
        }
    }

    private var styleTemplateSection: some View {
        let template = trimmedTemplate
        return Section {
            if !template.isEmpty {
                NavigationLink {
                    StyleTemplateDetailView(
                        session: session,
                        isDistillingStyle: isDistillingStyle,
                        isActionDisabled: isActionDisabled,
                        canDistill: hasManuscriptContent,
                        onDistillStyle: { onDistillStyle(true) }
                    )
                } label: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        HStack(spacing: Theme.Spacing.s) {
                            Text("仿写模板")
                                .font(Theme.labelEmphasis)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Text("\(template.count.formatted()) 字")
                                .font(Theme.numericSmall)
                                .foregroundStyle(.secondary)
                        }
                        Text(previewText(for: template))
                            .font(Theme.labelSmall)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            } else {
                if isDistillingStyle {
                    AppStatusLine(kind: .progress, text: "正在提炼文风…")
                }

                Button {
                    onDistillStyle(false)
                } label: {
                    SettingsLabelRow(
                        title: "从正文提炼文风",
                        detail: hasManuscriptContent ? "自动归纳" : "需先有正文"
                    )
                }
                .disabled(isActionDisabled || !hasManuscriptContent)

                NavigationLink {
                    StyleTemplateEditorPage(session: session)
                } label: {
                    SettingsLabelRow(title: "手动填写")
                }
            }
        } header: {
            AppSectionHeader(title: "仿写模板")
        }
    }

    private func previewText(for markdown: String) -> String {
        let lines = markdown
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !MarkdownInline.isDivider($0) }
            .map { MarkdownInline.headingLevel($0) == nil ? $0 : MarkdownInline.strippingHeadingMarker($0) }
        return lines.prefix(3).joined(separator: "\n")
    }
}

/// 仿写模板详情页：富文本排版预览，右上角支持重新提炼与编辑。
struct StyleTemplateDetailView: View {
    @Environment(AppStore.self) private var store
    @Bindable var session: ProjectSession
    var isDistillingStyle: Bool
    var isActionDisabled: Bool
    var canDistill: Bool
    var onDistillStyle: () -> Void

    @State private var isEditing = false

    private var template: String {
        session.payload.world.styleTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        List {
            if isDistillingStyle {
                Section {
                    AppStatusLine(kind: .progress, text: "正在提炼文风…")
                }
            }

            Section {
                if template.isEmpty {
                    InlineEmptyState(
                        symbol: "wand.and.stars",
                        message: "暂无仿写模板。",
                        actionTitle: canDistill ? "从正文提炼文风" : "手动填写",
                        action: {
                            if canDistill {
                                onDistillStyle()
                            } else {
                                isEditing = true
                            }
                        }
                    )
                } else {
                    MarkdownDocumentView(markdown: template)
                        .padding(.vertical, Theme.Spacing.xs)

                    Button("复制模板文本") {
                        UIPasteboard.general.string = template
                        store.toast = "已复制仿写模板"
                    }
                    .font(Theme.labelSmall)
                }
            } header: {
                AppSectionHeader(title: template.isEmpty ? "内容" : "\(template.count.formatted()) 字")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle("仿写模板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("重新提炼", action: onDistillStyle)
                    .disabled(isActionDisabled || !canDistill)

                Button("编辑") {
                    isEditing = true
                }
            }
        }
        .navigationDestination(isPresented: $isEditing) {
            StyleTemplateEditorPage(session: session)
        }
    }
}

/// 仿写模板正文编辑页：离开或点完成时同步写回并更新叙事工作区。
private struct StyleTemplateEditorPage: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: ProjectSession

    @State private var draft: String
    @State private var baseline: String

    init(session: ProjectSession) {
        self.session = session
        let initial = session.payload.world.styleTemplate
        _draft = State(initialValue: initial)
        _baseline = State(initialValue: initial)
    }

    var body: some View {
        AppTextEditor(
            text: $draft,
            placeholder: "叙事视角与结构、因果推进与节奏、句式用词、对白、转场与收束……",
            minHeight: 200,
            expands: true
        )
        .padding(Theme.Spacing.l)
        .groupedPageBackground()
        .navigationTitle("编辑仿写模板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    commitDraft()
                    dismiss()
                }
            }
        }
        .onChange(of: session.payload.world.styleTemplate) { _, newValue in
            guard WorldRuleDraftSync.decision(draft: draft, baseline: baseline) == .adoptExternal else {
                return
            }
            draft = newValue
            baseline = newValue
        }
        .onDisappear {
            commitDraft()
        }
    }

    private func commitDraft() {
        guard draft != baseline else { return }
        session.payload.world.styleTemplate = draft
        baseline = draft
        session.syncWorldChangesIntoNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        session.scheduleSave()
    }
}
