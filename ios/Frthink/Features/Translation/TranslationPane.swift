import SwiftUI
import Foundation
import UIKit
import UniformTypeIdentifiers

/// 翻译面板：原文编辑/导入 → 分段 → 逐段调模型，按 `ContentHash` 复用已翻好的段落。
///
/// 缓存键是原文分段的哈希，不是段号：原文只改了一句时，其余段落照样命中缓存，
/// 不会重新请求。切段/查表这类纯逻辑在 `TranslationSegmenter` 里，这里只管界面和跑批。
///
/// 原文编辑器固定高度、自己滚动，和下方的分段列表分开，避免两层滚动抢手势。
struct TranslationPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let session: ProjectSession

    /// 当前分段结果。只在点「分段」或首次进入时重建，不跟着每个按键重算。
    @State private var plan: [TranslationSegmenter.PlannedSegment] = []
    /// 这份 plan 是按哪份原文切的，用来提示「原文已修改」。
    @State private var planSource: String = ""
    /// sourceHash -> 最新译文。命中就直接显示，不再请求。
    @State private var cache: [String: String] = [:]
    @State private var isRunning = false
    @State private var stepIndex = 0
    @State private var stepTotal = 0
    @State private var runTask: Task<Void, Never>?
    /// 每轮跑批一个 token。中止后立刻再开一轮时，旧任务的收尾不会把新任务的状态抹掉。
    @State private var runID = UUID()
    @State private var importing = false
    /// 原文编辑区高度。@ScaledMetric 让大字号下它也随内容变高，不写死。
    @ScaledMetric(relativeTo: .body) private var sourceEditorHeight: CGFloat = 160

    init(session: ProjectSession) {
        self.session = session
    }

    var body: some View {
        VStack(spacing: 0) {
            sourceSection
            Divider().overlay(Theme.separator)

            List {
                actionSection
                if !plan.isEmpty {
                    segmentSection
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .groupedPageBackground()
        .onAppear { bootstrap() }
        .onDisappear { shutdown() }
        // 翻译进行中下滑关闭会中止这一轮；用「关闭」明确退出。
        .interactiveDismissDisabled(isRunning)
        .sheetToast()
        .onChange(of: session.sourceText) { _, _ in
            session.saveSource()
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.plainText, .text, .utf8PlainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("关闭") { dismiss() }
            }
        }
    }

    // MARK: - 原文

    @MainActor
    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Text("原文")
                    .font(Font.headline)
                Spacer(minLength: 0)
                Button("导入文件") { importing = true }
                    .font(Font.footnote)
                    .buttonStyle(.borderless)
            }

            AppTextEditor(
                text: sourceBinding,
                placeholder: "粘贴原文",
                minHeight: 120
            )
            .frame(height: sourceEditorHeight)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.m)
    }

    @MainActor
    private var sourceBinding: Binding<String> {
        Binding(
            get: { session.sourceText },
            set: { session.sourceText = $0 }
        )
    }

    // MARK: - 控制条

    @MainActor
    private var actionSection: some View {
        Section {
            PrimaryActionButton(
                title: "翻译全部",
                systemImage: "character.book.closed",
                isBusy: isRunning,
                isEnabled: !isRunning && !plan.isEmpty && !pendingIndexes.isEmpty
            ) {
                start(indices: pendingIndexes, force: false)
            }

            HStack(spacing: Theme.Spacing.s) {
                Button("分段") { rebuildPlan() }
                    .buttonStyle(.bordered)

                if isRunning {
                    Button("停止", role: .destructive) { stop() }
                        .buttonStyle(.bordered)
                } else {
                    Button("重译全部") {
                        start(indices: Array(plan.indices), force: true)
                    }
                    .buttonStyle(.bordered)
                    .disabled(plan.isEmpty)
                }

                Spacer(minLength: 0)
            }

            if !plan.isEmpty {
                Text(progressLine)
                    .font(Font.caption)
                    .foregroundStyle(.secondary)
                ProgressView(
                    value: Double(translatedCount),
                    total: Double(max(plan.count, 1))
                )
                .tint(Theme.accent)
                if planSource != session.sourceText {
                    AppStatusLine(kind: .info, text: "原文已修改")
                }
            }

            if let error = store.errorMessage {
                AppStatusLine(kind: .failure, text: error)
            }
        } header: {
            AppSectionHeader(title: "翻译")
        }
    }

    private var progressLine: String {
        var line = "进度 \(translatedCount)/\(plan.count) 段"
        if isRunning {
            line += " · 正在处理第 \(min(stepIndex + 1, max(stepTotal, 1)))/\(stepTotal) 段"
        }
        return line
    }

    // MARK: - 段落

    @MainActor
    private var segmentSection: some View {
        Section {
            ForEach(plan) { item in
                segmentRow(item)
            }
        } header: {
            AppSectionHeader(title: "分段")
        }
    }

    @MainActor
    private func segmentRow(_ item: TranslationSegmenter.PlannedSegment) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                Text("第 \(item.index + 1) 段")
                    .font(Font.caption)
                    .foregroundStyle(.tertiary)
                if cache[item.hash] != nil {
                    StatusPill(text: "已缓存", tone: .success)
                }
                Spacer(minLength: 0)
                // 逐段操作是低频动作，收进一个菜单，不和一屏唯一的主操作抢注意力。
                Menu {
                    Button("重译这一段") {
                        start(indices: [item.index], force: true)
                    }
                    .disabled(isRunning)
                    if cache[item.hash] != nil {
                        Button("复制译文") { copyTranslation(of: item) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(Font.body)
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("第 \(item.index + 1) 段操作")
            }

            Text(item.text)
                .font(Theme.prose)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let translated = cache[item.hash] {
                Divider().overlay(Theme.separator)
                Text(translated)
                    .font(Theme.reply)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text(isRunning ? "等待翻译…" : "未翻译")
                    .font(Font.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    // MARK: - 派生状态

    private var translatedCount: Int {
        plan.reduce(0) { partial, item in
            partial + ((cache[item.hash]?.isEmpty == false) ? 1 : 0)
        }
    }

    private var pendingIndexes: [Int] {
        plan.filter { cache[$0.hash] == nil }.map { $0.index }
    }

    // MARK: - 生命周期

    @MainActor
    private func bootstrap() {
        if planSource != session.sourceText || plan.isEmpty {
            rebuildPlan()
        }
    }

    @MainActor
    private func shutdown() {
        runID = UUID()
        runTask?.cancel()
        runTask = nil
        isRunning = false
        session.saveSource()
        session.saveTranslations()
    }

    @MainActor
    private func rebuildPlan() {
        let current = session.sourceText
        plan = TranslationSegmenter.plan(for: current)
        planSource = current
        cache = TranslationSegmenter.cache(
            from: session.translations,
            project: session.project.id
        )
    }

    // MARK: - 导入

    @MainActor
    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            store.errorMessage = "导入失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let data = try Data(contentsOf: url)
                guard let text = String(data: data, encoding: .utf8) else {
                    store.errorMessage = "读取失败：文件不是 UTF-8 编码的纯文本。"
                    return
                }
                session.sourceText = text
                session.saveSource()
                rebuildPlan()
                store.toast = "已导入原文，共 \(plan.count) 段"
            } catch {
                store.errorMessage = "读取失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 跑批

    /// 逐段翻译。`force` 为 false 时跳过已有缓存的段。
    @MainActor
    private func start(indices: [Int], force: Bool) {
        guard !isRunning else { return }
        let snapshot = plan
        let targets = indices.filter { $0 >= 0 && $0 < snapshot.count }
        guard !targets.isEmpty else {
            store.toast = "没有需要翻译的段落"
            return
        }
        guard let provider = store.translationProvider else {
            store.errorMessage = "还没有可用的AI服务商，请先到设置里填好服务地址和 API Key。"
            return
        }
        let client: any LLMClient
        do {
            client = try store.clientForTranslation()
        } catch {
            store.errorMessage = error.localizedDescription
            return
        }

        let owner = store.settings.ownerID
        let projectID = session.project.id
        let model = provider.resolvedModel
        let temperature = provider.temperature
        let maxTokens = provider.maxTokens

        store.errorMessage = nil
        isRunning = true
        stepIndex = 0
        stepTotal = targets.count
        let thisRun = UUID()
        runID = thisRun

        runTask = Task { @MainActor in
            var translated = 0
            for (offset, index) in targets.enumerated() {
                if Task.isCancelled || runID != thisRun { break }
                stepIndex = offset
                let item = snapshot[index]

                if !force, let cachedText = cache[item.hash], !cachedText.isEmpty {
                    continue
                }

                let request = LLMRequest(
                    model: model,
                    messages: PromptComposer.translationMessages(item.text),
                    stream: false,
                    temperature: temperature,
                    maxTokens: maxTokens
                )
                do {
                    let raw = try await client.complete(request)
                    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.isEmpty {
                        store.errorMessage = "第 \(index + 1) 段返回了空译文。"
                        continue
                    }
                    apply(text, to: item, owner: owner, projectID: projectID)
                    translated += 1
                    session.saveTranslations()
                } catch {
                    if Task.isCancelled || runID != thisRun { break }
                    store.errorMessage = "第 \(index + 1) 段翻译失败：\(error.localizedDescription)"
                    break
                }
            }

            session.saveTranslations()
            // 被中止或被新的一轮顶掉时，状态归新任务管，这里不要再动。
            guard runID == thisRun else { return }
            isRunning = false
            runTask = nil
            if !Task.isCancelled {
                store.toast = translated > 0 ? "翻译完成：新增 \(translated) 段" : "没有新的段落需要翻译"
            }
        }
    }

    @MainActor
    private func stop() {
        runID = UUID()
        runTask?.cancel()
        runTask = nil
        isRunning = false
        session.saveTranslations()
        store.toast = "已中止翻译"
    }

    /// 写回一段译文：同一个 owner/project/target/段号就覆盖，否则追加。
    @MainActor
    private func apply(
        _ text: String,
        to item: TranslationSegmenter.PlannedSegment,
        owner: String,
        projectID: String
    ) {
        cache[item.hash] = text
        let target = TranslationSegmenter.target
        if let position = session.translations.firstIndex(where: {
            $0.owner == owner
                && $0.project == projectID
                && $0.target == target
                && $0.segment == item.index
        }) {
            session.translations[position].sourceHash = item.hash
            session.translations[position].payload = text
            session.translations[position].updatedAt = Date()
        } else {
            session.translations.append(
                TranslationSegment(
                    owner: owner,
                    project: projectID,
                    target: target,
                    sourceHash: item.hash,
                    segment: item.index,
                    payload: text
                )
            )
        }
    }

    @MainActor
    private func copyTranslation(of item: TranslationSegmenter.PlannedSegment) {
        guard let text = cache[item.hash], !text.isEmpty else { return }
        UIPasteboard.general.string = text
        store.toast = "已复制第 \(item.index + 1) 段译文"
    }
}
