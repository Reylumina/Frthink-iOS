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

/// 世界任务登记令牌的持有盒。
///
/// 令牌来自「登记这个任务之后」，而任务闭包要读它，所以用引用盒子在
/// 「登记」与「收尾」之间传递；闭包捕获的是盒子本身（`let`），不是可变局部变量。
/// 只在主线程读写。
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
                        withAnimation(.snappy(duration: 0.2)) { tab = newTab }
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
        // 概览页的刷新行自带进度与停止；其余分栏只由这一行报进度，避免同时出现两处转圈。
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

    /// 启动一个可在切书时统一取消的世界任务。
    ///
    /// 任务登记到 `AppStore`，切书时由根视图取消；只靠视图 `@State` 的话，
    /// 视图销毁后任务还在对已经被驱逐的会话落盘。
    ///
    /// 登记返回令牌，收尾时用同一个令牌调用 `finishWorldTask(for:token:)`：
    /// 切书后同一本书可能已经由新页面登记了另一个任务，旧任务只清自己那一条。
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

    /// 四类世界任务共用的入口：占位、进度、取消文案、错误上屏收在一处。
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
                // 取消有三种形状（结构化并发 / URLSession / LLMError），统一判。
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
