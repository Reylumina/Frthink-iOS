import SwiftUI

/// 底部轻提示。
///
/// 只写结果（「已插入正文」），一次一条，用系统材质浮在内容上，自动消失；
/// 淡入淡出与位移统一走 `motionLayout`，减弱动态效果时只保留淡入淡出。
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.label)
            .foregroundStyle(.primary)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            .glassSurface(Capsule())
            .accessibilityAddTraits(.isStaticText)
    }
}

/// 轻提示的展示与自动消失。根视图和 sheet 共用一份计时逻辑，
/// 避免两处各写一个 `Task.sleep` 又要各管一遍取消。
struct ToastPresenter: View {
    let text: String
    var bottomPadding: CGFloat = Theme.Spacing.xxl

    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ToastView(text: text)
            .padding(.bottom, bottomPadding)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .task(id: text) {
                try? await Task.sleep(for: .seconds(2.2))
                guard !Task.isCancelled else { return }
                withAnimation(Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)) {
                    store.toast = nil
                }
            }
    }
}

/// 顶部错误条。可点关闭。
struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: Theme.Spacing.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(Theme.metadata)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(Font.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(
                            minWidth: Theme.Layout.hitTarget,
                            minHeight: Theme.Layout.hitTarget
                        )
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("关闭")
            }
            .padding(Theme.Spacing.m)
            .glassSurface(radius: Theme.Radius.medium)
            .padding(Theme.Spacing.l)
            Spacer()
        }
    }
}

/// sheet 内的轻提示。根视图的 toast 会被 sheet 的展示层盖住，
/// 在会写 `store.toast` 的 sheet 根上挂这一层。
struct SheetToastOverlay: ViewModifier {
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastPresenter(text: toast)
            }
        }
    }
}

extension View {
    /// 在 sheet 里也能看到全局轻提示。
    func sheetToast() -> some View {
        modifier(SheetToastOverlay())
    }
}
