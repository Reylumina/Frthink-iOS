# Frthink for iOS

[![Platform](https://img.shields.io/badge/Platform-iOS_17.0%2B-black?style=flat-square&logo=apple)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.10%2B-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![iOS Build](https://github.com/Reylumina/Frthink-iOS/actions/workflows/ios.yml/badge.svg)](https://github.com/Reylumina/Frthink-iOS/actions/workflows/ios.yml)

Frthink for iOS 是 Android 应用 Frthink v0.8.213 的 SwiftUI 移植。原应用由 Fr33 开发，包名为 `com.frthink.app`。本仓库为非官方移植，与原作者无隶属关系。原应用及其提示词版权归原作者所有。

本分支在原版创作流、提示词体系与 `.frthink` 存档兼容的基础上，重构了面向长篇小说的叙事记忆与上下文引擎。

## 架构概览

![Frthink 叙事架构与数据流](assets/architecture-dataflow.png)

## 功能

### 创作与码字机
- **流式续写与思维链**：支持流式生成正文与独立折叠的思考过程卡片；同一轮指令可多次重生成并左右切换候选变体。
- **采纳时提交（Commit-on-Select）**：未采纳的候选草稿不会写入世界状态；仅在点击“插入”或“追加正文”时更新叙事图谱，并与系统撤销/重做及撤回指令联动回滚。
- **分支走向推演**：根据当前在场角色、未决伏笔与写作规则生成多条候选剧情走向，可一键填入输入框。
- **叙事视角（POV）切换**：指定当前章节的视角角色后，自动按该角色的已知信息过滤上下文，隔离未知秘密。
- **选区改写与正文编辑**：支持正文选区指令改写、章节目录跳转及全屏正文编辑。

### 世界工作台（档案 / 剧情 / 规则）
- **设定档案**：按角色、组织、地点、物品分类管理独立档案页。支持从正文或对话气泡提取设定、别名归并、关系一跳联想及设定冲突确认。
- **剧情图谱**：以单轨主路径展示当前因果节拍，在分叉节点可通过菜单切换平行支线，或从任意历史节点分叉续写。切换支线时自动隔离支线事实与伏笔，保留全书通用设定。
- **伏笔追踪**：按 `待埋设 → 就绪 → 已触发 → 已回收 / 已废弃` 五种状态管理伏笔，记录原文引文位置并提示超期未推进的伏笔。
- **作者法则**：管理全局或分支范围的硬性写作要求与禁忌，生成时逐字注入上下文，不经摘要压缩。

### 上下文编排与工具检索
- **三段式上下文**：
  - `Tier 0`（静态前缀）：系统指令、静态文风模板、全书质心样本与顶层目录索引（`BOOK_INDEX`），保持跨轮次前缀一致以复用服务端 KV 缓存。
  - `Tier 1`（对话历史）：按固定轮次推进可逆折叠边界，保留近期完整对话并去重历史工具输出。
  - `Tier 2`（动态工作区）：组装逐字作者法则、在场实体及一跳关联实体、视角角色私有认知、就绪伏笔、场景匹配文风样本与书末正文窗口。
- **按需只读工具**：对支持 Tool Calling 的模型开放全文检索（`grep_manuscript`，受续写锚点因果截断限制）、档案查阅（`read_entity_page`）与历史对话展开（`restore_turn`）；不支持工具的接口自动回退至本地 BM25 与专名锚点检索。
- **分层剧情摘要**：将已发生节拍逐级归纳为近期场次卡、阶段剧情线与卷纲摘要。

### 文风与审校
- **文风提炼**：从样章提炼句法节奏、叙事腔调、感官细节与对白特征，按当前场景类型（动作、对白、心理、景物）动态匹配原文范例。
- **散文体检**：在本地检测旁白中的高频套话与冗余句式密度（自动跳过引号内的角色对白），在界面标出对应原句。
- **记忆自审**：核对正文与设定档案，检查陈旧认知、冗余条目与超期伏笔，支持逐条确认或批量清理。

### 阅读、翻译与共享宇宙
- **阅读器**：支持章节目录识别、全文搜索、书签定位及字号、行高、段距调节。
- **长篇翻译**：支持分段原文与译文对照翻译，以及原文、译文独立导入导出。
- **共享宇宙**：跨书稿复用共享设定词条。

## 模型供应方

在设置页配置服务地址与模型。API Key 保存在 iOS 系统 Keychain 中，不写入普通文件或备份存档。支持服务端返回用量与本地估算结合的累计 Token 统计。

| 供应方 | 默认地址 | 说明 |
|---|---|---|
| DeepSeek | `https://api.deepseek.com` | 支持 `deepseek-chat` / `deepseek-reasoner`、思维链分流与 Prefix 续写 |
| Anthropic | `https://api.anthropic.com` | 原生 `/v1/messages` 协议，支持 Extended Thinking 与 Prompt Caching |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta` | 原生 REST 协议，支持 `thinkingConfig` 与工具调用 |
| OpenRouter | `https://openrouter.ai/api/v1` | 支持统一 `reasoning` 参数与多模型路由 |
| OpenAI 兼容 | 自定义或内置预设 | 内置 Kimi、GLM、Qwen、豆包、混元、MiniMax、OpenCode Go、Ollama Cloud、Grok、Mistral 等预设 |

## 数据与存储

- **本地加密**：本地书稿正文、叙事账本、剧情图谱增量日志（`story_graph.wal`）与检查点均使用 `AES-256-GCM` 加密存储，主密钥保存在系统 Keychain。
- **导入与导出**：兼容原版 `.frthink` 归档导入与导出；正文与译文支持 UTF-8、UTF-16、GB18030 编码文本导入及 `.txt` 导出。

## 构建与安装

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

原版设置页中的版本行和 `Power by Fr33` 署名行在本移植版中原样保留。
