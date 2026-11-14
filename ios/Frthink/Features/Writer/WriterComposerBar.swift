// 本文件负责：写作台底部输入条（独立视图）。
//
// 将高频变化的输入文本状态独立封装至子视图中，避免输入过程中触发父视图大范围重新求值。

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

    /// 发送回调，返回 false 表示发送未成功，输入框还原原草稿文本。
    let onSend: (String) -> Bool
    let onContinue: () -> Void
    /// 截图流水线用：进入页面就聚焦输入框。
    var autoFocus: Bool = false

    @FocusState private var focused: Bool
    /// 输入条里控件的行内高度，跟随字号缩放（§2.4、§5.9）。
    @ScaledMetric(relativeTo: .body) private var controlSize: CGFloat = Theme.Layout.inlineControl

    /// 键盘弹起时右侧关闭按钮的直径：与胶囊总高（34pt 控件 + 上下各 4pt 内边距 = 42pt）一致，视觉同高。
    private var dismissButtonSize: CGFloat { controlSize + Theme.Spacing.xs * 2 }

    var body: some View {
        // 材质与形状见 `WriterComposerShell`：iOS 26 玻璃胶囊，17–25 回落 `.bar`（§1.6）。
        WriterComposerShell {
            HStack(alignment: .center, spacing: Theme.Spacing.s) {
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
                .padding(Theme.Spacing.xs)
                .frame(minHeight: dismissButtonSize)
                .modifier(WriterComposerFieldSurface())

                if focused {
                    keyboardDismissButton
                        .transition(.scale(scale: 0.85).combined(with: .opacity))
                }
            }
            .animation(Theme.motionLayout, value: focused)
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
            // 页面退出或切换项目时立即持久化输入草稿。
            saveDraft()
        }
    }

    /// 键盘升起时显示在输入条右侧的圆形玻璃关闭键，与系统搜索栏右侧关闭键同位同形。
    private var keyboardDismissButton: some View {
        Button {
            dismissKeyboard()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: dismissButtonSize, height: dismissButtonSize)
                .modifier(WriterComposerCircleSurface())
                .frame(
                    minWidth: Theme.Layout.hitTarget,
                    minHeight: Theme.Layout.hitTarget
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("收起键盘")
    }

    /// 续写入口：与右侧发送按钮等径的浅灰圆钮，保持左右对称与主次分明。
    private var continuationButton: some View {
        Button {
            sendContinuation()
        } label: {
            Image(systemName: "wand.and.stars")
                .font(Font.subheadline.weight(.semibold))
                .foregroundStyle(controller.isGenerating ? Color.secondary : Theme.accent)
                .frame(width: controlSize, height: controlSize)
                .background(Circle().fill(Theme.field))
                .frame(
                    minWidth: Theme.Layout.hitTarget,
                    minHeight: Theme.Layout.hitTarget
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isGenerating || controller.isPreparing)
        .accessibilityLabel("续写")
    }

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
            : "告诉码字机你的创作想法…"
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
/// 内部兼容不同系统版本的材质适配，封装系统版本分支判断。
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

/// 键盘关闭按钮的圆形表面，与输入胶囊同材质。
private struct WriterComposerCircleSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassSurface(Circle(), interactive: true)
        } else {
            content.background(Theme.field, in: Circle())
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
