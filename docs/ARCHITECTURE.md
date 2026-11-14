# ARCHITECTURE.md · Frthink iOS 技术架构

本文档阐述系统的架构组成、分层设计依据及权衡考量。性能与流式实现参见 [PERFORMANCE.md](PERFORMANCE.md)，界面规范详见 [`DESIGN.md`](DESIGN.md)，与原版的协议比对参见 [`spec/`](spec/)。

## 1. 背景

原版是 Android 原生应用，用 Kotlin 和 Compose。写作、世界资料、阅读和译文四条流程都挂在同一个大状态上，最终持久化成一份 `ProjectSnapshot`。

iOS 版需复现这些流程，并满足三项约束：提示词、协议、存档格式能与原版互通；除平台差异外不增删功能；在缺乏原版源码的前提下，需通过反编译产物与规格文档确证行为。该约束确立了工作流程：先逆向梳理规格，再按既定规范严格实现，避免凭主观经验自行调整。

## 2. 目标与非目标

目标是同一份 `.frthink` 在两端可互导且字段不丢，同一份输入产生同一份提示词（61 条模板逐字一致），四条流程在 iOS 上可用。

不改进原版的产品设计，也不默认加入原版没有的能力。用户明确要求的思考档位和 OpenCode Go 是例外，关闭时请求体保持原样。

## 3. 约束

| 约束 | 来源 | 影响 |
|---|---|---|
| 只发 `POST /chat/completions`（OpenAI 兼容）或 `POST /v1/messages`（Anthropic）与 `GET /models` | 反编译确认 + iOS 扩展 | 无法直接使用第三方服务商 SDK |
| 基础请求体 7 个键，没有 `top_p`、`stop`、`response_format` | 反编译确认 | 结构化输出需通过提示词约束 JSON 格式，思考模式开启时根据服务商追加 reasoning 相关字段 |
| `thinking` 只对 `api.deepseek.com` 发，OpenRouter 用 `reasoning`，OpenAI 兼容用 `reasoning_effort` | 反编译和官方 API | 服务提供方抽象层需识别供应方类型及思考档位 |
| 存档格式是 JSON 包 gzip 再 base64 | 反编译确认 | Foundation 的 `.zlib` 采用 RFC1950 规范，无法直接适配 |
| 没有跨端密钥交接机制 | 反编译未找到 | 加密方案在本地实现闭环 |

## 4. 架构

### 4.1 分层

```
App/            入口、根导航、演示数据、运行时自检
Features/       按业务域切的界面层：Writer、World、Translation（Reader）、Library、Universe、Settings
Core/
  Models/       值类型：Project、World、Chat、Settings、Universe
  Store/        AppStore（全局）、ProjectSession（单书）、FileStore（加密落盘）、TextFileCodec（正文编解码与导出）、Keychain
  Prompts/      PromptLibrary（模板）、PromptComposer（装配，按世界/素材/语料拆到 extension）
  LLM/          协议抽象、OpenAI 兼容与 Anthropic 实现、token 估算
  Archive*.swift Archive.swift（模型与入口）、ArchiveSnapshot.swift（快照构建与导出）、ArchiveRestore.swift（恢复校验与导入）；gzip 在 FrthinkGzip.swift，错误在 FrthinkArchiveError.swift
  Design/       Theme、AppComponents、AppFormComponents、JustifiedText 等
```

依赖方向是单向的：Features 依赖 Core，Core 不认识 Features，App 可以依赖两者。

### 4.2 架构拆分考量

原版基于单一大型状态对象与集中式 ViewModel 构建。若直接迁移至 SwiftUI，将产生庞大的 `ObservableObject`，局部状态修改极易引发全应用层面的视图无效重算。

| 决定 | 收益 | 代价 |
|---|---|---|
| 按业务域拆分 `Features` | 单文件可读性高，便于并行维护 | 跨域共享状态转为隐式依赖，当前书稿与生成中状态置于 `RootView` |
| `AppStore` 管全局，`ProjectSession` 管单书 | 打开与关闭书稿时资源边界清晰 | 两者生命周期不同，需显式刷新会话状态 |
| `FileStore` 采用纯文件持久化，未引入 SwiftData | 存档格式与原版严格一致，导出即可直接兼容原版 | 缺乏按需检索能力，列表数据依赖全量读取 |

已知架构约束：`RootView` 中的 `activeProjectID` 与 `ProjectSession` 共享当前打开书稿标识；`WriterPane.handleDisappear()` 通过比对 `RootView.activeProjectKey` 区分「系统内存告警释放缓存会话」与「用户主动关闭/切换书稿」，避免内存压力误中断后台生成。原版通过 Android 前台 Service 保活，iOS 端受系统后台配额限制。

存档界面将系统文件面板与导入流程视图解耦挂载：`fileImporter` / `fileExporter` 挂载于「存档与备份」页面，导入流程视图通过 `navigationDestination` 推入呈现，而非在按钮所在视图上直接弹出 `fullScreenCover`。当系统文件面板收起与自定义模态视图同时转场时容易发生冲突导致后者被系统丢弃；通过导航推入则可避免转场竞争。读取外部文件时先确保 iCloud 同步完成，再通过 `NSFileCoordinator` 进行协同读取。

### 4.3 状态与并发

`AppStore` 标 `@Observable`，只在主线程使用。`ProjectSession` 持有 `payload: ProjectPayload`，整份常驻内存。落盘采用 2 秒防抖，随后取快照并在后台编码写盘；章节扫描采用 1.5 秒防抖，同样在后台执行。生成基于 `AsyncThrowingStream`，事件分为 `.delta`、`.reasoning`、`.finished`。

应用退入后台前，通过 `beginBackgroundTask` 包裹 `flushDirtySessions()`：若不申请后台执行时间配额，`scenePhase` 的 onChange 会立即返回，进程可能在写盘过程中被系统挂起。文本生成阶段拥有独立的后台执行时间（约 30 秒），系统收回配额时将终止流式传输并标记为中断。

世界刷新、事件、文风、长期规则四种任务按书登记在 `AppStore`：`registerWorldTask(_:for:)` 返回一个令牌，任务收尾用同一令牌调 `finishWorldTask(for:token:)`，仅会清理自身对应的任务记录；切换项目、移入回收站或彻底删除则调用 `cancelWorldTask`。若缺乏令牌机制，旧任务结束时容易误将同项目后续发起的新任务一并清除。

正文与气泡排版统一走 TextKit：阅读页段落、码字机完成态气泡、用户指令气泡（`shrinksToFitWidth: true`）均使用 `Core/Design/JustifiedText.swift`（`UITextView`，`.justified` + `.pushOut` + `0.85` 断字系数），创作页全屏正文编辑器使用 `ManuscriptTextEditor`，流式气泡使用 `StreamingTextView`（按已完成段落前缀做 `O(末段)` 增量 `NSTextStorage` 替换）。各处统一复用 `WriterTypography`、`MarkdownInline.runs(_:)` 与 `Theme.Layout.paragraphSpacing(fontSize:lineHeight:)`。SwiftUI 的 `Text` 不支持两端对齐与段落级样式控制，因此正文与气泡层均基于 TextKit 实现。

写作台对话列表采用 `VStack` 而非 `LazyVStack`：整个列表已预先根据 `visibleMessageCount` 截断，行数存在明确上限；而流式生成行可能包含上万字，`LazyVStack` 估算行高配合 33ms 跟踪器的 `scrollTo`，在生成结束切换气泡时容易产生偏移计算误差并定位至内容区域之外，导致界面呈现全屏空白（此问题已在 Stream Check 中复现）。

正文编辑的撤销、重做挂窗口 `UndoManager`（`WriterUndo`）：插入/追加正文是一次独立动作，文字编辑由 `UITextView` 自己登记，两边共用同一个栈，所以 ⌘Z、摇一摇和编辑菜单都能用。

### 4.4 数据与持久化

```
Library/<projectID>/
  project.json     元信息
  payload.json     消息、世界、草稿、快照（AES-256-GCM 密文；正文在 body.pages/）
Archive/<name>.frthink
  信封 JSON（format/version/compression/createdAt/payload）
    payload = base64(gzip(全量 JSON))
```

gzip 是独立实现的 RFC1952 规范（`FrthinkGzip`）。Foundation 的 `COMPRESSION_ZLIB` 采用 RFC1950 规范，与原版的 `GZIPInputStream` 不兼容。

世界刷新、素材归纳、长期规则分别由 `WorldWorkflow`、`WorldMaterialWorkflow`、`WorldRulesWorkflow` 承担，共用 `WorldRequestContext`（当前服务商 + 客户端 + 一次性请求参数）；各 workflow 只保留业务逻辑。

`payload.json`、`body.pages/*.bin`、`body.meta.json`、`source.json`、`translations.json` 用 AES-256-GCM 加密，文件头 `FRTHENC1`，主密钥 32 字节存 Keychain。读取时按文件头判断：旧版本的明文文件解码后立即加密写回。导出不加密——原版密钥在 AndroidKeyStore，跨平台环境下密钥并不共享，导出保持明文才能实现双端互通。

### 4.5 提示词流水线

```text
0. WriterPromptBuilder：主线程仅生成 world/messages/settings 快照，组装与预算裁剪在后台
1. PromptAssembly：按 14 个固定槽位装块
2. PromptComposer：把块转成 system/user 消息，并裁剪历史
3. TokenEstimator：逐码点加权估算，不是 tokenizer
4. PromptBudget：推导 input、output、effective 三个预算
5. OpenAICompatibleClient / AnthropicClient：按当前服务商协议发送请求体，采样温度读取 `provider.temperature`，思考档位开启时追加对应推理字段
```

每次请求把实际发出的消息存进 `requestSnapshots`，事后可还原模型当时看到的内容。快照仅保留最近 30 条，可以单条删除或清空，删除不影响下一次请求。

世界块里，P07 仿写模板取 `world.styleTemplate`；P08 剧情梗概直接渲染事件卡（APK `L1/W2.java:480-484`），`world.plotOutline` 字符串只随存档往返，不参与提示词，也不再单独提供编辑入口。

自动摘要流水线在此基础上增加一个环节：当上下文占用达到阈值时，依据 P54 模板将尚未摘要的用户轮次合并至长期规则中，并记录 `sourceMessageKeys`。该步骤仅更新长期规则，不删除既有对话消息。

### 4.6 错误模型

`LLMError` 涵盖 `notConfigured`、`missingAPIKey`、`badURL`、`http(status, body)`、`decoding(detail)`、`cancelled`、`emptyResponse(detail)`、`truncated(detail)`。错误信息附带服务端返回的原始响应，以明确区分鉴权异常、参数错误、模型名称无效或配额耗尽等具体原因。

存档错误同样带键路径，由 `corruptedDetail` 返回。

## 5. 权衡

| 决策 | 备选 | 不选备选的原因 |
|---|---|---|
| 文件存储 | SwiftData、CoreData | 存档要能导出成原版格式，ORM 会把结构绑死在 schema 上 |
| 编辑器只载入书末窗口 | 任意跨页编辑窗口 | 续写集中在书末，跳到更早章节再扩窗口至书末；阅读按页取文 |
| 独立实现 gzip | Foundation Compression | 不兼容原版的 RFC1952 流 |
| 对话列用 `VStack` | `LazyVStack` | 流式行上万字时估算行高会让 `scrollTo` 落到内容之外，出现整屏空白；列已按条数截断，不需要懒加载 |
| 语义色加系统 tint | 品牌主色 | 品牌色和系统冷灰底冲突，也不响应辅助功能设置 |
| 提示词内嵌 Swift | 资源包加解析 | 规格要求逐字一致，内嵌可用于静态检查，资源包会多一条加载失败路径 |
| token 估算与原版严格对齐 | 接入 tokenizer | 若调整分词与裁剪边界，输出结果将无法进行一致性比对 |

## 6. 风险与债

工程债、影响和文件线索统一维护在 [`DEVELOPMENT.md` §6](DEVELOPMENT.md#6-已知工程问题)，本页不再重复；架构层面的取舍见第 5 节。

## 7. 验证

本地无 Swift 编译器，验证走三条通道。

1. `script/swift_check.py` 做跨文件符号检查，可检测重复定义和缺失引用，无法检测类型错误。
2. `-runSelfCheck` 在模拟器中执行 65 项纯逻辑检查；`Real Archive Verify` 基于仓库内置测试夹具验证导入、导出、重新加载及落盘读回流程。CI 断言 `ALL PASS`。
3. 截图流水线启动模拟器，逐 Tab 截图，人工检查。

未覆盖项：联网路径、真机文件选择器、真机键盘和滚动、Android 端读取 iOS 导出的文件。这些需通过真机人工测试进行验证。

## 8. 开放问题

- 暂无未决架构问题（50 万字以上正文已按页落盘于 `FileStore`，窗口管理由 `ProjectSession` 承担）。
