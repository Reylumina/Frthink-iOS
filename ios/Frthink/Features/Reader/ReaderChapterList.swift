// 阅读页目录：展示正文解析出的章节列表，支持点击跳转至对应位置。
//
// 章节行复用于写作工作台章节表（`WriterChaptersSheet`），保证展示一致。

import SwiftUI

/// 目录。章节来自 `ChapterScanner` 扫出的 `session.payload.chapters`，只读索引。
///
/// 章节为后台计算数据：排版未完成时展示加载状态，确认无章节后展示空状态，
/// 避免误报。
struct ReaderChapterList: View {
    let chapters: [Chapter]
    /// 正文或章节索引准备中。
    let isLoading: Bool
    let currentChapterID: String?
    let onSelect: (Chapter) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if chapters.isEmpty {
                    EmptyStateView(
                        symbol: "list.bullet.indent",
                        title: "还没有章节"
                    )
                } else {
                    List {
                        ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                            row(index: index, chapter: chapter)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .pageBackground()
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SheetCloseButton(title: "完成") { dismiss() }
                }
            }
        }
    }

    private func row(index: Int, chapter: Chapter) -> some View {
        let isCurrent = chapter.id == currentChapterID
        return Button {
            onSelect(chapter)
            dismiss()
        } label: {
            ChapterNavigationRow(
                ordinal: index + 1,
                title: chapter.title,
                isCurrent: isCurrent
            )
            .frame(minHeight: Theme.Layout.rowContentHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isCurrent ? Theme.accentSoft : Color.clear)
    }
}
