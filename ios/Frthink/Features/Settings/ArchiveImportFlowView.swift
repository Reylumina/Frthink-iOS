// 本文件负责：存档导入的结果页 —— 阶段进度、覆盖确认、完成摘要。
// 状态机在 `ArchiveImportController.swift`，这里只读它的状态。

import Foundation
import SwiftUI

/// 导入流程页：进度 / 覆盖确认 / 结果。由「存档与备份」页推进导航栈。
struct ArchiveImportFlowView: View {
    @Bindable var controller: ArchiveImportController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let outcome = controller.outcome {
                resultView(outcome)
            } else if let errorText = controller.errorText {
                errorView(errorText)
            } else {
                progressView
            }
        }
        .pageBackground()
        .navigationTitle("导入存档")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(controller.stage != nil)
        .toolbar {
            if controller.stage != nil {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { cancel() }
                }
            }
            if controller.outcome != nil || controller.errorText != nil {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { close() }
                }
            }
        }
        .onDisappear {
            // 正常点「完成」时 close() 已经复位；这里兜住侧滑返回与外部弹出。
            controller.cancel()
        }
        .alert(
            "覆盖同名书项目？",
            isPresented: Binding(
                get: { controller.pendingProjectImport != nil },
                set: { if !$0 { controller.clearPendingProjectImport() } }
            )
        ) {
            Button("取消", role: .cancel) { cancel() }
            Button("覆盖并导入", role: .destructive) {
                controller.confirmProjectOverride()
            }
        } message: {
            Text(overrideMessage)
        }
        .alert(
            "恢复全量备份？",
            isPresented: Binding(
                get: { controller.pendingFullRestore != nil },
                set: { if !$0 { controller.clearPendingFullRestore() } }
            )
        ) {
            Button("取消", role: .cancel) { cancel() }
            Button("恢复", role: .destructive) {
                controller.confirmFullRestore()
            }
        } message: {
            Text(fullRestoreMessage)
        }
    }

    private var overrideMessage: String {
        let titles = controller.pendingProjectImport?.overridingTitles ?? []
        let list = titles.prefix(4).joined(separator: "、")
        let suffix = titles.count > 4 ? " 等 \(titles.count) 本" : ""
        return "本机已有同名书项目：\(list)\(suffix)。覆盖后，这些书在本机的旧稿会被存档里的版本替换。"
    }

    private var fullRestoreMessage: String {
        guard let backup = controller.pendingFullRestore else { return "" }
        let count = backup.projects.count
        return "存档里有 \(count) 个项目。同名项目会被覆盖，本机其它项目保留；"
            + "全局设置会按存档合并（API Key 不受影响）。"
    }

    private var progressView: some View {
        VStack(spacing: Theme.Spacing.l) {
            ProgressView()
                .controlSize(.large)
            if let stage = controller.stage {
                Text(stage.title)
                    .font(Theme.labelEmphasis)
                    .foregroundStyle(.primary)
                Text(stage.detail)
                    .font(Font.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("正在准备…")
                    .font(Theme.labelEmphasis)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: 320)
        .cardSurface(radius: Theme.Radius.sheet)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultView(_ outcome: ArchiveImportOutcome) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Label(
                        outcome.isFull ? "全量存档已恢复" : "存档已导入",
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(Theme.heading)
                    .foregroundStyle(Theme.accent)
                    Text(resultSummary(outcome))
                        .font(Font.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVStack(spacing: 0) {
                    // 分隔线叠在行底，不进 ForEach 的子视图列表：每项只产出一个视图，
                    // 条件分支不会改变元素的结构身份。
                    ForEach(outcome.books) { book in
                        bookRow(book)
                            .overlay(alignment: .bottom) {
                                if book.id != outcome.books.last?.id {
                                    Divider().overlay(Theme.separator)
                                }
                            }
                    }
                }
                .cardSurface()

                if !outcome.settingsHighlights.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        Text("全局设置")
                            .font(Theme.sectionTitle)
                            .foregroundStyle(.secondary)
                        Text(outcome.settingsHighlights.joined(separator: " · "))
                            .font(Font.footnote)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Theme.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surfaceSecondary)
                    .clipShape(RoundedRectangle(
                        cornerRadius: Theme.Radius.medium,
                        style: .continuous
                    ))
                }
            }
            .padding(Theme.Spacing.l)
        }
    }

    private func bookRow(_ book: ArchiveBookSummary) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.s) {
                Text(book.title)
                    .font(Font.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if book.isTrashed {
                    Text("回收站")
                        .font(Theme.badge)
                        .foregroundStyle(AppTone.warning.color)
                }
                Spacer(minLength: 0)
                Text("\(book.bodyCharacters.formatted()) 字")
                    .font(Theme.numeric)
                    .foregroundStyle(.secondary)
            }
            Text(detailLine(book))
                .font(Font.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailLine(_ book: ArchiveBookSummary) -> String {
        var parts: [String] = []
        if book.messageCount > 0 { parts.append("对话 \(book.messageCount) 条") }
        if book.characterCardCount > 0 { parts.append("人物卡 \(book.characterCardCount) 张") }
        if book.worldbookCount > 0 { parts.append("世界书 \(book.worldbookCount) 条") }
        if book.eventCount > 0 { parts.append("事件卡 \(book.eventCount) 张") }
        if book.sourceCharacters > 0 { parts.append("原文 \(book.sourceCharacters.formatted()) 字") }
        return parts.isEmpty ? "正文为空" : parts.joined(separator: " · ")
    }

    private func resultSummary(_ outcome: ArchiveImportOutcome) -> String {
        let books = outcome.books.count
        let chars = outcome.totalCharacters.formatted()
        if outcome.isFull {
            return "\(books) 本书项目，正文共 \(chars) 字。"
        }
        return outcome.activeCount == books
            ? "\(books) 本书项目，正文共 \(chars) 字。"
            : "\(books) 本书项目（含回收站），正文共 \(chars) 字。"
    }

    private func errorView(_ text: String) -> some View {
        VStack(spacing: Theme.Spacing.l) {
            Image(systemName: "exclamationmark.triangle")
                .font(Font.system(size: 40))
                .foregroundStyle(.orange)
            Text("导入失败")
                .font(Theme.heading)
            Text(text)
                .font(Font.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("完成") { close() }
                .buttonStyle(.borderedProminent)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func close() {
        controller.dismiss()
        dismiss()
    }

    private func cancel() {
        controller.cancel()
        dismiss()
    }
}
