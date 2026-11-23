# Frthink for iOS

[![Platform](https://img.shields.io/badge/Platform-iOS_17.0%2B-black?style=flat-square&logo=apple)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.10%2B-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![iOS Build](https://github.com/Reylumina/Frthink-iOS/actions/workflows/ios.yml/badge.svg)](https://github.com/Reylumina/Frthink-iOS/actions/workflows/ios.yml)

Frthink for iOS 是 Android 应用 Frthink v0.8.213 的 SwiftUI 移植。原应用由 Fr33 开发，包名为 `com.frthink.app`。本仓库为非官方移植，与原作者无隶属关系。原应用及其提示词版权归原作者所有。

Frthink 面向中文长篇小说写作，提供码字机流式续写、世界书、人物卡、事件卡、仿写模板、长期写作规则、语料收集库、阅读器与原文翻译。

## 功能

### 创作与码字机
- **流式续写与思维链**：支持流式生成正文与独立折叠的思考过程卡片；同一轮指令可多次重生成并左右切换候选变体。
- **选区改写与正文编辑**：支持选中正文片段按指令局部改写、一键插入或追加至正文，支持系统级撤销/重做（`UndoManager`）。
- **素材面板**：在写作台随时开关参与本轮提示词组装的世界设定、人物卡、事件卡、仿写模板与长期规则。

### 世界观管理
- **世界设定与世界书**：管理作品时代背景、核心设定及自定义世界书词条。
- **人物卡与群组**：支持从正文或对话自动抽取人物卡、分批刷新与关系合并，也可手动编辑角色外貌、性格、目标与记忆。
- **事件卡**：按时序归纳正文剧情事件，支持从正文增量刷新事件脉络。
- **仿写模板与长期规则**：支持从样章分析生成仿写模板，或整理作品长期写作规则并保存历史版本。

### 阅读、翻译与共享宇宙
- **阅读器**：支持章节目录自动识别、全文搜索、书签管理及字号、行高、段距调节。
- **长篇翻译**：支持导入外文或古文原稿，按分段上下文对照翻译并独立导出译文。
- **共享宇宙**：跨书稿共享通用世界观设定与词条。
- **语料收集库**：随时收藏佳句与描写片段，按分类检索复用。

## 模型供应方

在设置页配置服务地址与模型。API Key 保存在 iOS 系统 Keychain 中，不写入普通文件或备份存档。

| 供应方 | 默认地址 | 说明 |
|---|---|---|
| DeepSeek | `https://api.deepseek.com` | 支持 `deepseek-chat` / `deepseek-reasoner` 与思维链分流 |
| Anthropic | `https://api.anthropic.com` | 原生 `/v1/messages` 协议，支持 Extended Thinking |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta` | 原生 REST 协议，支持 `thinkingConfig` |
| OpenRouter | `https://openrouter.ai/api/v1` | 支持统一 `reasoning` 参数与多模型路由 |
| OpenAI 兼容 | 自定义或内置预设 | 内置 Kimi、GLM、Qwen、豆包、混元、MiniMax、OpenCode Go、Ollama Cloud、Grok、Mistral 等预设 |

## 数据与存储

- **本地加密**：本地书稿正文、世界设定、翻译原文与译文均使用 `AES-256-GCM` 加密存储，主密钥保存在系统 Keychain。
- **导入与导出**：兼容原版 `.frthink` 归档导入与导出；正文与译文支持 UTF-8、UTF-16、GB18030 编码文本导入及 `.txt` 导出。

## 构建与安装

### 环境要求
- iOS 17.0 及以上（iOS 26 及以上启用原生 Liquid Glass 材质，iOS 17–25 使用系统毛玻璃材质）
- Xcode 16.0 及以上，无第三方依赖

### 编译

```bash
git clone https://github.com/Reylumina/Frthink-iOS.git
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
