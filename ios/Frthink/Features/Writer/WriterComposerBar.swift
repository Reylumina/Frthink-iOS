// 本文件负责：写作台底部输入条（独立视图）。
//
// 为什么要拆出来：输入框的 `text` 若放在 `WriterPane` 的 `@State` 里，每敲一个
// 字都会让整页 body 重算（正文编辑器、章节条、对话列表都跟着求值）。按 Apple
// WWDC25《Optimize SwiftUI performance with Instruments》的建议，把高频变化的
// 状态隔离到只依赖它的小视图，写作台只保留低频状态。

import SwiftUI
import UIKit

/// 输入框的文本状态。父视图只持有引用、不在 body 里读 `text`，
/// 所以打字不会触发写作台整页更新。
@MainActor
@Observable
final class WriterComposerModel {
    var text: String = ""
    /// 父视图要求收起键盘时 +1。子视图收到后清掉自己的 FocusState。
    var dismissRequest: Int = 0
}

struct WriterComposerBar: View {
    let session: ProjectSession
    let controller: WriterController
    @Bindable var model: WriterComposerModel
    @Environment(AppStore.self) private var store

    /// 返回 false 表示没发出去（未配置供应方等），输入框要把文字还回去。
    let onSend: (String) -> Bool
    let onContinue: () -> Void
    /// 截图流水线用：进入页面就聚焦输入框。
    var autoFocus: Bool = false

    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            generatingBanner

            HStack(alignment: .bottom, spacing: Theme.Spacing.s) {
                Button {
                    sendContinuation()
                } label: {
                    Image(systemName: "wand.and.stars")
                        .font(Font.subheadline.weight(.medium))
                        .foregroundStyle(controller.isGenerating ? Color.secondary : Theme.accent)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(Theme.accentSoft))
                }
                .buttonStyle(.plain)
                .disabled(controller.isGenerating)
                .accessibilityLabel("续写")

                inputField

                Button {
                    send()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(Font.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(canSend ? Theme.accent : Theme.separator))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("发送")
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
        }
        .glassSurface(radius: 0)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.separator.opacity(0.6))
                .frame(height: 0.5)
        }
        .onAppear {
            if autoFocus {
                focused = true
            }
        }
        .onChange(of: focused) { _, editing in
            if !editing {
                saveDraft()
            }
        }
        .onChange(of: model.dismissRequest) { _, _ in
            focused = false
        }
        .onDisappear {
            // 切页/切书时把没落盘的草稿立刻写掉。
            saveDraft()
        }
    }

    /// 生成中的顶部横幅：进度 + 停止。不生成时整段不出现。
    @ViewBuilder
    private var generatingBanner: some View {
        if controller.isGenerating {
            HStack(spacing: Theme.Spacing.s) {
                ProgressView().controlSize(.small)
                Text("码字机正在写…")
                    .font(Font.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("停止") {
                    controller.stop()
                }
                .font(Font.caption.weight(.medium))
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            Divider().overlay(Theme.separator)
        }
    }

    private var inputField: some View {
        TextField(inputPlaceholder, text: $model.text, axis: .vertical)
            .font(Font.body)
            .lineLimit(1...5)
            .focused($focused)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s + 2)
            .background(Theme.card)
            .clipShape(RoundedRectangle(
                cornerRadius: Theme.Radius.large,
                style: .continuous
            ))
            .overlay(
                RoundedRectangle(
                    cornerRadius: Theme.Radius.large,
                    style: .continuous
                )
                .strokeBorder(Theme.separator, lineWidth: 0.5)
            )
    }

    /// 草稿只在收键盘/离开页面时落盘。
    ///
    /// 以前每次停顿 600ms 就写一次 `session.payload.composerDraft`：`payload` 是
    /// `@Observable` 上的值类型，写一次会让写作台整页重算（正文、气泡、章节全部
    /// 重新求值），输入时每隔半秒就顿一下。草稿不是高频状态，收键盘再存足够。
    private func saveDraft() {
        let text = model.text
        guard session.payload.composerDraft != text else { return }
        session.payload.composerDraft = text
        session.scheduleSave()
    }

    private var canSend: Bool {
        !controller.isGenerating
            && store.settings.activeProvider != nil
            && !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputPlaceholder: String {
        store.settings.activeProvider == nil
            ? "先在设置里添加 AI 服务商"
            : "告诉码字机你想写什么、修改什么或重写什么…"
    }

    private func send() {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        dismissKeyboard()
        model.text = ""
        if !onSend(text) {
            model.text = text
            focused = true
            return
        }
        saveDraft()
    }

    private func sendContinuation() {
        dismissKeyboard()
        onContinue()
    }

    private func dismissKeyboard() {
        focused = false
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}
