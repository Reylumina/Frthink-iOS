import SwiftUI

/// 单条对话消息的上下文摘要编辑浮层：将敏感或高感官细节压成客观摘要发给模型，原对话完整保留。
struct MessagePruneSummarySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let session: ProjectSession
    let message: ChatMessage

    @State private var summaryDraft: String
    @State private var isDistilling = false
    @State private var distillTask: Task<Void, Never>?
    @State private var errorMessage: String?

    init(session: ProjectSession, message: ChatMessage) {
        self.session = session
        self.message = message
        let existing = message.prunedSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = existing.isEmpty ? Self.defaultSnippet(from: message.content) : existing
        _summaryDraft = State(initialValue: fallback)
    }

    private var trimmedDraft: String {
        summaryDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasOriginalContent: Bool {
        !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(
                        "用 1 至 2 句客观交代结果，去除感官与情绪渲染",
                        text: $summaryDraft,
                        axis: .vertical
                    )
                    .font(Theme.label)
                    .lineLimit(3...8)

                    if isDistilling {
                        AppStatusLine(kind: .progress, text: "正在提炼中性摘要…")
                    }

                    Button {
                        startDistillation()
                    } label: {
                        Label("用轻模型提炼中性摘要", systemImage: "wand.and.stars")
                    }
                    .disabled(isDistilling || !hasOriginalContent || store.narrativeSyncProvider == nil)
                } header: {
                    AppSectionHeader(title: "发给模型的前情摘要")
                } footer: {
                    Text("本地聊天记录原样保留；发送给模型时将用此处摘要替代原正文与思维链，防止前场意象反复吸引注意力。")
                        .font(Theme.metadata)
                }

                if message.contextMode != .normal {
                    Section {
                        Button("恢复发送原文") {
                            session.setMessageContextMode(.normal, for: message.id)
                            store.toast = "已恢复发送原文"
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("折叠为摘要")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton(title: "取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton(title: "保存", isEnabled: !trimmedDraft.isEmpty && !isDistilling) {
                        session.setMessageContextMode(.summaryOnly, summary: trimmedDraft, for: message.id)
                        store.toast = "已转为仅发摘要"
                        dismiss()
                    }
                }
            }
            .onDisappear {
                distillTask?.cancel()
                distillTask = nil
            }
            .narrativeErrorAlert($errorMessage)
        }
    }

    private func startDistillation() {
        guard !isDistilling else { return }
        guard let provider = store.narrativeSyncProvider else {
            errorMessage = LLMError.notConfigured.localizedDescription
            return
        }
        isDistilling = true
        let source = PromptComposer.codePointTail(message.content, limit: 3_000)
        distillTask = Task { @MainActor in
            defer {
                isDistilling = false
                distillTask = nil
            }
            do {
                let client = try store.clientForNarrativeSync()
                let request = LLMRequest(
                    model: provider.resolvedModel,
                    messages: [
                        .system("将下列小说片段或对话轮次压缩为 1 至 2 句中性客观的事实摘要（80 字以内）。只写已发生的事件、时间节点、位置变化或状态结果，剥离感官修辞与情绪渲染；只输出摘要文本。"),
                        .user(source),
                    ],
                    stream: false,
                    temperature: 0.2,
                    maxTokens: 256,
                    thinking: false,
                    failOnLength: false
                )
                let raw = try await client.complete(request)
                guard !Task.isCancelled else { return }
                let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty {
                    summaryDraft = clean
                }
            } catch {
                guard !Task.isCancelled, !error.isLLMCancellation else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private static func defaultSnippet(from content: String) -> String {
        let singleLine = content
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
        if singleLine.count <= 60 {
            return singleLine
        }
        return String(singleLine.prefix(60)) + "…"
    }
}

/// 换场起点配置浮层：非破坏性隔离前场正文原文与旧场检索，让新场生成专注于当前上下文。
struct SceneBoundarySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let session: ProjectSession
    let cursorOffset: Int
    let cursorPlaced: Bool

    private var boundaryLabel: String {
        guard let boundary = session.payload.sceneBoundaryOffset, boundary > 0 else {
            return "不限（按正文窗口发送）"
        }
        return "第 \(boundary.formatted()) 字起"
    }

    private var canSetCursorBoundary: Bool {
        cursorPlaced && cursorOffset > 0 && cursorOffset < session.manuscriptLength
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AppValueRow(title: "当前换场起点", value: boundaryLabel)

                    Button("将正文末尾设为新场起点") {
                        session.setSceneBoundaryOffset(session.manuscriptLength)
                        store.toast = "已将正文末尾设为新场起点"
                    }
                    .disabled(
                        session.manuscriptLength == 0
                            || session.payload.sceneBoundaryOffset == session.manuscriptLength
                    )

                    if canSetCursorBoundary {
                        Button("将当前光标位置（第 \(cursorOffset.formatted()) 字）设为起点") {
                            session.setSceneBoundaryOffset(cursorOffset)
                            store.toast = "已将光标处设为本场起点"
                        }
                        .disabled(session.payload.sceneBoundaryOffset == cursorOffset)
                    }

                    if session.payload.sceneBoundaryOffset != nil {
                        Button("取消换场起点") {
                            session.setSceneBoundaryOffset(nil)
                            store.toast = "已取消换场起点"
                        }
                    }
                } header: {
                    AppSectionHeader(title: "换场隔离前文")
                } footer: {
                    Text("设置起点后，仅将起点之后的新场正文原文与检索纳入活跃写作窗口；此前章节改由摘要与档案承接，不改动原稿。")
                        .font(Theme.metadata)
                }
            }
            .navigationTitle("换场起点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
