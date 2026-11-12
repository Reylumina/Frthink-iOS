# ARCHITECTURE.md · Frthink iOS 技术架构

这份文档说明系统由哪些部分组成、为什么这样切、代价是什么。性能与流式实现见 [PERFORMANCE.md](PERFORMANCE.md)。界面规则见 [`DESIGN.md`](DESIGN.md)，与原版的协议比对见 [`spec/`](spec/)。

## 1. 背景

原版是 Android 原生应用，用 Kotlin 和 Compose。写作、世界资料、阅读和译文四条流程都挂在同一个大状态上，最终持久化成一份 `ProjectSnapshot`。

iOS 版需复现这些流程，并满足三项约束：提示词、协议、存档格式能与原版互通，除平台差异外不增删功能，没有原版源码，只能靠反编译和规格文档确认行为。第三条决定了工作方式：先整理规格，再按规格实现，不按“通常合理的做法”改。

## 2. 目标与非目标

目标是同一份 `.frthink` 在两端可互导且字段不丢，同一份输入产生同一份提示词（61 条模板逐字一致），四条流程在 iOS 上可用。

不改进原版的产品设计，也不默认加入原版没有的能力。用户明确要求的思考档位和 OpenCode Go 是例外，关闭时请求体保持原样。

## 3. 约束

| 约束 | 来源 | 影响 |
|---|---|---|
| 只发 `POST /chat/completions` 和 `GET /models` | 反编译确认 | 不能用 provider SDK |
| 基础请求体 7 个键，没有 `top_p`、`stop`、`response_format` | 反编译确认 | 结构化输出只能靠提示词约束 JSON，思考档位开启时按 provider 追加 reasoning 字段 |
| `thinking` 只对 `api.deepseek.com` 发，OpenRouter 用 `reasoning`，OpenAI 兼容用 `reasoning_effort` | 反编译和官方 API | provider 抽象要知道供应方类型和思考档位 |
| 存档格式是 JSON 包 gzip 再 base64 | 反编译确认 | Foundation 的 `.zlib` 是 RFC1950，不能直接用 |
| 没有跨端密钥交接机制 | 反编译未找到 | 加密只能本地自洽 |

## 4. 架构

### 4.1 分层

```
App/            入口、根导航、演示数据、运行时自检
Features/       按业务域切的界面层：Writer、World、Reader 等
Core/
  Models/       值类型：Project、World、Chat、Settings、Archive 快照
  Store/        AppStore（全局）、ProjectSession（单书）、FileStore（落盘）、Keychain
  Prompts/      PromptLibrary（模板）、PromptComposer（装配，按世界/素材/语料拆到 extension）
  LLM/          协议抽象、OpenAI 兼容实现、token 估算
  Archive.swift 信封、编解码、导入导出；gzip 在 FrthinkGzip.swift，错误在 FrthinkArchiveError.swift
  Design/       token 与容器
```

依赖方向是单向的：Features 依赖 Core，Core 不认识 Features，App 可以依赖两者。

### 4.2 为什么这样切

原版是一个大状态对象加一个大 ViewModel。若直接迁移到 SwiftUI，将得到一个很大的 `ObservableObject`，每次修改都会导致全应用重算视图。

| 决定 | 收益 | 代价 |
|---|---|---|
| 按业务域拆 `Features` | 单文件可读，能并行改 | 跨域共享状态变成隐式的，当前书稿和生成中状态放在 `RootView` |
| `AppStore` 管全局，`ProjectSession` 管单书 | 打开和关闭书时资源边界清楚 | 两者生命周期不同，需要显式刷新会话 |
| `FileStore` 只用文件，不用 SwiftData | 存档格式和原版一致，导出就是原版格式 | 没有查询能力，列表靠全量读 |

已知架构债：`RootView` 里的 `activeProjectID` 和 `ProjectSession` 隐式耦合，切 Tab 时生成任务没有统一的生命周期管理。原版用前台 Service，这一点没有对应实现。

存档界面把文件面板和导入页分开挂：`fileImporter` / `fileExporter` 在「存档与备份」页，导入流程页用 `navigationDestination` 推入，而不是在按钮同一视图上弹 `fullScreenCover`。文件面板收起和自定义弹层同时转场时系统会丢弃后者；导航推入没有这个竞争。读文件先等 iCloud 下载落地，再走 `NSFileCoordinator`。

### 4.3 状态与并发

`AppStore` 标 `@Observable`，只在主线程用。`ProjectSession` 持有 `payload: ProjectPayload`，整份常驻内存。落盘是 2 秒防抖，然后取快照，在后台编码写盘。章节扫描 500ms 防抖，后台执行。生成用 `AsyncThrowingStream`，事件分 `.delta`、`.reasoning`、`.finished`。

没有后台执行（`BGProcessingTask`），切后台可能被系统挂起。

### 4.4 数据与持久化

```
Library/<projectID>/
  project.json     元信息
  payload.json     消息、世界、草稿、快照（AES-256-GCM 密文；正文在 body.pages/）
Archive/<name>.frthink
  信封 JSON（format/version/compression/createdAt/payload）
    payload = base64(gzip(全量 JSON))
```

gzip 是手写的 RFC1952 实现（`FrthinkGzip`）。Foundation 的 `COMPRESSION_ZLIB` 是 RFC1950 包装，和原版的 `GZIPInputStream` 不兼容。

世界刷新、素材归纳、长期规则分别由 `WorldWorkflow`、`WorldMaterialWorkflow`、`WorldRulesWorkflow` 承担，共用 `WorldRequestContext`（当前服务商 + 客户端 + 一次性请求参数）；各 workflow 只保留业务逻辑。

`payload.json`、`body.pages/*.bin`、`body.meta.json`、`source.json`、`translations.json` 用 AES-256-GCM 加密，文件头 `FRTHENC1`，主密钥 32 字节存 Keychain。读取时按文件头判断：旧版本的明文文件解码后立即加密写回。导出不加密——原版密钥在 AndroidKeyStore，跨端本来就不共享，导出保持明文才能互认。

### 4.5 提示词流水线

```text
0. WriterPromptBuilder：主线程只拍 world/messages/settings 快照，组装与预算裁剪在后台
1. PromptAssembly：按 14 个固定槽位装块
2. PromptComposer：把块转成 system/user 消息，并裁剪历史
3. TokenEstimator：逐码点加权估算，不是 tokenizer
4. PromptBudget：推导 input、output、effective 三个预算
5. OpenAICompatibleClient：发 7 键基础请求体，思考档位开启时追加 provider 字段
```

每次请求把实际发出的消息存进 `requestSnapshots`，事后可还原模型当时看到的内容。快照只留最近 30 条，可以单条删除或清空，删除不影响下一次请求。

自动摘要在同一条流水线上多一步：上下文占用达到阈值时，用 P54 把未摘要的用户轮次并进长期规则，并记录 `sourceMessageKeys`。这一步只改长期规则，不删除对话消息。

### 4.6 错误模型

`LLMError` 分六类：`notConfigured`、`http(status, body)`、`decoding`、`cancelled`、`emptyResponse(detail)`、`truncated(detail)`。错误必须带服务端原文。“连接失败”四个字分不清鉴权、参数、模型名和配额，之前就把“模型默认开思考导致正文为空”误报成了网络故障。

存档错误同样带键路径，由 `corruptedDetail` 返回。

## 5. 权衡

| 决策 | 备选 | 不选备选的原因 |
|---|---|---|
| 文件存储 | SwiftData、CoreData | 存档要能导出成原版格式，ORM 会把结构绑死在 schema 上 |
| 编辑器仍整份解密正文 | 编辑器窗口化 | 打开书只读 `body.meta.json`；阅读按页取文，编辑器仍整份解密 |
| 手写 gzip | Foundation Compression | 不兼容原版的 RFC1952 流 |
| 语义色加系统 tint | 品牌主色 | 品牌色和系统冷灰底冲突，也不响应辅助功能设置 |
| 提示词内嵌 Swift | 资源包加解析 | 规格要求逐字一致，内嵌可用于静态检查，资源包会多一条加载失败路径 |
| token 估算照抄原版 | 接入 tokenizer | 换了裁剪点，输出就无法比对 |

## 6. 风险与债

工程债、影响和文件线索统一维护在 [`DEVELOPMENT.md` §6](DEVELOPMENT.md#6-已知工程问题)，本页不再重复；架构层面的取舍见第 5 节。

## 7. 验证

本地无 Swift 编译器，验证走三条通道。

1. `script/swift_check.py` 做跨文件符号检查，可检测重复定义和缺失引用，无法检测类型错误。
2. `-runSelfCheck` 在模拟器里跑 33 项纯逻辑检查；`Real Archive Verify` 用仓库内 fixture 跑导入、导出、重开、落盘读回。CI 断言 `ALL PASS`。
3. 截图流水线启动模拟器，逐 Tab 截图，人工检查。

未覆盖项：联网路径、真机文件选择器、真机键盘和滚动、Android 端读取 iOS 导出的文件。这些仅能通过真机手测。

## 8. 开放问题

- 50 万字以上的分页边界放在哪一层，`FileStore` 还是 `ProjectSession`。
