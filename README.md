# Frthink for iOS

Frthink for iOS 是 Android 应用 Frthink v0.8.213 的 SwiftUI 移植。原应用由 Fr33 开发，包名为 `com.frthink.app`。本仓库为非官方移植，与原作者无隶属关系。原应用及其提示词版权归原作者所有。

Frthink 面向中文长篇小说写作，功能包括码字机流式续写、世界书、人物卡、事件卡、仿写模板、长期写作规则、语料收集库与原文翻译。原版采用 Kotlin 与 Jetpack Compose，本仓库提供 SwiftUI 实现，不包含反编译产物和原始 APK。

## 署名

| 项目 | 内容 |
|---|---|
| 原作 | Fr33 |
| 原应用 | Frthink v0.8.213（Android，`com.frthink.app`） |
| 原版署名 | `Power by Fr33` |

原版设置页中的版本行和署名行在本移植版中原样保留。v0.8.213 相对 v0.8.210 的差异见 [`docs/archive/APK-0.8.213-DELTA.md`](docs/archive/APK-0.8.213-DELTA.md)。

## 状态

| 项目 | 状态 |
|---|---|
| 编译与打包 | 通过。CI 生成未签名 IPA |
| 运行时自检 | 43 项通过。仓库内 fixture 通过 `Real Archive Verify` 执行真实备份导入、导出、落盘与读回 |
| 真实存档导入与导出 | 模拟器运行时验证通过。真机文件选择器未验证 |
| 联网功能 | 未在真机验证，详见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |
| 加密存储 | `payload.json`、`body.pages/*.bin`、`body.meta.json`、`source.json`、`translations.json` 落盘 AES-256-GCM，主密钥在 Keychain，导出保持原版明文 |
| 正文分页、后台生成 | 后台生成已实现；阅读器按块取页；全屏编辑器只载入书末窗口，保存只写窗口页，详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| 世界设定 | `worldbook:setting` 伪词条已移除。旧设定文本迁移为世界书词条，分栏改为概览 |
| 自动摘要 | 阈值触发、P54、历史版本与元数据维护已实现；摘要模型可单独指定，留空跟随当前供应方 |

## 环境要求

| 项目 | 版本 |
|---|---|
| 最低系统 | iOS 17.0 |
| 构建 SDK | iOS 26.2（CI 用 Xcode 26.3 + iPhoneSimulator26.2.sdk；Liquid Glass 通过 `#available(iOS 26.0, *)` 判断，17–25 回落材质） |
| 构建环境 | Xcode 26.3，Swift 5 语言模式 |
| 第三方依赖 | 无 |

## AI 服务商图标

设置页用服务商自己的品牌标，不用通用 SF Symbol：

| 服务商 | 图标来源 |
|---|---|
| DeepSeek | [Simple Icons](https://simpleicons.org/?q=deepseek)（CC0），填充官方蓝 `#4D6BFE` |
| OpenRouter | [官方品牌页](https://openrouter.ai/brand) glyph，浅色 Grape / 深色 Volt |
| OpenAI 兼容 / OpenCode | SF Symbol，无官方品牌标 |

品牌标只用于标识对应服务商，不拉伸、不改色。商标归各自所有者。

## 构建

使用 Xcode 打开 `ios/Frthink.xcodeproj`，或在项目根目录执行：

```bash
xcodebuild -project ios/Frthink.xcodeproj -scheme Frthink \
  -destination 'generic/platform=iOS Simulator' build
```

`.github/workflows/ios.yml` 在 GitHub Actions 上完成编译，并生成未签名 IPA。未签名 IPA 需经 Sideloadly、AltStore 等工具自签，或安装至越狱设备。

## 目录结构

Git 跟踪的部分：

```
ios/
  Frthink.xcodeproj/           文件同步分组，新增 .swift 无需修改工程文件
  Frthink/
    App/                       入口与五个一级 Tab
    Core/
      Models/                  Project、WorldBook、CharacterCard、EventCard、Universe
      Store/                   文件持久化、Keychain、@Observable 状态
      LLM/                     OpenAI 兼容客户端、SSE 解析、token 估算
      Prompts/                 提示词与拼装逻辑
      Design/                  主题与通用容器
    Features/
      Library/                 书架
      Writer/                  创作、码字机
      World/                   世界、世界书、人物卡、事件卡、模板与规则
      Translation/             阅读、原文与译文对照
      Universe/                跨项目共享设定
      Settings/                供应方与密钥
docs/spec/                     反编译还原的四份规格
docs/archive/                  历史审计、研究记录与初期简报
.github/workflows/              编译、自检与截图流水线
```

本机参考材料（`.gitignore` 排除，不随仓库分发）：

```
out/               原版 APK 反编译产物：apktool、jadx、dex 字符串表
tools/             JDK 21、jadx、apktool、cfr
script/            本地校验脚本与一次性迁移脚本
```

仓库不包含 APK 或 IPA：原版 APK 只在本机 `Downloads/Frthink.apk`，未签名 IPA 由 CI 生成。

## 文档

| 文件 | 内容 |
|---|---|
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | 开发环境、验证命令、CI、未验证项与约定 |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 架构、边界、权衡与风险 |
| [docs/DESIGN.md](docs/DESIGN.md) | 视觉、交互、文案与评审清单 |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | 性能、硬件利用与流式实现的依据和做法 |
| [docs/APK-NOTES.md](docs/APK-NOTES.md) | 原版行为拆解与规格索引 |
| [docs/archive/](docs/archive/) | 历史审计、研究记录与旧版执行记录 |
| [docs/spec/](docs/spec/) | 与原版的逐条协议比对 |
| [docs/skills/ios-taste/](docs/skills/ios-taste/) | 界面设计方法参考（vendored，MIT） |

## 模型供应方

供应方在设置页配置。API Key 存储在 Keychain，不写入文件。

| 供应方 | 默认地址 |
|---|---|
| DeepSeek | `https://api.deepseek.com` |
| OpenRouter | `https://openrouter.ai/api/v1` |
| OpenAI 兼容 | 由用户填写，提供 OpenCode Go 预设 |

应用不内置凭据，不上报数据。

## 数据存储

数据位于 `Application Support/Frthink/`：

```
settings.json
projects/<id>/project.json       元数据
projects/<id>/payload.json       世界书、对话等元数据（密文）
projects/<id>/body.pages/         正文分页（每页密文）
projects/<id>/body.json          旧版单文件正文（仅迁移）
projects/<id>/body.meta.json     字数、UTF-16 长度与章节（密文）
projects/<id>/source.json        翻译原文（密文）
projects/<id>/translations.json  译文分段（密文）
```
