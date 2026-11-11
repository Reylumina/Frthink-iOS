# Frthink 拆解 / 移植 —— 共享简报

> 归档说明：这是 2026-11-08 移植初期的共享简报，路径与工具位置按当时仓库布局写成，现已过时。保留作规格溯源；当前开发约定见 [`../DEVELOPMENT.md`](../DEVELOPMENT.md)。

所有 agent 开工前先读完本文件。它只写一次，所有人共用。

## 素材位置（只读，不要改动）

| 路径 | 内容 |
|---|---|
| `out/apktool/` | apktool 2.11.1 解包结果：`AndroidManifest.xml`、`res/`、`smali/`（4881 个 smali，含 R8 混淆类）、`assets/` |
| `out/jadx/sources/` | jadx 1.5.6 反编译的 4789 个 `.java`（185 个类反编译失败） |
| `out/dex-stringtable.txt` | DEX 字符串表全量 18580 条，**精确、未被截断**。找文案/提示词/JSON 字段首选这里 |
| `out/dex-chinese.txt` | 上面筛出的 1976 条含中文的字符串（粗筛，会按标点断句，长提示词请以 stringtable 为准） |
| `out/classes.dex` | 原始 dex |
| `C:\Users\Token\Downloads\Frthink.apk` | 原始 APK |

工具：JDK 21 在 `tools/jdk/jdk-21.0.13+9/bin/java.exe`，jadx jar 在 `tools/jadx/lib/jadx-1.5.6-all.jar`，apktool 在 `tools/apktool_2.11.1.jar`。

**不要重新跑反编译**，产物已经在了。也不要再调 jadx 的 `-jar`（那个 jar 的 Main-Class 是 GUI，会弹窗），确实要跑只能用
`java -cp tools/jadx/lib/jadx-1.5.6-all.jar jadx.cli.JadxCLI`。

## 已知事实（不用再验证）

- 包名 `com.frthink.app`，应用名 Frthink，compileSdk 36，单 Activity（`MainActivity`）+ 一个前台服务 `com.frthink.app.runtime.LlmTransferService`（dataSync）
- 权限只有：INTERNET / VIBRATE / POST_NOTIFICATIONS / FOREGROUND_SERVICE / FOREGROUND_SERVICE_DATA_SYNC / WAKE_LOCK
- `usesCleartextTraffic=true`，`allowBackup=false`，`largeHeap=true`
- 技术栈：Kotlin + Jetpack Compose + OkHttp + Room + DataStore + kotlinx.coroutines。R8 全量混淆（repackage 到 `A`/`L1`/`M1`/`p000a` 这类顶层包）
- 无加固、无第三方 SDK、无统计埋点
- LLM 供应方：`https://api.deepseek.com`、`https://openrouter.ai/api/v1`、以及自定义 OpenAI 兼容端点（枚举 `DEEPSEEK` / `OPENROUTER` / `OPENAI_COMPATIBLE` / `CUSTOM_OPENAI_COMPATIBLE`）
- 流式：SSE，`text/event-stream`，`Authorization: Bearer`，终止符 `[DONE]`
- 这是一个**AI 中文小说写作/翻译**应用：码字机、世界书、人物卡、事件卡、仿写模板、长期写作规则、语料收集库、译文分段、分支/版本
- 两套 Room 库：
  - ProjectDatabase：`projects`、`project_snapshots`、`project_manuscripts`、`project_source_documents`、`project_deletion_tombstones`、`source_blobs`、`source_blob_links`
  - TranslationDatabase：`translation_segments(owner, project, target, sourceHash, segment, payload)`
- 界面文案几乎全部硬编码在 Kotlin 里（`res/values/strings.xml` 只有 Compose 自带的几条），所以要靠字符串表 + 代码还原

## 阅读代码的技巧

- Kotlin data class 的 `toString()` 保留了字段名，是还原模型最快的入口：
  `grep -r 'return "[A-Z][A-Za-z0-9_]*(' out/jadx/sources`
- Compose 界面类方法多（100+），一般在 `M1`、`Q1`、`B2`、`C2` 这些包里
- 网络层看 `L1/X`（SSE 解析、`[DONE]`）、`L1/V`（27 方法，请求构造）、`L1/U`、`L1/U2`（99 方法）、`J1/P`（CharacterMemory）
- 数据库实体看 `com/frthink/app/data/*Database_Impl.java` 和 `R2/y.java`、`I1/f1.java`
- 提示词在 `out/dex-stringtable.txt`，按"你是/请/只输出/格式"开头检索

## 交付约定

- 参与者只写自己负责的文件，**不要动别人的文件**，不要改 `out/` 下任何东西
- 结论要带证据：给出类名/文件路径/字符串原文，不要臆测
- 中文写作，术语保留英文原文（如 SSE、Room、Compose）
- 拿不准的地方标注「未验证」，不要当成事实写
