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
    /// 键盘是否弹起。父视图据此显示「收起键盘」的 X。
    var isEditing: Bool = false
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
    /// 输入条里控件的行内高度，跟随字号缩放（§2.4、§5.9）。
    @ScaledMetric(relativeTo: .body) private var controlSize: CGFloat = Theme.Layout.inlineControl

    var body: some View {
        // 材质与形状见 `WriterComposerShell`：iOS 26 玻璃胶囊，17–25 回落 `.bar`（§1.6）。
        WriterComposerShell {
            // 一块输入区域把续写、输入、发送包在一起（§5.9）：三件控件共用同一个
            // 胶囊表面，不再各自成块。行内控件同一条中轴，输入框长高时两侧跟着居中。
            HStack(alignment: .center, spacing: Theme.Spacing.xs) {
                continuationButton
                TextField(inputPlaceholder, text: $model.text, axis: .vertical)
                    .font(Font.body)
                    .lineLimit(1...5)
                    .focused($focused)
                primaryControl
            }
            .padding(.leading, Theme.Spacing.s)
            .padding(.trailing, Theme.Spacing.xs)
            .padding(.vertical, Theme.Spacing.xs)
            .frame(minHeight: controlSize)
            .modifier(WriterComposerFieldSurface())
        }
        .onAppear {
            if autoFocus {
                focused = true
            }
        }
        .onChange(of: focused) { _, editing in
            model.isEditing = editing
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

    /// 续写入口：浅灰淡圆底包裹图标，和右侧实心圆发送键形成对称但主次分明的结构。
    private var continuationButton: some View {
        Button {
            sendContinuation()
        } label: {
            Image(systemName: "wand.and.stars")
                .font(Font.subheadline.weight(.medium))
                .foregroundStyle(controller.isGenerating ? Color.secondary : Theme.accent)
                .frame(width: glyph, height: glyph)
                .background(Theme.field, in: Circle())
                // 可视尺寸 28pt，热区补回 44pt；负内边距把多出来的占位让回去，
                // 胶囊不会因此被撑高（§5.1）。
                .frame(width: Theme.Layout.hitTarget, height: Theme.Layout.hitTarget)
                .contentShape(Rectangle())
                .padding(.horizontal, -(Theme.Layout.hitTarget - glyph) / 2)
                .padding(.vertical, -(Theme.Layout.hitTarget - glyph) / 2)
        }
        .buttonStyle(.plain)
        .disabled(controller.isGenerating || controller.isPreparing)
        .accessibilityLabel("续写")
    }

    /// 续写图标的可视边长。
    private var glyph: CGFloat { controlSize * 0.82 }

    /// 行尾主操作：生成中是停止，准备中是转圈，其余是发送（§5.7）。
    @ViewBuilder
    private var primaryControl: some View {
        if controller.isGenerating {
            WriterComposerPrimaryButton(
                symbol: "stop.fill",
                label: "停止创作",
                isEnabled: true
            ) {
                controller.stop()
            }
        } else if controller.isPreparing {
            ProgressView()
                .frame(width: Theme.Layout.hitTarget, height: Theme.Layout.hitTarget)
        } else {
            WriterComposerPrimaryButton(
                symbol: "paperplane.fill",
                label: "发送",
                isEnabled: canSend
            ) {
                send()
            }
        }
    }

    /// 草稿仅在收键盘或离开页面时写回 `session.payload`，避免输入期间高频触发 `@Observable` 整页重算。
    private func saveDraft() {
        let text = model.text
        guard session.payload.composerDraft != text else { return }
        session.payload.composerDraft = text
        session.scheduleSave()
    }

    private var canSend: Bool {
        !controller.isGenerating
            && !controller.isPreparing
            && store.settings.activeProvider != nil
            && !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var inputPlaceholder: String {
        if controller.isPreparing {
            return "码字机准备中…"
        }
        return store.settings.activeProvider == nil
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

// MARK: - 输入条材质

/// 输入条外壳。§1.6：iOS 26 只有输入框是玻璃胶囊，发送键是实心圆，
/// 所以这一条只有一个玻璃元素、不套 `GlassEffectContainer`，也不铺满宽底条；
/// 17–25 回落成 `.bar` 材质满宽底条。两档分支收在组件里，页面代码不写
/// `#available`（§5.2）。
private struct WriterComposerShell<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let padded = content
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)

        if #available(iOS 26.0, *) {
            padded
        } else {
            padded
                .background(.bar)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(height: 0.5)
                }
        }
    }
}

/// 输入框表面。iOS 26 用 interactive 玻璃胶囊；17–25 用实底胶囊，避免在 `.bar` 上再叠材质。
private struct WriterComposerFieldSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassSurface(Capsule(), interactive: true)
        } else {
            content.background(Theme.field, in: Capsule())
        }
    }
}

/// 输入条右侧的主操作：发送 / 停止。
///
/// 直径 34pt（主题里的行内高度 token）的强调色实心圆，不用 glassProminent：玻璃主操作会给 44pt 的
/// 热区再包一圈内边距，@3x 下量出来的实心圆是 59pt，比输入框还高，圆心比
/// 输入框中线高 12pt，整行看着是歪的。§5.4 的「一屏一个主操作」靠颜色和
/// 位置表达，不靠放大。禁用时退回 field 底 + 次要色图标。
private struct WriterComposerPrimaryButton: View {
    let symbol: String
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var size: CGFloat = Theme.Layout.inlineControl

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Font.subheadline.weight(.semibold))
                .foregroundStyle(isEnabled ? Theme.onAccent : Color.secondary)
                .frame(width: size, height: size)
                .background(Circle().fill(isEnabled ? Theme.accent : Theme.field))
                .frame(
                    minWidth: Theme.Layout.hitTarget,
                    minHeight: Theme.Layout.hitTarget
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
    }
}
