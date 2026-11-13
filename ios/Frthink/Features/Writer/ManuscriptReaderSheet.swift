// 本文件负责：正文页 —— 阅读为主，按需切到编辑。
//
// 创作页现在是 ChatBot 单栏，正文不再和对话挤在上下两半；点「正文」进入这里。
// 阅读态不挂键盘，编辑态才成为 first responder，退出编辑立即保存并回灌只读视图。

import SwiftUI
import UIKit

struct ManuscriptReaderSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @Bindable var session: ProjectSession
    @Binding var cursor: Int
    let onCursorInteraction: () -> Void

    @State private var editing = false
    @State private var scrollRequest: ManuscriptScrollRequest?
    @State private var showChapters = false
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var showRewrite = false
    @State private var rewriteRange = NSRange(location: 0, length: 0)
    @State private var rewriteText = ""
    /// 正文编辑器的撤销栈状态：编辑时 ⋯ 菜单里的「撤销 / 重做」跟着它变。
    @State private var undoState: WriterUndoState?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showsWindowBanner {
                    windowBanner
                }

                ManuscriptTextEditor(
                    text: Binding(
                        get: { session.editorText },
                        set: { session.updateEditorText($0) }
                    ),
                    cursor: editorCursor,
                    scrollRequest: scrollRequest,
                    fontSize: DynamicTypeFont.bodySize(
                        store.settings.bodyFontSize,
                        dynamicTypeSize: dynamicTypeSize
                    ),
                    revision: session.manuscriptRevision,
                    isEditable: editing,
                    onCursorInteraction: onCursorInteraction,
                    onSelectionChange: { range in
                        selection = range
                    },
                    onUndoManagerReady: { manager in
                        guard let manager else { return }
                        undoState = WriterUndoState(manager: manager)
                    }
                )

                if selection.length > 0 {
                    rewriteBar
                }

                Divider().overlay(Theme.separator)

                bottomBar
            }
            .pageBackground()
            .navigationTitle("正文")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { close() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing ? "完成编辑" : "编辑") {
                        toggleEditing()
                    }
                }
                if editing, let undoState {
                    // 编辑器的逐字撤销登记在 UITextView 自己的栈上；没有聚焦输入框
                    // 时摇一摇和 ⌘Z 不一定能触发，所以给一个看得见的入口（§5.8）。
                    ToolbarItem(placement: .topBarTrailing) {
                        undoMenu(undoState)
                    }
                }
            }
            .sheet(isPresented: $showChapters) {
                WriterChaptersSheet(
                    chapters: session.payload.chapters,
                    totalLength: session.manuscriptLength,
                    currentChapterID: currentChapter?.id
                ) { chapter in
                    jump(to: chapter)
                }
            }
            .sheet(isPresented: $showRewrite, onDismiss: rewriteDidDismiss) {
                ManuscriptRewriteSheet(
                    session: session,
                    range: rewriteRange,
                    selectedText: rewriteText,
                    cursor: $cursor
                )
            }
            .onAppear {
                session.beginWindowedEditing()
                let length = session.editorLength
                if cursor < 0 || cursor > length {
                    cursor = length
                }
                scrollRequest = ManuscriptScrollRequest(
                    location: session.editorLocalCursor(max(0, cursor))
                )
            }
            .onDisappear {
                if editing {
                    finishEditing()
                }
            }
            .sensoryFeedback(.selection, trigger: editing)
        }
    }

    private func undoMenu(_ undoState: WriterUndoState) -> some View {
        Menu {
            Button {
                undoState.undo()
            } label: {
                Label(undoState.undoTitle, systemImage: "arrow.uturn.backward")
            }
            .disabled(!undoState.canUndo)

            Button {
                undoState.redo()
            } label: {
                Label(undoState.redoTitle, systemImage: "arrow.uturn.forward")
            }
            .disabled(!undoState.canRedo)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("撤销与重做")
    }

    // MARK: - 窗口提示

    private var showsWindowBanner: Bool {
        session.isWindowEditing && session.editorWindowStart > 0
    }

    /// 只载入书末时明确告诉用户，避免误以为正文被截断；
    /// 「加载更早」放这里比塞进底栏更容易被发现，也不和字数抢位置。
    private var windowBanner: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                .font(Font.caption)
                .foregroundStyle(.secondary)
            Text("正文较长，当前只载入末段")
                .font(Font.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Theme.Spacing.s)
            Button("加载更早") {
                loadEarlier()
            }
            .font(Font.footnote.weight(.semibold))
            .frame(minHeight: Theme.Layout.controlHeight)
            .accessibilityHint("把更早的正文载入编辑器")
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.xs)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider().overlay(Theme.separator)
        }
    }

    // MARK: - 底栏

    /// 底栏只放章节与字数：撤销/重做不再占常驻按钮，
    /// 走系统 `UndoManager`（⌘Z / ⇧⌘Z、摇一摇、编辑菜单，§5.8）。
    private var bottomBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            chapterButton
            Spacer(minLength: Theme.Spacing.s)
            Text("\(session.manuscriptCharacterCount.formatted()) 字")
                .font(Theme.numericSmall)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
    }

    private var editorCursor: Binding<Int> {
        Binding(
            get: { session.editorLocalCursor(cursor) },
            set: { cursor = session.editorGlobalCursor($0) }
        )
    }

    private var chapterButton: some View {
        Button {
            showChapters = true
        } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(currentChapter?.title ?? "正文")
                    .font(Font.subheadline)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
            }
        }
        .buttonStyle(.plain)
        .disabled(session.payload.chapters.isEmpty)
    }

    // MARK: - 改写

    private var rewriteBar: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "wand.and.stars")
                .font(Font.caption.weight(.semibold))
                .foregroundStyle(Theme.accent)
            Text("已选 \(selection.length) 字")
                .font(Font.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.s)
            Button {
                openRewrite()
            } label: {
                Label("改写选区", systemImage: "sparkles")
                    .font(Font.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
        .background(.bar)
    }

    private func openRewrite() {
        let ns = session.editorText as NSString
        guard selection.length > 0,
              selection.location >= 0,
              selection.location + selection.length <= ns.length
        else { return }
        rewriteRange = NSRange(
            location: session.editorGlobalCursor(selection.location),
            length: selection.length
        )
        rewriteText = ns.substring(with: selection)
        showRewrite = true
    }

    /// 弹层关闭后收起旧的选区状态：替换成功时 `cursor` 已经在结果末尾，滚过去让用户看到；
    /// 取消时也把 UITextView 里留着的选区折成光标，避免“界面没按钮、正文却还高亮”。
    private func rewriteDidDismiss() {
        selection = NSRange(location: 0, length: 0)
        rewriteRange = NSRange(location: 0, length: 0)
        rewriteText = ""
        scrollRequest = ManuscriptScrollRequest(
            location: session.editorLocalCursor(max(0, cursor))
        )
    }

    // MARK: - 章节与编辑态

    private var currentChapter: Chapter? {
        let chapters = session.payload.chapters
        guard !chapters.isEmpty else { return nil }
        return chapters.last(where: { $0.location <= cursor }) ?? chapters.first
    }

    private func toggleEditing() {
        if editing {
            finishEditing()
        } else {
            editing = true
            onCursorInteraction()
        }
        if !editing {
            selection = NSRange(location: 0, length: 0)
        }
    }

    private func finishEditing() {
        session.saveNow()
        session.finishWindowEditing()
        session.noteManuscriptEdited()
        editing = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    private func close() {
        if editing {
            finishEditing()
        }
        dismiss()
    }

    private func jump(to chapter: Chapter) {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        selection = NSRange(location: 0, length: 0)
        session.reloadEditorWindow(containing: chapter.location)
        cursor = chapter.location
        scrollRequest = ManuscriptScrollRequest(
            location: session.editorLocalCursor(chapter.location)
        )
        onCursorInteraction()
    }

    /// 窗口只覆盖书末；向前扩一页，保持编辑器内存有界。
    private func loadEarlier() {
        guard session.isWindowEditing, session.editorWindowStart > 0 else { return }
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        let target = max(0, session.editorWindowStart - 1)
        session.reloadEditorWindow(containing: target)
        cursor = target
        scrollRequest = ManuscriptScrollRequest(
            location: session.editorLocalCursor(target)
        )
        onCursorInteraction()
    }
}
