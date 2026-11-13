# APK-NOTES.md · 原版拆解笔记

对 Android 应用 `com.frthink.app` v0.8.213 的拆解结论索引。详细证据在
[`docs/spec/`](spec/) 四份规格里，本文只做总览和交叉引用。

本文记录原版 v0.8.213 的行为，不代表 iOS 当前实现。v0.8.213 相对 v0.8.210 的差异见 [`archive/APK-0.8.213-DELTA.md`](archive/APK-0.8.213-DELTA.md)；下文未改标「v0.8.210 复核」的规格引用仍指向旧版反编译。

## 一、这是什么

AI 中文小说写作工具。主要功能是将长篇小说写作所需的上下文自动化：人物、事件、文风、写作规则
由模型从正文里增量提炼，再回灌到下一次续写的系统提示词。世界刷新、剧情梗概、文风笔记、
事件卡、长期规则都由用户触发，只有自动对话摘要会在达到阈值时后台更新长期规则。

作者署名 **Fr33**（原版设置页 `Power by Fr33`）。

## 二、基本面

| 项 | 值 |
|---|---|
| 包名 | `com.frthink.app` |
| 版本 | v0.8.213 |
| compileSdk | 36 |
| 技术栈 | Kotlin + Jetpack Compose + OkHttp + Room + kotlinx.serialization |
| 混淆 | R8 全量（repackage 到 `A`/`L1`/`M1` 等顶层包） |
| 加固 | **无**。无第三方 SDK、无统计埋点、无网络代理 |
| 组件 | 1 个 Activity（`MainActivity`）+ 1 个前台服务（`LlmTransferService`） |
| 权限 | INTERNET、VIBRATE、POST_NOTIFICATIONS、FOREGROUND_SERVICE(_DATA_SYNC)、WAKE_LOCK |
| 体积构成 | 24.4 MB 是 `res/35.ttf` 一个中文字体，dex 4.48 MB |

应用仅声明上述权限，不读取设备数据，只处理文本。

## 三、功能面

五个一级 Tab（原版没有用路由库，是一个枚举 + `AnimatedContent`）：

| Tab | 内容 |
|---|---|
| **创作** | 码字机。消息气泡 + 候选版本、输入栏三态（阅读/编辑/译文）、本书写作资料浮层 |
| **阅读** | 正文/译文阅读器。搜索、字号行距、章节目录、书签、上一段/下一段 |
| **世界** | 世界书、人物卡、人物卡库、事件卡、仿写模板、剧情梗概 |
| **宇宙** | 跨项目共享层：全局预设、共享世界书、Skill |
| **设置** | 15 个区块，见 [`spec/01`](spec/01-architecture.md) §1.4 |

写作之外的能力：`.frthink` 存档导入导出、语料收集库、提示词集成管理器、翻译分段缓存。

## 四、技术内核：提示词块系统

提示词系统是应用的核心，[`spec/04-prompts.md`](spec/04-prompts.md) 逐字还原了
**64 条**（P01–P64，含 3 条业务正则）。

主写作请求按固定 **14 块顺序**拼装（顺序本身是产品语义）：

```text
项目补充指令、全局预设、技能、全局审查规则(去AI味)、宇宙共享、
本书仿写模板、剧情梗概、语料条目、世界书词条、人物卡、
长期规则摘要、权威正文、调用方块、历史消息
```

三个易错点：
- 第 1 块是**项目级**补充指令，第 2 块才是全局预设
- 第 4 块标题是「全局审查规则」，内容对应「去 AI 味规则」
- 正文块永远在人物卡和长期规则之后、历史消息之前

## 五、LLM 协议

[`spec/02-llm-protocol.md`](spec/02-llm-protocol.md)。

- 端点只有两个：`POST {base}/chat/completions`、`GET {base}/models`
- 请求体 7 个键：`model` / `messages` / `stream` / `temperature` / `max_tokens` /
  `stream_options` / `thinking`
- `thinking` 只发给主机名等于 `api.deepseek.com` 的端点，`stream_options` 只发给
  **非** DeepSeek 的端点。两者互斥
- 没有 `top_p`、`stop`、`response_format`、`presence_penalty`
- **不发** OpenRouter 的 `HTTP-Referer` / `X-Title`（字符串表全表无此串）
- 超时：connect 20s / read 300s / callTimeout 4h
- 应用层**没有**重试退避，`V2.c` 那套退避阶梯是死代码

## 六、数据层

[`spec/03-data-model.md`](spec/03-data-model.md)：63 个 `@Serializable` data class，
两套 Room 库共 8 张表。

一个关键发现：**payload 列不是明文 JSON**，是 `sealed-editor-v1:` 前缀 +
AES-256-GCM，密钥在 AndroidKeyStore 里不可导出。所以跨平台迁移只能走 `.frthink`
导出（`{format, version, compression:"gzip+base64", createdAt, payload}`）。

## 七、安全评估

| 项 | 结论 |
|---|---|
| 加固/壳 | 无 |
| 敏感权限 | 无（无存储、无位置、无通讯录、无剪贴板读取） |
| 网络出口 | 仅用户自配的 LLM 端点 |
| 凭据存储 | API Key 在 EncryptedSharedPreferences，主机名硬编码的端点只有 DeepSeek / OpenRouter 两个 |
| 硬编码密钥 | 未发现 |
| 可疑行为 | 未发现。`usesCleartextTraffic=true` 是为了允许自建 HTTP 反代 |

## 八、移植到 iOS

[SwiftUI 重写](../README.md)，提示词主体逐字保留（[`script/prompt_check.py`](../script/prompt_check.py)
对拍 61/61 命中）。P48–P51 额外追加了事件行文要求：原版只约束「不流水账」，
模型仍会一句一顿；iOS 在原文后要求连贯段落，并在解析时把字段内换行并段。

## 九、已知缺口

见各规格末节，汇总：

- 阅读页 `J5.i0` 方法体 9923 条指令，jadx 放弃反编译，内部分页算法**未验证**
- `L1/K0` 系列（世界抽取主力）jadx 全部失败，只能读 smali
- `create_character_card` 工具 schema 是运行时生成的，**未验证**
- 自动保存去抖间隔、SSE 重连退避：**未验证**
- `M1/v2.smali` 与 `M1/V2.smali` 在 Windows 大小写碰撞，幸存的 `v2.1.smali`
  是唯一含「Tab 到界面」分发逻辑的文件
