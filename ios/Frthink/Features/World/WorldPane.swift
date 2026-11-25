// 「世界」工作台：档案、剧情与规则三栏直出界面，以及顶栏动作和世界核查入口。

import Foundation
import SwiftUI

enum WorldTab: String, CaseIterable, Identifiable, Hashable {
    case entities = "档案"
    case plot = "剧情"
    case rules = "规则"

    var id: String { rawValue }
}

enum WorldBusy: Equatable {
    case distillingStyle
    case updatingRules

    var label: String {
        switch self {
        case .distillingStyle: return "正在提炼文风…"
        case .updatingRules: return "正在从最近对话归纳规则…"
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

    @State private var tab: WorldTab = .entities
    @State private var entityKindFilter: EntityKind? = nil
    @State private var entityCreateTrigger = 0
    @State private var entityExtractTrigger = 0
    @State private var plotBeatTrigger = 0
    @State private var plotThreadTrigger = 0
    @State private var plotForkTrigger = 0
    @State private var ruleCreateTrigger = 0

    @State private var showingAudit = false
    @State private var showingStyleLint = false
    @State private var pendingAuditCount = 0
    @State private var auditRefreshTrigger = 0

    @State private var busy: WorldBusy? = nil
    @State private var statusMessage: String? = nil
    @State private var lastRawResponse: String? = nil
    @State private var showingRawResponse = false
    @State private var worldTask: Task<Void, Never>?

    @ScaledMetric(relativeTo: .footnote) private var statusSlotHeight: CGFloat = 36
    @ScaledMetric(relativeTo: .footnote) private var statusIconWidth: CGFloat = 16

    private let allEntityKinds: [EntityKind] = [.character, .location, .artifact, .lore]

    init(session: ProjectSession) {
        self.session = session
        #if DEBUG
        if let launch = WorldPane.launchTab {
            _tab = State(initialValue: launch)
        }
        #endif
    }

    #if DEBUG
    private static var launchTab: WorldTab? {
        switch LaunchArguments.worldTab {
        case "entities", "setting", "worldbook", "characters":
            return .entities
        case "plot", "events":
            return .plot
        case "rules":
            return .rules
        default:
            return nil
        }
    }
    #endif

    private var hasManuscriptContent: Bool {
        session.manuscriptCharacterCount > 0 || session.bodyPageCount > 0
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("世界分栏", selection: $tab) {
                ForEach(WorldTab.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)

            statusArea

            switch tab {
            case .entities:
                EntityPagesView(
                    session: session,
                    embeddedInWorld: true,
                    externalSelectedKind: $entityKindFilter,
                    externalCreateTrigger: entityCreateTrigger,
                    externalExtractTrigger: entityExtractTrigger
                )
            case .plot:
                StoryGraphView(
                    session: session,
                    embeddedInWorld: true,
                    externalBeatTrigger: plotBeatTrigger,
                    externalThreadTrigger: plotThreadTrigger,
                    externalForkTrigger: plotForkTrigger
                )
            case .rules:
                WorldRulesHubView(
                    session: session,
                    isDistillingStyle: busy == .distillingStyle,
                    isActionDisabled: busy != nil,
                    externalCreateTrigger: ruleCreateTrigger,
                    onDistillStyle: { refreshTemplate in
                        startStyleDistillation(refreshTemplate: refreshTemplate)
                    }
                )
            }
        }
        .themeAnimation(Theme.motionSelection, value: tab)
        .groupedPageBackground()
        .sensoryFeedback(.selection, trigger: tab) { _, _ in store.settings.hapticsEnabled }
        .toolbar { worldToolbar }
        .navigationDestination(isPresented: $showingAudit) {
            DreamingAuditView(session: session)
        }
        .navigationDestination(isPresented: $showingStyleLint) {
            StyleLintCardView(session: session)
        }
        .onChange(of: showingAudit) { _, presented in
            if !presented {
                auditRefreshTrigger &+= 1
            }
        }
        .task(id: "\(session.project.id)-\(session.narrativeRevision)-\(auditRefreshTrigger)") {
            await refreshAuditBadge()
        }
        .onDisappear {
            session.scheduleSave()
        }
        .sheet(isPresented: $showingRawResponse) {
            WorldRawResponseSheet(text: lastRawResponse ?? "")
        }
    }

    // MARK: - 导航栏动作

    @ToolbarContentBuilder
    private var worldToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            switch tab {
            case .entities:
                entityFilterMenu
                entityAddMenu
            case .plot:
                plotAddMenu
            case .rules:
                Button {
                    ruleCreateTrigger &+= 1
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加写作规则")

                rulesMoreMenu
            }

            auditToolbarButton
        }
    }

    private var entityFilterMenu: some View {
        Menu {
            Picker("按分类筛选", selection: $entityKindFilter) {
                Text("全部").tag(EntityKind?.none)
                ForEach(allEntityKinds, id: \.rawValue) { kind in
                    Text(NarrativeViewSupport.entityKindLabel(kind))
                        .tag(EntityKind?.some(kind))
                }
            }
        } label: {
            Image(
                systemName: entityKindFilter == nil
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .accessibilityLabel("按分类筛选")
    }

    private var entityAddMenu: some View {
        Menu {
            Button("新建档案", systemImage: "plus") {
                entityCreateTrigger &+= 1
            }
            Button("从正文提取档案", systemImage: "arrow.clockwise") {
                entityExtractTrigger &+= 1
            }
            .disabled(!hasManuscriptContent)
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("添加档案")
    }

    private var plotAddMenu: some View {
        Menu {
            Button("规划下一幕", systemImage: "plus.rectangle.on.rectangle") {
                plotBeatTrigger &+= 1
            }
            Button("新建伏笔", systemImage: "flag") {
                plotThreadTrigger &+= 1
            }
            Button("从当前幕分叉", systemImage: "arrow.triangle.branch") {
                plotForkTrigger &+= 1
            }
        } label: {
            Image(systemName: "plus")
        }
        .accessibilityLabel("新增剧情或伏笔")
    }

    private var rulesMoreMenu: some View {
        Menu {
            Button("提炼文风", systemImage: "wand.and.stars") {
                let hasTemplate = !session.payload.world.styleTemplate
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                startStyleDistillation(refreshTemplate: hasTemplate)
            }
            .disabled(busy != nil || !hasManuscriptContent)

            Button("从最近对话归纳规则", systemImage: "text.badge.plus") {
                startLongTermRuleUpdate()
            }
            .disabled(busy != nil)

            Divider()

            Button("行文观感", systemImage: "wand.and.stars") {
                showingStyleLint = true
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("更多规则操作")
    }

    private var auditToolbarButton: some View {
        Button {
            showingAudit = true
        } label: {
            if pendingAuditCount > 0 {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(AppTone.warning.color)
            } else {
                Image(systemName: "checkmark.shield")
            }
        }
        .accessibilityLabel(pendingAuditCount > 0 ? "世界核查，\(pendingAuditCount) 项待处理" : "世界核查")
    }

    // MARK: - 状态条

    @ViewBuilder
    private var statusArea: some View {
        if busy != nil || statusMessage != nil || lastRawResponse != nil {
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
        if let statusMessage, !statusMessage.isEmpty { return statusMessage }
        if let busy { return busy.label }
        return ""
    }

    // MARK: - 后台任务

    private func refreshAuditBadge() async {
        do {
            let report = try await ConsistencyCheckWorkflow.runOfflineDreamingAsync(
                session: session,
                store: store
            )
            let dismissed = NarrativeViewSupport.dismissedAuditFindingIDs(for: session.project.id)
            pendingAuditCount = report.findings.filter { !dismissed.contains($0.id) }.count
        } catch {
            pendingAuditCount = 0
        }
    }

    private func startTrackedTask(_ work: @escaping @MainActor () async -> Void) {
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
        statusMessage = nil
        startTrackedTask {
            do {
                self.statusMessage = try await operation()
            } catch {
                if error.isLLMCancellation {
                    self.statusMessage = cancelled
                } else {
                    self.handle(error)
                }
            }
            self.busy = nil
        }
    }

    private func startStyleDistillation(refreshTemplate: Bool) {
        startWorldTask(
            kind: .distillingStyle,
            cancelled: "已停止提炼文风。"
        ) {
            try await WorldMaterialWorkflow.distillStyleProfile(
                session: self.session,
                store: self.store,
                refreshTemplate: refreshTemplate
            )
        }
    }

    private func startLongTermRuleUpdate() {
        startWorldTask(
            kind: .updatingRules,
            cancelled: "已停止归纳规则。"
        ) {
            let outcome = try await WorldRulesWorkflow.updateLongTermRules(
                session: self.session,
                store: self.store
            )
            let added = NarrativeViewSupport.syncLongTermRulesToDirectives(
                session: self.session,
                store: self.store
            )
            if added > 0 {
                return "已归纳并添加 \(added) 条写作规则。"
            }
            return outcome.updated ? "写作规则已同步。" : "未发现新的写作规则。"
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
