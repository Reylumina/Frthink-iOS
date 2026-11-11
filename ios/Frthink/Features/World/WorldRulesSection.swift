// 「模板与规则」分栏：剧情梗概、文风笔记、仿写模板、长期写作规则。
//
// 主列表只做概览（一句预览 + 字数）；正文都进整页编辑器，三个动作
// （提炼文风笔记、并入仿写模板、更新长期规则）跟着各自的正文走。

import SwiftUI
import Foundation

/// 模板与规则的四个文本字段。主列表和编辑器共用这份枚举，避免两边写串。
enum WorldRuleTextKind: String, CaseIterable, Identifiable {
    case plotOutline
    case styleNotes
    case styleTemplate
    case longTermRules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plotOutline: return "剧情梗概"
        case .styleNotes: return "文风笔记"
        case .styleTemplate: return "仿写模板"
        case .longTermRules: return "长期写作规则"
        }
    }

    var symbol: String {
        switch self {
        case .plotOutline: return "text.alignleft"
        case .styleNotes: return "text.magnifyingglass"
        case .styleTemplate: return "doc.text"
        case .longTermRules: return "list.bullet"
        }
    }

    var placeholder: String {
        switch self {
        case .plotOutline:
            return "按事件顺序记录起因、关键发展、结果与后续影响"
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
        case .plotOutline: return world.plotOutline
        case .styleNotes: return world.styleNotes
        case .styleTemplate: return world.styleTemplate
        case .longTermRules: return world.longTermRules
        }
    }

    func valueLabel(in world: WorldBook) -> String {
        switch self {
        case .styleNotes:
            return "\(WorldRuleTextKind.lineCount(of: world.styleNotes)) 行"
        case .plotOutline, .styleTemplate, .longTermRules:
            return "\(text(in: world).count) 字"
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
    var isBusy: Bool
    /// 任何世界任务在跑时都禁用 AI 入口，避免点了没反馈。
    var isActionDisabled: Bool = false
    var onExtractStyleNotes: () -> Void
    var onUpdateRules: () -> Void

    @State private var editing: WorldRuleTextKind?

    /// 四个文本字段的快照；只在真正变化时触发一次保存。
    private var ruleTexts: [String] {
        [
            session.payload.world.plotOutline,
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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .sheet(item: $editing) { kind in
            WorldRuleEditorSheet(
                session: session,
                kind: kind,
                isBusy: isBusy,
                isActionDisabled: isActionDisabled,
                onExtractStyleNotes: onExtractStyleNotes,
                onUpdateRules: onUpdateRules
            )
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
            HStack(spacing: Theme.Spacing.m) {
                IconTile(symbol: kind.symbol)
                Text(kind.title)
                    .font(Font.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: Theme.Spacing.s)
                Text(kind.valueLabel(in: session.payload.world))
                    .font(Theme.numeric)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(Font.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 模板与规则的整页编辑器：正文自动保存，模型动作跟着字段走。
private struct WorldRuleEditorSheet: View {
    @Bindable var session: ProjectSession
    let kind: WorldRuleTextKind
    var isBusy: Bool
    var isActionDisabled: Bool
    var onExtractStyleNotes: () -> Void
    var onUpdateRules: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingMerge = false
    @State private var receipt: String?
    /// 编辑期间只改局部草稿，离开或点完成时一次写回 payload。
    @State private var draft: String

    init(
        session: ProjectSession,
        kind: WorldRuleTextKind,
        isBusy: Bool,
        isActionDisabled: Bool,
        onExtractStyleNotes: @escaping () -> Void,
        onUpdateRules: @escaping () -> Void
    ) {
        self.session = session
        self.kind = kind
        self.isBusy = isBusy
        self.isActionDisabled = isActionDisabled
        self.onExtractStyleNotes = onExtractStyleNotes
        self.onUpdateRules = onUpdateRules
        _draft = State(initialValue: kind.text(in: session.payload.world))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AppTextEditor(
                    text: $draft,
                    placeholder: kind.placeholder,
                    minHeight: 180,
                    expands: true
                )
                .padding(Theme.Spacing.l)

                if showsBottomBar {
                    bottomBar
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
            .onDisappear {
                commitDraft()
            }
            .onChange(of: session.payload.world.styleNotes) { _, newValue in
                // 并入后笔记区清空，回执先留着；一旦又开始记新笔记，就把回执收掉。
                guard kind == .styleNotes else { return }
                if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    receipt = nil
                }
            }
        }
    }

    // MARK: - 草稿

    private func commitDraft() {
        guard draft != kind.text(in: session.payload.world) else { return }
        switch kind {
        case .plotOutline: session.payload.world.plotOutline = draft
        case .styleNotes: session.payload.world.styleNotes = draft
        case .styleTemplate: session.payload.world.styleTemplate = draft
        case .longTermRules: session.payload.world.longTermRules = draft
        }
        session.scheduleSave()
    }

    private var hasNotes: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - 底部

    private var showsBottomBar: Bool {
        kind == .styleNotes || kind == .longTermRules
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: Theme.Spacing.s) {
            actions

            if let receipt {
                AppStatusLine(kind: .success, text: receipt)
            } else if isBusy, let busyText {
                AppStatusLine(kind: .progress, text: busyText)
            } else if !sideLabel.isEmpty {
                HStack(spacing: Theme.Spacing.s) {
                    Text(sideLabel)
                        .font(Font.footnote)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.m)
    }

    @ViewBuilder
    private var actions: some View {
        switch kind {
        case .styleNotes:
            HStack(spacing: Theme.Spacing.s) {
                SecondaryActionButton(
                    title: "从正文提炼",
                    systemImage: "text.magnifyingglass",
                    isEnabled: !isActionDisabled
                ) {
                    commitDraft()
                    onExtractStyleNotes()
                }
                SecondaryActionButton(
                    title: "并入仿写模板",
                    systemImage: "arrow.down.doc",
                    isEnabled: hasNotes
                ) {
                    confirmingMerge = true
                }
            }
        case .longTermRules:
            SecondaryActionButton(
                title: "用最近对话更新",
                systemImage: "arrow.triangle.2.circlepath",
                isEnabled: !isActionDisabled
            ) {
                commitDraft()
                onUpdateRules()
            }
        case .plotOutline, .styleTemplate:
            EmptyView()
        }
    }

    private var sideLabel: String {
        switch kind {
        case .plotOutline, .styleTemplate:
            return ""
        case .styleNotes:
            return "\(WorldRuleTextKind.lineCount(of: session.payload.world.styleNotes)) 行"
        case .longTermRules:
            return "码字机用户消息 \(recentUserMessageCount) 条"
        }
    }

    /// 模型动作在弹层里排队时，进度就地显示，不必退出去看分栏上方的状态条。
    private var busyText: String? {
        switch kind {
        case .styleNotes:
            return WorldBusy.extractingStyleNotes.label
        case .longTermRules:
            return WorldBusy.updatingRules.label
        case .plotOutline, .styleTemplate:
            return nil
        }
    }

    private var recentUserMessageCount: Int {
        session.payload.messages.filter { $0.role == .user }.count
    }

    // MARK: - 并入

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
