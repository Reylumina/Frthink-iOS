// 提示词回看：把某次生成**实际发出去的** messages 原样列出来。
// 数据来自 `ProjectPayload.requestSnapshots`（原版 `requestSnapshots`）。

import SwiftUI

struct RequestSnapshotsSheet: View {
    @Bindable var session: ProjectSession

    @Environment(\.dismiss) private var dismiss
    @State private var selected: RequestSnapshot?
    @State private var confirmingClear = false
    @State private var pendingDelete: RequestSnapshot?

    private var ordered: [RequestSnapshot] {
        session.payload.requestSnapshots.sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        NavigationStack {
            Group {
                if ordered.isEmpty {
                    EmptyStateView(
                        symbol: "text.magnifyingglass",
                        title: "还没有请求记录"
                    )
                } else {
                    list
                }
            }
            .groupedPageBackground()
            .navigationTitle("提示词回看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if !ordered.isEmpty {
                        Button("清空") { confirmingClear = true }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("清空回看记录？", isPresented: $confirmingClear) {
                Button("清空", role: .destructive) {
                    session.clearRequestSnapshots()
                }
                Button("取消", role: .cancel) {}
            }
            .alert("删除这条回看记录？", isPresented: deleteAlertBinding) {
                Button("删除", role: .destructive) {
                    if let snapshot = pendingDelete {
                        session.deleteRequestSnapshots([snapshot.id])
                    }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            } message: {
                Text("删除后无法恢复。")
            }
            .sheet(item: $selected) { snapshot in
                RequestSnapshotDetail(snapshot: snapshot)
            }
        }
    }

    private func snapshotRow(_ snapshot: RequestSnapshot) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(formatted(snapshot.createdAt))
                    .font(Font.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: Theme.Spacing.s)
                Text("\(snapshot.messages.count) 条消息")
                    .font(Font.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                if let label = sourceLabel(for: snapshot) {
                    StatusPill(text: label)
                }
                Text(tokenLine(snapshot))
                    .font(Theme.numericSmall)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if snapshot.omittedHistoryMessages > 0 {
                Text("丢弃 \(snapshot.omittedHistoryMessages) 条历史消息")
                    .font(Font.caption)
                    .foregroundStyle(.orange)
            }
            if !snapshot.sourceIds.isEmpty {
                Text(snapshot.sourceIds.joined(separator: " · "))
                    .font(Theme.numericSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
    }

    private var list: some View {
        List(ordered) { snapshot in
            Button {
                selected = snapshot
            } label: {
                snapshotRow(snapshot)
            }
            .buttonStyle(.plain)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    pendingDelete = snapshot
                } label: {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func formatted(_ date: Date) -> String {
        Self.formatter.string(from: date)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        )
    }

    private func tokenLine(_ snapshot: RequestSnapshot) -> String {
        "估算 \(snapshot.estimatedInputTokens) tok · 预算 \(snapshot.inputBudgetTokens)"
            + " · 窗口 \(snapshot.modelContextWindowTokens)"
    }

    /// 从已记录的 `sourceIds` 里取一个用户看得懂的来源标签。
    /// 没有记录就返回 nil，不凭时间或字数猜请求类型。
    private func sourceLabel(for snapshot: RequestSnapshot) -> String? {
        guard let first = snapshot.sourceIds.first else { return nil }
        let prefix = first.split(separator: ":", maxSplits: 1).first.map(String.init) ?? first
        let name: String
        switch prefix {
        case "body": name = "正文"
        case "preset": name = "预设"
        case "skill": name = "技能"
        case "corpus": name = "语料"
        case "worldbook": name = "世界书"
        case "character": name = "人物卡"
        default: return nil
        }
        return "来源 · \(name)"
    }

    /// DateFormatter 创建很贵；列表每行都 new 一个会明显拖慢滚动。
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd HH:mm:ss"
        return formatter
    }()
}

private struct RequestSnapshotDetail: View {
    let snapshot: RequestSnapshot

    @Environment(\.dismiss) private var dismiss
    /// 默认只渲染每条消息的前 400 字；展开才铺全文。一次生成可能带十几万字
    /// 的上下文，全部文本 + textSelection 一次性铺出来会卡住主线程。
    @State private var expandedIndices: Set<Int> = []

    private static let previewCharacters = 400

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    summary
                    Divider().overlay(Theme.separator)

                    ForEach(Array(snapshot.messages.enumerated()), id: \.offset) { index, message in
                        messageRow(index: index, message: message)
                        Divider().overlay(Theme.separator)
                    }
                }
                .padding(Theme.Spacing.l)
            }
            .pageBackground()
            .navigationTitle("请求详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            AppValueRow(
                title: "模型",
                value: snapshot.modelId.isEmpty ? "（未记录）" : snapshot.modelId
            )
            AppValueRow(title: "估算输入", value: "\(snapshot.estimatedInputTokens) tok")
            AppValueRow(title: "输入预算", value: "\(snapshot.inputBudgetTokens) tok")
            AppValueRow(title: "上下文窗口", value: "\(snapshot.modelContextWindowTokens) tok")
            AppValueRow(title: "输出预留", value: "\(snapshot.outputReserveTokens) tok")
            AppValueRow(title: "丢弃历史", value: "\(snapshot.omittedHistoryMessages) 条")
        }
        .padding(.bottom, Theme.Spacing.s)
    }

    @ViewBuilder
    private func messageRow(index: Int, message: LLMMessage) -> some View {
        let expanded = expandedIndices.contains(index)
        let preview = String(message.content.prefix(Self.previewCharacters))

        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("#\(index + 1) \(message.role)")
                    .font(Theme.numeric)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text("\(message.content.count) 字")
                    .font(Theme.numericSmall)
                    .foregroundStyle(.tertiary)
            }

            if expanded {
                Text(message.content)
                    .font(Theme.numeric)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(preview)
                    .font(Theme.numeric)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if message.content.count > Self.previewCharacters {
                Button(expanded ? "收起" : "展开全文") {
                    if expanded {
                        expandedIndices.remove(index)
                    } else {
                        expandedIndices.insert(index)
                    }
                }
                .font(Font.caption)
            }
        }
    }
}
