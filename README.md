<div align="center">

# Frthink

**面向长篇小说创作的原生 iOS AI 叙事工作台**

零第三方依赖 · 纯 SwiftUI 构建 · 事件溯源叙事记忆 · 端到端本地加密

[![Platform](https://img.shields.io/badge/Platform-iOS_17.0%2B-black?style=flat-square&logo=apple)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.10%2B-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![UI](https://img.shields.io/badge/UI-SwiftUI_%2B_Liquid_Glass-0A84FF?style=flat-square)](https://developer.apple.com/xcode/swiftui/)
[![Dependencies](https://img.shields.io/badge/Dependencies-Zero-34C759?style=flat-square)](#架构设计)
[![iOS Build](https://github.com/Reylumina/Frthink-iOS/actions/workflows/ios.yml/badge.svg)](https://github.com/Reylumina/Frthink-iOS/actions/workflows/ios.yml)

<p align="center">
  <a href="#核心特性">核心特性</a> •
  <a href="#叙事记忆与上下文引擎">叙事引擎</a> •
  <a href="#文风提炼与审校">文风与审校</a> •
  <a href="#模型与协议支持">模型支持</a> •
  <a href="#隐私与本地存储">安全存储</a> •
  <a href="#构建与安装">构建安装</a>
</p>

</div>

---

**Frthink** 是一款专为中文长篇网文与严肃小说创作者打造的原生 iOS 创作应用。它将**高帧率流式码字机**、**事件溯源三账本（事实 / 认知 / 伏笔）**、**Cache-First 上下文编排**与**六维文风提炼引擎**融为一体，解决长篇连载中“吃设定、角色串戏、AI 腔调浓重、上下文前缀频繁失效”四大核心痛点。

---

## 核心特性

### 1. 创作台与流式码字机
- **33ms 帧控流式输出**：底层基于 `NSTextStorage` 末段增量替换与 TextKit 两端对齐排版，长文流式生成与思维链（CoT）实时展开零抖动。
- **多变体分支与 Commit-on-Select**：同一轮指令支持多次重生成、左右切换变体与独立折叠思考卡片；**未采纳的草稿绝不污染世界状态**，仅在点击“插入/追加正文”时原子提交至叙事图谱，并支持系统级撤销/重做（`UndoManager`）联动回退设定账本。
- **分支走向推演**：卡文时可基于当前在场状态、未决伏笔与法则推演多条差异化剧情走向，一键填入码字机指令。
- **窗口化大文本编辑**：正文按页落盘，全屏编辑器仅加载书末活跃窗口，百万字书稿秒开秒存。

### 2. 三段式世界工作台（档案 · 剧情 · 规则）
- **设定档案（Entity Pages）**：每位角色、组织、地点、物品拥有独立档案页，支持从正文/对话一键提取设定、关系一跳联想、别名归一化及设定冲突温和确认。
- **线性主路径剧情图谱（Story Graph）**：采用 `Focus + Context` 单轨线性主路径呈现因果节拍，在分叉点通过内联菜单切换平行支线；切换或回退分支时，自动隔离支线剧情事实与伏笔，同时保留全书通用设定。
- **五态伏笔追踪（Prospective Threads）**：支持 `待埋设 (Pending) → 就绪可触发 (Ready) → 已触发 (Enacted) → 已回收 (Satisfied) / 已废弃 (Invalidated)` 全生命周期流转与超期未回收提醒。
- **作者法则（Author Directives）**：支持全局与分支级逐字硬性法则（禁词、人设底线、叙事铁律），**永不被摘要压缩**，始终逐字注入动态工作区。

### 3. 阅读器与长篇译制
- **沉浸式分页阅读**：按块懒加载正文页，支持章节目录自动识别、全文搜索、书签定位与字号/行高（默认 `1.2x`）精细调节。
- **长篇分段对照翻译**：内置针对长篇小说优化的滑窗上下文与术语一致性翻译工作流，支持原文与译文双栏/分段对照及独立导入导出。
- **共享宇宙（Universe）**：跨书稿共享世界观词条与基础设定，方便系列作品与多卷联动。

---

## 叙事记忆与上下文引擎

Frthink 摒弃了传统的“全量塞入提示词”或“靠模型全盘重写设定表”，采用**写时确定性事件溯源 + 读时前缀锁定（Cache-First）**架构：

```text
┌─────────────────────────────────────────────────────────────────────────┐
│ Tier 0 · 静态冻结前缀 (100% 命中服务端 KV Cache)                        │
│   系统指令 + 文风静态模板与全书质心样本 + 全书紧凑索引 (≤ 200 行)       │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 1 · 可逆折叠对话流 (ReFold k=3)                                    │
│   远期对话折叠为单行摘要 + 保留最近 3 轮完整对话与工具调用轨迹          │
├─────────────────────────────────────────────────────────────────────────┤
│ Tier 2 · 动态场景工作区 (Query-Cone 按需装配)                           │
│   逐字作者法则 + 在场实体与一跳关联实体 + POV 私有认知隔离 +            │
│   就绪伏笔 + 场景匹配文风样本 + 书末正文窗口 (2K / 6K / 12K)            │
└─────────────────────────────────────────────────────────────────────────┘
```

- **真相与认知分离（Epistemic Isolation）**：严格区分“客观世界事实 $W$”与“角色私有认知 $B[c]$”。选定当前章节叙事视角（POV）后，仅向模型暴露该视角角色已知的事实与合理误解，从根源杜绝“全知视角泄密”。
- **原生只读工具闭环**：对支持 Tool Calling 的模型默认开启 `grep_manuscript`（因果截断全文正则检索）、`read_entity_page`（按需查阅离场实体档案）、`restore_turn`（展开历史折叠对话）；无工具网关自动无缝回退至端侧增量 BM25 + 机械锚点（`AnchorIndex`）预检索。
- **四层叙事金字塔（Narrative Pyramid）**：支持将离散场拍滚动归纳为阶段小结、卷纲一句话摘要与已完结剧情线，兼顾百万字跨度与近期细节。

---

## 文风提炼与审校

- **六维文风提炼（Style Distiller）**：从样章中提炼句法节奏、叙事腔调、感官密度、对白特征与正反技法，结合五维 MMR 多样性采样与当前场景语域（动作 / 对白 / 心理 / 景物）动态路由最具代表性的原文范例。
- **纯端侧去 AI 味体检（Prose Style Linter）**：内置毫秒级纯 Swift 散文体检器，自动扫描旁白中的翻译腔、高频陈词滥调与排比句式密度，**智能豁免双引号与直角引号内的角色对白**，并在界面直接标红问题原句。
- **记忆自审（Offline Dreaming）**：按需扫描全书事实冲突、失效认知、档案膨胀与超期伏笔，提供“同步事实 / 保留信息差 / 查看档案 / 一键安全整理”精细化治理。

---

## 模型与协议支持

内置三大原生协议客户端与统一流式传输层（`LLMHTTPTransport`），支持 `<think>` 标签流式实时剥离、表驱动思考预算调节、流式/非流式服务端 Token 用量解析与本地估算兜底：

| 协议 / 供应方 | 接入方式与特性 |
|---|---|
| **DeepSeek** | 原生支持 `deepseek-chat` / `deepseek-reasoner`、`reasoning_content` 思维链流式分流、Prefix 续写与工具调用透传 |
| **Anthropic (Claude)** | 原生 `/v1/messages` 协议，支持 Extended Thinking 预算控制与超过 `1024 tokens` 自动挂载 `ephemeral` Prompt Caching 断点 |
| **Google Gemini** | 原生 `/v1beta` REST 协议，支持 `thinkingConfig` 思考等级控制、`thought` 部分离与原生 `functionDeclarations` |
| **OpenRouter** | 原生支持统一 `reasoning` 参数与多厂商模型路由 |
| **OpenAI 兼容网关** | 内置 DeepSeek、Kimi、GLM、Qwen、豆包、混元、MiniMax、OpenCode Go、Ollama Cloud、Grok、Mistral 等 13 项预设与独立 Key 绑定，支持 `stream_options` / `tools` / `prefill` 不兼容时自动降级重试 |

---

## 隐私与本地存储

- **零云端后台 & Keychain 隔离**：所有 API Key 仅存储于 iOS 系统级 `Keychain`；应用无任何遥测、统计或中转服务器，请求直连用户配置的模型端点。
- **全盘 AES-256-GCM 加密 + 增量 WAL**：书稿正文分页（`body.pages/*.bin`）、叙事三账本（`ledgers.json`）、剧情图谱增量日志（`story_graph.wal`，达阈值自动压实并支持崩溃尾帧自愈）与检查点快照均以 `AES-256-GCM` 密文落盘。
- **开放导入与归档**：支持 `.frthink` 全量压缩归档备份与恢复，正文与译文支持 UTF-8 / UTF-16 / GB18030 自动识别导入及纯文本 `.txt` 导出。

---

## 架构设计

工程仅使用 iOS 原生框架（`SwiftUI`、`Foundation`、`UIKit`、`CryptoKit`、`Security`、`Compression`），零第三方依赖：

```text
ios/Frthink/
├── App/                  应用入口、五栏 Tab 导航与内置运行时自检 (SelfCheck)
├── Core/
│   ├── Narrative/        事件溯源三账本、StoryGraph DAG、加密 WAL、ReFold 折叠、
│   │                     Query-Cone 上下文编排、只读工具集、去 AI 味体检与离线自审
│   ├── Prompts/          提示词模板、六维文风提炼 (StyleDistiller) 与预算规划
│   ├── LLM/              OpenAI 兼容 / Anthropic / Gemini 客户端、流式 <think> 拆分器、Token 统计
│   ├── Store/            AES-256-GCM 加密存储、正文分页引擎、增量 BM25 索引、Keychain
│   ├── Models/           项目、章节、共享宇宙与设置模型
│   └── Design/           iOS 26 Liquid Glass 自适应材质、主题 Token、TextKit 两端对齐排版
└── Features/
    ├── Library/          书架、作品封面与回收站
    ├── Writer/           流式码字机、多变体卡片、分支推演、选区改写与窗口化正文编辑器
    ├── World/            三段式世界工作台（档案 · 剧情 · 规则）、文风提炼与生成工作流
    ├── Narrative/        设定档案页、线性主路径剧情图、五态伏笔、作者法则与记忆自审视图
    ├── Reader/           分页阅读器、目录检索与排版设置
    ├── Translation/      长篇分段翻译与双语对照
    ├── Universe/         跨书稿共享宇宙设定库
    └── Settings/         模型供应方、提示词管理、语料库、Token 统计与归档导入导出
```

---

## 构建与安装

### 环境要求
- **运行系统**：iOS 17.0 及以上（在 iOS 26+ 自动启用原生 Liquid Glass 液态玻璃材质，iOS 17–25 自动回落至原生毛玻璃材质）
- **编译环境**：Xcode 16.0+ / Xcode 26+，Swift 5.10+

### 本地编译
1. 克隆仓库并在 Xcode 中打开工程：
   ```bash
   git clone https://github.com/Reylumina/Frthink-iOS.git
   cd Frthink-iOS
   open ios/Frthink.xcodeproj
   ```
2. 或直接通过命令行编译模拟器产物：
   ```bash
   xcodebuild -project ios/Frthink.xcodeproj -scheme Frthink \
     -destination 'generic/platform=iOS Simulator' build
   ```

### 获取 IPA 安装包
仓库内置 GitHub Actions 自动化流水线（[`.github/workflows/ios.yml`](.github/workflows/ios.yml)），每次触发构建会自动生成未签名安装包 `Frthink-unsigned.ipa`，下载后可通过 **AltStore**、**SideStore**、**Sideloadly** 或 **TrollStore** 签名安装至真机。
