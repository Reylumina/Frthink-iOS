# APK-NOTES.md · 原版拆解笔记

对 Android 应用 `com.frthink.app` v0.8.213 的拆解结论索引。详细证据见
[`docs/spec/`](spec/) 四份规格，本文汇总 v0.8.213 的核心结构与行为。

本文记录原版 v0.8.213 的行为，不代表 iOS 当前实现。

## 一、概述

AI 中文小说写作工具。主要功能是将长篇小说写作所需的上下文处理自动化：人物、事件、文风与写作规则
由模型从正文增量提炼，并注入后续续写请求的系统提示词。世界刷新、剧情梗概、文风笔记、
事件卡、长期规则均由用户显式触发（`J1/C0398d` 中的 `autoConversationSummary` / `conversationSummaryThresholdPercent` 在 0.8.213 中为未触发的未生效字段）。

作者署名 **Fr33**（原版设置页 `Power by Fr33`）。

## 二、基础规格

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
| 体积构成 | 其中 24.4 MB 为 `res/35.ttf` 中文字体文件，DEX 文件为 4.48 MB |

应用仅声明上述权限，不读取设备数据，只处理文本。

## 三、功能架构

五个一级 Tab（原版未引入第三方路由库，通过枚举结合 `AnimatedContent` 实现界面分发）：

| Tab | 内容 |
|---|---|
| **创作** | 码字机。消息气泡 + 候选版本、输入栏三态（阅读/编辑/译文）、本书写作资料浮层 |
| **阅读** | 正文/译文阅读器。搜索、字号行距、章节目录、书签、上一段/下一段 |
| **世界** | 世界书、人物卡、人物卡库、事件卡、仿写模板、剧情梗概 |
| **宇宙** | 跨项目共享层：全局预设、共享世界书、Skill |
| **设置** | 15 个区块，见 [`spec/01`](spec/01-architecture.md) §1.4 |

写作之外的能力：`.frthink` 存档导入导出、语料收集库、提示词集成管理器、翻译分段缓存。

## 四、技术内核：提示词块系统

提示词系统是应用的核心，[`spec/04-prompts.md`](spec/04-prompts.md) 完整收录了
**64 条**（P01–P64，含 3 条业务正则）。

主写作请求按固定 **14 块顺序**拼装（顺序本身代表产品语义）：

```text
项目补充指令、全局预设、技能、全局审查规则(去AI味)、宇宙共享、
本书仿写模板、剧情梗概、语料条目、世界书词条、人物卡、
长期规则摘要、权威正文、调用方块、历史消息
```

三项关键设计细节：
- 第 1 块是**项目级**补充指令，第 2 块才是全局预设
- 第 4 块标题是「全局审查规则」，内容对应「去 AI 味规则」
- 正文块永远在人物卡和长期规则之后、历史消息之前

## 五、LLM 协议

[`spec/02-llm-protocol.md`](spec/02-llm-protocol.md)。

- 端点仅有两处：`POST {base}/chat/completions`、`GET {base}/models`
- 请求体 7 个键：`model` / `messages` / `stream` / `temperature` / `max_tokens` /
  `stream_options` / `thinking`
- `thinking` 仅发送给主机名等于 `api.deepseek.com` 的端点，`stream_options` 仅发送给
  **非** DeepSeek 的端点。两者互斥
- 没有 `top_p`、`stop`、`response_format`、`presence_penalty`
- **不发送** OpenRouter 的 `HTTP-Referer` / `X-Title`（字符串表全表无此字符串）
- 超时：connect 20s / read 300s / callTimeout 4h
- 应用层**未实现**重试退避机制，`V2.c` 中的退避阶梯逻辑未实际生效

## 六、数据层

[`spec/03-data-model.md`](spec/03-data-model.md)：63 个 `@Serializable` data class，
两套 Room 库共 8 张表。

关键发现：**payload 列并非明文 JSON**，采用 `sealed-editor-v1:` 前缀 +
AES-256-GCM 加密，密钥保存在 AndroidKeyStore 内部且不可导出。因此跨平台迁移需通过 `.frthink`
导出（`{format, version, compression:"gzip+base64", createdAt, payload}`）。

## 七、安全评估

| 项 | 结论 |
|---|---|
| 加固/壳 | 无 |
| 敏感权限 | 无（无存储、无位置、无通讯录、无剪贴板读取） |
| 网络出口 | 仅用户自配的 LLM 端点 |
| 凭据存储 | API Key 存储于 EncryptedSharedPreferences，主机名硬编码的端点仅有 DeepSeek 与 OpenRouter 两处 |
| 硬编码密钥 | 未发现 |
| 可疑行为 | 未发现。`usesCleartextTraffic=true` 旨在支持自建 HTTP 反向代理 |

## 八、v0.8.213 关键机制核实与移植要点

- [SwiftUI 重写](../README.md)，提示词主体保持严格一致（[`script/prompt_check.py`](../script/prompt_check.py) 比对通过率 61/61）。
- **世界刷新（`L1/W2.B`）**：UI 入口仅写人物卡；普通模式按 `clamp(min(4000, contextBudget × 0.2), 256, 4000)` token 切段（96 token 重叠），**每轮上限 256 段**（`L1/K0.smali:5774-5776`）；长文本模式（码点数 `≥ 500,000`）单次仅分析上下文容量允许的前缀（收尾文案「已分析正文前 N 字，其余未分析」），并扣除已有角色卡字符串（上限 6000 字）与 `4096` 等预算；写库前先按姓名/别称执行连通分量合并（`L1.r.b`/`q0`）再执行 P32–P34 全书去重。
- **素材归纳（`L1/W2.Q0` / `L1/Q2`）**：按 **3000 token** 切段、最多 256 段；剧情模式仅接收「事件数组」或「`events` / `plot_events` 恰好一个」（若同时出现则报错 `事件卡结果必须包含唯一事件数组`），**不写入 `plotOutline`**；每段结束写回 `materialChunkHashes` 与 `materialSourceProgress` 并更新 `StateFlow<C0>` 落盘。
- **语料全量注入（`L1/W2.java:489-530`）**：注入所有启用语料库的全部条目，无 10 条上限。
- **长期规则门控（`L1/W2.java:606-658`）**：要求 `enabled == true && rulesVersion == 1 && !content.isBlank() && content != "暂无长期规则。"`，且所有 `sourceMessageKeys` 以 `"user:"` 开头、`sourceHash == p000a.a.o(sourceMessageKeys)`；`previousRevisions` 保留最近 10 条。
- **人物卡工具路径（`L1/W.smali:423-805`）**：`create_character_card` schema 字段与层级已完整验证；首次请求不发 `thinking`，仅在 HTTP 400 返回同时含 `thinking mode` 与 `tool[_\s-]?choice` 时，无条件附带 `"thinking": {"type": "disabled"}` 与 `Idempotency-Key: {attemptId}-thinking-disabled` 重试。
- **写作台范围限制**：支持 `1–1,000,000` 字「正文范围」配置与保存回执。

## 九、已知缺口

见各规格末节，汇总如下：

- 阅读页 `J5.i0` 方法体包含 9923 条指令，jadx 未能完成反编译，内部分页算法**未验证**
- `L1/K0` 系列（世界设定抽取的核心逻辑）jadx 全部反编译失败，主要结论依据 smali 字节码核实
- 自动保存去抖间隔、SSE 重连退避：**未验证**
- `M1/v2.smali` 与 `M1/V2.smali` 在 Windows 环境发生大小写碰撞，保留下来的 `v2.1.smali`
  为唯一包含「Tab 到界面」分发逻辑的文件
