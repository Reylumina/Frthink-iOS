# iOS 端共享契约

Core 层已由 Lead 写完，**不要修改 `Core/` 和 `App/` 下的文件**。你只写自己负责的
`Features/` 子目录，四个人的文件互不重叠，靠这份契约对接。

目标：iOS 17.0+，Xcode 26（Swift 5 语言模式），无任何第三方依赖，纯 SwiftUI。

## 工程结构

```
ios/
  Frthink.xcodeproj/          # 已建好，PBXFileSystemSynchronizedRootGroup 自动收录文件
  Frthink/
    App/                      # Lead 负责，不要动
      FrthinkApp.swift
      RootView.swift
      ProjectWorkspaceView.swift
    Core/                     # Lead 负责，不要动
      Models/  Store/  LLM/  Prompts/  Design/
    Features/                 # 四个人分
    Resources/Assets.xcassets
```

**新增 .swift 文件不需要改 pbxproj**——工程用的是文件夹同步分组，放进
`Frthink/Features/...` 就会被编译。

## 可以直接用的 API

### 数据

```swift
struct Project                     // id, title, synopsis, updatedAt, revision,
                                   // coverImagePayload(String?), branchRootId,
                                   // branchOrder, trashedAt(Date?)
struct ProjectPayload              // manuscript, chapters, messages, world, continuationAnchor
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

enum ProviderKind                  // .deepseek / .openRouter / .openAICompatible
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
    var toast: String?                            // 设了就会在底部弹 2 秒
    var errorMessage: String?                     // 设了就会弹顶部错误条
    func createProject(title: String) -> Project
    func openSession(for: Project) -> ProjectSession
    func rename(_:to:) / setSynopsis(_:to:) / trash(_:) / restore(_:) / deleteForever(_:)
    func duplicate(_:) -> Project
    func branches(of: Project) -> [Project]
    func saveSettings()
    func apiKey(for providerID: String) -> String
    func setAPIKey(_ key: String, for providerID: String)
    func clientForActiveProvider() throws -> any LLMClient

@MainActor @Observable final class ProjectSession
    var project: Project
    var payload: ProjectPayload        // 直接读改，改完调 scheduleSave()
    var sourceText: String             // 原文（翻译源）
    var translations: [TranslationSegment]
    var isDirty: Bool
    func scheduleSave()                // 防抖 1.2s 落盘
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
    func rollbackToMessage(_ messageID: String)        // 砍掉它之后的所有消息
    var lastUserMessage / lastAssistantMessage: ChatMessage?
```

### 网络

```swift
struct LLMMessage  { role, content; .system()/.user()/.assistant() 便捷构造 }
struct LLMRequest  { model, messages, stream, temperature, maxTokens, topP }

enum LLMStreamEvent { case delta(String), reasoning(String), finished(reason: String?) }
enum LLMError: LocalizedError  // .notConfigured/.missingAPIKey/.badURL/.http/.decoding/.cancelled/.emptyResponse

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
        case .reasoning(let text): /* 可以攒到单独字段，也可以忽略 */
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
enum PromptLibrary     // 全部提示词常量，逐字来自 APK，不要改措辞
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

```swift
Theme.accent / .accentSoft / .paper / .cardBackground / .hairline
Theme.inkPrimary / .inkSecondary / .inkTertiary
Theme.Radius.small(8) / .medium(12) / .large(18) / .sheet(28)
Theme.Spacing.xs(4) / .s(8) / .m(12) / .l(16) / .xl(24) / .xxl(32)
Theme.manuscript(17) / .title(22) / .reply(16) / .mono(13)

.paperBackground()                    // View 扩展，铺纸感底色
CardContainer { ... }                 // 白底圆角卡片容器
EmptyStateView(symbol:title:message:)
ToastView / ErrorBanner               // RootView 已经接了，业务侧设 store.toast / store.errorMessage 即可
```

## 各人负责的产物（签名必须完全一致）

| 谁 | 文件 | 必须提供的类型 |
|---|---|---|
| library | `Features/Library/` | `LibraryView(store: AppStore, onOpen: (Project) -> Void)` |
| writer | `Features/Writer/` | `WriterPane(session: ProjectSession)` |
| world | `Features/World/` | `WorldPane(session: ProjectSession)` |
| settings | `Features/Settings/` + `Features/Translation/` | `SettingsView(store: AppStore)`、`TranslationPane(session: ProjectSession)` |

`LibraryView` 里放一个 toolbar 入口打开 `SettingsView`（用 sheet 或
navigationDestination 都行，自己决定）。`onOpen` 由 Lead 的 RootView 接管导航。

## 硬性约束

1. **不要修改 `App/` 和 `Core/` 下的任何文件。** 需要新 API 就在自己的目录里加，
   或写个同名的 `extension`（不能加存储属性）。
2. **不要引入第三方依赖。** 没有 SPM 包，没有 CocoaPods。Markdown 渲染用
   `AttributedString(markdown:)` 或自己写简单解析。
3. **不用 SwiftData / CoreData。** 持久化已经由 `ProjectSession` + `FileStore` 做了。
4. **视觉遵循 Theme。** 不要硬编码颜色值和字号，用 `Theme.*`。
5. **每个文件顶部写一句注释说明这个文件负责什么。**
6. 上屏文案用中文，和 APK 里的说法保持一致（世界书、码字机、仿写模板、人物卡、
   事件卡、译文、语料收集库）。

## 编译验证

本机没有 Xcode，**任何代码都没法在本地编译**。所以：

- 只用确定的、稳定的 SwiftUI API。拿不准的写法换成更朴素的写法。
- 不用 `#Preview` 之外的宏技巧；`@Observable` 已在 Core 里用，你会正常。
- `@Environment(AppStore.self)` 取 store，注意 `@Bindable` 才能做双向绑定。
- 写完自己通读一遍，检查：所有引用的类型是否真实存在、是否都在本文件里
  `import SwiftUI` 了、闭包捕获是否会有并发告警。

CI 会在 GitHub 上编译（`.github/workflows/ios.yml`），报错会回来。
