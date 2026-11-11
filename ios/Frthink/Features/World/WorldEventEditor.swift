// 单张事件卡的编辑页：标题、场景、人物、起因、经过、结果。

import SwiftUI
import Foundation

struct WorldEventEditor: View {
    let session: ProjectSession
    let eventID: String

    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
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
        ToolbarItem(placement: .topBarTrailing) {
            Button("完成") {
                commitDraft()
                dismiss()
            }
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
    }

    @ViewBuilder
    private var duplicateTitleWarning: some View {
        if hasDuplicateTitle {
            Text("已有同名事件卡")
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
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return false }
        return session.payload.world.events.contains {
            $0.id != eventID
                && $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == title
        }
    }

    private func commitDraft() {
        guard let index = session.payload.world.events.firstIndex(where: {
            $0.id == eventID
        }) else { return }
        guard draft != session.payload.world.events[index] else { return }
        var event = draft
        event.updatedAt = Date()
        session.payload.world.events[index] = event
        draft = event
        session.scheduleSave()
    }

    // MARK: - 操作

    private func deleteEvent() {
        session.payload.world.events.removeAll { $0.id == eventID }
        session.scheduleSave()
        dismiss()
    }
}
