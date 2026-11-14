// 本文件负责：写作台的章节导航 —— 搜索、字数、当前章标记、点选跳转。

import SwiftUI

struct WriterChaptersSheet: View {
    let chapters: [Chapter]
    /// 全文 UTF-16 长度。章节字数用偏移差估算，避免为了列表再拼全文。
    let totalLength: Int
    let currentChapterID: String?
    let onSelect: (Chapter) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var rows: [Row] = []

    private struct Row: Identifiable {
        let chapter: Chapter
        let ordinal: Int
        let characters: Int
        var id: String { chapter.id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if rows.isEmpty {
                    EmptyStateView(
                        symbol: "list.bullet.indent",
                        title: "还没有章节"
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    list
                }
            }
            .pageBackground()
            .navigationTitle("章节")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .searchable(text: $query, prompt: "搜索章节标题")
        }
        .task {
            buildRows()
        }
    }

    private var list: some View {
        List(filtered) { row in
            let isCurrent = row.chapter.id == currentChapterID
            Button {
                onSelect(row.chapter)
                dismiss()
            } label: {
                ChapterNavigationRow(
                    ordinal: row.ordinal,
                    title: row.chapter.title,
                    characters: row.characters,
                    isCurrent: isCurrent
                )
            }
            .buttonStyle(.plain)
            .listRowBackground(isCurrent ? Theme.accentSoft : Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    private var filtered: [Row] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rows }
        return rows.filter {
            $0.chapter.title.localizedCaseInsensitiveContains(trimmed)
        }
    }

    /// 计算各章节字符区间与字数统计，并在挂载时执行一次。
    private func buildRows() {
        guard rows.isEmpty else { return }
        let length = max(0, totalLength)
        rows = chapters.enumerated().map { index, chapter in
            let start = min(max(chapter.location, 0), length)
            let end = index + 1 < chapters.count
                ? min(max(chapters[index + 1].location, start), length)
                : length
            return Row(
                chapter: chapter,
                ordinal: index + 1,
                characters: max(0, end - start)
            )
        }
    }
}
