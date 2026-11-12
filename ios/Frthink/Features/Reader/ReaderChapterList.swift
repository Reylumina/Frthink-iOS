// 本文件负责：阅读页的目录 —— 列出正文里扫出来的章节，点一下跳到对应位置。
//
// 章节行同时给写作台的章节表复用（`WriterChaptersSheet`），两处不要再各画一套。

import SwiftUI

/// 目录。章节来自 `ChapterScanner` 扫出的 `session.payload.chapters`，只读索引。
///
/// 章节是后台派生数据：正文还没排完时先显示加载态，确认扫不出章节之后再报空，
/// 不把「还没扫完」误报成「没有章节」。
struct ReaderChapterList: View {
    let chapters: [Chapter]
    /// 正文/章节索引还在准备。
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
            .frame(minHeight: Theme.Layout.hitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isCurrent ? Theme.accentSoft : Color.clear)
    }
}
