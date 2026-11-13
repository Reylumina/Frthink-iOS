// AI服务商编辑页：类型、地址、模型、生成参数、API Key 与连通性测试。
//
// 编辑都落在本地 draft 上，点「保存」才写回 AppStore；只有 Key 走 Keychain。
// 界面永远只显示掩码。测试连接与保存解耦：测试失败不会清空表单，也不会阻止保存。

import SwiftUI
import Foundation

struct ProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss

    private let store: AppStore
    private let onSaved: () -> Void

    @State private var original: ProviderSetting
    @State private var draft: ProviderSetting
    /// 新输入的 Key。留空表示不修改已有的。
    @State private var keyInput: String = ""
    @State private var statusText: String?
    @State private var statusKind: AppStatusLine.Kind = .info
    @State private var isBusy = false
    @State private var isTesting = false
    @State private var models: [String] = []
    @State private var showingModelPicker = false
    /// 避免同一个视图挂两个 `confirmationDialog`：用一份待确认状态驱动。
    @State private var pendingConfirmation: EditorConfirmation?
    /// 钥匙串写入不在 Observation 里，改完 Key 用它顶一下刷新。
    @State private var keyRevision = 0

    private enum EditorConfirmation {
        case discard
        case clearKey
    }

    init(store: AppStore, provider: ProviderSetting, onSaved: @escaping () -> Void) {
        self.store = store
        self.onSaved = onSaved
        _original = State(initialValue: provider)
        _draft = State(initialValue: provider)
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                generationSection
                keySection
                actionSection
                dangerSection
            }
            .navigationTitle(draft.kind.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton {
                        if hasChanges {
                            pendingConfirmation = .discard
                        } else {
                            dismiss()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton(title: "保存") { save() }
                }
            }
            .sheet(isPresented: $showingModelPicker) {
                ModelPickerSheet(
                    models: models,
                    currentModel: draft.resolvedModel
                ) { picked in
                    draft.model = picked
                }
            }
            .confirmationDialog(
                confirmationTitle,
                isPresented: confirmationBinding,
                titleVisibility: .visible
            ) {
                switch pendingConfirmation {
                case .discard:
                    Button("放弃修改", role: .destructive) { dismiss() }
                    Button("继续编辑", role: .cancel) {}
                case .clearKey:
                    Button("清除 Key", role: .destructive) { clearKey() }
                    Button("取消", role: .cancel) {}
                case nil:
                    Button("取消", role: .cancel) {}
                }
            }
        }
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .discard: return "放弃未保存的修改？"
        case .clearKey: return "清除这个AI服务商的 API Key？"
        case nil: return ""
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingConfirmation != nil },
            set: { if !$0 { pendingConfirmation = nil } }
        )
    }

    // MARK: - 连接

    /// 新建时只给三类；旧的 OpenCode AI服务商仍可在编辑时保留。
    private var editableKinds: [ProviderKind] {
        var kinds = ProviderKind.selectableCases
        if draft.kind == .openCodeGo, !kinds.contains(.openCodeGo) {
            kinds.append(.openCodeGo)
        }
        return kinds
    }

    private enum ProviderPreset: String, CaseIterable, Identifiable {
        case custom
        case openCodeGo

        var id: String { rawValue }
        var title: String {
            switch self {
            case .custom: return "自定义"
            case .openCodeGo: return "OpenCode Go"
            }
        }
    }

    private var presetBinding: Binding<ProviderPreset> {
        Binding(
            get: {
                draft.baseURLForDisplay.lowercased().contains("opencode.ai")
                    ? .openCodeGo : .custom
            },
            set: { preset in
                switch preset {
                case .openCodeGo:
                    draft.baseURL = ProviderKind.openCodeGo.defaultBaseURL
                    draft.model = ProviderKind.openCodeGo.defaultModel
                case .custom:
                    if draft.baseURLForDisplay.lowercased().contains("opencode.ai") {
                        draft.baseURL = ""
                        draft.model = ""
                    }
                }
                models = []
            }
        )
    }

    private var connectionSection: some View {
        Section {
            Picker("类型", selection: $draft.kind) {
                ForEach(editableKinds) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .onChange(of: draft.kind) { oldKind, newKind in
                // 地址/模型还是旧类型的默认值时才跟着换，用户自己填过的不动。
                if draft.baseURL.isEmpty || draft.baseURL == oldKind.defaultBaseURL {
                    draft.baseURL = newKind.defaultBaseURL
                }
                if draft.model.isEmpty || draft.model == oldKind.defaultModel {
                    draft.model = newKind.defaultModel
                }
                models = []
            }

            if draft.kind == .openAICompatible {
                Picker("预设", selection: presetBinding) {
                    ForEach(ProviderPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.menu)
            }

            AppTextField(
                title: "服务地址",
                text: $draft.baseURL,
                placeholder: draft.kind.defaultBaseURL.isEmpty
                    ? "https://host/v1"
                    : draft.kind.defaultBaseURL,
                keyboard: .URL
            )

            AppTextField(
                title: "模型",
                text: $draft.model,
                placeholder: "模型名",
                hint: deprecatedModelHint
            )

            Button {
                loadModels()
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    if isBusy && !isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.circle")
                    }
                    Text(models.isEmpty ? "从服务端读取模型列表" : "重新读取模型列表")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(minHeight: Theme.Layout.rowContentHeight)
            }
            .disabled(isBusy)
        } header: {
            AppSectionHeader(title: "连接")
        }
    }

    /// 已弃用的历史别名要当场提示，别让用户发出去才发现 400。
    private var deprecatedModelHint: String? {
        guard draft.usesDeprecatedModel else { return nil }
        let latest = ModelCatalog.latest(for: draft.kind) ?? ""
        return "\(draft.resolvedModel) 已弃用，建议改为 \(latest)"
    }

    // MARK: - 生成

    private var generationSection: some View {
        Section {
            Toggle("流式输出", isOn: $draft.stream)

            Picker("思考档位", selection: thinkingBinding) {
                ForEach(ThinkingLevel.allCases) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.menu)

            // 关闭思考时要不要额外发一个「别推理」的字段。默认不发，和原版一致；
            // 服务端默认开推理（OpenCode 这类）时才需要挑一种。
            if draft.effectiveThinkingLevel == .off, !draft.isDeepSeek {
                Picker("关闭思考时发送", selection: reasoningOffBinding) {
                    ForEach(ReasoningOffStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                HStack {
                    Text("温度")
                    Spacer(minLength: 0)
                    Text(String(format: "%.2f", draft.temperature))
                        .font(Theme.numeric)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $draft.temperature, in: 0...2, step: 0.05)
                    .tint(Theme.accent)
            }
        } header: {
            AppSectionHeader(title: "生成")
        }
    }

    private var thinkingBinding: Binding<ThinkingLevel> {
        Binding(
            get: { draft.effectiveThinkingLevel },
            set: { level in
                draft.thinkingLevel = level
                draft.thinking = level != .off
            }
        )
    }

    private var reasoningOffBinding: Binding<ReasoningOffStyle> {
        Binding(
            get: { draft.effectiveReasoningOffStyle },
            set: { draft.reasoningOffStyle = $0 }
        )
    }

    // MARK: - API Key

    private var keySection: some View {
        Section {
            AppValueRow(title: "当前 Key", value: storedKeyDisplay)

            AppSecureField(
                title: keyInput.isEmpty ? "API Key" : "新 API Key",
                text: $keyInput,
                placeholder: storedKey.isEmpty ? "粘贴 API Key" : "留空表示不修改"
            )
        }
    }

    // MARK: - 动作

    private var actionSection: some View {
        Section {
            Button {
                testConnection()
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    if isTesting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "bolt.horizontal")
                    }
                    Text(isTesting ? "正在测试…" : "测试连接")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(minHeight: Theme.Layout.rowContentHeight)
            }
            .disabled(isBusy)

            if let statusText {
                AppStatusLine(kind: statusKind, text: statusText)
                    .listRowSeparator(.hidden)
            }

            Button {
                activate()
            } label: {
                HStack(spacing: Theme.Spacing.s) {
                    Image(systemName: "checkmark.circle")
                    Text(isActive ? "已设为当前AI服务商" : "保存并设为当前AI服务商")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .frame(minHeight: Theme.Layout.rowContentHeight)
            }
            .disabled(isActive || isBusy)
        } header: {
            AppSectionHeader(title: "状态")
        }
    }

    // MARK: - 危险动作

    private var dangerSection: some View {
        Section {
            DestructiveActionRow(
                title: "清除这个AI服务商的 API Key",
                systemImage: "key.slash",
                isEnabled: !storedKey.isEmpty
            ) {
                pendingConfirmation = .clearKey
            }
        }
    }

    // MARK: - 计算属性

    @MainActor
    private var isActive: Bool {
        store.settings.activeProviderID == draft.id
    }

    private var hasChanges: Bool {
        draft != original || !keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @MainActor
    private var storedKey: String {
        _ = keyRevision
        return store.apiKey(for: draft.id)
    }

    @MainActor
    private var storedKeyDisplay: String {
        storedKey.isEmpty ? "未填写" : ProviderEditorView.maskKey(storedKey)
    }

    @MainActor
    private var effectiveKey: String {
        let typed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? storedKey : typed
    }

    /// `sk-••••1234` 形式。空串就是没配。
    static func maskKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let prefix = trimmed.hasPrefix("sk-") ? "sk-" : String(trimmed.prefix(2))
        let suffix = trimmed.count > 4 ? String(trimmed.suffix(4)) : ""
        return prefix + "••••" + suffix
    }

    // MARK: - 网络

    /// 用「正在编辑的这份配置」造客户端，不改动当前AI服务商。
    @MainActor
    private func makeClient() throws -> any LLMClient {
        let key = effectiveKey
        guard !key.isEmpty else {
            throw LLMError.missingAPIKey(draft.kind.displayName)
        }
        var provider = draft
        if provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            provider.baseURL = provider.kind.defaultBaseURL
        }
        guard !provider.baseURLForDisplay.isEmpty else {
            throw LLMError.badURL(provider.baseURL)
        }
        return OpenAICompatibleClient(
            baseURL: provider.baseURLForDisplay,
            apiKey: key,
            provider: provider
        )
    }

    @MainActor
    private func testConnection() {
        guard !isBusy else { return }
        isTesting = true
        isBusy = true
        statusText = "正在测试连接…"
        statusKind = .progress
        Task { @MainActor in
            do {
                let client = try makeClient()
                try await client.testConnection()
                statusText = "连接成功"
                statusKind = .success
            } catch {
                statusText = "连接失败：\(error.localizedDescription)"
                statusKind = .failure
            }
            isBusy = false
            isTesting = false
        }
    }

    @MainActor
    private func loadModels() {
        guard !isBusy else { return }
        guard !effectiveKey.isEmpty else {
            statusText = "先填 API Key，再读取模型列表"
            statusKind = .failure
            return
        }
        isBusy = true
        statusText = "正在读取模型列表…"
        statusKind = .progress
        Task { @MainActor in
            do {
                let client = try makeClient()
                let list = try await client.listModels()
                models = list
                if list.isEmpty {
                    statusText = "服务端没有返回任何模型"
                    statusKind = .failure
                } else {
                    statusText = "读取到 \(list.count) 个模型"
                    statusKind = .success
                    showingModelPicker = true
                }
            } catch {
                statusText = "读取失败：\(error.localizedDescription)"
                statusKind = .failure
            }
            isBusy = false
        }
    }

    // MARK: - 保存

    @MainActor
    @discardableResult
    private func commit() -> Bool {
        var normalized = draft
        normalized.baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalized.baseURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              !(url.host?.isEmpty ?? true)
        else {
            statusText = "Base URL 格式无效，请填写 http:// 或 https:// 开头的地址"
            statusKind = .failure
            return false
        }
        draft = normalized

        var settings = store.settings
        if let index = settings.providers.firstIndex(where: { $0.id == draft.id }) {
            settings.providers[index] = draft
        } else {
            settings.providers.append(draft)
        }
        store.settings = settings

        let typed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            store.setAPIKey(typed, for: draft.id)
            keyInput = ""
            keyRevision += 1
        }
        store.saveSettings()
        return true
    }

    @MainActor
    private func save() {
        guard commit() else { return }
        original = draft
        onSaved()
        dismiss()
    }

    @MainActor
    private func activate() {
        guard commit() else { return }
        store.settings.activeProviderID = draft.id
        store.saveSettings()
        original = draft
        onSaved()
        statusText = "已设为当前AI服务商"
        statusKind = .success
    }

    @MainActor
    private func clearKey() {
        store.setAPIKey("", for: draft.id)
        keyInput = ""
        keyRevision += 1
        statusText = "已清除这个AI服务商的 Key"
        statusKind = .success
    }
}

/// 服务端返回的模型列表选择器。OpenRouter 有几百个模型，所以带搜索。
struct ModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let models: [String]
    var currentModel: String = ""
    let onPick: (String) -> Void

    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(filtered, id: \.self) { model in
                    modelRow(model)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "搜索模型")
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton(title: "关闭") { dismiss() }
                }
            }
        }
    }

    private func modelRow(_ model: String) -> some View {
        Button {
            onPick(model)
            dismiss()
        } label: {
            HStack(spacing: Theme.Spacing.s) {
                Text(model)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Theme.Spacing.s)
                if model == currentModel {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("当前")
                }
            }
            .contentShape(Rectangle())
            .frame(minHeight: Theme.Layout.rowContentHeight)
        }
        .buttonStyle(.plain)
    }

    private var filtered: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(trimmed) }
    }
}
