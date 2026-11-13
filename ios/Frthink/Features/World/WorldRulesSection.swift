// 「模板与规则」分栏：文风笔记、仿写模板、长期写作规则。
//
// 主列表只做概览（一句预览 + 字数）和模型更新入口；正文进推入页编辑，
// 长文编辑不再打包在 sheet 里。更新动作跟着正文分栏走，用户不用先点进
// 编辑器再找按钮。
//
// 剧情梗概不在这一栏：写作提示词直接使用「事件」分栏的 `plotEvents`；
// 数据模型中的 `plotOutline` 为废弃字段，不暴露编辑入口，避免两处都能改。

import SwiftUI
import Foundation

/// 模板与规则的三个文本字段。主列表和编辑器共用这份枚举，避免两边写串。
enum WorldRuleTextKind: String, CaseIterable, Identifiable, Hashable {
    case styleNotes
    case styleTemplate
    case longTermRules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .styleNotes: return "文风笔记"
        case .styleTemplate: return "仿写模板"
        case .longTermRules: return "长期写作规则"
        }
    }

    var placeholder: String {
        switch self {
        case .styleNotes:
            return "每行一条可迁移的写法规则"
        case .styleTemplate:
            return "叙事视角与结构、因果推进与节奏、句式用词、对白、转场与收束……"
        case .longTermRules:
            return "例如：\n- 每章结尾留一个悬念\n- 不用第二人称\n- 对白不写「说道」"
        }
    }

    func text(in world: WorldBook) -> String {
        switch self {
        case .styleNotes: return world.styleNotes
        case .styleTemplate: return world.styleTemplate
        case .longTermRules: return world.longTermRules
        }
    }

    func valueLabel(in world: WorldBook) -> String {
        switch self {
        case .styleNotes:
            return "\(WorldRuleTextKind.lineCount(of: world.styleNotes)) 行"
        case .styleTemplate, .longTermRules:
            let count = text(in: world)
                .trimmingCharacters(in: .whitespacesAndNewlines).count
            return count == 0 ? "未建立" : "\(count) 字"
        }
    }

    static func lineCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isNewline })
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }
}

struct WorldRulesSection: View {
    @Bindable var session: ProjectSession
    /// 当前运行中的世界任务；只有本分栏的任务显示进度。
    var busy: WorldBusy?
    /// 任何世界任务在跑时都禁用 AI 入口，避免点了没反馈。
    var isActionDisabled: Bool = false
    var onExtractStyleNotes: () -> Void
    var onUpdateRules: () -> Void

    @State private var editing: WorldRuleTextKind?

    /// 三个文本字段的快照；只在真正变化时触发一次保存。
    private var ruleTexts: [String] {
        [
            session.payload.world.styleNotes,
            session.payload.world.styleTemplate,
            session.payload.world.longTermRules,
        ]
    }

    var body: some View {
        List {
            Section {
                ForEach(WorldRuleTextKind.allCases) { kind in
                    ruleRow(kind)
                }
            } header: {
                AppSectionHeader(title: "模板与规则")
            }

            Section {
                updateRow(
                    title: "从正文提炼文风笔记",
                    kind: .extractingStyleNotes,
                    action: onExtractStyleNotes
                )
                updateRow(
                    title: "用最近对话更新长期规则",
                    kind: .updatingRules,
                    action: onUpdateRules
                )
            } header: {
                AppSectionHeader(title: "从正文更新")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationDestination(item: $editing) { kind in
            WorldRuleEditorPage(session: session, kind: kind)
        }
        .onChange(of: ruleTexts) { _, _ in
            session.scheduleSave()
        }
    }

    // MARK: - 概览行

    private func ruleRow(_ kind: WorldRuleTextKind) -> some View {
        Button {
            editing = kind
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                // 二级页的列表行使用 Label，不加有色方块。
                SettingsLabelRow(
                    title: kind.title,
                    detail: kind.valueLabel(in: session.payload.world)
                )
                Image(systemName: "chevron.right")
                    .font(Font.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 模型更新入口放在列表上，点正文行只负责编辑，两个动作不互相打岔。
    /// 动作行不配图标：这里是一句命令，标题已经把动作说清楚了，再加一个小符号
    /// 只会让人猜它和上面那些「资源行」有什么区别。
    private func updateRow(
        title: String,
        kind: WorldBusy,
        action: @escaping () -> Void
    ) -> some View {
        let running = busy == kind
        return Button(action: action) {
            HStack(spacing: Theme.Spacing.m) {
                Text(title)
                    .font(Font.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: Theme.Spacing.s)
                if running {
                    Text("进行中")
                        .font(Font.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: Theme.Layout.rowContentHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isActionDisabled)
        .accessibilityValue(running ? "进行中" : "")
    }
}

/// 规则编辑页的草稿与外部（AI 摘要）写入之间的同步判定。
///
/// 页面打开时 `draft == baseline`；用户改过以后两者不再相等。只有没被用户
/// 动过的草稿才接受外部新值，否则会把用户正在写的内容顶掉。
enum WorldRuleDraftSync: Equatable {
    case adoptExternal
    case keepDraft

    static func decision(draft: String, baseline: String) -> Self {
        draft == baseline ? .adoptExternal : .keepDraft
    }
}

/// 模板与规则的整页编辑器：正文在离开或点完成时一次写回，模型动作不在这里。
private struct WorldRuleEditorPage: View {
    @Bindable var session: ProjectSession
    let kind: WorldRuleTextKind

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingMerge = false
    @State private var receipt: String?
    /// 编辑期间只改局部草稿，离开或点完成时一次写回 payload。
    @State private var draft: String
    /// 打开页面时的原文。用来区分「用户改过」与「后台 AI 更新过」。
    @State private var baseline: String

    init(session: ProjectSession, kind: WorldRuleTextKind) {
        self.session = session
        self.kind = kind
        let initial = kind.text(in: session.payload.world)
        _draft = State(initialValue: initial)
        _baseline = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            AppTextEditor(
                text: $draft,
                placeholder: kind.placeholder,
                minHeight: 180,
                expands: true
            )
            .padding(Theme.Spacing.l)

            if kind == .styleNotes {
                mergeBar
            }
        }
        .groupedPageBackground()
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    commitDraft()
                    dismiss()
                }
            }
        }
        .confirmationDialog(
            "并入仿写模板？",
            isPresented: $confirmingMerge,
            titleVisibility: .visible
        ) {
            Button("并入", role: .destructive) { mergeNotesIntoTemplate() }
            Button("取消", role: .cancel) {}
        }
        // 页面开着时 AI 可能更新了同一字段（手动入口在列表上，自动摘要在后台跑）。
        // 用户没动过草稿就直接换成新值，避免他看到旧内容再点「完成」把新结果盖掉。
        .onChange(of: kind.text(in: session.payload.world)) { _, newValue in
            guard WorldRuleDraftSync.decision(draft: draft, baseline: baseline)
                == .adoptExternal
            else { return }
            draft = newValue
            baseline = newValue
        }
        .onDisappear {
            commitDraft()
        }
    }

    // MARK: - 草稿

    private func commitDraft() {
        // 用户没动过就什么都不写：后台 AI 可能在编辑期间更新过同一字段，
        // 拿打开时的旧草稿回写会把新结果覆盖掉。
        guard draft != baseline else { return }
        switch kind {
        case .styleNotes:
            session.payload.world.styleNotes = draft
        case .styleTemplate:
            session.payload.world.styleTemplate = draft
        case .longTermRules:
            // 和设置页共用摘要写入口：记录历史版本与 updatedAt，恢复上一版才有依据。
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            _ = session.payload.world.applySummaryUpdate(
                content: draft,
                newKeys: [],
                now: now
            )
        }
        baseline = draft
        session.scheduleSave()
    }

    // MARK: - 并入仿写模板

    private var mergeBar: some View {
        VStack(spacing: Theme.Spacing.s) {
            SecondaryActionButton(
                title: "并入仿写模板",
                systemImage: "arrow.down.doc",
                isEnabled: hasNotes
            ) {
                confirmingMerge = true
            }

            if let receipt {
                AppStatusLine(kind: .success, text: receipt)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.m)
    }

    private var hasNotes: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func mergeNotesIntoTemplate() {
        commitDraft()
        let notes = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return }

        let template = session.payload.world.styleTemplate
            .trimmingCharacters(in: .whitespacesAndNewlines)
        session.payload.world.styleTemplate = template.isEmpty
            ? notes
            : template + "\n\n" + notes
        session.payload.world.styleNotes = ""
        draft = ""
        session.scheduleSave()
        receipt = "已并入仿写模板"
    }
}
