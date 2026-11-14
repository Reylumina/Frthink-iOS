// 本文件负责：正文选区的改写弹层。
//
// 选中一段 → 输入要求 → 流式改写 → 只替换这一段，其余正文和码字机气泡都不动。

import SwiftUI

struct ManuscriptRewriteSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @Bindable var session: ProjectSession
    let range: NSRange
    let selectedText: String
    @Binding var cursor: Int

    @State private var instruction = ""
    @State private var result = ""
    /// 流式增量先落这里，约 60ms 合并一次到结果框，避免逐 token 重排。
    @State private var streamBuffer = ""
    @State private var lastFlush = Date.distantPast
    @State private var isRunning = false
    @State private var errorText: String?
    @State private var task: Task<Void, Never>?
    /// 每轮改写一个 token；停止后立刻再开始时，旧任务的收尾不会把新任务的状态抹掉。
    @State private var runID = UUID()
    /// 有草稿或结果时关闭前确认放弃（§5.8）。
    @State private var showDiscardConfirm = false

    private var trimmedResult: String {
        result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 有没有会丢的东西：未发送的要求、已经生成的结果。
    private var hasUnsavedWork: Bool {
        !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !trimmedResult.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(selectedText)
                        .font(Theme.reply)
                        .lineLimit(5)
                        .foregroundStyle(.secondary)
                    Text("\(selectedText.count.formatted()) 字")
                        .font(Font.caption)
                        .foregroundStyle(.tertiary)
                } header: {
                    AppSectionHeader(title: "选中的正文")
                }

                Section {
                    AppTextArea(
                        title: "具体要求",
                        text: $instruction,
                        placeholder: "更克制、更具体",
                        minLines: 2,
                        maxLines: 4
                    )

                    quickChipsStrip
                } header: {
                    AppSectionHeader(title: "改写要求")
                }

                if !result.isEmpty || isRunning || errorText != nil {
                    Section {
                        resultSection
                    } header: {
                        AppSectionHeader(title: "改写结果")
                    }
                }
            }
            .navigationTitle("改写选中正文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancelTapped() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    toolbarConfirmButton
                }
            }
            // 有未保存的指令或已经有生成结果时，下滑关闭会被半路丢掉；
            // 只有「取消」这条明确入口能关，关闭前再确认一次（§5.8）。
            .interactiveDismissDisabled(hasUnsavedWork || isRunning)
            .alert(
                "放弃这次改写？",
                isPresented: $showDiscardConfirm
            ) {
                Button("放弃", role: .destructive) { close() }
                Button("继续编辑", role: .cancel) {}
            }
            .onDisappear {
                task?.cancel()
            }
        }
    }

    private var quickChipsStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                quickChip("更简洁", "在不删信息的前提下压缩句子，去掉空泛修饰。")
                quickChip("更有画面感", "把抽象概括改成可感知的动作、声音和细节，不要堆形容词。")
                quickChip("更像对话", "让对话更口语、更有潜台词，不要解释情绪。")
                quickChip("只修病句", "只修语病、错别字和指代不清，尽量保留原句。")
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    @ViewBuilder
    private var toolbarConfirmButton: some View {
        if isRunning {
            Button("停止") { stop() }
        } else if trimmedResult.isEmpty {
            Button("开始改写") { start() }
                .disabled(selectedText.isEmpty)
        } else {
            Button("替换选区") { apply() }
        }
    }

    // MARK: - 结果区

    @ViewBuilder
    private var resultSection: some View {
        if isRunning {
            AppStatusLine(kind: .progress, text: "正在改写…")
        }

        if !result.isEmpty {
            TextEditor(text: $result)
                .font(Theme.reply)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 180)
                .disabled(isRunning)
        }

        if let errorText {
            AppStatusLine(kind: .failure, text: errorText)
        }
    }

    // MARK: - 快捷要求

    private func quickChip(_ title: String, _ prompt: String) -> some View {
        Button(title) {
            appendPrompt(prompt)
        }
        .font(Font.caption)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    /// 快捷要求追加而不是覆盖：连点几条可以叠加，也能再手动删改。
    private func appendPrompt(_ prompt: String) {
        let current = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else {
            instruction = prompt
            return
        }
        guard !current.contains(prompt) else { return }
        instruction = current + "\n" + prompt
    }

    // MARK: - 流式改写

    private func start() {
        guard !isRunning else { return }
        errorText = nil
        result = ""
        streamBuffer = ""
        lastFlush = .distantPast
        isRunning = true
        let thisRun = UUID()
        runID = thisRun

        task = Task { @MainActor in
            defer {
                if runID == thisRun {
                    isRunning = false
                }
            }
            do {
                guard let provider = store.settings.activeProvider else {
                    throw LLMError.notConfigured
                }
                let client = try store.clientForActiveProvider()
                let request = LLMRequest(
                    model: provider.resolvedModel,
                    messages: [
                        .system(Self.systemPrompt),
                        .user(Self.userPrompt(selection: selectedText, instruction: instruction)),
                    ],
                    stream: true,
                    temperature: 0.2,
                    maxTokens: max(1_024, min(provider.maxTokens, 8_192)),
                    thinking: false
                )

                if provider.stream {
                    for try await event in client.stream(request) {
                        try Task.checkCancellation()
                        guard runID == thisRun else { return }
                        guard case .delta(let text) = event else { continue }
                        streamBuffer += text
                        let now = Date()
                        guard now.timeIntervalSince(lastFlush) >= 0.06 else { continue }
                        result = streamBuffer
                        lastFlush = now
                    }
                    guard runID == thisRun else { return }
                    if result != streamBuffer {
                        result = streamBuffer
                    }
                } else {
                    let complete = try await client.complete(request)
                    guard runID == thisRun else { return }
                    result = complete
                    streamBuffer = complete
                }
            } catch is CancellationError {
                // 用户停止，不需要错误提示。
            } catch {
                guard runID == thisRun else { return }
                errorText = error.localizedDescription
            }
        }
    }

    private func stop() {
        runID = UUID()
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// 「取消」：有草稿或结果时先确认放弃，否则直接关。
    private func cancelTapped() {
        if hasUnsavedWork || isRunning {
            showDiscardConfirm = true
        } else {
            close()
        }
    }

    private func close() {
        task?.cancel()
        task = nil
        dismiss()
    }

    private func apply() {
        let replacement = trimmedResult
        guard !replacement.isEmpty else { return }
        let ns = session.manuscript as NSString
        guard range.location >= 0,
              range.length >= 0,
              range.location + range.length <= ns.length
        else {
            errorText = "选区已失效"
            return
        }

        let updated = ns.replacingCharacters(in: range, with: replacement)
        session.updateManuscript(updated)
        session.noteManuscriptEdited()
        session.saveNow()
        cursor = range.location + (replacement as NSString).length
        dismiss()
    }

    private static let systemPrompt = """
    你是中文小说编辑。只改写用户给出的正文片段，严格保留原意、人物、视角、时态和段落结构。只输出改写后的正文，不要解释、不要加引号、不要 Markdown、不要复述要求。
    """

    private static func userPrompt(selection: String, instruction: String) -> String {
        let requirement = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let final = requirement.isEmpty
            ? "保留原意和人物视角，让文字更自然、更有画面感。"
            : requirement
        return """
        【改写要求】
        \(final)

        【正文片段】
        \(selection)
        """
    }
}
