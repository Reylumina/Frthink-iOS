import SwiftUI
import Foundation
import UIKit
import UniformTypeIdentifiers

/// 翻译面板：原文编辑/导入 → 分段 → 逐段请求模型，基于 `ContentHash` 复用已有译文。
///
/// 缓存键采用原文分段哈希而非段落序号：原文局部调整时其余未变动段落仍命中缓存，
/// 避免重复请求。切段与查表逻辑封装于 `TranslationSegmenter`，视图层负责界面交互与批量任务调度。
///
/// 原文编辑器采用固定高度独立滚动，与分段列表分层解耦，避免嵌套滚动冲突。
struct TranslationPane: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let session: ProjectSession

    /// 当前分段结果：仅在主动触发分段或初次进入时重构，避免输入过程频繁重算。
    @State private var plan: [TranslationSegmenter.PlannedSegment] = []
    /// 记录当前分段计划对应的原文基准，用于检测原文修改状态。
    @State private var planSource: String = ""
    /// sourceHash -> 最新译文映射：命中缓存直接渲染，不发起网络请求。
    @State private var cache: [String: String] = [:]
    @State private var isRunning = false
    @State private var runTask: Task<Void, Never>?
    /// 批量任务执行标识：中断并立即重启新批次时，防止旧任务回调覆盖新状态。
    @State private var runID = UUID()
    @State private var importing = false
    /// 翻译进行中触发关闭需二次确认，防止误触中断未完成任务。
    @State private var confirmingStop = false
    /// 原文编辑区域基准高度，适配动态字体。
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
        // 任务进行中禁用手势下滑，防止意外中断批处理。
        .interactiveDismissDisabled(isRunning)
        .sheetToast()
        .onChange(of: isRunning) { _, running in
            // 批量任务自然结束或已停止时，重置停止确认弹窗状态。
            if !running { confirmingStop = false }
        }
        .onChange(of: session.sourceText) { _, _ in
            session.scheduleSourceSave()
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
                SheetCloseButton(title: "关闭") { requestClose() }
            }
        }
        .alert(
            "停止并关闭？",
            isPresented: $confirmingStop
        ) {
            Button("停止并关闭", role: .destructive) {
                stopRunningAndClose()
            }
            Button("取消", role: .cancel) {}
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
                AppStatusLine(kind: isRunning ? .progress : .info, text: progressLine)
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
        "进度 \(translatedCount.formatted())/\(plan.count.formatted()) 段"
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
                // 单段操作收拢至次级菜单，突出主操作入口。
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
                Text("未翻译")
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

    /// 关闭操作：任务执行中提示确认，空闲状态直接退出。
    @MainActor
    private func requestClose() {
        if isRunning {
            confirmingStop = true
        } else {
            dismiss()
        }
    }

    /// 停止任务并退出：保留已完成段落译文，若任务已自然完成则直接关闭。
    @MainActor
    private func stopRunningAndClose() {
        if isRunning {
            stop()
        }
        dismiss()
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
            Task {
                do {
                    let text = try await Self.readTextFile(url)
                    session.sourceText = text
                    session.saveSource()
                    rebuildPlan()
                    store.toast = "已导入原文，共 \(plan.count) 段"
                } catch {
                    store.errorMessage = "读取失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private static let maxImportBytes = 50 * SecurityScopedFileReader.bytesPerMiB

    private static func readTextFile(_ url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let data = try SecurityScopedFileReader.read(url, maxBytes: maxImportBytes) { _ in
                NSError(
                    domain: "Frthink.TranslationImport",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "原文文件过大（超过 50 MB）"]
                )
            }
            return try TextFileCodec.decode(data)
        }.value
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
            store.errorMessage = "还没有可用的 AI 服务商"
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
        let sourceSnapshot = session.sourceText

        store.errorMessage = nil
        isRunning = true
        let thisRun = UUID()
        runID = thisRun

        runTask = Task { @MainActor in
            var translated = 0
            for index in targets {
                if Task.isCancelled || runID != thisRun || session.sourceText != sourceSnapshot { break }
                let item = snapshot[index]

                if !force, let cachedText = cache[item.hash], !cachedText.isEmpty {
                    continue
                }

                let request = LLMRequest(
                    model: model,
                    messages: PromptComposer.translationMessages(item.text),
                    stream: false,
                    temperature: temperature,
                    maxTokens: maxTokens,
                    failOnLength: true
                )
                do {
                    let raw = try await client.complete(request)
                    if Task.isCancelled || runID != thisRun || session.sourceText != sourceSnapshot { break }
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
            // 任务已被取消或被新批次取代时，状态由新任务接管，直接返回。
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
        store.toast = "已停止翻译"
    }

    /// 持久化单段译文：相同 owner/project/target/段序号则覆盖，否则新增记录。
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
