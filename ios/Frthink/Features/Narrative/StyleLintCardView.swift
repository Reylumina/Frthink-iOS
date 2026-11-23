// 旁白去模板化文风体检页：后台按页读取末尾正文执行密度检测，避免阻塞主线程或触发整书解密。

import Foundation
import SwiftUI

struct StyleLintCardView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession

    @State private var report: StyleLintReport?
    @State private var isRunning = false
    @State private var runTrigger = 0

    private struct MetricItem: Identifiable {
        let key: String
        let title: String
        let threshold: Double
        var id: String { key }
    }

    private struct FlaggedSpanItem: Identifiable {
        let id: String
        let span: TextSpanAnchor
    }

    private let metricItems: [MetricItem] = [
        MetricItem(
            key: "hollow_pronouns",
            title: "空泛修饰",
            threshold: StyleLintThresholds.literaryP90.hollowPronounsPer1K
        ),
        MetricItem(
            key: "demonstrative_clutter",
            title: "重复指代",
            threshold: StyleLintThresholds.literaryP90.demonstrativeClutterPer1K
        ),
        MetricItem(
            key: "contrastive_negation",
            title: "套路转折",
            threshold: StyleLintThresholds.literaryP90.contrastiveNegationPer1K
        ),
        MetricItem(
            key: "narration_em_dash",
            title: "旁白破折号",
            threshold: StyleLintThresholds.literaryP90.narrationEmDashPer1K
        ),
    ]

    var body: some View {
        List {
            actionSection
            if let report {
                metricsSection(report)
                flaggedSpansSection(report)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle("文风检查")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.narrativeRevision) {
            loadLatestReport()
        }
        .task(id: runTrigger) {
            guard runTrigger > 0 else { return }
            await runLintOnTail()
        }
    }

    private var actionSection: some View {
        Section {
            Button {
                runTrigger &+= 1
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Text(isRunning ? "正在检查正文末尾…" : "检查正文末尾")
                    if isRunning {
                        Spacer(minLength: 0)
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(session.manuscriptCharacterCount == 0 || isRunning)

            if let report {
                AppValueRow(
                    title: "最近检查时间",
                    value: report.checkedAt.formatted(date: .abbreviated, time: .shortened)
                )
            } else {
                Text("暂无检查记录，点击上方按钮开始检查，或在采纳正文后自动生成。")
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
            }
        } header: {
            AppSectionHeader(title: "旁白检查（不计对话）")
        }
    }

    private func metricsSection(_ report: StyleLintReport) -> some View {
        Section {
            ForEach(metricItems) { item in
                let value = report.metricsPer1KChars[item.key] ?? 0
                let exceeded = value > item.threshold
                HStack(spacing: Theme.Spacing.s) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(item.title)
                            .font(Theme.label)
                            .foregroundStyle(.primary)
                        Text(String(format: "每千字 %.1f 次（基线 %.1f）", value, item.threshold))
                            .font(Theme.numericSmall)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    StatusPill(
                        text: exceeded ? "偏高" : "自然",
                        tone: exceeded ? .warning : .success
                    )
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        } header: {
            AppSectionHeader(title: "每千字频率")
        }
    }

    private func flaggedSpansSection(_ report: StyleLintReport) -> some View {
        let items = report.flaggedSpans.enumerated().map { index, span in
            FlaggedSpanItem(
                id: "\(index)_\(span.pageIndex)_\(span.utf16Start)_\(span.paragraphHash)",
                span: span
            )
        }
        return Section {
            if items.isEmpty {
                Text("未发现明显模板化表达。")
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    HStack(spacing: Theme.Spacing.s) {
                        StatusPill(text: item.span.quote, tone: .danger)
                        Spacer(minLength: 0)
                        Text("第 \(item.span.pageIndex + 1) 页")
                            .font(Theme.numericSmall)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        } header: {
            AppSectionHeader(title: "可润色片段（\(items.count)）")
        }
    }

    private func loadLatestReport() {
        let workspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        report = workspace.latestStyleLint
    }

    private func runLintOnTail() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let fileStore = store.fileStore
        let projectID = session.project.id
        let canReadByPage = session.canReadByPage
        let pageCount = session.bodyPageCount
        let pageSize = FileStore.bodyPageSize
        let loadedText = canReadByPage ? "" : session.manuscript

        let generated = await Task.detached(priority: .userInitiated) { () -> StyleLintReport? in
            let sourceText: String
            let pageIndex: Int
            let baseOffset: Int
            if canReadByPage, pageCount > 0,
               let lastPage = fileStore.loadBodyPage(projectID, index: pageCount - 1) {
                sourceText = lastPage
                pageIndex = pageCount - 1
                baseOffset = pageIndex * pageSize
            } else {
                sourceText = loadedText
                pageIndex = 0
                baseOffset = 0
            }
            let tail = PromptComposer.codePointTail(sourceText, limit: 3_000)
            guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return ProseStyleLinter.lint(
                tail,
                pageIndex: pageIndex,
                baseUTF16Offset: baseOffset
            )
        }.value

        guard let generated else { return }
        var workspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        workspace.latestStyleLint = generated
        session.noteNarrativeWorkspaceUpdated(workspace)
        report = generated
        store.toast = generated.flaggedSpans.isEmpty
            ? "文风自然，未见明显问题"
            : "标出 \(generated.flaggedSpans.count) 处可润色表达"
    }
}
