// 「世界」面板：概览 / 世界书 / 人物 / 事件 / 规则五个分栏。

import SwiftUI
import Foundation

enum WorldTab: String, CaseIterable, Identifiable, Hashable {
    case setting = "概览"
    case worldbook = "世界书"
    case characters = "人物卡"
    case events = "事件卡"
    case rules = "模板与规则"

    var id: String { rawValue }

    /// 分栏控件上的短标签：五个中文全称并排会挤成一团。
    var shortTitle: String {
        switch self {
        case .setting: return "概览"
        case .worldbook: return "世界书"
        case .characters: return "人物"
        case .events: return "事件"
        case .rules: return "规则"
        }
    }
}

enum WorldBusy: Equatable {
    case refreshingWorld
    case extractingEvents
    case extractingStyleNotes
    case updatingRules

    var label: String {
        switch self {
        case .refreshingWorld: return "正在刷新人物卡…"
        case .extractingEvents: return "正在抽取事件卡…"
        case .extractingStyleNotes: return "正在提炼文风笔记…"
        case .updatingRules: return "正在整理长期规则…"
        }
    }
}

struct WorldPane: View {
    @Environment(AppStore.self) private var store
    let session: ProjectSession

    @State private var tab: WorldTab = .setting
    @State private var busy: WorldBusy? = nil
    @State private var progressText = ""
    @State private var statusMessage: String? = nil
    @State private var lastRawResponse: String? = nil
    @State private var showingRawResponse = false
    @State private var worldTask: Task<Void, Never>?

    /// 各分栏只感知自己的任务；全局状态条仍显示当前运行的任务。
    private var isWorldRefreshing: Bool { busy == .refreshingWorld }
    private var isExtractingEvents: Bool { busy == .extractingEvents }
    private var isRulesBusy: Bool {
        busy == .extractingStyleNotes || busy == .updatingRules
    }

    /// 状态行最小高度，跟随 Dynamic Type。
    @ScaledMetric(relativeTo: .footnote) private var statusSlotHeight: CGFloat = 36

    init(session: ProjectSession) {
        self.session = session
        #if DEBUG
        // 截图流水线：`-worldTab setting|worldbook|characters|events|rules` 直接落到分栏。
        if let launch = WorldPane.launchTab {
            _tab = State(initialValue: launch)
        }
        #endif
    }

    #if DEBUG
    private static var launchTab: WorldTab? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-worldTab"), index + 1 < args.count
        else { return nil }
        switch args[index + 1] {
        case "setting": return .setting
        case "worldbook": return .worldbook
        case "characters": return .characters
        case "events": return .events
        case "rules": return .rules
        default: return nil
        }
    }
    #endif

    var body: some View {
        VStack(spacing: 0) {
            Picker("世界分栏", selection: $tab) {
                ForEach(WorldTab.allCases) { item in
                    Text(item.shortTitle).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)

            statusArea

            switch tab {
            case .setting:
                WorldSettingSection(
                    session: session,
                    isBusy: isWorldRefreshing,
                    isActionDisabled: busy != nil,
                    onRefreshIncremental: { startWorldRefresh(forceFull: false) },
                    onRefreshFull: { startWorldRefresh(forceFull: true) },
                    onOpenTab: { newTab in
                        withAnimation(.snappy(duration: 0.2)) { tab = newTab }
                    }
                )
            case .characters:
                WorldCharactersSection(session: session)
            case .worldbook:
                // 世界书词条是独立的键值清单，和「世界设定」那一整段正文不是一回事。
                WorldbookPane(session: session)
            case .events:
                WorldEventsSection(
                    session: session,
                    isBusy: isExtractingEvents,
                    isActionDisabled: busy != nil,
                    onExtract: startEventExtraction
                )
            case .rules:
                WorldRulesSection(
                    session: session,
                    isBusy: isRulesBusy,
                    isActionDisabled: busy != nil,
                    onExtractStyleNotes: startStyleNoteExtraction,
                    onUpdateRules: startLongTermRuleUpdate
                )
            }
        }
        .groupedPageBackground()
        .onDisappear {
            session.scheduleSave()
        }
        .sheet(isPresented: $showingRawResponse) {
            WorldRawResponseSheet(text: lastRawResponse ?? "")
        }
    }

    // MARK: - 状态条

    /// 有任务、有回执或能看原始响应时才占位；空闲时不预留空白行。
    @ViewBuilder
    private var statusArea: some View {
        if busy != nil || statusMessage != nil || lastRawResponse != nil {
            HStack(spacing: Theme.Spacing.s) {
                statusIcon
                    .frame(width: 16)

                if busy == nil, statusMessage == nil, lastRawResponse != nil {
                    Button {
                        showingRawResponse = true
                    } label: {
                        HStack(spacing: Theme.Spacing.s) {
                            Text("查看上一次原始响应")
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(Font.caption2.weight(.semibold))
                        }
                        .font(Font.footnote)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(statusText)
                        .font(Font.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: Theme.Spacing.s)

                    if busy != nil, worldTask != nil {
                        Button("停止") {
                            worldTask?.cancel()
                        }
                        .font(Font.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                    } else if statusMessage != nil {
                        Button {
                            self.statusMessage = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(Font.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("关闭提示")
                    }
                }
            }
            .frame(minHeight: statusSlotHeight)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xs)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if busy != nil {
            ProgressView().controlSize(.mini)
        } else if statusMessage != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        // 任务进行中被拒绝的操作也要有反馈，优先显示刚写入的状态文案。
        if let statusMessage, !statusMessage.isEmpty { return statusMessage }
        if let busy { return progressText.isEmpty ? busy.label : progressText }
        return ""
    }

    // MARK: - 世界刷新

    private func startWorldRefresh(forceFull: Bool) {
        guard busy == nil else {
            statusMessage = "当前任务还没结束，请稍候。"
            return
        }
        busy = .refreshingWorld
        progressText = "正在准备正文…"
        statusMessage = nil
        worldTask = Task { @MainActor in
            await self.runWorldRefresh(forceFull: forceFull)
            self.worldTask = nil
        }
    }

    @MainActor
    private func runWorldRefresh(forceFull: Bool) async {
        do {
            let outcome = try await WorldWorkflow.refreshWorld(
                session: session,
                store: store,
                forceFull: forceFull,
                progress: { current, total in
                    self.progressText = total > 1
                        ? "正在整理第 \(current)/\(total) 段正文…"
                        : "正在分析正文…"
                }
            )
            statusMessage = outcome.summary
        } catch is CancellationError {
            statusMessage = "已停止刷新；已完成的段已保留。"
        } catch {
            handle(error)
        }
        busy = nil
        progressText = ""
    }

    // MARK: - 事件卡

    private func startEventExtraction() {
        guard busy == nil else {
            statusMessage = "当前任务还没结束，请稍候。"
            return
        }
        busy = .extractingEvents
        progressText = ""
        statusMessage = nil
        worldTask = Task { @MainActor in
            await self.runEventExtraction()
            self.worldTask = nil
        }
    }

    @MainActor
    private func runEventExtraction() async {
        do {
            let outcome = try await WorldMaterialWorkflow.extractEvents(
                session: session,
                store: store
            )
            statusMessage = outcome.summary
        } catch is CancellationError {
            statusMessage = "已停止抽取；已完成的段已保留。"
        } catch {
            handle(error)
        }
        busy = nil
    }

    // MARK: - 文风笔记

    private func startStyleNoteExtraction() {
        guard busy == nil else {
            statusMessage = "当前任务还没结束，请稍候。"
            return
        }
        busy = .extractingStyleNotes
        progressText = ""
        statusMessage = nil
        worldTask = Task { @MainActor in
            await self.runStyleNoteExtraction()
            self.worldTask = nil
        }
    }

    @MainActor
    private func runStyleNoteExtraction() async {
        do {
            let outcome = try await WorldMaterialWorkflow.extractStyleNotes(
                session: session,
                store: store
            )
            statusMessage = outcome.summary
        } catch is CancellationError {
            statusMessage = "已停止提炼；已完成的笔记已保留。"
        } catch {
            handle(error)
        }
        busy = nil
    }

    // MARK: - 长期规则

    private func startLongTermRuleUpdate() {
        guard busy == nil else {
            statusMessage = "当前任务还没结束，请稍候。"
            return
        }
        busy = .updatingRules
        progressText = ""
        statusMessage = nil
        worldTask = Task { @MainActor in
            await self.runLongTermRuleUpdate()
            self.worldTask = nil
        }
    }

    @MainActor
    private func runLongTermRuleUpdate() async {
        do {
            let outcome = try await WorldRulesWorkflow.updateLongTermRules(
                session: session,
                store: store
            )
            statusMessage = outcome.summary
        } catch is CancellationError {
            statusMessage = "已停止更新长期规则。"
        } catch {
            handle(error)
        }
        busy = nil
    }

    // MARK: - 错误

    @MainActor
    private func handle(_ error: Error) {
        if let runError = error as? WorldRunError {
            var message = runError.message
            if let raw = runError.rawResponse, !raw.isEmpty {
                lastRawResponse = raw
                message += "\n\n原始响应片段：\n" + WorldJSON.snippet(raw, limit: 240)
            }
            store.errorMessage = message
        } else {
            store.errorMessage = error.localizedDescription
        }
    }
}

/// 世界面板出错时展示模型原始响应的弹窗。
struct WorldRawResponseSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.isEmpty ? "（没有保存下来的原始响应）" : text)
                    .font(Theme.numeric)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Spacing.l)
            }
            .pageBackground()
            .navigationTitle("原始响应")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}
