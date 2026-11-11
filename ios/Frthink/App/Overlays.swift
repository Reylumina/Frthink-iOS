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
