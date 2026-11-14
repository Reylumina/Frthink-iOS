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

    /// 分栏控件紧凑标签文本。
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

/// 世界任务登记令牌的持有盒。
///
/// 用于在任务注册与生命周期结束间传递令牌，避免闭包捕获局部可变状态。
private final class WorldTaskToken {
    var value: UUID?
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

    /// 状态行最小高度，跟随 Dynamic Type。
    @ScaledMetric(relativeTo: .footnote) private var statusSlotHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .footnote) private var statusIconWidth: CGFloat = 16

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
        switch LaunchArguments.worldTab {
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
                    onOpenTab: { newTab in
                        withAnimation(Theme.motionSelection) { tab = newTab }
                    }
                )
            case .characters:
                WorldCharactersSection(
                    session: session,
                    isActionDisabled: busy != nil,
                    onRefresh: { startWorldRefresh(forceFull: false) },
                    onRefreshFull: { startWorldRefresh(forceFull: true) }
                )
            case .worldbook:
                // 世界书词条为结构化清单配置，独立于世界设定正文。
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
                    busy: busy,
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
        // 概览分栏内建刷新与终止控制；其余分栏由该状态行统一展示进度。
        if isWorldRefreshing, tab == .setting {
            EmptyView()
        } else if busy != nil || statusMessage != nil || lastRawResponse != nil {
            HStack(spacing: Theme.Spacing.s) {
                statusIcon
                    .frame(width: statusIconWidth)
                statusContent
            }
            .frame(minHeight: statusSlotHeight)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xs)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if busy == nil, statusMessage == nil, lastRawResponse != nil {
            rawResponseButton
        } else {
            Text(statusText)
                .font(Font.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: Theme.Spacing.s)
            statusTrailingAction
        }
    }

    private var rawResponseButton: some View {
        Button {
            showingRawResponse = true
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Text("查看上一次原始响应")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
            }
            .font(Font.footnote)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var statusTrailingAction: some View {
        if busy != nil, worldTask != nil {
            Button("停止") {
                worldTask?.cancel()
            }
            .font(Font.footnote.weight(.semibold))
            .buttonStyle(.borderless)
            .frame(minHeight: Theme.Layout.hitTarget)
            .contentShape(Rectangle())
        } else if statusMessage != nil {
            Button {
                self.statusMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(Font.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: Theme.Layout.hitTarget, height: Theme.Layout.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("关闭提示")
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        if busy != nil {
            ProgressView().controlSize(.mini)
        } else if statusMessage != nil {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppTone.success.color)
        } else {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        // 优先显示最新的状态提示文本。
        if let statusMessage, !statusMessage.isEmpty { return statusMessage }
        if let busy { return progressText.isEmpty ? busy.label : progressText }
        return ""
    }

    // MARK: - 世界刷新

    /// 启动一个可在切书时统一取消的世界任务。
    ///
    /// 任务注册至 `AppStore` 集中调度，切换项目时支持全局统一取消，防止视图销毁后残留后台写入。
    /// 注册生成的专属令牌用于任务注销校验，保证多任务并发时状态隔离。
    private func startTrackedTask(_ work: @escaping @MainActor () async -> Void) {
        // 令牌要在任务闭包里读，而它来自「登记这个任务之后」；用一个引用盒子
        // 传递，避免闭包捕获可变的局部变量。
        let token = WorldTaskToken()
        let task = Task { @MainActor in
            await work()
            self.worldTask = nil
            if let value = token.value {
                self.store.finishWorldTask(
                    for: self.session.project.id,
                    token: value
                )
            }
        }
        worldTask = task
        token.value = store.registerWorldTask(task, for: session.project.id)
    }

    /// 统一的世界任务调度入口：集中管理运行状态、进度反馈、取消处理与异常展示。
    private func startWorldTask(
        kind: WorldBusy,
        cancelled: String,
        operation: @escaping @MainActor () async throws -> String
    ) {
        guard busy == nil else {
            statusMessage = "当前任务还没结束，请稍候。"
            return
        }
        busy = kind
        progressText = ""
        statusMessage = nil
        startTrackedTask {
            do {
                self.statusMessage = try await operation()
            } catch {
                // 统一判定各类取消异常（结构化并发、网络层与模型客户端取消）。
                if error.isLLMCancellation {
                    self.statusMessage = cancelled
                } else {
                    self.handle(error)
                }
            }
            self.busy = nil
            self.progressText = ""
        }
    }

    private func startWorldRefresh(forceFull: Bool) {
        startWorldTask(
            kind: .refreshingWorld,
            cancelled: "已停止刷新；已完成的段已保留。"
        ) {
            let outcome = try await WorldWorkflow.refreshWorld(
                session: self.session,
                store: self.store,
                forceFull: forceFull,
                progress: { current, total in
                    self.progressText = total > 1
                        ? "正在整理第 \(current)/\(total) 段正文…"
                        : "正在分析正文…"
                }
            )
            return outcome.summary
        }
    }

    private func startEventExtraction() {
        startWorldTask(
            kind: .extractingEvents,
            cancelled: "已停止抽取；已完成的段已保留。"
        ) {
            let outcome = try await WorldMaterialWorkflow.extractEvents(
                session: self.session,
                store: self.store
            )
            return outcome.summary
        }
    }

    private func startStyleNoteExtraction() {
        startWorldTask(
            kind: .extractingStyleNotes,
            cancelled: "已停止提炼；已完成的笔记已保留。"
        ) {
            let outcome = try await WorldMaterialWorkflow.extractStyleNotes(
                session: self.session,
                store: self.store
            )
            return outcome.summary
        }
    }

    private func startLongTermRuleUpdate() {
        startWorldTask(
            kind: .updatingRules,
            cancelled: "已停止更新长期规则。"
        ) {
            let outcome = try await WorldRulesWorkflow.updateLongTermRules(
                session: self.session,
                store: self.store
            )
            return outcome.summary
        }
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
