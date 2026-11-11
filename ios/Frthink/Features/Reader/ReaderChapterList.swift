// 本文件负责：阅读页的目录 —— 列出正文里扫出来的章节，点一下跳到对应位置。
//
// 章节行同时给写作台的章节表复用（`WriterChaptersSheet`），两处不要再各画一套。

import SwiftUI

/// 目录。章节来自 `ChapterScanner` 扫出的 `session.payload.chapters`，只读索引。
struct ReaderChapterList: View {
    let chapters: [Chapter]
    let currentChapterID: String?
    let onSelect: (Chapter) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if chapters.isEmpty {
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
            .pageBackground()
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
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
        }
        .buttonStyle(.plain)
        .listRowBackground(isCurrent ? Theme.accentSoft : Color.clear)
    }
}
