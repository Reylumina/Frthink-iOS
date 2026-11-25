// 旁白去模板化文风体检页：按语域基线检测末尾正文，并支持一键带语境跳转润色。

import Foundation
import SwiftUI

struct StyleLintCardView: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession

    @State private var profile: StyleLintProfile = .literary
    @State private var report: StyleLintReport?
    @State private var isRunning = false
    @State private var runTrigger = 0
    @State private var hapticTrigger = 0
    @State private var rewriteTarget: RewriteTarget?
    @State private var rewriteCursor = 0
    @State private var revisionBeforeRewrite = 0

    private struct MetricItem: Identifiable {
        let key: String
        let title: String
        let hint: String
        let threshold: (StyleLintThresholds) -> Double
        var id: String { key }
    }

    private struct FlaggedSpanItem: Identifiable {
        let id: String
        let span: TextSpanAnchor
    }

    private struct RewriteTarget: Identifiable {
        let id = UUID()
        let range: NSRange
        let selectedText: String
        let instruction: String
    }

    private let metricItems: [MetricItem] = [
        MetricItem(
            key: "hollow_pronouns",
            title: "空泛修饰",
            hint: "某种、一丝、不由得等抽象垫词",
            threshold: { $0.hollowPronounsPer1K }
        ),
        MetricItem(
            key: "demonstrative_clutter",
            title: "重复指代",
            hint: "这个、那个、那一刻等冗余指示词",
            threshold: { $0.demonstrativeClutterPer1K }
        ),
        MetricItem(
            key: "contrastive_negation",
            title: "套路转折",
            hint: "“不是……而是……”等高频辩证句式",
            threshold: { $0.contrastiveNegationPer1K }
        ),
        MetricItem(
            key: "narration_em_dash",
            title: "旁白破折号",
            hint: "旁白中的解释性破折号（对话已豁免）",
            threshold: { $0.narrationEmDashPer1K }
        ),
        MetricItem(
            key: "bare_pronoun_chain",
            title: "连续裸代词",
            hint: "句首连续用“他/她/它”推进（防替代效应）",
            threshold: { $0.barePronounChainPer1K }
        ),
    ]

    private var activeThresholds: StyleLintThresholds {
        profile.thresholds
    }

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
        .navigationTitle("行文观感")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: hapticTrigger) { _, _ in
            store.settings.hapticsEnabled
        }
        .task(id: session.narrativeRevision) {
            loadLatestReport()
        }
        .task(id: runTrigger) {
            guard runTrigger > 0 else { return }
            await runLintOnTail()
        }
        .onChange(of: profile) { _, _ in
            if report != nil {
                runTrigger &+= 1
            }
        }
        .sheet(item: $rewriteTarget, onDismiss: {
            if session.manuscriptRevision != revisionBeforeRewrite {
                runTrigger &+= 1
            }
        }) { target in
            ManuscriptRewriteSheet(
                session: session,
                range: target.range,
                selectedText: target.selectedText,
                cursor: $rewriteCursor,
                initialInstruction: target.instruction
            )
        }
    }

    private var actionSection: some View {
        Section {
            if let report {
                HStack(spacing: Theme.Spacing.m) {
                    Image(systemName: report.flaggedSpans.isEmpty ? "checkmark.seal.fill" : "wand.and.stars")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(
                            report.flaggedSpans.isEmpty ? AppTone.success.color : AppTone.warning.color
                        )
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(report.flaggedSpans.isEmpty ? "读起来顺畅自然" : "发现 \(report.flaggedSpans.count) 处可顺手润色")
                            .font(Theme.labelEmphasis)
                            .foregroundStyle(.primary)
                        Text("最近检查：\(report.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(Theme.metadata)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    StatusPill(
                        text: report.flaggedSpans.isEmpty ? "自然" : "可润色",
                        tone: report.flaggedSpans.isEmpty ? .success : .warning
                    )
                }
                .padding(.vertical, Theme.Spacing.xs)
            } else {
                Text("仅检视旁白节奏（人物对白完全保留）；挑出可润色句子后，可一键带上下文顺手重写。")
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
            }

            Picker("文风尺度", selection: $profile) {
                ForEach(StyleLintProfile.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.menu)

            Button {
                runTrigger &+= 1
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Text(isRunning ? "正在通读末尾段落…" : (report == nil ? "检查末尾行文" : "重新通读末尾"))
                    if isRunning {
                        Spacer(minLength: 0)
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(session.manuscriptCharacterCount == 0 || isRunning)
        } header: {
            AppSectionHeader(title: "旁白检查（对白不计入）")
        }
    }

    private func metricsSection(_ report: StyleLintReport) -> some View {
        Section {
            ForEach(metricItems) { item in
                let value = report.metricsPer1KChars[item.key] ?? 0
                let limit = item.threshold(activeThresholds)
                let exceeded = value > limit
                let progress = limit > 0 ? min(1.0, max(0.0, value / limit)) : 0
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.s) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(Theme.label)
                                .foregroundStyle(.primary)
                            Text(item.hint)
                                .font(Theme.labelSmall)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        StatusPill(
                            text: exceeded ? "偏高" : "自然",
                            tone: exceeded ? .warning : .success
                        )
                    }

                    ProgressView(value: progress)
                        .tint(exceeded ? AppTone.warning.color : AppTone.success.color)

                    Text(String(format: "每千字 %.1f 次 · 建议不超 %.1f", value, limit))
                        .font(Theme.numericSmall)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, Theme.Spacing.xs)
            }
        } header: {
            AppSectionHeader(title: "细项节奏")
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
                Text("这段读起来自然顺畅，未见明显套话。")
                    .font(Theme.labelSmall)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        HStack(spacing: Theme.Spacing.s) {
                            StatusPill(text: item.span.quote, tone: .danger)
                            Text("第 \(item.span.pageIndex + 1) 页")
                                .font(Theme.numericSmall)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("润色这段") {
                                openRewrite(for: item.span)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        } header: {
            AppSectionHeader(title: "可润色片段（\(items.count)）")
        }
    }

    private func openRewrite(for span: TextSpanAnchor) {
        let fullText = session.manuscript
        let ns = fullText as NSString
        guard ns.length > 0 else {
            store.toast = "当前正文为空"
            return
        }

        let matchRange: NSRange?
        let directRange = NSRange(location: max(0, span.utf16Start), length: max(0, span.utf16Length))
        if directRange.location + directRange.length <= ns.length,
           !span.quote.isEmpty,
           ns.substring(with: directRange) == span.quote {
            matchRange = directRange
        } else if !span.quote.isEmpty {
            let searchStart = max(0, min(ns.length, span.utf16Start - 600))
            let searchLen = max(0, min(ns.length - searchStart, 1_400))
            let nearby = ns.range(of: span.quote, options: [], range: NSRange(location: searchStart, length: searchLen))
            if nearby.location != NSNotFound {
                matchRange = nearby
            } else {
                let fallback = ns.range(of: span.quote, options: .backwards)
                matchRange = fallback.location != NSNotFound ? fallback : nil
            }
        } else {
            matchRange = nil
        }

        guard let found = matchRange else {
            store.toast = "未在最新正文中找到该片段，建议重新检查"
            return
        }

        var paragraphRange = ns.paragraphRange(for: found)
        while paragraphRange.length > 0 {
            let lastChar = ns.character(at: paragraphRange.location + paragraphRange.length - 1)
            if lastChar == 0x000A || lastChar == 0x000D {
                paragraphRange.length -= 1
            } else {
                break
            }
        }
        guard paragraphRange.length > 0 else { return }

        let snippet = ns.substring(with: paragraphRange)
        rewriteCursor = paragraphRange.location + paragraphRange.length
        revisionBeforeRewrite = session.manuscriptRevision
        rewriteTarget = RewriteTarget(
            range: paragraphRange,
            selectedText: snippet,
            instruction: "消除「\(span.quote)」等模板化表达，改用具体动作、感官细节或白描重写；避免换用连续空洞代词或堆砌排比。"
        )
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
        let lastPageBaseOffset = pageCount > 0 ? session.pageStartOffset(for: pageCount - 1) : 0
        let prevPageBaseOffset = pageCount > 1 ? session.pageStartOffset(for: pageCount - 2) : 0
        let loadedText = canReadByPage ? "" : session.manuscript
        let thresholds = activeThresholds

        let generated = await Task.detached(priority: .userInitiated) { () -> StyleLintReport? in
            let sourceText: String
            let pageIndex: Int
            let baseOffset: Int
            if canReadByPage, pageCount > 0,
               let lastPage = fileStore.loadBodyPage(projectID, index: pageCount - 1) {
                if lastPage.count < 3_000,
                   pageCount > 1,
                   let prevPage = fileStore.loadBodyPage(projectID, index: pageCount - 2) {
                    sourceText = prevPage + lastPage
                    pageIndex = pageCount - 2
                    baseOffset = prevPageBaseOffset
                } else {
                    sourceText = lastPage
                    pageIndex = pageCount - 1
                    baseOffset = lastPageBaseOffset
                }
                let tail = PromptComposer.codePointTail(sourceText, limit: 3_000)
                guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let tailNS = tail as NSString
                let sourceNS = sourceText as NSString
                let tailOffsetInSource = max(0, sourceNS.length - tailNS.length)
                let absoluteStart = baseOffset + tailOffsetInSource
                let effectivePage = (pageIndex == pageCount - 2 && absoluteStart >= lastPageBaseOffset)
                    ? pageCount - 1
                    : pageIndex
                return ProseStyleLinter.lint(
                    tail,
                    pageIndex: effectivePage,
                    baseUTF16Offset: absoluteStart,
                    thresholds: thresholds
                )
            } else {
                sourceText = loadedText
                let tail = PromptComposer.codePointTail(sourceText, limit: 3_000)
                guard !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                let tailNS = tail as NSString
                let sourceNS = sourceText as NSString
                let tailOffset = max(0, sourceNS.length - tailNS.length)
                let fallbackPage = tailOffset / max(1, FileStore.bodyPageSize)
                return ProseStyleLinter.lint(
                    tail,
                    pageIndex: fallbackPage,
                    baseUTF16Offset: tailOffset,
                    thresholds: thresholds
                )
            }
        }.value

        guard let generated else { return }
        var workspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        workspace.latestStyleLint = generated
        session.noteNarrativeWorkspaceUpdated(workspace)
        report = generated
        hapticTrigger &+= 1
        store.toast = generated.flaggedSpans.isEmpty
            ? "行文顺畅自然，未见明显套路表达"
            : "标出 \(generated.flaggedSpans.count) 处可润色表达"
    }
}
