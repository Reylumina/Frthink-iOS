// 「人物卡」分栏：搜索、分组、排序、列表、新建、删除，点进单张卡编辑。

import SwiftUI
import Foundation

enum WorldCharacterSort: Hashable {
    case name
    case recentlyUpdated

    var displayName: String {
        switch self {
        case .name: return "按姓名"
        case .recentlyUpdated: return "最近更新"
        }
    }
}

struct WorldCharactersSection: View {
    @Bindable var session: ProjectSession
    /// 人物卡由世界刷新流程写入；入口放在卡片列表上，不必回概览找。
    var isActionDisabled: Bool = false
    var onRefresh: (() -> Void)? = nil
    var onRefreshFull: (() -> Void)? = nil

    @State private var searchText = ""
    @State private var sortMode: WorldCharacterSort = .name
    @State private var route: Route? = nil
    @State private var pendingDeleteIDs: Set<String> = []
    @State private var groupFilter = "__all__"
    @State private var showGroupEditor = false

    private struct Route: Identifiable {
        let id: String
    }

    var body: some View {
        let cards = filteredCards
        VStack(spacing: 0) {
            header

            if cards.isEmpty {
                emptyState
            } else {
                cardList(cards)
            }
        }
        .sheet(item: $route) { item in
            NavigationStack {
                WorldCharacterEditor(session: session, cardID: item.id)
            }
        }
        .sheet(isPresented: $showGroupEditor) {
            NavigationStack {
                WorldGroupEditor(session: session)
            }
        }
        .onAppear {
            #if DEBUG
            applyLaunchCard()
            #endif
        }
        .onChange(of: session.payload.world.characterGroups) { _, groups in
            // 当前筛选的分组被删掉后回到「全部分组」，不留一个永远空着的列表。
            guard groupFilter != "__all__", groupFilter != "__ungrouped__",
                  !groups.contains(where: { $0.id == groupFilter })
            else { return }
            groupFilter = "__all__"
        }
    }

    #if DEBUG
    /// 截图流水线：`-openWorldCard first` 打开列表里的第一张人物卡。
    private func applyLaunchCard() {
        guard LaunchArguments.opensWorldCard,
              route == nil,
              let first = filteredCards.first
        else { return }
        route = Route(id: first.id)
    }
    #endif

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.s) {
                InlineSearchField(placeholder: "搜索姓名或别称", text: $searchText)
                sortMenu
                CircleIconButton(symbol: "plus", label: "新建人物") {
                    addCard()
                }
            }
            HStack(spacing: Theme.Spacing.s) {
                Text("共 \(session.payload.world.characters.count) 张人物卡")
                    .font(Font.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if onRefresh != nil {
                    refreshButton
                }
                groupMenu
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
    }

    private var sortMenu: some View {
        Menu {
            Picker("排序", selection: $sortMode) {
                Text(WorldCharacterSort.name.displayName).tag(WorldCharacterSort.name)
                Text(WorldCharacterSort.recentlyUpdated.displayName)
                    .tag(WorldCharacterSort.recentlyUpdated)
            }
        } label: {
            CircleIconLabel(
                symbol: "arrow.up.arrow.down",
                fill: Theme.field,
                tint: .secondary
            )
            .frame(minWidth: Theme.Layout.hitTarget, minHeight: Theme.Layout.hitTarget)
            .contentShape(Circle())
        }
        .accessibilityLabel("排序")
        .accessibilityValue(sortMode.displayName)
    }

    /// 从正文整理人物卡：使用原生 Menu 就近弹出液态玻璃操作菜单，与右侧分组菜单保持一致。
    private var refreshButton: some View {
        Menu {
            Button {
                onRefresh?()
            } label: {
                Label("增量刷新", systemImage: "arrow.triangle.2.circlepath")
            }
            if onRefreshFull != nil {
                Button {
                    onRefreshFull?()
                } label: {
                    Label("从头整理（重新分析全部正文）", systemImage: "arrow.counterclockwise")
                }
            }
        } label: {
            // 进度由世界页的状态行统一报，这一行只留入口。
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(Font.caption)
                Text("刷新")
                    .font(Font.footnote)
            }
            .foregroundStyle(isActionDisabled ? Color.secondary : Theme.accent)
            .frame(minHeight: Theme.Layout.rowContentHeight)
            .contentShape(Rectangle())
        }
        .disabled(isActionDisabled)
        .accessibilityLabel("刷新人物卡")
    }
    private var groupMenu: some View {
        Menu {
            Button("全部人物") { groupFilter = "__all__" }
            Button("未分组") { groupFilter = "__ungrouped__" }
            if !session.payload.world.characterGroups.isEmpty {
                Divider()
                ForEach(session.payload.world.characterGroups) { group in
                    Button {
                        groupFilter = group.id
                    } label: {
                        if group.enabled {
                            Text(group.name)
                        } else {
                            Label(group.name + "（已停用）", systemImage: "eye.slash")
                        }
                    }
                }
            }
            Divider()
            Button("管理分组…") { showGroupEditor = true }
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(groupFilterLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
            }
            .font(Font.footnote)
            .foregroundStyle(.secondary)
            .frame(minHeight: Theme.Layout.rowContentHeight)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("分组筛选")
        .accessibilityValue(groupFilterLabel)
    }

    private var groupFilterLabel: String {
        switch groupFilter {
        case "__all__": return "全部分组"
        case "__ungrouped__": return "未分组"
        default:
            return session.payload.world.characterGroups
                .first(where: { $0.id == groupFilter })?.name ?? "分组"
        }
    }

    // MARK: - 列表

    private func cardList(_ cards: [CharacterCard]) -> some View {
        List {
            Section {
                ForEach(cards) { card in
                    Button {
                        route = Route(id: card.id)
                    } label: {
                        CharacterRow(card: card)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete(perform: deleteCards)
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 4, for: .scrollContent)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.hidden)
        .groupedPageBackground()
        .keyboardDismissOnScroll()
        .deleteConfirmationDialog(deleteTitle, isPresented: deleteAlertBinding) {
            confirmDelete()
        }
    }

    // MARK: - 行

    /// 列表行只依赖卡片本身，和分栏的搜索、路由状态解耦。
    private struct CharacterRow: View {
        let card: CharacterCard

        /// 头像圆圈的尺寸是控件尺寸，跟随 Dynamic Type 缩放。
        @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 44

        private var subtitle: String {
            card.identity.isEmpty ? card.personality : card.identity
        }

        private var avatarColor: Color {
            let seed = card.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = seed.isEmpty ? card.id : seed
            // 对齐概览页图标的 iOS 系统色板，保持明亮一致的视觉身份。
            let palette: [Color] = [.blue, .indigo, .orange, .purple, .pink, .teal, .mint, .cyan]
            let hash = key.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
            return palette[abs(hash) % palette.count]
        }

        var body: some View {
            HStack(alignment: .center, spacing: Theme.Spacing.m) {
                Image(systemName: "person.fill")
                    .font(.system(size: avatarSize * 0.45, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: avatarSize, height: avatarSize)
                    .background(Circle().fill(avatarColor))
                    .accessibilityHidden(true)

                summaryColumn

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(Font.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, Theme.Spacing.s)
            .contentShape(Rectangle())
        }

        private var summaryColumn: some View {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    Text(card.name.isEmpty ? "未命名人物" : card.name)
                        .font(Font.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    if !card.aliases.isEmpty {
                        Text(card.aliases.prefix(2).joined(separator: "、"))
                            .font(Font.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if session.payload.world.characters.isEmpty {
            EmptyStateView(
                symbol: "person.text.rectangle",
                title: "还没有人物卡",
                actionTitle: "新建人物",
                action: addCard
            )
            .frame(maxHeight: .infinity)
        } else {
            InlineEmptyState(symbol: "magnifyingglass", message: "没有匹配的人物")
                .frame(maxHeight: .infinity)
        }
    }

    // MARK: - 数据

    private var filteredCards: [CharacterCard] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var cards: [CharacterCard]
        if keyword.isEmpty {
            cards = session.payload.world.characters
        } else {
            cards = session.payload.world.characters.filter { card in
                if card.name.lowercased().contains(keyword) { return true }
                return card.aliases.contains { $0.lowercased().contains(keyword) }
            }
        }

        switch groupFilter {
        case "__all__":
            break
        case "__ungrouped__":
            cards = cards.filter { ($0.groupId ?? "").isEmpty }
        default:
            cards = cards.filter { $0.groupId == groupFilter }
        }

        return cards.sorted { lhs, rhs in
            switch sortMode {
            case .name:
                let result = lhs.name.localizedStandardCompare(rhs.name)
                if result == .orderedSame { return lhs.updatedAt > rhs.updatedAt }
                return result == .orderedAscending
            case .recentlyUpdated:
                return lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    private func addCard() {
        let card = CharacterCard(name: "")
        session.payload.world.characters.append(card)
        session.scheduleSave()
        route = Route(id: card.id)
    }

    private var deleteTitle: String {
        pendingDeleteIDs.count == 1
            ? "删除这张人物卡？"
            : "删除 \(pendingDeleteIDs.count) 张人物卡？"
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { !pendingDeleteIDs.isEmpty },
            set: { if !$0 { pendingDeleteIDs.removeAll() } }
        )
    }

    private func deleteCards(at offsets: IndexSet) {
        pendingDeleteIDs = Set(offsets.map { filteredCards[$0].id })
    }

    private func confirmDelete() {
        let ids = pendingDeleteIDs
        pendingDeleteIDs.removeAll()
        session.payload.world.characters.removeAll { ids.contains($0.id) }
        session.scheduleSave()
    }
}
