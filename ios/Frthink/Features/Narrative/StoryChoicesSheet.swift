// 按需分支剧情推演页：基于当前写作规则、伏笔与关键实体生成 2-3 条候选走向供作者选用或丢弃。

import Foundation
import SwiftUI

struct StoryChoicesSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let session: ProjectSession
    let onFillInstruction: (String) -> Void
    let onSendInstruction: (String) -> Void

    @State private var choices: [StoryChoice] = []
    @State private var isLoading = false
    @State private var loadTrigger = 0
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                contentSection
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .groupedPageBackground()
            .navigationTitle("剧情走向")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton(title: "关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("换一批") {
                        loadTrigger &+= 1
                    }
                    .disabled(isLoading)
                }
            }
            .task(id: loadTrigger) {
                await loadChoices()
            }
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if isLoading {
            Section {
                AppStatusLine(kind: .progress, text: "正在构思剧情走向…")
            }
        } else if let errorMessage {
            Section {
                AppStatusLine(kind: .failure, text: errorMessage)
                Button("重试") {
                    loadTrigger &+= 1
                }
            } header: {
                AppSectionHeader(title: "生成失败")
            }
        } else if choices.isEmpty {
            Section {
                InlineEmptyState(
                    symbol: "sparkles",
                    message: "暂无结果，点击右上角「换一批」重试。"
                )
            }
        } else {
            ForEach(choices) { choice in
                Section {
                    choiceCard(choice)
                }
            }
        }
    }

    private func choiceCard(_ choice: StoryChoice) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(choice.title)
                .font(Theme.labelEmphasis)
                .foregroundStyle(.primary)

            Text(choice.direction)
                .font(Theme.label)
                .foregroundStyle(.primary)

            if !choice.tensionHook.isEmpty {
                Text("看点：\(choice.tensionHook)")
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
            }

            if !choice.involvedEntityIDs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(choice.involvedEntityIDs, id: \.self) { entityID in
                            StatusPill(
                                text: resolvedEntityName(entityID),
                                tone: .neutral
                            )
                        }
                    }
                }
            }

            HStack(spacing: Theme.Spacing.m) {
                Button("填入输入框") {
                    onFillInstruction(formattedInstruction(choice))
                    dismiss()
                }
                .font(Theme.labelSmall)

                Spacer(minLength: 0)

                Button("直接续写") {
                    try? session.addPlotBeat(
                        summary: "\(choice.title)：\(choice.direction)",
                        settingsCorpusLibraries: store.settings.corpusLibraries
                    )
                    onSendInstruction(formattedInstruction(choice))
                    dismiss()
                }
                .font(Theme.labelSmall.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .padding(.top, Theme.Spacing.xs)
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func resolvedEntityName(_ entityID: String) -> String {
        session.narrativeWorkspace?.entityPages[entityID]?.name ?? entityID
    }

    private func formattedInstruction(_ choice: StoryChoice) -> String {
        if choice.tensionHook.isEmpty {
            return "\(choice.title)：\(choice.direction)"
        }
        return "\(choice.title)：\(choice.direction)（\(choice.tensionHook)）"
    }

    private func loadChoices() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            choices = try await NarrativeCommitCoordinator.suggestNextChoices(
                session: session,
                store: store,
                desiredCount: 3
            )
        } catch {
            guard !Task.isCancelled, !error.isLLMCancellation else { return }
            errorMessage = error.localizedDescription
        }
    }
}
