import Foundation

/// LLM 供应方。Android 端是一个 Kotlin enum，字符串常量在 DEX 里是
/// `DEEPSEEK` / `OPENROUTER` / `OPENAI_COMPATIBLE` / `CUSTOM_OPENAI_COMPATIBLE`。
///
/// 后两者行为一致，都是「OpenAI 兼容的任意端点」，这里合为一个 case。
enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case deepseek = "DEEPSEEK"
    case openRouter = "OPENROUTER"
    case anthropic = "ANTHROPIC"
    case openAICompatible = "OPENAI_COMPATIBLE"
    case openCodeGo = "OPENCODE_GO"

    var id: String { rawValue }

    /// 新建供应方时可选类型；OpenCode 已并入 OpenAI 兼容预设。
    static var selectableCases: [ProviderKind] {
        [.deepseek, .openRouter, .anthropic, .openAICompatible]
    }

    var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek"
        case .openRouter: return "OpenRouter"
        case .anthropic: return "Claude"
        case .openAICompatible: return "OpenAI 兼容"
        case .openCodeGo: return "OpenAI 兼容"
        }
    }

    /// 设置页的服务商图标。OpenRouter 用分叉表示路由，OpenAI 兼容用机架。
    var symbolName: String {
        switch self {
        case .deepseek: return "sparkles"
        case .openRouter: return "arrow.triangle.branch"
        case .anthropic: return "sparkle"
        case .openAICompatible: return "server.rack"
        case .openCodeGo: return "chevron.left.forwardslash.chevron.right"
        }
    }

    /// 官方品牌标的 asset 名；OpenAI 兼容默认回落到 OpenAI 图标。
    var logoAssetName: String? {
        logoAssetName(forBaseURL: nil)
    }

    /// 按协议与服务地址解析品牌图标（兼容标准 API 与各家 Token/Coding Plan 地址）。
    func logoAssetName(forBaseURL baseURL: String?) -> String? {
        switch self {
        case .deepseek: return "ProviderDeepSeek"
        case .openRouter: return "ProviderOpenRouter"
        case .anthropic: return "ProviderAnthropic"
        case .openCodeGo: return "ProviderOpenCode"
        case .openAICompatible:
            return Self.matchedBrandAsset(for: baseURL) ?? "ProviderOpenAI"
        }
    }

    private static func matchedBrandAsset(for baseURL: String?) -> String? {
        guard let raw = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return nil
        }
        // 有合法 host 时只匹配 host，避免代理路径里出现 `/openai/`、`/claude/` 误判。
        let host = URL(string: raw)?.host?.lowercased() ?? ""
        let target = host.isEmpty ? raw : host

        let rules: [(keywords: [String], asset: String)] = [
            (["moonshot", "kimi"], "ProviderKimi"),
            (["z.ai", "bigmodel.cn", "zhipuai"], "ProviderZai"),
            (["hunyuan", "huanyuan", "lkeap.cloud.tencent", "tencentcloudapi"], "ProviderHuanyuan"),
            (["dashscope", "qwen"], "ProviderQwen"),
            (["volces.com", "volcengine", "doubao"], "ProviderDoubao"),
            (["minimaxi", "minimax"], "ProviderMiniMax"),
            (["opencode.ai", "opencode"], "ProviderOpenCode"),
            (["commandcode", "command-code"], "ProviderCommandCode"),
            (["opendesign", "open-design"], "ProviderOpenDesign"),
            (["ollama"], "ProviderOllama"),
            (["generativelanguage.googleapis", "aiplatform.googleapis", "gemini"], "ProviderGemini"),
            (["x.ai", "grok"], "ProviderGrok"),
            (["mistral.ai", "mistral"], "ProviderMistral"),
            (["openai.com", "openai"], "ProviderOpenAI"),
        ]
        for rule in rules where rule.keywords.contains(where: { target.contains($0) }) {
            return rule.asset
        }
        return nil
    }

    /// 默认服务地址。
    var defaultBaseURL: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .openAICompatible: return ""
        case .openCodeGo: return "https://opencode.ai/zen/go/v1"
        }
    }

    /// 新建供应方时的默认模型。
    var defaultModel: String {
        ModelCatalog.latest(for: self) ?? ""
    }
}

/// 思考档位。关闭时不发任何推理参数。
enum ThinkingLevel: String, Codable, CaseIterable, Identifiable, Hashable {
    case off
    case low
    case high
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "关闭"
        case .low: return "低"
        case .high: return "高"
        case .max: return "最高"
        }
    }

    var rank: Int {
        switch self {
        case .off: return 0
        case .low: return 1
        case .high: return 2
        case .max: return 3
        }
    }
}

/// 「关闭思考」时向服务端声明禁用推理的字段策略。
///
/// 原版请求体仅包含 7 个基础键，关闭思考即不传递任何推理参数。但部分 OpenAI 兼容服务
/// 默认启用推理，若不显式声明则无法关闭（如 OpenCode 等）。此处提供供应方维度的
/// 字段配置：默认不传递以对齐原版行为，必要时支持显式指定禁用推理字段。
enum ReasoningOffStyle: String, Codable, CaseIterable, Identifiable, Hashable {
    /// 不发任何字段（原版行为）。
    case none
    /// OpenAI / DeepSeek / OpenCode 网关：`reasoning_effort: "none"`。
    case reasoningEffortNone
    /// DeepSeek / 兼容网关：`thinking: {"type": "disabled"}`。
    case thinkingDisabled
    /// OpenAI 兼容 / OpenRouter 一族：`reasoning: {"enabled": false}`。
    case reasoningDisabled
    /// vLLM、Qwen 这类本地/自建服务：`enable_thinking: false`。
    case enableThinkingFalse

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "不发送（默认）"
        case .reasoningEffortNone: return "reasoning_effort = none"
        case .thinkingDisabled: return "thinking.type = disabled"
        case .reasoningDisabled: return "reasoning.enabled = false"
        case .enableThinkingFalse: return "enable_thinking = false"
        }
    }
}

/// 单个供应方的配置。API Key 不进这个结构，单独存 Keychain。
struct ProviderSetting: Identifiable, Codable, Hashable {
    var id: String
    var kind: ProviderKind
    var baseURL: String
    var model: String
    var temperature: Double
    var maxTokens: Int
    var stream: Bool
    var enabled: Bool
    /// 兼容用布尔开关（仅迁移回退用）。
    var thinking: Bool?
    /// 思考档位；nil 时回落到 `thinking`。
    var thinkingLevel: ThinkingLevel?
    /// 关闭思考时发什么字段；nil 等同 `.none`（原版行为）。
    var reasoningOffStyle: ReasoningOffStyle?

    init(
        id: String = UUID().uuidString,
        kind: ProviderKind,
        baseURL: String? = nil,
        model: String? = nil,
        temperature: Double = 1.0,
        maxTokens: Int = 30000,
        stream: Bool = true,
        enabled: Bool = true,
        thinking: Bool? = nil,
        thinkingLevel: ThinkingLevel? = nil,
        reasoningOffStyle: ReasoningOffStyle? = nil
    ) {
        self.id = id
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.model = model ?? kind.defaultModel
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stream = stream
        self.enabled = enabled
        self.thinking = thinking
        self.thinkingLevel = thinkingLevel
        self.reasoningOffStyle = reasoningOffStyle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(ProviderKind.self, forKey: .kind)
        self.id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.kind = kind
        self.baseURL = (try? c.decode(String.self, forKey: .baseURL)) ?? kind.defaultBaseURL
        self.model = (try? c.decode(String.self, forKey: .model)) ?? kind.defaultModel
        self.temperature = (try? c.decode(Double.self, forKey: .temperature)) ?? 1.0
        self.maxTokens = (try? c.decode(Int.self, forKey: .maxTokens)) ?? 30000
        self.stream = (try? c.decode(Bool.self, forKey: .stream)) ?? true
        self.enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        self.thinking = try? c.decodeIfPresent(Bool.self, forKey: .thinking)
        self.thinkingLevel = try? c.decodeIfPresent(ThinkingLevel.self, forKey: .thinkingLevel)
        self.reasoningOffStyle = try? c.decodeIfPresent(ReasoningOffStyle.self, forKey: .reasoningOffStyle)
    }

    var effectiveThinkingLevel: ThinkingLevel {
        if let thinkingLevel { return thinkingLevel }
        return thinking == true ? .high : .off
    }

    var isOpenCode: Bool {
        kind == .openCodeGo || baseURLForDisplay.lowercased().contains("opencode.ai")
    }

    /// 关闭思考时实际要发的字段形态；OpenCode 默认发 `reasoning_effort = none`。
    var effectiveReasoningOffStyle: ReasoningOffStyle {
        if let reasoningOffStyle { return reasoningOffStyle }
        return isOpenCode ? .reasoningEffortNone : .none
    }

    var baseURLForDisplay: String {
        baseURL.isEmpty ? kind.defaultBaseURL : baseURL
    }

    /// 真正要发出去的模型名。
    ///
    /// 模型字段留空时回退至目录中的最新模型，避免发送空 `model`
    /// 导致服务端返回 400 错误。若用户已配置则直接使用，不做额外推断。
    var resolvedModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return ModelCatalog.latest(for: kind) ?? ""
    }

    /// 是否在用已弃用的历史别名。
    var usesDeprecatedModel: Bool {
        ModelCatalog.isDeprecated(resolvedModel)
    }

    /// 是否走 DeepSeek 专用分支（传递 `thinking` 字段）。
    ///
    /// 原版实现并非依据枚举判断，而是比对请求 URL 主机名与 `api.deepseek.com`
    /// （`L1/X.java:498-511`，忽略大小写）。严格对齐该逻辑：自建反代域名
    /// 不归入 DeepSeek 分支，即使后端接入的是 DeepSeek 服务。
    var isDeepSeek: Bool {
        guard let url = URL(string: baseURLForDisplay.trimmingCharacters(in: .whitespaces)),
              let host = url.host
        else { return false }
        return host.caseInsensitiveCompare("api.deepseek.com") == .orderedSame
    }

    /// 设置页展示用的平台名。用启发式，和请求分支无关
    /// （`L1/U2.java:1011-1021`）。
    var platformDisplayName: String {
        let url = baseURLForDisplay.lowercased()
        if url.contains("deepseek") { return "DeepSeek" }
        if url.isEmpty { return "未知 API" }
        return "OpenAI 兼容"
    }
}

/// 设置页「外观」里的主题选择。原版是跟随系统 / 浅色 / 深色三选一。
enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}

/// 全局设置。落盘到 `Application Support/Frthink/settings.json`。
struct AppSettings: Codable {
    var providers: [ProviderSetting]
    var activeProviderID: String
    /// 语料收集库开关（提示词里有「启用语料收集库用于写作」）。
    var corpusEnabled: Bool
    /// 译文分段的 `owner` 字段，用于把本机数据与导入数据隔开。
    var ownerID: String
    /// 关闭流式时走一次性请求。
    var streamByDefault: Bool
    /// 宇宙层：跨项目共享的设定。
    var universeEntries: [UniverseEntry]
    /// 当前书项目启用的宇宙条目集合（单项目配置保存在 ProjectPayload 中，
    /// 此处存储全局启用的默认集合）。
    var enabledUniverseEntryIDs: [String]

    // MARK: 提示词集成管理器

    /// 全局预设（P03）。正文原样注入，不加任何前后缀。
    var globalPreset: String
    /// 去 AI 味规则（P05）。渲染成「用户确认的写作偏好：\n<内容>」。
    var aiFlavorRules: String
    /// 技能列表（P04）。启用的每条渲染成 `# <技能名>\n<内容>`。
    var skills: [Skill]
    /// 语料收集库。原版存 `universe-corpus-v1.enc`，库可以嵌套；这里平铺多库。
    var corpusLibraries: [CorpusLibrary]

    // MARK: 外观

    /// 主题。设置页用 `.preferredColorScheme` 立刻生效。
    var theme: AppTheme
    /// 正文字号（pt）。写作台、阅读页渲染正文时读它；设置页负责写入和预览。
    var bodyFontSize: Double

    // MARK: 全局模型响应

    /// 默认采样温度。新建供应方、或点「应用到当前供应方」时用。
    var defaultTemperature: Double
    /// 默认最大输出 token。
    var defaultMaxTokens: Int

    // MARK: 长上下文预算

    /// 上下文窗口大小（token）。默认按 `TokenEstimator.contextWindow(for:)` 的
    /// 估计值；用户改过就以这里的值为准。
    var contextWindowTokens: Int
    /// 输入预算。原版 `input_budget_tokens`，出厂 32768。
    var inputBudgetTokens: Int
    /// 给输出预留的 token。预算 = 窗口 − 预留 − 安全余量。
    var reservedOutputTokens: Int

    // MARK: 界面

    /// 把界面动画限制到 60 帧（省电、降发热）。
    var limitAnimationFrameRate: Bool
    /// 触感反馈。
    var hapticsEnabled: Bool

    // MARK: 用量

    /// 累计 token 消耗（估算）。
    var tokenUsageTotal: Int
    /// 「翻译模型」：翻译任务单独指定一个供应方；空串表示复用当前供应方。
    var translationProviderID: String
    /// 「摘要模型」：空串表示复用当前供应方的模型。
    var summaryModel: String
    /// 「世界建立」：改写 P18「世界建立要求」的正文；空串表示用出厂值。
    var worldBuildInstruction: String
    /// 「剧情归纳预设」：改写 P19 素材归纳的正文；空串表示用出厂值。
    var plotOutlineInstruction: String
    /// 「仿写归纳预设」：改写 P19 素材归纳的正文；空串表示用出厂值。
    var imitationInstruction: String
    /// 自动对话摘要（APK `autoConversationSummary`）。
    var autoConversationSummary: Bool
    /// 摘要触发阈值（百分比）。
    var conversationSummaryThresholdPercent: Int
    /// 摘要时排除助手历史（APK `excludeAssistantChatHistory`）。
    var excludeAssistantChatHistory: Bool

    init(
        providers: [ProviderSetting]? = nil,
        activeProviderID: String = "",
        corpusEnabled: Bool = false,
        ownerID: String = "",
        streamByDefault: Bool = true,
        universeEntries: [UniverseEntry] = [],
        enabledUniverseEntryIDs: [String] = [],
        theme: AppTheme = .system,
        bodyFontSize: Double = 18,
        defaultTemperature: Double = 1.0,
        defaultMaxTokens: Int = 30000,
        contextWindowTokens: Int = 0,
        inputBudgetTokens: Int = 32_768,
        reservedOutputTokens: Int = 30_000,
        limitAnimationFrameRate: Bool = false,
        hapticsEnabled: Bool = true,
        tokenUsageTotal: Int = 0,
        translationProviderID: String = "",
        summaryModel: String = "",
        worldBuildInstruction: String = "",
        plotOutlineInstruction: String = "",
        imitationInstruction: String = "",
        autoConversationSummary: Bool = true,
        conversationSummaryThresholdPercent: Int = 95,
        excludeAssistantChatHistory: Bool = false,
        globalPreset: String = "",
        aiFlavorRules: String = "",
        skills: [Skill]? = nil,
        corpusLibraries: [CorpusLibrary] = []
    ) {
        let defaults = providers ?? ProviderKind.selectableCases.map { ProviderSetting(kind: $0) }
        self.providers = defaults
        self.activeProviderID = activeProviderID.isEmpty
            ? (defaults.first?.id ?? "")
            : activeProviderID
        self.corpusEnabled = corpusEnabled
        self.ownerID = ownerID.isEmpty ? UUID().uuidString : ownerID
        self.streamByDefault = streamByDefault
        self.universeEntries = universeEntries
        self.enabledUniverseEntryIDs = enabledUniverseEntryIDs
        self.theme = theme
        self.bodyFontSize = bodyFontSize
        self.defaultTemperature = defaultTemperature
        self.defaultMaxTokens = defaultMaxTokens
        self.contextWindowTokens = contextWindowTokens
        self.inputBudgetTokens = inputBudgetTokens
        self.reservedOutputTokens = reservedOutputTokens
        self.limitAnimationFrameRate = limitAnimationFrameRate
        self.hapticsEnabled = hapticsEnabled
        self.tokenUsageTotal = tokenUsageTotal
        self.translationProviderID = translationProviderID
        self.summaryModel = summaryModel
        self.worldBuildInstruction = worldBuildInstruction
        self.plotOutlineInstruction = plotOutlineInstruction
        self.imitationInstruction = imitationInstruction
        self.autoConversationSummary = autoConversationSummary
        self.conversationSummaryThresholdPercent = conversationSummaryThresholdPercent
        self.excludeAssistantChatHistory = excludeAssistantChatHistory
        self.globalPreset = globalPreset
        self.aiFlavorRules = aiFlavorRules
        self.skills = skills ?? Skill.defaults
        self.corpusLibraries = corpusLibraries
    }

    /// 提示词能用的预算：上下文窗口 − 预留输出，再留一成安全空间。
    ///
    /// `TokenEstimator.trimTail(_:toTokens:)` 直接吃这个值；下限 1024 防止把
    /// 窗口/预留填反了以后算出负数。
    var promptBudgetTokens: Int {
        let model = activeProvider?.resolvedModel ?? ""
        let plan = try? PromptBudget.make(
            settings: self,
            model: model,
            contextWindowOverride: contextWindowTokens > 0 ? contextWindowTokens : nil
        )
        return plan?.effectiveInputBudget ?? max(1_024, inputBudgetTokens)
    }

    var activeProvider: ProviderSetting? {
        providers.first { $0.id == activeProviderID } ?? providers.first
    }

    /// 本书实际注入的宇宙条目：全局启用 + 本书勾选，两者缺一不可。
    func enabledUniverseEntries(for projectEntryIDs: [String]) -> [UniverseEntry] {
        let selected = Set(projectEntryIDs)
        return universeEntries.filter { $0.enabled && selected.contains($0.id) }
    }

    /// 兼容早期设置文件：缺失字段按默认值回填。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 存档里没有 providers（Android 备份）时解成空数组，交给
        // `FrthinkArchive.mergeSettings` 保留本机列表；在这里造默认供应方
        // 会产生新 UUID，Keychain 里的 Key 再也对不上。
        providers = (try? c.decode([ProviderSetting].self, forKey: .providers)) ?? []
        activeProviderID = (try? c.decode(String.self, forKey: .activeProviderID)) ?? ""
        corpusEnabled = (try? c.decode(Bool.self, forKey: .corpusEnabled)) ?? false
        ownerID = (try? c.decode(String.self, forKey: .ownerID)) ?? UUID().uuidString
        streamByDefault = (try? c.decode(Bool.self, forKey: .streamByDefault)) ?? true
        universeEntries = (try? c.decode([UniverseEntry].self, forKey: .universeEntries)) ?? []
        enabledUniverseEntryIDs =
            (try? c.decode([String].self, forKey: .enabledUniverseEntryIDs)) ?? []
        theme = (try? c.decode(AppTheme.self, forKey: .theme)) ?? .system
        bodyFontSize = (try? c.decode(Double.self, forKey: .bodyFontSize)) ?? 18
        defaultTemperature = (try? c.decode(Double.self, forKey: .defaultTemperature)) ?? 1.0
        defaultMaxTokens = (try? c.decode(Int.self, forKey: .defaultMaxTokens)) ?? 30000
        contextWindowTokens =
            (try? c.decode(Int.self, forKey: .contextWindowTokens)) ?? 0
        inputBudgetTokens = (try? c.decode(Int.self, forKey: .inputBudgetTokens)) ?? 32_768
        reservedOutputTokens =
            (try? c.decode(Int.self, forKey: .reservedOutputTokens)) ?? 30_000
        limitAnimationFrameRate =
            (try? c.decode(Bool.self, forKey: .limitAnimationFrameRate)) ?? false
        hapticsEnabled = (try? c.decode(Bool.self, forKey: .hapticsEnabled)) ?? true
        tokenUsageTotal = (try? c.decode(Int.self, forKey: .tokenUsageTotal)) ?? 0
        translationProviderID =
            (try? c.decode(String.self, forKey: .translationProviderID)) ?? ""
        summaryModel = (try? c.decode(String.self, forKey: .summaryModel)) ?? ""
        worldBuildInstruction =
            (try? c.decode(String.self, forKey: .worldBuildInstruction)) ?? ""
        plotOutlineInstruction =
            (try? c.decode(String.self, forKey: .plotOutlineInstruction)) ?? ""
        imitationInstruction =
            (try? c.decode(String.self, forKey: .imitationInstruction)) ?? ""
        autoConversationSummary =
            (try? c.decode(Bool.self, forKey: .autoConversationSummary)) ?? true
        conversationSummaryThresholdPercent =
            (try? c.decode(Int.self, forKey: .conversationSummaryThresholdPercent)) ?? 95
        excludeAssistantChatHistory =
            (try? c.decode(Bool.self, forKey: .excludeAssistantChatHistory)) ?? false
        globalPreset = (try? c.decode(String.self, forKey: .globalPreset)) ?? ""
        aiFlavorRules = (try? c.decode(String.self, forKey: .aiFlavorRules)) ?? ""
        skills = (try? c.decode([Skill].self, forKey: .skills)) ?? Skill.defaults
        corpusLibraries =
            (try? c.decode([CorpusLibrary].self, forKey: .corpusLibraries)) ?? []
        if activeProviderID.isEmpty, let first = providers.first {
            activeProviderID = first.id
        }
    }
}
