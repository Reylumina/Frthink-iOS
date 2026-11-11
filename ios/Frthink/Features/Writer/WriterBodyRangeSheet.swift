// 正文发送范围：原版 `bodyPromptSendWhole` / `bodyPromptTailCodePoints`。
// 只影响发给模型的正文片段，不改正文本身。

import SwiftUI

struct WriterBodyRangeSheet: View {
    @Bindable var session: ProjectSession
    @Environment(\.dismiss) private var dismiss

    private static let values: [Int] = [
        0, 1_000, 2_000, 3_000, 4_000, 5_000, 6_000, 7_000, 8_000, 9_000, 10_000,
        15_000, 20_000, 25_000, 30_000, 40_000, 50_000, 75_000, 100_000,
        125_000, 250_000, 500_000, 750_000, 1_000_000,
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
            return "全文 · \(size.formatted()) 字"
        }
        return "末尾 \(session.payload.bodyPromptTailCodePoints.formatted()) 字 · 正文 \(size.formatted()) 字"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AppValueRow(title: "发送范围", value: currentLabel)

                    Slider(
                        value: indexBinding,
                        in: 0...Double(Self.values.count - 1),
                        step: 1
                    )
                    .tint(Theme.accent)
                    .accessibilityLabel("正文发送范围")
                    .accessibilityValue(currentLabel)

                    HStack {
                        Text("发全文")
                        Spacer(minLength: 0)
                        Text("末尾最多 \(Self.values.last ?? 0) 字")
                    }
                    .font(Font.caption)
                    .foregroundStyle(.tertiary)
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
