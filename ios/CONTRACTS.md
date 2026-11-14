# iOS 端模块与接口契约

本文档记录 `App/`、`Core/` 与 `Features/` 各层之间的模块边界及核心公开接口。

目标：iOS 17.0+，Xcode 26（Swift 5 语言模式），无任何第三方依赖，纯 SwiftUI。

## 工程结构

```
ios/
  Frthink.xcodeproj/          # 由 PBXFileSystemSynchronizedRootGroup 自动同步文件
  Frthink/
    App/                      # 应用入口、根导航、演示数据与运行时自检（SelfCheck）
      FrthinkApp.swift
      RootView.swift
      ProjectWorkspaceView.swift
    Core/                     # 核心模型、持久化、存档、LLM 协议、提示词与设计组件
      Archive.swift / ArchiveSnapshot.swift / ArchiveRestore.swift
      FrthinkGzip.swift / FrthinkArchiveError.swift
      Models/  Store/  LLM/  Prompts/  Design/
    Features/                 # 业务特性模块（Library / Writer / World / Translation / Universe / Settings）
    Resources/Assets.xcassets
```

**新增 `.swift` 源代码文件无需手动修改 `pbxproj`**——工程配置了文件系统同步分组，放置于 `Frthink/...` 对应目录下即可自动参与编译。

## 可直接调用的 API

### 数据

```swift
struct Project                     // id, title, synopsis, updatedAt, revision,
                                   // coverImagePayload(String?), branchRootId,
                                   // branchOrder, trashedAt(Date?)
struct ProjectPayload              // chapters, messages, world, continuationAnchor, composerDraft 等
                                   // 正文分页独立存储在 FileStore（body.pages/），通过 session.manuscript / editorText 访问
struct Chapter                     // id, title, location

struct WorldBook                   // setting, styleTemplate, styleNotes, longTermRules,
                                   // characters, events, corpus, lastRefreshedAt, refreshedUpTo
struct CharacterCard               // id, name, identity, personality, voice, goals,
                                   // boundaries, aliases[], personalMemory,
                                   // relationshipAttitudes, customEntries[], updatedAt
struct CharacterCard.CustomEntry   // id, title, body
struct EventCard                   // id, title, scene, characters[], cause, development,
                                   // consequence, updatedAt
struct CorpusEntry                 // id, source, title, text, category, tags[]

struct ChatMessage                 // id, role(.user/.assistant/.system), variants[String],
                                   // selectedVariant, createdAt, model
                                   // content 是计算属性，读写当前选中变体
struct TranslationSegment          // id, owner, project, target, sourceHash, segment, payload, updatedAt

enum ProviderKind                  // .deepseek / .openRouter / .anthropic / .openAICompatible
struct ProviderSetting             // id, kind, baseURL, model, temperature, maxTokens, stream, enabled
struct AppSettings                 // providers[], activeProviderID, corpusEnabled, ownerID, streamByDefault
                                   // .activeProvider 取当前供应方
```

### 状态

```swift
@MainActor @Observable final class AppStore
    var projects: [Project]                       // 全部，含回收站
    var activeProjects: [Project]                 // 不含回收站
    var trashedProjects: [Project]
    var settings: AppSettings
    var toast: String?                            // 赋值后将在底部弹出提示，展示时长 2 秒
    var errorMessage: String?                     // 赋值后将在顶部展示错误横幅
    func createProject(title: String) -> Project
    func openSession(for: Project) -> ProjectSession
    func rename(_:to:) / setSynopsis(_:to:) / trash(_:) / restore(_:) / deleteForever(_:)
    func duplicate(_:) -> Project
    func branches(of: Project) -> [Project]
    func saveSettings()
    func apiKey(for providerID: String) -> String
    func setAPIKey(_ key: String, for providerID: String)
    func makeClient(for provider: ProviderSetting, apiKeyOverride: String? = nil) throws -> any LLMClient
    func clientForActiveProvider() throws -> any LLMClient

@MainActor @Observable final class ProjectSession
    var project: Project
    var payload: ProjectPayload        // 支持直接读写，修改后调用 scheduleSave()
    var sourceText: String             // 原文（翻译源）
    var translations: [TranslationSegment]
    var isDirty: Bool
    func scheduleSave()                // 防抖 2s 落盘
    func saveNow()
    func saveSource() / saveTranslations()
    func updateManuscript(_ text: String)
    func insertIntoManuscript(_ text: String, at: Int)
    func appendToManuscript(_ text: String)
    func addUserMessage(_ text: String) -> ChatMessage
    func beginAssistantMessage(model: String?) -> ChatMessage
    func appendDelta(_ text: String, to messageID: String)
    func finishAssistantMessage(_ messageID: String, model: String?)
    func removeMessage(_ messageID: String)
    func addVariant(to messageID: String)              // 重新生成
    func selectVariant(_ variant: Int, for messageID: String)
    func rollbackToMessage(_ messageID: String)        // 回退并清除该消息之后的所有历史消息
    var lastUserMessage / lastAssistantMessage: ChatMessage?
```

### 网络

```swift
struct LLMMessage  { role, content; .system()/.user()/.assistant() 便捷构造 }
struct LLMRequest  { model, messages, stream, temperature, maxTokens, topP }

enum LLMStreamEvent { case delta(String), reasoning(String), finished(reason: String?) }
enum LLMError: LocalizedError  // .notConfigured/.missingAPIKey/.badURL/.http/.decoding/.cancelled/.emptyResponse/.truncated

protocol LLMClient {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error>
    func complete(_ request: LLMRequest) async throws -> String
    func listModels() async throws -> [String]
    func testConnection() async throws
}

enum TokenEstimator   // .estimate(String) / .estimate([LLMMessage]) / .contextWindow(for:) / .trimTail
```

用法示例：

```swift
let client = try store.clientForActiveProvider()
let provider = store.settings.activeProvider!
let request = LLMRequest(
    model: provider.model,
    messages: PromptComposer.writingMessages(
        world: session.payload.world,
        manuscript: session.payload.manuscript,
        history: history,
        userInstruction: instruction
    ),
    stream: provider.stream,
    temperature: provider.temperature,
    maxTokens: provider.maxTokens
)
let message = session.beginAssistantMessage(model: provider.model)
do {
    for try await event in client.stream(request) {
        switch event {
        case .delta(let text): session.appendDelta(text, to: message.id)
        case .reasoning(let text): /* 可累积至独立字段，或按需忽略 */
        case .finished: break
        }
    }
    session.finishAssistantMessage(message.id, model: provider.model)
} catch {
    store.errorMessage = error.localizedDescription
    session.removeMessage(message.id)
}
```

### 提示词

```swift
enum PromptLibrary     // 全部提示词常量，完全依循 APK 原文，严禁修改文案
enum PromptComposer
    .writingSystemPrompt(world:manuscript:) -> String
    .writingMessages(world:manuscript:history:userInstruction:) -> [LLMMessage]
    .continueFragmentMessages(world:manuscript:history:fragment:) -> [LLMMessage]
    .worldRefreshMessages(existingCharacters:existingStyleTemplate:digest:incremental:) -> [LLMMessage]
    .eventMessages(existingEvents:digest:) -> [LLMMessage]
    .styleNotesMessages(existingTemplate:digest:) -> [LLMMessage]
    .longTermRulesMessages(existingLog:recentUserMessages:) -> [LLMMessage]
    .corpusMessages(rules:fragments:) -> [LLMMessage]
    .dedupeMessages(candidates:existingNames:) -> [LLMMessage]
    .translationMessages(_ segment: String) -> [LLMMessage]
    .renderCharacters([CharacterCard]) -> String
    .renderEvents([EventCard]) -> String
```

### 设计

token 和共用组件以 [`docs/DESIGN.md`](../docs/DESIGN.md) 为准（组件清单见 §5.11），实现在 `Core/Design/Theme.swift`、`Core/Design/AppComponents.swift`、`Core/Design/AppFormComponents.swift` 和 `Core/Design/JustifiedText.swift`。

```swift
ToastView / ErrorBanner               // 已在 RootView 中接入，业务层仅需为 store.toast 或 store.errorMessage 赋值
```

## 各特性模块入口

| 模块 | 文件路径 | 入口视图 |
|---|---|---|
| library | `Features/Library/` | `LibraryView(store: AppStore, onOpen: (Project) -> Void)` |
| writer | `Features/Writer/` | `WriterPane(session: ProjectSession)`（辅视图在 `WriterSupportViews.swift` 等） |
| world | `Features/World/` | `WorldPane(session: ProjectSession)` |
| reader / translation | `Features/Translation/` | `ReaderPane(session: ProjectSession)`、`TranslationPane(session: ProjectSession)` |
| universe | `Features/Universe/` | `UniversePane(store: AppStore, session: ProjectSession?)` |
| settings | `Features/Settings/` | `SettingsView(store: AppStore)` |

`LibraryView` 中需提供工具栏入口以呈现 `SettingsView`（可通过 sheet 或 navigationDestination 实现）。`onOpen` 回调由 `RootView` 统一处理导航路由。

## 硬性约束

1. **单向依赖。** `Features/` 依赖 `Core/`，`Core/` 不反向依赖 `Features/`。
2. **不要引入第三方依赖。** 不引入 SPM 包或 CocoaPods。正文与气泡排版统一走 `WriterTypography`、`MarkdownInline` 与 TextKit（`JustifiedText` / `StreamingTextView` / `ManuscriptTextEditor`）。
3. **不用 SwiftData / CoreData。** 数据持久化已统一由 `ProjectSession`、`FileStore` 与 `TextFileCodec` 负责实现。
4. **视觉遵循 Theme。** 禁止硬编码颜色值与字号字面量，统一使用 `Theme.*` 规范。
5. **每个文件顶部写一句注释说明这个文件负责什么。**
6. 上屏文案用书面中文，遵循 `docs/DESIGN.md` §8 精简与去口语化规范，核心领域术语与原版保持一致（世界书、码字机、仿写模板、人物卡、事件卡、译文、语料收集库）。

## 编译验证

本地未安装 Xcode，**无法在本地执行代码编译**。因此须遵循以下规范：

- 仅使用确定且稳定的 SwiftUI API。对于不确定的高级特性，优先采用基础可靠的标准语法替代。
- 不用 `#Preview` 之外的宏技巧；`@Observable` 已在 Core 里使用，可正常编译。
- `@Environment(AppStore.self)` 取 store，注意 `@Bindable` 才能做双向绑定。
- 编写完成后须通读代码复核：确认所有引用的类型真实存在、对应文件均已正确引入
  `import SwiftUI`、以及闭包捕获逻辑不会触发并发安全警告。

CI 会在 GitHub 上编译（`.github/workflows/ios.yml`），编译错误信息将直接输出至工作流日志中。
