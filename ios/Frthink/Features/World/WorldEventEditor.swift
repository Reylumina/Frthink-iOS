// 单张事件卡的编辑页：标题、场景、人物、起因、经过、结果。

import SwiftUI
import Foundation

struct WorldEventEditor: View {
    let session: ProjectSession
    let eventID: String

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    /// 标题冲突时点「取消」：确认放弃这份草稿。
    @State private var confirmingDiscard = false
    /// 编辑期间只改局部草稿，离开或点完成时一次写回 payload。
    @State private var draft: EventCard

    init(session: ProjectSession, eventID: String) {
        self.session = session
        self.eventID = eventID
        _draft = State(
            initialValue: session.payload.world.events.first { $0.id == eventID }
                ?? EventCard(title: "")
        )
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
        .groupedPageBackground()
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .onDisappear { commitDraft() }
        // 标题冲突且有未保存改动时不能滑走：滑走会走 onDisappear，草稿被静默丢掉。
        // 用户必须先改标题，或点「取消」确认放弃。
        .interactiveDismissDisabled(blocksDismissal)
        .confirmationDialog(
            "删除事件卡",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                deleteEvent()
            }
            Button("取消", role: .cancel) {}
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
            // 同名事件卡不能保存：合并/抽取都按 title 认事件，两张同名卡里
            // 只有第一张会被继续补充，另一张从此是孤儿。
            .disabled(hasDuplicateTitle)
        }
    }

    private var editor: some View {
        Form {
            Section {
                AppTextField(
                    title: "标题",
                    text: $draft.title,
                    placeholder: "事件标题"
                )
                WorldTagsField(
                    title: "人物",
                    values: $draft.characters,
                    placeholder: "用、分隔"
                )
            } header: {
                AppSectionHeader(title: "基本")
            } footer: {
                duplicateTitleWarning
            }

            Section {
                AppTextArea(
                    title: "场景",
                    text: $draft.scene,
                    placeholder: "地点、时间与在场状态",
                    minLines: 3
                )
            }

            Section {
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
            } header: {
                AppSectionHeader(title: "过程")
            }

            Section {
                DestructiveActionRow(title: "删除事件卡") {
                    confirmingDelete = true
                }
            }
        }
        .scrollContentBackground(.hidden)
        .confirmationDialog(
            "放弃未保存的修改？",
            isPresented: $confirmingDiscard,
            titleVisibility: .visible
        ) {
            Button("放弃修改", role: .destructive) { discardDraft() }
            Button("继续编辑", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var duplicateTitleWarning: some View {
        if hasDuplicateTitle {
            // APK 保存侧原文（`str:17316`）：同名事件卡不允许保存。
            Text("事件名称重复，请先整理事件卡")
                .font(Font.caption)
                .foregroundStyle(.orange)
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

    /// 已保存的那一版。用来区分「用户改过」与「只是打开看看」。
    private var storedEvent: EventCard? {
        session.payload.world.events.first { $0.id == eventID }
    }

    /// 有未保存改动，且标题与其它卡冲突：滑走会走 onDisappear，草稿被静默丢掉。
    /// 只有这种状态需要拦住下滑并给一个明确的放弃入口。
    private var blocksDismissal: Bool {
        Self.shouldBlockDismissal(
            draft: draft,
            stored: storedEvent,
            hasDuplicateTitle: hasDuplicateTitle
        )
    }

    /// 离开前是否必须先处理草稿：标题冲突 + 有未保存改动。
    ///
    /// 没有改动时不需要拦（`onDisappear` 的自动保存本来就是空操作）；
    /// 标题不冲突时也不用拦（滑走会正常保存）。
    static func shouldBlockDismissal(
        draft: EventCard,
        stored: EventCard?,
        hasDuplicateTitle: Bool
    ) -> Bool {
        guard let stored else { return false }
        return draft != stored && hasDuplicateTitle
    }

    /// 事件卡标题唯一性：合并与抽取都按 title 认事件，同名卡只能有一张。
    ///
    /// 保存侧校验（APK `str:17316`「事件名称重复，请先整理事件卡」）。空标题不拦：
    /// 新建卡还没填标题时不该连「完成」都按不下去。
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
        guard draft != session.payload.world.events[index] else { return }
        // 标题与其它卡冲突时整份草稿都不写：保存按钮已经禁用并给了行内原因，
        // 下滑也已被拦住，用户只能改标题或点「取消」确认放弃。
        guard !hasDuplicateTitle else { return }
        var event = draft
        event.updatedAt = Date()
        session.payload.world.events[index] = event
        draft = event
        session.scheduleSave()
    }

    // MARK: - 操作

    /// 确认放弃后把草稿恢复成已保存的那版再关闭：`onDisappear` 的自动保存
    /// 于是变成空操作，同名标题与其它未保存改动都不会进库。
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
