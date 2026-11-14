// 阅读页搜索面板：提供关键词输入、匹配结果列表及上下导航。

import Foundation
import SwiftUI

/// 搜索面板：检索当前阅读模式下的文本内容，占位提示跟随模式切换。
///
/// 面板以覆盖层形式展示于正文上方，不改变正文布局。检索进行中展示加载态，
/// 结果就绪或确认为空后再切换内容，避免界面闪烁。
struct ReaderSearchPanel: View {
    let mode: ReaderMode
    @Binding var query: String
    let matches: [ReaderMatch]
    let currentIndex: Int
    /// 全文检索进行中状态；为 true 时显示加载提示。
    let isSearching: Bool
    let onSubmit: () -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSelect: (Int) -> Void
    let onClose: () -> Void

    /// 匹配结果列表最大展示行数，其余项通过翻页导航浏览。
    private static let visibleRows = 60

    @FocusState private var focused: Bool
    /// 列表高度支持 Dynamic Type 动态缩放，确保大字号下完整展示。
    @ScaledMetric(relativeTo: .body) private var resultListHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            searchField
            if !trimmedQuery.isEmpty {
                results
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().overlay(Theme.separator)
        }
        .onAppear { focused = true }
    }

    // MARK: - 输入

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(Font.footnote)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            TextField(mode.searchPlaceholder, text: $query)
                .font(Font.subheadline)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($focused)
                .accessibilityLabel(mode.searchPlaceholder)
                .onSubmit(onSubmit)

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Font.footnote)
                        .foregroundStyle(.tertiary)
                        .frame(
                            minWidth: Theme.Layout.hitTarget,
                            minHeight: Theme.Layout.hitTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空关键词")
            }

            Button {
                focused = false
                onClose()
            } label: {
                Text("收起")
                    .font(Font.footnote.weight(.medium))
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: Theme.Layout.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.field)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
    }

    // MARK: - 状态与命中

    @ViewBuilder
    private var results: some View {
        if isSearching {
            AppStatusLine(kind: .progress, text: "正在搜索…")
        } else if matches.isEmpty {
            InlineEmptyState(
                symbol: "magnifyingglass",
                message: "没有找到「\(trimmedQuery)」"
            )
        } else {
            statusRow
            resultList
        }
    }

    private var statusRow: some View {
        HStack(spacing: Theme.Spacing.m) {
            Text(statusText)
                .font(Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: onPrevious) {
                Label("上一处", systemImage: "chevron.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("上一处")

            Button(action: onNext) {
                Label("下一处", systemImage: "chevron.down")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("下一处")
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var statusText: String {
        "第 \(currentIndex + 1)/\(matches.count) 处命中"
    }

    // MARK: - 命中列表

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(
                    Array(matches.prefix(Self.visibleRows).enumerated()),
                    id: \.element.id
                ) { index, match in
                    // 一行命中连同分隔线收成一个视图，`ForEach` 每项只对应一个。
                    VStack(spacing: 0) {
                        resultRow(index: index, match: match)
                        Divider().overlay(Theme.separator)
                    }
                }

                if matches.count > Self.visibleRows {
                    Text("还有 \(matches.count - Self.visibleRows) 条")
                        .font(Font.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Spacing.m)
                        .padding(.vertical, Theme.Spacing.s)
                }
            }
        }
        .frame(maxHeight: resultListHeight)
        .scrollDismissesKeyboard(.immediately)
        .cardSurface(radius: Theme.Radius.medium)
    }

    private func resultRow(index: Int, match: ReaderMatch) -> some View {
        Button {
            onSelect(index)
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Text("\(index + 1)")
                    .font(Theme.numeric)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, Theme.Spacing.xs)
                Text(match.snippet)
                    .font(Theme.prose)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .background(index == currentIndex ? Theme.accentSoft : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
