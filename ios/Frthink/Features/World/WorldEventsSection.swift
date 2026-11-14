// 「事件卡」分栏：搜索、列表、新建/删除，点进单张事件卡编辑。

import SwiftUI
import Foundation

struct WorldEventsSection: View {
    @Bindable var session: ProjectSession
    var isBusy: Bool
    /// 存在进行中的世界任务时禁用抽取操作。
    var isActionDisabled: Bool = false
    var onExtract: () -> Void

    @State private var searchText = ""
    @State private var route: Route? = nil
    @State private var pendingDeleteIDs: Set<String> = []
    /// 抽取胶囊的可见高度，跟随字号缩放。
    @ScaledMetric(relativeTo: .body) private var controlSize: CGFloat = Theme.Layout.controlHeight

    private struct Route: Identifiable {
        let id: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if filteredEvents.isEmpty {
                emptyState
            } else {
                eventList
            }
        }
        .sheet(item: $route) { item in
            NavigationStack {
                WorldEventEditor(session: session, eventID: item.id)
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            InlineSearchField(placeholder: "搜索事件或人物", text: $searchText)
            extractButton
            CircleIconButton(symbol: "plus", label: "新建事件") {
                addEvent()
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
    }

    /// 抽取按钮：次要操作样式，高度与搜索输入框保持一致。
    private var extractButton: some View {
        Button {
            onExtract()
        } label: {
            // 任务进度由主状态栏统一呈现。
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "wand.and.stars")
                    .font(Font.footnote)
                Text("从正文抽取")
                    .font(Font.footnote.weight(.medium))
            }
            .foregroundStyle(isBusy ? Color.secondary : Theme.accent)
            .padding(.horizontal, Theme.Spacing.m)
            .frame(minHeight: controlSize)
            .background(Theme.field, in: Capsule())
            // 可见高度 36pt，热区补到 44pt。
            .frame(minHeight: Theme.Layout.rowContentHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isActionDisabled)
    }

    // MARK: - 列表

    private var eventList: some View {
        List {
            Section {
                ForEach(filteredEvents) { event in
                    Button {
                        route = Route(id: event.id)
                    } label: {
                        EventRow(event: event)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteEvents)
            } header: {
                AppSectionHeader(title: "共 \(session.payload.world.events.count) 张事件卡")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .keyboardDismissOnScroll()
        .deleteConfirmationDialog(deleteTitle, isPresented: deleteAlertBinding) {
            confirmDelete()
        }
    }

    // MARK: - 行

    /// 列表行只依赖事件卡本身，与搜索状态解耦。
    private struct EventRow: View {
        let event: EventCard

        private var preview: String {
            if !event.consequence.isEmpty { return event.consequence }
            if !event.development.isEmpty { return event.development }
            if !event.cause.isEmpty { return event.cause }
            if !event.scene.isEmpty { return event.scene }
            return ""
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.xs) {
                    if event.title == "剧情梗概" {
                        Image(systemName: "text.book.closed")
                            .font(Font.caption)
                            .foregroundStyle(Color.secondary)
                    }
                    Text(event.title.isEmpty ? "未命名事件" : event.title)
                        .font(Font.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Text(event.updatedAt.formatted(date: .abbreviated, time: .omitted))
                        .font(Font.caption)
                        .foregroundStyle(.tertiary)
                }

                if !event.characters.isEmpty {
                    Text("人物：" + event.characters.joined(separator: "、"))
                        .font(Font.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if !preview.isEmpty {
                    Text(preview)
                        .font(Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            .contentShape(Rectangle())
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if session.payload.world.events.isEmpty {
            // 采用统一空状态组件风格。
            EmptyStateView(
                symbol: "calendar",
                title: "还没有事件卡",
                actionTitle: "新建事件",
                action: addEvent
            )
            // 占满可用高度，保持空状态内容垂直居中。
            .frame(maxHeight: .infinity)
        } else {
            InlineEmptyState(symbol: "magnifyingglass", message: "没有匹配的事件")
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - 数据

    private var filteredEvents: [EventCard] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return session.payload.world.events }
        return session.payload.world.events.filter { event in
            if event.title.lowercased().contains(keyword) { return true }
            return event.characters.contains { $0.lowercased().contains(keyword) }
        }
    }

    private func addEvent() {
        // 事件卡标题要求唯一：新建时自动生成不重复的默认标题。
        var title = "新事件"
        var suffix = 2
        while session.payload.world.events.contains(where: { $0.title == title }) {
            title = "新事件 \(suffix)"
            suffix += 1
        }
        let event = EventCard(title: title)
        session.payload.world.events.append(event)
        session.scheduleSave()
        route = Route(id: event.id)
    }

    private var deleteTitle: String {
        pendingDeleteIDs.count == 1
            ? "删除这张事件卡？"
            : "删除 \(pendingDeleteIDs.count) 张事件卡？"
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { !pendingDeleteIDs.isEmpty },
            set: { if !$0 { pendingDeleteIDs.removeAll() } }
        )
    }

    private func deleteEvents(at offsets: IndexSet) {
        pendingDeleteIDs = Set(offsets.map { filteredEvents[$0].id })
    }

    private func confirmDelete() {
        let ids = pendingDeleteIDs
        pendingDeleteIDs.removeAll()
        session.payload.world.events.removeAll { ids.contains($0.id) }
        session.scheduleSave()
    }
}
