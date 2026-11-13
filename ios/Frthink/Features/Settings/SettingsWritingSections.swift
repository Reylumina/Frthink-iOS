// 设置三级页：生成参数、外观与交互。每个文件只放一类页面，参数不再堆在二级页里。

import Foundation
import SwiftUI

// MARK: - 全局模型响应

/// 三级页：默认 temperature / 回复上限。
///
/// 保留「全局默认值」与「当前凭证配置」两层：本页负责调整默认值，需要时再应用到当前AI服务商。
struct SettingsModelResponsePage: View {
    let store: AppStore

    @State private var temperature: Double

    init(store: AppStore) {
        self.store = store
        _temperature = State(initialValue: store.settings.defaultTemperature)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack {
                        Text("温度")
                        Spacer(minLength: 0)
                        Text(String(format: "%.2f", temperature))
                            .font(Theme.numeric)
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: $temperature,
                        in: 0...2,
                        step: 0.05,
                        onEditingChanged: { editing in
                            if !editing { commitTemperature() }
                        }
                    )
                    .tint(Theme.accent)
                }
                .padding(.vertical, 2)

                AppValueRow(
                    title: "回复上限",
                    value: settingsTokenText(store.settings.reservedOutputTokens)
                )
            } header: {
                AppSectionHeader(title: "默认值")
            }

            Section {
                SecondaryActionButton(
                    title: "应用到当前AI服务商",
                    systemImage: "arrow.down.to.line",
                    isEnabled: store.settings.activeProvider != nil
                ) {
                    applyToActiveProvider()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .settingsFormColumn()
        .navigationTitle("全局模型响应")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { commitTemperatureIfNeeded() }
    }

    @MainActor
    private func commitTemperature() {
        guard store.settings.defaultTemperature != temperature else { return }
        store.settings.defaultTemperature = temperature
        store.saveSettings()
    }

    @MainActor
    private func commitTemperatureIfNeeded() {
        commitTemperature()
    }

    @MainActor
    private func applyToActiveProvider() {
        commitTemperature()
        guard let provider = store.settings.activeProvider,
              let index = store.settings.providers.firstIndex(where: { $0.id == provider.id })
        else {
            store.toast = "先选好当前AI服务商"
            return
        }
        store.settings.providers[index].temperature = temperature
        store.saveSettings()
        store.toast = "已应用到 \(provider.kind.displayName)"
    }
}

// MARK: - 长上下文预算

/// 三级页：输入预算、单轮输出上限、由此算出的提示词预算。
///
/// 上下文窗口由模型决定，不在这里手调。
struct SettingsContextBudgetPage: View {
    let store: AppStore
    @State private var inputBudget = 0
    @State private var outputBudget = 0

    var body: some View {
        Form {
            if let provider = store.settings.activeProvider {
                Section {
                    AppValueRow(
                        title: "模型上下文窗",
                        value: settingsTokenText(effectiveWindow(for: provider.resolvedModel))
                    )
                }
            }

            Section {
                TokenSliderRow(
                    title: "输入预算",
                    values: Self.inputValues,
                    value: $inputBudget,
                    onCommit: commitBudgets
                )
            }

            Section {
                TokenSliderRow(
                    title: "单轮输出上限",
                    values: Self.outputValues,
                    value: $outputBudget,
                    onCommit: commitBudgets
                )
            }

            Section {
                AppValueRow(
                    title: "提示词预算",
                    value: settingsTokenText(store.settings.promptBudgetTokens)
                )
            }
        }
        .settingsFormColumn()
        .navigationTitle("长上下文预算")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            inputBudget = store.settings.inputBudgetTokens
            outputBudget = store.settings.reservedOutputTokens
        }
        .onDisappear { commitBudgets() }
    }

    /// 拖动结束或离开页面时提交一次，避免每个 tick 重写整份 settings.json。
    private func commitBudgets() {
        var changed = false
        if store.settings.inputBudgetTokens != inputBudget {
            store.settings.inputBudgetTokens = inputBudget
            changed = true
        }
        if store.settings.reservedOutputTokens != outputBudget {
            store.settings.reservedOutputTokens = outputBudget
            changed = true
        }
        if changed { store.saveSettings() }
    }

    private static let inputValues = [
        0, 1_024, 2_048, 4_096, 8_192, 16_384, 32_768,
        65_536, 131_072, 262_144, 524_288, 750_000, 1_000_000,
    ]

    private static let outputValues = [
        1_024, 2_048, 4_096, 8_192, 12_000, 16_000,
        20_000, 30_000, 40_000, 50_000, 75_000, 100_000,
    ]

    private func effectiveWindow(for model: String) -> Int {
        store.settings.contextWindowTokens > 0
            ? store.settings.contextWindowTokens
            : TokenEstimator.contextWindow(for: model)
    }
}

// MARK: - 外观

/// 外观页的第一节：主题 + 正文字号 + 实时预览。
struct SettingsAppearanceSection: View {
    let store: AppStore

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var fontSize: Double

    init(store: AppStore) {
        self.store = store
        _fontSize = State(initialValue: min(28, max(13, store.settings.bodyFontSize)))
    }

    /// 预览要和正文页用同一套换算，否则设置页看着合适、正文却更大。
    private var previewFontSize: CGFloat {
        DynamicTypeFont.bodySize(fontSize, dynamicTypeSize: dynamicTypeSize)
    }

    var body: some View {
        Section {
            Picker("主题", selection: settingsBinding(store, \.theme)) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack {
                    Text("正文字号")
                    Spacer(minLength: 0)
                    Text("\(Int(fontSize)) pt")
                        .font(Theme.numeric)
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $fontSize,
                    in: 13...28,
                    step: 1,
                    onEditingChanged: { editing in
                        if !editing { commitFontSize() }
                    }
                )
                .tint(Theme.accent)
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("夜色像被谁拧暗了一格，走廊尽头的灯还亮着。")
                    .font(ReaderStyle.bodyFont(size: previewFontSize))
                    .lineSpacing(ReaderStyle.lineSpacing(size: previewFontSize, lineHeight: 1.6))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("正文预览，\(Int(fontSize)) 点")
            }
            .padding(.vertical, 2)
        } header: {
            AppSectionHeader(title: "主题与正文")
        }
        .onAppear {
            // 字号范围统一为阅读页的 13–28，避免两处静默截断。
            if store.settings.bodyFontSize != fontSize {
                commitFontSize()
            }
        }
        .onDisappear { commitFontSize() }
    }

    @MainActor
    private func commitFontSize() {
        guard store.settings.bodyFontSize != fontSize else { return }
        store.settings.bodyFontSize = fontSize
        store.saveSettings()
        // 阅读页用自己的 @AppStorage 键；这里同步过去，范围与阅读页一致。
        // 键名与 ReaderStorageKey.fontSize 相同；Settings 不反向依赖 Reader 模块。
        UserDefaults.standard.set(fontSize, forKey: "reader.fontSize")
    }
}

/// 外观页的第二节：动画帧率。
struct SettingsAnimationSection: View {
    let store: AppStore

    var body: some View {
        Section {
            Toggle("限制界面动画为 60 帧", isOn: settingsBinding(store, \.limitAnimationFrameRate))
        } header: {
            AppSectionHeader(title: "动画")
        }
    }
}

/// 外观页的第三节：触感。
struct SettingsHapticsSection: View {
    let store: AppStore

    var body: some View {
        Section {
            Toggle("触感反馈", isOn: settingsBinding(store, \.hapticsEnabled))
        } header: {
            AppSectionHeader(title: "触感")
        }
    }
}

// MARK: - Token 滑块

/// 离散档位滑块，方便在大范围（如 4K–32K）快速调节。
struct TokenSliderRow: View {
    let title: String
    let values: [Int]
    @Binding var value: Int
    /// 拖动结束时提交，调用方负责一次性写盘。
    var onCommit: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.s) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                Text(displayValue)
                    .font(Theme.numeric)
                    .foregroundStyle(.secondary)
            }

            Slider(
                value: indexBinding,
                in: 0...Double(max(values.count - 1, 1)),
                step: 1,
                onEditingChanged: { editing in
                    if !editing { onCommit?() }
                }
            )
                .tint(Theme.accent)
                .accessibilityLabel(title)
                .accessibilityValue(displayValue)

            HStack {
                Text(label(for: values.first ?? 0))
                    .font(Theme.badge)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(label(for: values.last ?? 0))
                    .font(Theme.badge)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var selectedIndex: Int {
        values.enumerated().min {
            abs($0.element - value) < abs($1.element - value)
        }?.offset ?? 0
    }

    private var indexBinding: Binding<Double> {
        Binding(
            get: { Double(selectedIndex) },
            set: { raw in
                let index = min(max(Int(raw.rounded()), 0), values.count - 1)
                value = values[index]
            }
        )
    }

    private var displayValue: String {
        value == 0 ? "跟随模型" : value.formatted()
    }

    private func label(for value: Int) -> String {
        value == 0 ? "跟随模型" : value.formatted()
    }
}
