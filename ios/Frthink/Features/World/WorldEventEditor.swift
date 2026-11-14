// 单张事件卡的编辑页：标题、场景、人物、起因、经过、结果。

import SwiftUI
import Foundation

struct WorldEventEditor: View {
    let session: ProjectSession
    let eventID: String

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    /// 标题冲突时取消操作：确认放弃当前草稿修改。
    @State private var confirmingDiscard = false
    /// 编辑期间维护局部草稿，退出或点击完成时统一提交至 payload。
    @State private var draft: EventCard
    /// 打开页面时的初始快照：写回时仅提交发生修改的字段，保留后台刷新合并的新内容。
    private let openedCard: EventCard

    init(session: ProjectSession, eventID: String) {
        self.session = session
        self.eventID = eventID
        let current = session.payload.world.events.first { $0.id == eventID }
            ?? EventCard(title: "")
        _draft = State(initialValue: current)
        openedCard = current
    }

    var body: some View {
        Group {
            if hasEvent {
                editor
            } else {
                EmptyStateView(
                    symbol: "calendar.badge.exclamationmark",
                    title: "这张事件卡已被删除"
                )
            }
        }
        .pageBackground()
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onDisappear { commitDraft() }
        // 标题冲突且存在未保存改动时拦截手势退出，避免触发 onDisappear 导致修改丢失；需修改标题或确认放弃。
        .discardChangesDialog(isPresented: $confirmingDiscard, hasChanges: blocksDismissal) {
            discardDraft()
        }
        .deleteConfirmationDialog("删除事件卡", isPresented: $confirmingDelete) {
            deleteEvent()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if blocksDismissal {
            ToolbarItem(placement: .cancellationAction) {
                SheetCloseButton {
                    confirmingDiscard = true
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("完成") {
                commitDraft()
                dismiss()
            }
            // 禁止保存重名事件卡：合并与抽取均基于 title 标识事件，需确保标题唯一性。
            .disabled(hasDuplicateTitle)
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    AppSectionHeader(title: "基本")
                    AppTextField(
                        title: "标题",
                        text: $draft.title,
                        placeholder: "事件标题"
                    )
                    duplicateTitleWarning
                    WorldTagsField(
                        title: "人物",
                        values: $draft.characters,
                        placeholder: "用、分隔"
                    )
                }

                AppTextArea(
                    title: "场景",
                    text: $draft.scene,
                    placeholder: "地点、时间与在场状态",
                    minLines: 3
                )

                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    AppSectionHeader(title: "过程")
                    AppTextArea(
                        title: "起因",
                        text: $draft.cause,
                        placeholder: "这件事为什么发生",
                        minLines: 3
                    )
                    AppTextArea(
                        title: "经过",
                        text: $draft.development,
                        placeholder: "动作与变化，合并同一事件，不写流水账",
                        minLines: 3
                    )
                    AppTextArea(
                        title: "结果",
                        text: $draft.consequence,
                        placeholder: "造成了什么变化，留下什么后果",
                        minLines: 3
                    )
                }

                DestructiveActionRow(title: "删除事件卡") {
                    confirmingDelete = true
                }
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.xs)
                .background(
                    Theme.field,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                )
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
        }
        .keyboardDismissOnScroll()
    }

    @ViewBuilder
    private var duplicateTitleWarning: some View {
        if hasDuplicateTitle {
            // 同名事件卡不允许保存。
            Text("事件名称重复，请先整理事件卡")
                .font(Font.caption)
                .foregroundStyle(AppTone.warning.color)
        }
    }

    // MARK: - 草稿

    private var hasEvent: Bool {
        session.payload.world.events.contains { $0.id == eventID }
    }

    private var navigationTitle: String {
        draft.title.isEmpty ? "事件卡" : draft.title
    }

    private var hasDuplicateTitle: Bool {
        Self.conflicts(
            title: draft.title,
            in: session.payload.world.events,
            excluding: eventID
        )
    }

    /// 数据库已持久化版本，用于判断是否存在实质性修改。
    private var storedEvent: EventCard? {
        session.payload.world.events.first { $0.id == eventID }
    }

    /// 存在未保存改动且标题与既有卡片冲突时，拦截手势退出并提供放弃修改选项。
    private var blocksDismissal: Bool {
        Self.shouldBlockDismissal(
            draft: draft,
            stored: storedEvent,
            hasDuplicateTitle: hasDuplicateTitle
        )
    }

    /// 判定退出前是否需强制处理草稿冲突：仅在标题重名且存在有效修改时拦截。
    static func shouldBlockDismissal(
        draft: EventCard,
        stored: EventCard?,
        hasDuplicateTitle: Bool
    ) -> Bool {
        guard let stored else { return false }
        return draft != stored && hasDuplicateTitle
    }

    /// 校验事件卡标题唯一性：排重忽略空标题，防止新建阶段误拦截。
    static func conflicts(
        title: String,
        in events: [EventCard],
        excluding eventID: String
    ) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return events.contains {
            $0.id != eventID
                && $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed
        }
    }

    private func commitDraft() {
        guard let index = session.payload.world.events.firstIndex(where: {
            $0.id == eventID
        }) else { return }
        guard draft != openedCard else { return }
        // 标题冲突时终止提交，必须修改标题或确认放弃。
        guard !hasDuplicateTitle else { return }

        // 差异合并：仅提交发生变动的字段，防止以旧快照覆盖并发刷新的最新数据。
        var event = session.payload.world.events[index]
        if draft.title != openedCard.title { event.title = draft.title }
        if draft.scene != openedCard.scene { event.scene = draft.scene }
        if draft.characters != openedCard.characters { event.characters = draft.characters }
        if draft.cause != openedCard.cause { event.cause = draft.cause }
        if draft.development != openedCard.development { event.development = draft.development }
        if draft.consequence != openedCard.consequence { event.consequence = draft.consequence }
        guard event != session.payload.world.events[index] else { return }
        event.updatedAt = Date()
        session.payload.world.events[index] = event
        draft = event
        session.scheduleSave()
    }

    // MARK: - 操作

    /// 放弃修改：将草稿回退为持久化版本后关闭，避免 onDisappear 提交冲突数据。
    private func discardDraft() {
        if let storedEvent {
            draft = storedEvent
        }
        dismiss()
    }

    private func deleteEvent() {
        session.payload.world.events.removeAll { $0.id == eventID }
        session.scheduleSave()
        dismiss()
    }
}
