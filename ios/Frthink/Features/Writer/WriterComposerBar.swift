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
    /// 输入条里控件的行内高度，跟随字号缩放（§2.4、§5.9）。
    @ScaledMetric(relativeTo: .body) private var controlSize: CGFloat = Theme.Layout.inlineControl

    var body: some View {
        // 材质与形状见 `WriterComposerShell`：iOS 26 玻璃胶囊，17–25 回落 `.bar`（§1.6）。
        WriterComposerShell {
            // 三件控件同一条中轴：输入框随行数长高时，两侧按钮跟着居中，
            // 不再按底边对齐：底对齐时圆钮会被玻璃内边距顶高一截。
            HStack(alignment: .center, spacing: Theme.Spacing.s) {
                continuationButton
                inputField
                if controller.isGenerating {
                    // 生成中主操作变成停止（§5.7）。
                    // 页面上只留这一个停止入口，气泡头部不再放第二个。
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

    /// 辅助按钮：续写。图标按输入条的行内高度画，热区仍是 44pt（§5.1）。
    private var continuationButton: some View {
        Button {
            sendContinuation()
        } label: {
            Image(systemName: "wand.and.stars")
                .font(Font.subheadline.weight(.medium))
                .foregroundStyle(controller.isGenerating ? Color.secondary : Theme.accent)
                .frame(width: controlSize, height: controlSize)
                .frame(width: Theme.Layout.hitTarget, height: Theme.Layout.hitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(controller.isGenerating || controller.isPreparing)
        .accessibilityLabel("续写")
    }

    private var inputField: some View {
        TextField(inputPlaceholder, text: $model.text, axis: .vertical)
            .font(Font.body)
            .lineLimit(1...5)
            .focused($focused)
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.vertical, Theme.Spacing.s)
            .frame(minHeight: controlSize)
            .modifier(WriterComposerFieldSurface())
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
        if #available(iOS 26.0, *) {
            content
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
        } else {
            content
                .padding(.horizontal, Theme.Spacing.m)
                .padding(.vertical, Theme.Spacing.s)
                .background(.bar)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(height: 0.5)
                }
        }
    }
}

/// 输入框表面。iOS 26 用玻璃胶囊（由外层 `GlassEffectContainer` 归并），
/// 17–25 用实底输入框胶囊——那一档整条已经是 `.bar`，内层再叠材质会糊成一片。
private struct WriterComposerFieldSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // 可点的输入框声明成 interactive，点下去有系统的玻璃反馈。
            content.glassSurface(Capsule(), interactive: true)
        } else {
            content.background(Theme.field, in: Capsule())
        }
    }
}

/// 输入条右侧的主操作：发送 / 停止。
///
/// 直径 34pt 的强调色实心圆，不用 glassProminent：玻璃主操作会给 44pt 的
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
                .foregroundStyle(isEnabled ? Color.white : Color.secondary)
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
