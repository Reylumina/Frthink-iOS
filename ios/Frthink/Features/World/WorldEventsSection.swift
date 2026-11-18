// 「事件卡」分栏：搜索、列表、新建/删除，点进单张事件卡编辑。

import SwiftUI
import Foundation

struct WorldEventsSection: View {
    @Bindable var session: ProjectSession
    var isBusy: Bool
    var isSyncingState: Bool = false
    var isCheckingConsistency: Bool = false
    /// 存在进行中的世界任务时禁用抽取操作。
    var isActionDisabled: Bool = false
    var onExtract: () -> Void
    var onSyncState: () -> Void = {}
    var onScanFullThreads: () -> Void = {}
    var onCheckConsistency: () -> Void = {}

    @State private var searchText = ""
    @State private var route: Route? = nil
    @State private var pendingDeleteIDs: Set<String> = []
    @State private var showingNewThreadAlert = false
    @State private var newThreadTitle = ""
    @State private var newThreadObligation = ""
    /// 抽取胶囊的可见高度，跟随字号缩放。
    @ScaledMetric(relativeTo: .body) private var controlSize: CGFloat = Theme.Layout.controlHeight

    private struct Route: Identifiable {
        let id: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if filteredEvents.isEmpty && filteredThreads.isEmpty {
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
        .alert("新建未决伏笔", isPresented: $showingNewThreadAlert) {
            TextField("伏笔标题", text: $newThreadTitle)
            TextField("待兑现内容（可选）", text: $newThreadObligation)
            Button("添加") {
                addPlotThread()
            }
            Button("取消", role: .cancel) {
                newThreadTitle = ""
                newThreadObligation = ""
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

    /// 整理与审校菜单：收纳事件抽取、末段同步与一致性审校，保持列表清爽。
    private var extractButton: some View {
        let anyBusy = isBusy || isSyncingState || isCheckingConsistency
        return Menu {
            Button {
                onExtract()
            } label: {
                Label("从正文抽取事件卡", systemImage: "text.badge.plus")
            }
            Button {
                onSyncState()
            } label: {
                Label("同步末段状态与伏笔", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                onScanFullThreads()
            } label: {
                Label("全书扫描伏笔与状态", systemImage: "doc.text.magnifyingglass")
            }
            Button {
                onCheckConsistency()
            } label: {
                Label("检查设定与情节一致性", systemImage: "checkmark.shield")
            }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "wand.and.stars")
                    .font(Font.footnote)
                Text("整理与审校")
                    .font(Font.footnote.weight(.medium))
            }
            .foregroundStyle(anyBusy ? Color.secondary : Theme.accent)
            .padding(.horizontal, Theme.Spacing.m)
            .frame(minHeight: controlSize)
            .background(Theme.field, in: Capsule())
            // 可见高度 36pt，热区补到 44pt。
            .frame(minHeight: Theme.Layout.rowContentHeight)
            .contentShape(Capsule())
        }
        .disabled(isActionDisabled)
    }

    // MARK: - 列表

    private var eventList: some View {
        List {
            Section {
                ForEach(filteredThreads) { thread in
                    PlotThreadRow(thread: thread) {
                        toggleThreadStatus(thread.id)
                    }
                }
                .onDelete(perform: deleteThreads)

                Button {
                    showingNewThreadAlert = true
                } label: {
                    Label("手动记伏笔", systemImage: "plus")
                        .font(Font.footnote.weight(.medium))
                }
            } header: {
                let openCount = session.payload.world.openThreads.filter { $0.status == .open }.count
                AppSectionHeader(title: "未决伏笔（\(openCount) 条待兑现）")
            }

            if !filteredEvents.isEmpty {
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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .keyboardDismissOnScroll()
        .deleteConfirmationDialog(deleteTitle, isPresented: deleteAlertBinding) {
            confirmDelete()
        }
    }

    private struct PlotThreadRow: View {
        let thread: PlotThread
        var onToggle: () -> Void

        var body: some View {
            Button(action: onToggle) {
                HStack(alignment: .top, spacing: Theme.Spacing.s) {
                    Image(systemName: thread.status == .resolved ? "checkmark.circle.fill" : "circle")
                        .font(Font.body)
                        .foregroundStyle(thread.status == .resolved ? AppTone.success.color : Theme.accent)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(thread.title)
                            .font(Font.subheadline.weight(.semibold))
                            .foregroundStyle(thread.status == .resolved ? .secondary : .primary)
                            .strikethrough(thread.status == .resolved)
                        if !thread.obligation.isEmpty {
                            Text(thread.obligation)
                                .font(Font.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if !thread.relatedCharacters.isEmpty {
                            Text("相关人物：" + thread.relatedCharacters.joined(separator: "、"))
                                .font(Font.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Theme.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

    private var filteredThreads: [PlotThread] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = session.payload.world.openThreads.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.status == .open }
            return lhs.updatedAt > rhs.updatedAt
        }
        guard !keyword.isEmpty else { return sorted }
        return sorted.filter { thread in
            thread.title.lowercased().contains(keyword)
                || thread.obligation.lowercased().contains(keyword)
                || thread.relatedCharacters.contains { $0.lowercased().contains(keyword) }
        }
    }

    private func addPlotThread() {
        let title = newThreadTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let obligation = newThreadObligation.trimmingCharacters(in: .whitespacesAndNewlines)
        newThreadTitle = ""
        newThreadObligation = ""
        guard !title.isEmpty else { return }
        session.payload.world.openThreads.insert(
            PlotThread(title: title, obligation: obligation),
            at: 0
        )
        session.scheduleSave()
    }

    private func toggleThreadStatus(_ id: String) {
        guard let idx = session.payload.world.openThreads.firstIndex(where: { $0.id == id }) else {
            return
        }
        let next: PlotThreadStatus = session.payload.world.openThreads[idx].status == .open
            ? .resolved
            : .open
        session.payload.world.openThreads[idx].status = next
        session.payload.world.openThreads[idx].updatedAt = Date()
        session.scheduleSave()
    }

    private func deleteThreads(at offsets: IndexSet) {
        let ids = Set(offsets.map { filteredThreads[$0].id })
        session.payload.world.openThreads.removeAll { ids.contains($0.id) }
        session.scheduleSave()
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
