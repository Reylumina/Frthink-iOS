# Frthink for iOS

[![Platform](https://img.shields.io/badge/Platform-iOS_17.0%2B-black?style=flat-square&logo=apple)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.10%2B-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![iOS Build](https://github.com/Reylumina/Frthink-iOS/actions/workflows/ios.yml/badge.svg)](https://github.com/Reylumina/Frthink-iOS/actions/workflows/ios.yml)

Frthink for iOS（下称 **Frthink**）是基于 Android 应用 Frthink v0.8.213（由 Fr33 开发，包名 `com.frthink.app`）开发的非官方 SwiftUI 移植版，与原作者无隶属关系；原应用及其提示词的版权均归原作者所有。

Frthink 在保留原版创作流、提示词体系与 `.frthink` 存档兼容的基础上，重构了面向长篇小说的叙事记忆与上下文引擎。

## 1. 创作与叙事流程

![创作与叙事流程](assets/architecture-loop.svg)

创作流程分为读时生成（步骤 1–4）与写时入库（步骤 5–8），以点击「插入」或「追加正文」作为状态提交的分界线：

- **流式续写与多版本切换**：支持流式生成正文与独立折叠的思考过程卡片；同一轮指令可多次重生成并左右切换候选版本。
- **采纳时提交**：未采纳的候选草稿不会改写世界状态；仅在采纳正文后才提交剧情节点，并随系统撤销、重做及撤回指令同步回滚全部支线账本。
- **语境感知选区改写**：选中正文片段改写时，自动带入前后文衔接、在场档案约束、写作规则与仿写模板；应用替换后局部调整下游机械锚点偏移，保持长文定位不漂移。
- **分支走向推演**：结合在场角色、未决伏笔、进行中关键事件与写作规则生成 2–3 条候选走向，可一键填入输入框。
- **叙事视角（POV）切换**：指定当前章节的视角角色后，自动按该角色的已知与盲区过滤上下文，隔离未公开秘密。
- **单步增量抽取与状态机更新**：采纳正文后，后台以关闭思考与低温（`T=0.15`）调用「世界更新模型」抽取单步变更，按权威等级更新人物/地点/物件/世界观档案（含多目标关系 `relation:<对象>`）、关键事件（起因、经过、结果）、角色认知与伏笔。

## 2. 上下文编排与工具检索

![上下文编排与工具检索](assets/architecture-context.svg)

上下文按更新频率分为三层，将慢变内容固定在前部以复用服务端前缀缓存，高频变动的状态紧贴末尾指令：

- **三段式上下文窗口**：
  - `Tier 0`（静态前缀）：全局写作基准（系统预设、可开关技能、去 AI 味规则）、常驻世界观（始终生效）、静态文风模板、`corpusEnabled` 开启时注入的全书质心样本，以及顶层目录索引（`BOOK_INDEX`）。
  - `Tier 1`（可逆折叠对话流）：保留最近轮次完整对话与工具记录；早期对话按固定步长折叠为单行进展摘要并清理废旧存根，重复工具结果自动去重。
  - `Tier 2`（尾部动态工作区）：组装逐字写作规则、按「在场人物与认知边界 / 当前地点 / 当前物件 / 相关世界观」分块呈现的四类上下文（支持别名与独立触发词唤醒，声线与认知仅作用于人物）、一跳关联离场实体、就绪伏笔及命中触发线索的潜伏伏笔（附埋设依据短引用）、相关关键事件、场景匹配的文风示范与书末正文窗口（`2K / 6K / 12K`）。
- **只读工具与本地检索回退**：
  - `grep_manuscript`：检索全书分页原稿，受续写锚点因果截断限制（续写锚点之后的正文不可见）。
  - `read_entity_page`：按需读取未在场人物、地点、物件或世界观的完整档案页、关联事实与关键事件。
  - `restore_turn`：将早期折叠的对话轮次追加至上下文末尾展开，不破坏历史前缀缓存。
  - 关闭或不支持工具调用的接口，不暴露 `restore_turn` 提示，自动切回本地 BM25 与专名锚点预检索，并前置状态时序优先规则防止陈旧回忆覆盖最新事实。

## 3. 世界工作台、行文审校与存储

![世界工作台与分文件加密存储](assets/architecture-storage.svg)

世界页分为「档案 · 剧情 · 规则」三栏：

- **档案**：按人物、地点、物件、世界观四类管理独立档案页。人物保留声线与私有认知边界；世界观区分「按关键词触发」与「始终生效」，不与戏外写作规则混淆。详情页展示分类圆形徽章、中文属性标签（如「所在」「持有」「对某人」）、关联关键事件与冲突确认。
- **剧情图谱与关键事件**：以单轨主路径展示因果节拍，在分叉节点切换平行支线或新建分支；切换或撤回支线时隔离支线事实、角色认知、伏笔与关键事件（按故事线分组记录起因、经过、结果），保留全书通用档案与全局写作规则。
- **伏笔追踪与分层摘要**：伏笔按 `潜伏 → 待回收 → 已回收 / 已放弃` 流转，未决状态展示触发时机与原文埋设依据；已发生节拍逐级归纳为近期场次卡、阶段剧情线与卷纲摘要。
- **写作规则**：管理全局、分支或指定档案作用域的写作要求与禁忌，生成时逐字注入 `Tier 2`，不经摘要改写。
- **文风提炼、行文观感与世界核查**：
  - **文风提炼**：从样章提炼句法节奏、叙事腔调、感官细节与对白特征，展示句均字数、短句占比、对白占比与段均字数四项指标（`StyleFingerprintBar`），按当前场景匹配原文范例。
  - **行文观感**：本地检测旁白中空泛修饰、重复指代、套路转折、旁白破折号与连续裸代词五项节奏指标（自动跳过引号内人物对白），支持切换「文学 / 正剧」与「网文 / 快节奏」两档尺度；点击片段可直接调起带上下文的选区改写，应用后自动重检。
  - **世界核查**：核对正文与档案，排查过时角色认知、冗长条目与超期伏笔，支持单条处理或批量整理。
  - **统一文档与触感控件**：只读长文、档案预览与仿写模板统一使用 `MarkdownDocumentView`，全应用滑块统一使用带刻度与步进触感的 `TactileSlider`。
- **阅读、翻译与共享宇宙**：阅读器支持章节识别、全文搜索（缺页与非 BMP 代理对下保持定位准确）、书签与排版调节；翻译页在原文分段缩减后自动清理遗留末尾译文；共享宇宙支持跨书稿复用世界词条。

## 4. 模型供应方与提示词分层

在设置页配置服务地址与模型。API Key 保存在 iOS 系统 Keychain 中，不写入普通文件或备份存档。支持服务端返回用量与本地估算结合的累计 Token 统计。任务模型按职责拆分为「翻译模型」与「世界更新模型」（统一负责后台状态抽取、档案提取与长期规则归纳）；提示词管理分为「全局写作基准」（全局预设、去 AI 味规则、技能）、「单书规则」（仿写模板、写作规则）与「长期规则摘要」三层。

| 供应方 | 默认地址 | 说明 |
|---|---|---|
| DeepSeek | `https://api.deepseek.com` | 支持 `deepseek-chat` / `deepseek-reasoner` 与原生思维链分流 |
| Anthropic | `https://api.anthropic.com` | 原生 `/v1/messages` 协议，支持 Extended Thinking 与 Prompt Caching |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta` | 原生 REST 协议，支持 `thinkingConfig` 与工具调用 |
| OpenRouter | `https://openrouter.ai/api/v1` | 支持统一 `reasoning` 参数与多模型路由 |
| OpenAI 兼容 | 自定义或内置预设 | 内置 Kimi、GLM、Qwen、豆包、混元、MiniMax、OpenCode Go、Ollama Cloud、Grok、Mistral 等预设 |

## 5. 数据与存储

- **本地加密与增量日志**：本地书稿正文分页（`body.pages/*.bin`，并在 `body.meta.json` 记录每页真实 UTF-16 起点偏移）、叙事账本（`ledgers.json`）、剧情图谱增量日志（`story_graph.wal`）与检查点快照（`checkpoints/*.json`）均使用 `AES-256-GCM` 加密存储，主密钥保存在系统 Keychain。
- **导入与导出**：兼容原版 `.frthink` 归档导入与导出；正文与译文支持 UTF-8、UTF-16、GB18030 编码文本导入及 `.txt` 导出。

## 6. 构建与安装

### 环境要求
- iOS 17.0 及以上（iOS 26 及以上启用原生 Liquid Glass 材质，iOS 17–25 使用系统毛玻璃材质）
- Xcode 16.0 及以上，无第三方依赖

### 编译

```bash
git clone -b feat/narrative-engine https://github.com/Reylumina/Frthink-iOS.git
cd Frthink-iOS

xcodebuild -project ios/Frthink.xcodeproj -scheme Frthink \
  -destination 'generic/platform=iOS Simulator' build
```

GitHub Actions 工作流（[`.github/workflows/ios.yml`](.github/workflows/ios.yml)）可直接构建未签名安装包 `Frthink-unsigned.ipa`，通过 AltStore、SideStore、Sideloadly 或 TrollStore 安装至设备。

## 署名

| 项目 | 内容 |
|---|---|
| 原作 | Fr33 |
| 原应用 | Frthink v0.8.213（Android，`com.frthink.app`） |
| 原版署名 | `Power by Fr33` |

原版设置页中的版本行和 `Power by Fr33` 署名行在 Frthink 中原样保留。
