// 正文提示词发送范围配置：对应 `bodyPromptSendWhole` 与 `bodyPromptTailCodePoints`。
// 仅控制提交至模型上下文的正文截取范围，不修改本地正文数据。

import SwiftUI

struct WriterBodyRangeSheet: View {
    @Environment(AppStore.self) private var store
    @Bindable var session: ProjectSession
    @Environment(\.dismiss) private var dismiss

    private static let values: [Int] = [
        0, 4_000, 8_000, 16_000, 32_000, 64_000, 128_000, 256_000, 500_000, 1_000_000,
    ]

    private var currentValue: Int {
        session.payload.bodyPromptSendWhole
            ? 0
            : session.payload.bodyPromptTailCodePoints
    }

    private var selectedIndex: Int {
        Self.values.enumerated().min {
            abs($0.element - currentValue) < abs($1.element - currentValue)
        }?.offset ?? 0
    }

    private var indexBinding: Binding<Double> {
        Binding(
            get: { Double(selectedIndex) },
            set: { raw in
                let index = min(max(Int(raw.rounded()), 0), Self.values.count - 1)
                let value = Self.values[index]
                session.payload.bodyPromptSendWhole = value == 0
                if value > 0 {
                    session.payload.bodyPromptTailCodePoints = value
                }
                session.scheduleSave()
            }
        )
    }

    private var currentLabel: String {
        let size = session.manuscriptCharacterCount
        if session.payload.bodyPromptSendWhole {
            return "全文（\(size.formatted()) 字）"
        }
        return "末尾 \(formatCompactChars(session.payload.bodyPromptTailCodePoints)) / 正文 \(size.formatted()) 字"
    }

    private func formatCompactChars(_ count: Int) -> String {
        if count >= 1_000_000, count % 1_000_000 == 0 {
            return "\(count / 1_000_000)M 字"
        }
        if count >= 1_000, count % 1_000 == 0 {
            return "\(count / 1_000)K 字"
        }
        return "\(count.formatted()) 字"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        HStack {
                            Text("发送范围")
                                .font(Theme.label)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            Text(currentLabel)
                                .font(Theme.numeric)
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }

                        TactileSlider(
                            value: indexBinding,
                            in: 0...Double(Self.values.count - 1),
                            step: 1,
                            hapticsEnabled: store.settings.hapticsEnabled
                        )
                        .accessibilityLabel("正文发送范围")
                        .accessibilityValue(currentLabel)

                        HStack {
                            Text("发全文")
                            Spacer(minLength: 0)
                            Text(formatCompactChars(Self.values.last ?? 1_000_000))
                        }
                        .font(Theme.badge)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
            .navigationTitle("正文发送范围")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
