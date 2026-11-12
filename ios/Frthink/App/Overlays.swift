import SwiftUI

/// 底部轻提示。业务侧设 `AppStore.toast` 就会自动弹出并在 2 秒后消失。
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s + 2)
            .background(Capsule().fill(Color.black.opacity(0.78)))
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
                Text(message)
                    .font(Font.footnote)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(Font.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
            .padding(Theme.Spacing.m)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
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
                ToastView(text: toast)
                    .padding(.bottom, Theme.Spacing.xxl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: toast) {
                        try? await Task.sleep(for: .seconds(2.2))
                        guard !Task.isCancelled else { return }
                        withAnimation { store.toast = nil }
                    }
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
