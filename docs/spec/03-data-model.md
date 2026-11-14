# 03 · 领域模型与持久化结构

> 目标读者：依据本文档实现 Swift 端模型层与持久化存储模块的工程师。
> 所有结论都带证据（类名 / 文件 / 字符串原文）。R8 混淆后类名是 `I1.j2` 这种，文档里同时给出
> **原始全限定名**（来自 kotlinx.serialization 的 `PluginGeneratedSerialDescriptor`）和**混淆类名**。
> 字段命名严格依循代码实际拼写；尚未确证的项均标记为「未验证」。

> v0.8.213 复核：关键结构与差异汇总见 [`../APK-NOTES.md`](../APK-NOTES.md)；本文保留数据字段规格。

---

## 0. 结论速览

| 项 | 结论 |
|---|---|
| 持久化层 | **Room ×2 + EncryptedSharedPreferences ×1 + 普通 SharedPreferences ×3 + 加密文件 ×1 + JSON 文件 ×1 + 导出文件** |
| 项目库 | `frthink_projects.db`，Room v6，7 张表 |
| 翻译库 | `frthink_translations.db`，Room v1，1 张表 |
| 设置/凭证 | `dream_machine_secrets`（androidx EncryptedSharedPreferences，AES256_SIV 键 + AES256_GCM 值） |
| **payload 是否明文** | **不是。全部是 AES-GCM 加密后 Base64，带 `sealed-editor-v1:` 前缀** |
| 加密密钥 | AndroidKeyStore 别名 `frthink-editor-v1`，AES-256，GCM/NoPadding |
| JSON 序列化 | kotlinx.serialization，主 Json 实例配置 `encodeDefaults=true, ignoreUnknownKeys=true` |
| 哈希 | SHA-256；正文/原文类用**小写 hex(64)**，项目内容哈希用**标准 Base64** |
| 时间戳 | 一律 `Long` epoch millis（`System.currentTimeMillis()`），**不是** ISO 字符串 |
| 排序/版本 | `revision: Long` 单调递增；`schemaVersion` 当前 **20** |

**Swift 端开发关键提示**：`projects` / `project_snapshots` / `project_manuscripts` /
`project_source_documents` / `source_blobs` / `translation_segments` 中的 `payload` 列**并非明文 JSON**，
而是结构为 `"sealed-editor-v1:" + Base64(AES-GCM(...))` 的加密数据。如需获取 JSON 结构必须先完成解密，参见 §4。
`projects` 表的其它列（`title`/`synopsis`/`updatedAt`/`revision`/`branchRootId`/`branchOrder`/`trashedAt`）
是明文。

---

## 1. 存储分层总览

| # | 载体 | 路径 / 名称 | 存什么 | 证据 |
|---|---|---|---|---|
| 1 | Room DB | `frthink_projects.db` | 项目元数据、快照、正文、原文清单、墓碑、原文 blob | `L1\U2.java:269` `T0.b.B(applicationContext2, ProjectDatabase.class, "frthink_projects.db")` |
| 2 | Room DB | `frthink_translations.db` | 译文分段 | `I1\M3.java:35` `"frthink_translations.db"` |
| 3 | EncryptedSharedPreferences | `dream_machine_secrets` | 所有设置 + API Key | `I1\C0330o2.java:109`；见 §7 |
| 4 | SharedPreferences | `frthink_connection` | 连接相关状态 | `L1\U2.java:287` |
| 5 | SharedPreferences | `frthink-body-sync` | `local-only-mvp` 布尔开关 | `L1\C0557l1.java:297` 等 |
| 6 | SharedPreferences | `storage-maintenance` | 存储维护状态 | `C\x.java:647` |
| 7 | 加密文件 | `<filesDir>/universe-corpus-v1.enc` | 语料库（AtomicFile） | `I1\C0370z.java:1031` |
| 8 | JSON 文件 | `<filesDir>/task-diagnostics-v1.json` | 诊断事件 | `I1\n3.java:43` |
| 9 | 加密目录 | `<noBackupFilesDir>/editor-drafts-v1`、`editor-outbox-v1` | 增量草稿 journal、outbox | `A\C0034r0.java:662-670` |
| 10 | 导出文件 | `*.frthink` | 全量备份 / 书项目存档 | §9 |

> **注意**：BRIEF 里写的 "DataStore" 在代码里**没有实际使用**——`PreferenceDataStoreFactory` /
> `preferencesDataStore` 在全量源码里 0 命中（androidx.datastore 只是被依赖打包进来）。
> 设置全部走 **EncryptedSharedPreferences**。这一点对移植很关键。

---

## 2. Room 库 A：ProjectDatabase

### 2.1 基本信息

| 项 | 值 |
|---|---|
| 类 | `com.frthink.app.data.ProjectDatabase`（抽象）+ `ProjectDatabase_Impl` |
| 文件 | `frthink_projects.db` |
| version | **6**（`I1\C0285f1.java:145` `this(6)`） |
| identity_hash | `f00e1b35e44defb4e6df7b39bf2eb284`（`ProjectDatabase_Impl.java:32`、`I1\C0285f1.java:41`） |
| 表 | `projects`、`project_snapshots`、`project_manuscripts`、`project_source_documents`、`project_deletion_tombstones`、`source_blobs`、`source_blob_links` |

### 2.2 建表语句（原文，`I1\C0285f1.java:32-39`）

```sql
CREATE TABLE IF NOT EXISTS `projects` (`id` TEXT NOT NULL, `title` TEXT NOT NULL, `synopsis` TEXT NOT NULL, `updatedAt` INTEGER NOT NULL, `revision` INTEGER NOT NULL, `coverImagePayload` TEXT, `branchRootId` TEXT NOT NULL DEFAULT '', `branchOrder` INTEGER NOT NULL DEFAULT 0, `trashedAt` INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(`id`))
CREATE TABLE IF NOT EXISTS `project_snapshots` (`projectId` TEXT NOT NULL, `payload` TEXT NOT NULL, `updatedAt` INTEGER NOT NULL, PRIMARY KEY(`projectId`))
CREATE TABLE IF NOT EXISTS `project_manuscripts` (`projectId` TEXT NOT NULL, `payload` TEXT NOT NULL, `contentHash` TEXT NOT NULL, `updatedAt` INTEGER NOT NULL, PRIMARY KEY(`projectId`))
CREATE TABLE IF NOT EXISTS `project_source_documents` (`projectId` TEXT NOT NULL, `payload` TEXT NOT NULL, `contentHash` TEXT NOT NULL, `updatedAt` INTEGER NOT NULL, PRIMARY KEY(`projectId`))
CREATE TABLE IF NOT EXISTS `project_deletion_tombstones` (`projectId` TEXT NOT NULL, `markedAt` INTEGER NOT NULL, PRIMARY KEY(`projectId`))
CREATE TABLE IF NOT EXISTS `source_blobs` (`id` TEXT NOT NULL, `payload` TEXT NOT NULL, PRIMARY KEY(`id`))
CREATE TABLE IF NOT EXISTS `source_blob_links` (`projectId` TEXT NOT NULL, `blobId` TEXT NOT NULL, PRIMARY KEY(`projectId`, `blobId`))
CREATE INDEX IF NOT EXISTS `source_blob_lookup` ON `source_blob_links` (`blobId`)
```

### 2.3 实体 ↔ 表

| 表 | entity 全名 | 混淆类 | 字段（顺序即列序） |
|---|---|---|---|
| `projects` | `com.frthink.app.data.ProjectEntity` | `I1\C0295h1.java` | `id: String` / `title: String` / `synopsis: String` / `updatedAt: Long` / `revision: Long` / `coverImagePayload: String?` / `branchRootId: String` / `branchOrder: Int` / `trashedAt: Long` |
| `project_snapshots` | `ProjectSnapshotEntity` | `I1\C0311k2.java` | `projectId: String` / `payload: String` / `updatedAt: Long` |
| `project_manuscripts` | `ProjectManuscriptEntity` | `I1\C0300i1.java` | `projectId: String` / `payload: String` / `contentHash: String` / `updatedAt: Long` |
| `project_source_documents` | `ProjectSourceDocumentsEntity` | `I1\C0316l2.java` | `projectId: String` / `payload: String` / `contentHash: String` / `updatedAt: Long` |
| `project_deletion_tombstones` | `ProjectDeletionEntity` | `I1\C0290g1.java` | `projectId: String` / `markedAt: Long` |
| `source_blobs` | `SourceBlobEntity` | `I1\C0267b3.java` | `id: String` / `payload: String` |
| `source_blob_links` | `SourceBlobLinkEntity` | `I1\C0272c3.java` | `projectId: String` / `blobId: String` |

> 实体全名来自 Room 的 schema 校验错误串，例如
> `"projects(com.frthink.app.data.ProjectEntity).\n Expected:\n..."`（`I1\C0285f1.java:67`）。

### 2.4 迁移（`R2\y.java:799-827`，`I1\C0280e1.java`）

`C0280e1(from, to, case)`：`(2,3,0) (3,4,1) (4,5,2) (5,6,3)`。

| 迁移 | SQL |
|---|---|
| 2 → 3 | `CREATE TABLE IF NOT EXISTS project_deletion_tombstones (...)` |
| 3 → 4 | `ALTER TABLE projects ADD COLUMN coverImagePayload TEXT` |
| 4 → 5 | `ALTER TABLE projects ADD COLUMN branchRootId TEXT NOT NULL DEFAULT ''`；`ALTER TABLE projects ADD COLUMN branchOrder INTEGER NOT NULL DEFAULT 0` |
| 5 → 6 | `ALTER TABLE projects ADD COLUMN trashedAt INTEGER NOT NULL DEFAULT 0`；`CREATE TABLE source_blobs (...)`；`CREATE TABLE source_blob_links (...)`；`CREATE INDEX source_blob_lookup` |

> 推论：v1/v2 的 `projects` 只有 `id,title,synopsis,updatedAt,revision`。
> 也就是说 `coverImagePayload`/`branchRootId`/`branchOrder`/`trashedAt` 都是后加的（默认值已给出）。

### 2.5 DAO SQL（`I1\C0275d1.java`、`I1\E1.java`、`I1\S0.java`、`I1\T0.java`、`I1\R0.java`）

写入：

```sql
INSERT INTO `project_snapshots` (`projectId`,`payload`,`updatedAt`) VALUES (?,?,?)
INSERT INTO `project_manuscripts` (`projectId`,`payload`,`contentHash`,`updatedAt`) VALUES (?,?,?,?)
INSERT INTO `project_source_documents` (`projectId`,`payload`,`contentHash`,`updatedAt`) VALUES (?,?,?,?)
INSERT OR IGNORE INTO `source_blobs` (`id`,`payload`) VALUES (?,?)
INSERT INTO `project_deletion_tombstones` (`projectId`,`markedAt`) VALUES (?,?)
```

**分块读取**（关键：payload 可能很大，读的时候按 `substr` 切片）：

```sql
SELECT substr(payload, ?, ?) FROM project_snapshots  WHERE projectId = ? LIMIT 1
SELECT substr(payload, ?, ?) FROM project_manuscripts WHERE projectId = ? LIMIT 1
SELECT substr(payload, ?, ?) FROM project_source_documents WHERE projectId = ? LIMIT 1
SELECT substr(payload, ?, ?) FROM source_blobs WHERE id = ?
SELECT length(payload) FROM project_snapshots WHERE projectId = ? LIMIT 1
SELECT length(payload) FROM project_manuscripts WHERE projectId = ? LIMIT 1
SELECT length(payload) FROM project_source_documents WHERE projectId = ? LIMIT 1
```

统计/一致性检查（`I1\C0348t1.java:52`）——**这些 key 名是存储层自检报告用的**：

`orphanSnapshots` / `orphanManuscripts` / `orphanSourceManifests` / `orphanSourceLinks` /
`missingSourceBlobs` / `unreferencedSourceBlobs` / `missingSnapshots` / `missingManuscripts`

```sql
DELETE FROM source_blobs WHERE NOT EXISTS (SELECT 1 FROM source_blob_links l WHERE l.blobId = source_blobs.id)
```

> 语义：`source_blobs` 与项目是**多对多**（通过 `source_blob_links`），同内容只存一份；
> 无引用的 blob 会被清理。
>
> **分段读取**是这套存储的核心约束：payload 可能远大于单个 Cursor 窗口，
> 所以读取一律是「先 `SELECT length(payload)`，再按偏移 `substr` 循环拼」。
> 读取/解密失败时的文案是 `加密资料分段读取失败；原资料未删除`（字符串表 17540 行）。

---

## 3. Room 库 B：TranslationDatabase

| 项 | 值 |
|---|---|
| 类 | `com.frthink.app.data.TranslationDatabase` + `_Impl` |
| 文件 | `frthink_translations.db` |
| version | **1**（`I1\C0285f1.java:24` `this(1)`） |
| identity_hash | `7e05e746b83ccbafc8149d839bac86f0` |
| entity | `com.frthink.app.data.TranslationSegmentEntity`（`I1\t3.java`） |

```sql
CREATE TABLE IF NOT EXISTS `translation_segments` (`owner` TEXT NOT NULL, `project` TEXT NOT NULL, `target` TEXT NOT NULL, `sourceHash` TEXT NOT NULL, `segment` INTEGER NOT NULL, `payload` TEXT NOT NULL, PRIMARY KEY(`owner`, `project`, `target`, `sourceHash`, `segment`))
```

| 列 | 类型 | 说明 |
|---|---|---|
| `owner` | TEXT | 归属（见 `ProjectStorageKey.owner`，由项目推导，见 §8.3） |
| `project` | TEXT | projectId |
| `target` | TEXT | 目标语言，正文译文固定 `"body"`（见 `I1\R0.java:57` 的 `target='body'`） |
| `sourceHash` | TEXT | 原文小写 hex SHA-256（64 字符，强校验） |
| `segment` | INTEGER | 分段序号，从 0 开始 |
| `payload` | TEXT | Base64(AES-GCM(JSON `TranslationRecord`))，**无前缀** |

读取时 payload 被截断到 64 KiB 用于列表：

```sql
SELECT owner, project, target, sourceHash, segment, substr(payload,1,65536) AS payload
FROM translation_segments WHERE owner=? AND project=? AND target=? AND sourceHash=? ORDER BY segment
```

删除：

```sql
DELETE FROM translation_segments WHERE owner=? AND project=?
DELETE FROM translation_segments WHERE owner=? AND project=? AND target=? AND sourceHash!=?
DELETE FROM translation_segments WHERE owner=? AND project=? AND target='body' AND sourceHash=?
DELETE FROM translation_segments WHERE owner=? AND project=? AND target=? AND sourceHash=?
```

---

## 4. payload 的加密封装：`sealed-editor-v1`

### 4.1 算法与格式

证据：`A\C0034r0.java`（R8 合并类，`u()` 加密 / `q()` 解密）。

```
明文 ──(>=4096 字节则 gzip，且仅当压缩更小)──> payload
wire = [1 byte 版本][12 byte IV][ciphertext || 16 byte GCM tag]
版本: 0x01 = 原始明文, 0x02 = gzip 明文
列值 = "sealed-editor-v1:" + Base64(标准, 无换行)(wire)
```

- 算法：`AES/GCM/NoPadding`，`GCMParameterSpec(128, iv)`，IV 12 字节（`cipher.getIV()`）。
- **AAD = identity 字符串的 UTF-8 字节**（`cipher.updateAAD(str.getBytes(UTF_8))`）。
  每个 payload 的 identity 不同，见 §4.3。AAD 不对就解不开。
- gzip 阈值：`bArr.length >= 4096` 才尝试压缩，且 `byteArray.length < bArr.length` 才采用。
- 解压上限：`201326592` 字节（192 MiB），超出抛 `IllegalStateException("解压资料超过安全上限")`。
- 解密前置校验：`bArr.length < 29 || bArr[0] ∉ {1,2}` → `IllegalArgumentException("不支持或损坏的编辑缓存")`。

### 4.2 密钥来源

`I1\I.java`：

```java
KeyStore.getInstance("AndroidKeyStore"); keyStore.containsAlias("frthink-editor-v1")
KeyGenParameterSpec.Builder("frthink-editor-v1", 3)   // 3 = ENCRYPT|DECRYPT
    .setBlockModes("GCM").setEncryptionPaddings("NoPadding").setKeySize(256)
```

- 别名 `frthink-editor-v1`，AES-256-GCM，密钥在 AndroidKeyStore 内**不可导出**。
- 惰性单例，`I.editorKey()`（Kotlin property delegate）。
- **Swift 端无法复用**：iOS 必须换成 Keychain + CryptoKit(AES.GCM)，并且**旧数据无法直接解密迁移**，
  只能走「导出明文」路径（见 §9 的 `credentialSecrets` / 明文正文恢复注意事项）。

### 4.3 各 payload 的 identity（AAD）

| 载体 | identity（AAD） | 列值前缀 | 证据 |
|---|---|---|---|
| `project_snapshots.payload` | `projectId` | `sealed-editor-v1:` | `I1\C0286f2.java:134` `u(str, bytes)`，str = projectId |
| `project_manuscripts.payload` | `projectId + ":manuscript-v1"` | `sealed-editor-v1:` | `I1\C0286f2.java:100,103` |
| `project_source_documents.payload` | `projectId + ":source-documents-v1"` | `sealed-editor-v1:` | `I1\C0286f2.java:1176` |
| `source_blobs.payload` | `blobId`（= `owner + ":" + hex(sha256(content))`） | `sealed-editor-v1:` | `I1\C0286f2.java:1163` |
| `projects.coverImagePayload` | `projectId + ":cover"` | `sealed-editor-v1:` | `I1\C0286f2.java:78,95`；明文按 **US-ASCII** 编解码（`p089y2.a.f18152d`），即内容本身就是 ASCII 文本（Base64 图片） |
| `translation_segments.payload` | `JSON 数组 [owner, project, target, sourceHash, segment.toString()]` | **无前缀** | `I1\M3.java:89-96`、`I1\H3.java:60` |
| `<filesDir>/universe-corpus-v1.enc` | 字面量 `"frthink:universe:corpus:v1"` | **无前缀**（整文件） | `I1\C0366y.java:56`、`I1\C0362x.java:51` |
| `editor-drafts-v1/*.sealed` 等 | 各自的 identity 字符串 | 整文件 | `A\C0034r0.java:302-310`（文件名 = `hex(sha256(identity)) + ".sealed"`） |

翻译分段的 AAD 生成（`I1\M3.java:89-96`）：

```kotlin
// identity = Json.encodeToString(ListSerializer(String.serializer()),
//              listOf(owner, project, target, sourceHash, segment.toString()))
```
→ 实际字符串形如 `["default","proj-1","body","ab12…64hex","0"]`（紧凑 JSON，无空格）。

### 4.4 大小上限（原文）

| 文案 | 触发 | 证据 |
|---|---|---|
| `单项项目加密资料超出安全保存上限（N MiB）；未写入` | 单个 sealed 项 ≥ 134217729 字节（128 MiB） | `I1\C0286f2.java:55-63` |
| `译文编辑稿过大，未覆盖已保存译文` | Base64 后 > 96000000 字符 | `I1\H3.java:61-63` |
| `语料库超过保存上限，未覆盖存档` | JSON > 67108864 字节（64 MiB） | `I1\C0366y.java:54` |
| `解压资料超过安全上限` | 解密后解压 > 192 MiB | `A\C0034r0.java:375` |
| `加密资料分段读取失败；原资料未删除` | `substr(payload, ?, ?)` 分块读取/解密失败时 | 字符串表 17540 行；对应方法 jadx 未能反编译（185 个失败类之一），调用点未验证 |

---

## 5. payload 里的 JSON 结构

序列化统一用 kotlinx.serialization。主 Json 实例：
`Q2.q f4124c = b3.l.c(new C0258a(7))` → `JsonConfiguration(encodeDefaults=true, ignoreUnknownKeys=true)`（`b3\l.java:640` + `Q2\j.java:77` 的字段顺序对照）。

> **对 Swift 端**：`encodeDefaults=true` 意味着**所有字段都会写进 JSON，包括默认值**。
> 因此 Swift 的 `Codable` 不能依赖「缺省字段 = 默认值」的宽松解码，最好全部给默认值 + 容错。

### 5.1 `project_snapshots.payload` → `com.frthink.app.data.ProjectSnapshot`

混淆类 `I1\C0306j2`，serializer `I1\C0296h2`，共 **56** 个字段。
descriptor 里 56 条全是 `q3.m(name, true)`，即 **全部带默认值**（`isOptional = true`）；
配合 `encodeDefaults = true`，正常写出的 JSON 里 56 个键**一个都不缺**。
可空（Kotlin `?`）的只有 `lastBodyAppendUndo`、`coreBodyNextCursor`。

| # | 字段 | 类型 | 说明 |
|---|---|---|---|
| 0 | `schemaVersion` | `Int`（默认 20） | 快照结构版本；不支持时报「项目数据版本不受支持」 |
| 1 | `coreIdentity` | `String` | 项目归属身份 |
| 2 | `projectRevision` | `Long` | 对应 `projects.revision` |
| 3 | `messages` | `List<ChatMessage>` | 聊天/对话消息 |
| 4 | `deletedChatMessageIds` | `Set<String>` | 已删除消息 id |
| 5 | `world` | `WorldSummary` | 世界观摘要 |
| 6 | `projectAssistantPrompt` | `String` | 项目级助手提示词 |
| 7 | `characterCards` | `List<CharacterCard>` | 人物卡 |
| 8 | `characterGroups` | `List<CharacterGroup>` | 人物分组 |
| 9 | `worldbooks` | `List<WorldbookEntry>` | 世界书条目 |
| 10 | `enabledUniverseEntryIds` | `Set<String>` | 启用的宇宙条目 |
| 11 | `requestSnapshots` | `List<CloudRequestSnapshot>` | 请求快照历史 |
| 12 | `requestContentPool` | `List<String>` | 请求内容池 |
| 13 | `conversationSummary` | `ConversationSummary` | 对话摘要 |
| 14 | `characterAnalysisCheckpoint` | `CharacterAnalysisCheckpoint` | 人物分析断点 |
| 15 | `localSourceDocuments` | `List<LocalSourceDocument>` | 原文文档（**注意：这里 `content` 为空串**，正文在 blob 里） |
| 16 | `authoritativeBody` | `String` | 权威正文（全量） |
| 17 | `bodyPromptTailCodePoints` | `Int` | 送 prompt 时取正文末尾多少码点 |
| 18 | `bodyPromptSendWhole` | `Boolean` | 是否整篇送 |
| 19 | `bodyPromptStartCodePoint` | `Int` | 送 prompt 的起始码点 |
| 20 | `bodyPromptEndCodePoint` | `Int` | 送 prompt 的结束码点 |
| 21 | `bodyAppendReceiptIds` | `List<String>` | 正文追加回执 id |
| 22 | `lastBodyAppendUndo` | `BodyAppendUndo?` | 可空 |
| 23 | `coreBodyDocumentId` | `String` | 核心正文文档 id |
| 24 | `coreBodyVersion` | `Long` | 核心正文版本 |
| 25 | `coreBodyLoadedAll` | `Boolean` | 是否已全量加载 |
| 26 | `coreBodyContentLength` | `Long` | 正文总长（UTF-16） |
| 27 | `coreBodyLoadedStart` | `Int` | 已加载起点 |
| 28 | `coreBodyNextCursor` | `String?` | 可空 |
| 29 | `bodyLocks` | `List<BodyLockSnapshot>` | 编辑锁 |
| 30 | `pendingBodyLockIds` | `Set<String>` | 待同步锁 id |
| 31 | `lockSyncError` | `String` | 锁同步错误 |
| 32 | `composerDraft` | `String` | 输入框草稿 |
| 33 | `readerOffset` | `Int` | 阅读位置 |
| 34 | `readerBookmarkOffset` | `Int` | 书签位置 |
| 35 | `continuationAnchorOffset` | `Int` | 续写锚点 |
| 36 | `continuationAnchorPrefixHash` | `String` | 锚点前缀哈希 |
| 37 | `formDrafts` | `Map<String,String>` | 表单草稿 |
| 38 | `agentTaskId` | `String` | 智能体任务 id |
| 39 | `agentRequestKey` | `String` | 请求幂等键 |
| 40 | `agentTaskEventSeq` | `Long` | 事件序号 |
| 41 | `agentTaskStatus` | `String` | 任务状态 |
| 42 | `agentTaskSummary` | `String` | 任务摘要 |
| 43 | `agentStreamingText` | `String` | 流式输出文本 |
| 44 | `agentStreamingMessageId` | `String` | 流式消息 id |
| 45 | `agentStreamingAppend` | `Boolean` | 是否追加式流 |
| 46 | `agentTurns` | `List<AgentTurnUi>` | 智能体轮次 |
| 47 | `agentTaskEvents` | `List<String>` | 任务事件 |
| 48 | `task` | `AgentTaskUi` | 当前任务 UI 状态 |
| 49 | `auditTaskId` | `String` | 审计任务 id |
| 50 | `auditTaskStatus` | `String` | 审计状态 |
| 51 | `auditTaskSummary` | `String` | 审计摘要 |
| 52 | `auditCompletedBatches` | `Int` | 已完成批次数 |
| 53 | `auditTotalBatches` | `Int` | 总批次数 |
| 54 | `auditChangedPatches` | `Int` | 变更补丁数 |
| 55 | `auditError` | `String` | 审计错误 |

> 证据：`I1\C0296h2.java`（descriptor 的 56 条 `q3.m("…")` + decode 的 `case N`）与
> `I1\C0306j2.java` 的合成构造器默认值。元素类型来自 `I1\C0306j2.java:192` 的 `L2.a[] f4170e0`。

### 5.2 `project_source_documents.payload` → `com.frthink.app.data.SharedSourceManifest`

混淆类 `I1\X2`，serializer `I1\V2`，2 字段：

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `format` | `String` | `"shared-source-v1"` | 格式标记 |
| `documents` | `List<SharedSourceReference>` | 无 | 引用清单 |

`SharedSourceReference`（`I1\C0262a3`，serializer `I1\Y2`）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `document` | `LocalSourceDocument` | 元数据，`content` 被置空（`J1.J0.a(j4, "", …)`，`I1\C0286f2.java:1140`） |
| `blobId` | `String` | 指向 `source_blobs.id` |

`source_blobs.payload` = sealed(原文 UTF-8 文本)，identity = `blobId`。
`contentHash` 列 = `Base64(SHA-256(projectId ‖ 0x00 ‖ JSON(List<LocalSourceDocument>)))`（含 content 的完整列表，`I1\C0261a2.java:123`）。

### 5.3 `project_manuscripts.payload`

**不是 JSON**：是正文原文的 sealed 串。

```
payload     = "sealed-editor-v1:" + Base64(AESGCM(authoritativeBody.getBytes(UTF_8), aad = projectId+":manuscript-v1"))
contentHash = Base64(SHA-256(projectId ‖ 0x00 ‖ authoritativeBody))
```
证据：`I1\C0286f2.java:98-104`、`I1\C0261a2.java:74,90,96`、`p051o0\c.java:147-162`。
编码：`p089y2.a.f18149a` = UTF-8。

### 5.4 `translation_segments.payload` → `com.frthink.app.runtime.TranslationRecord`

混淆类 `L1\y3`，serializer `L1\w3`，12 字段：

| # | 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|---|
| 0 | `target` | `String` | — | 目标语言；正文译文 = `"body"` |
| 1 | `sourceHash` | `String` | — | **必须**匹配 `[a-f0-9]{64}` |
| 2 | `index` | `Int` | — | 分段序号 ≥ 0，须等于行的 `segment` |
| 3 | `chunkHash` | `String` | — | **必须**匹配 `[a-f0-9]{64}` |
| 4 | `text` | `String` | — | 译文，非空，长度 ≤ 20000 |
| 5 | `model` | `String` | — | 产出该译文的模型 id |
| 6 | `sourceDocument` | `String` | `""` | 原文；`index == 0` 时长度 ≤ 16000000 且 `hex(sha256(sourceDocument)) == sourceHash` |
| 7 | `bodyTypeset` | `Boolean` | `false` | 是否排版过 |
| 8 | `bodyChineseQuotes` | `Boolean` | `false` | 是否中文引号化 |
| 9 | `bodyEditedText` | `String?` | `null` | 人工编辑稿，≤ 16000000 |
| 10 | `bodyEditedSegments` | `Int` | `0` | ≥ 0；`bodyEditedText == null` 时必须为 0 |
| 11 | `bodyBookmarkOffset` | `Int` | `-1` | ≥ -1 |

校验逻辑原文：`p051o0\c.java:597+`（`R(TranslationRecord)`），错误文案
`译文原文关联校验失败` / `译文编辑关联校验失败`。
读出后还要比对 `target/sourceHash/index` 与行值，不符抛 `译文身份校验失败`（`I1\M3.java:75-77`）。

### 5.5 存档与备份核心载荷

#### `FrthinkArchiveEnvelope`（`I1\O`，serializer `I1\M`）—— `.frthink` 文件的最外层

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `format` | `String` | `"writing-workspace-backup"` | 全量备份为 `"frthink-full-backup"` |
| `version` | `Int` | `1` | 只接受 1 |
| `compression` | `String` | `"gzip+base64"` | 只接受这个值 |
| `createdAt` | `Long` | — | epoch millis |
| `payload` | `String` | — | `Base64(gzip(JSON(…)))` |

#### `ProjectArchivePayload`（`I1\K0`）—— 书项目存档解压后的结构

| 字段 | 类型 | 默认 |
|---|---|---|
| `formatVersion` | `Int` | `1` |
| `createdAt` | `Long` | `currentTimeMillis()` |
| `projects` | `List<ProjectBackupPayload>` | 无 |

#### `ProjectBackupPayload`（`I1\O0`，serializer `I1\M0`）

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `formatVersion` | `Int` | `1` | 必须 1 |
| `createdAt` | `Long` | now | |
| `projectId` | `String` | — | |
| `title` | `String` | — | |
| `synopsis` | `String` | — | |
| `snapshot` | `ProjectSnapshot` | — | 明文快照（**存档里不加密**） |
| `universeEntries` | `List<WorldbookEntry>` | `[]` | |
| `coverImageBase64` | `String` | `""` | |
| `branchRootId` | `String` | `""` | |
| `branchOrder` | `Int` | `0` | |
| `trashedAt` | `Long` | `0` | |
| `translations` | `List<TranslationRecord>` | `[]` | |

#### `FullFrthinkBackupPayload`（`I1\S`，serializer `I1\P`）

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `formatVersion` | `Int` | `1` | 必须 1 |
| `createdAt` | `Long` | now | |
| `settings` | `StoredSettings` | — | required |
| `credentialSecrets` | `Map<String,String>` | `{}` | credentialId → **明文 API Key** |
| `projects` | `List<ProjectBackupPayload>` | — | required |
| `activeProjectId` | `String` | `""` | |
| `corpusLibrary` | `CorpusLibrary?` | `null` | 有默认值，可空 |

> 存档校验（`I1\L0.java`）的错误文案（原文）：
> `书项目存档版本不受支持`、`书项目存档为空`、`书项目存档含重复项目`、`书项目数据版本不受支持`、
> `书项目存档含重复译文分段`、`书项目存档引用了未包含的共享世界书`、
> `全量备份版本不受支持`、`全量备份含重复项目`、`备份含重复译文分段`、`收集库结构无效`、`收集库 ID 重复`。

---

## 6. 领域模型全集

共 **63** 个 `@Serializable` data class（扫描方式：每个序列化器里 `new P2.Q("全限定名", …, N)`）。
下表按模块分组。

> 关于「默认值」：kotlinx 的 `PluginGeneratedSerialDescriptor.addElement(name, isOptional)` 里
> 第二个参数 `true` = 有默认值（JSON 可缺省）、`false` = 必填。
> 本文只对已核实过的类标注默认值；没标的表示「未逐个核对」，不代表没有默认值。
> `encodeDefaults=true` 时即使有默认值也会写出，所以**新数据**里键总是齐的，但**旧数据**可能缺新键。

### 6.1 项目 / 正文 / 分支

| 类（全名） | 混淆类 | 字段 |
|---|---|---|
| `model.ProjectRecord` | `J1\Y0` | `id: String`=UUID / `title: String` / `synopsis: String`=`""` / `updatedLabel: String`=`"刚刚"` / `documentCount: Int`=0 / `contentLength: Long`=0 / `kindCounts: Map<String,Int>`={} / `createdLabel: String`=`""` / `coverImageBase64: String`=`""` / `branchRootId: String`=`""` / `branchOrder: Int`=0 / `trashedAt: Long`=0 |
| `data.ProjectCatalogRow` | `I1\P0` | `id/title/synopsis: String`、`updatedAt: Long`、`revision: Long`、`branchRootId: String`、`branchOrder: Int`、`trashedAt: Long`（Room 投影，非 `@Serializable`，但会出现在列表 UI） |
| `data.OfflineProjectSpec` | `I1\H0` | `title: String`、`synopsis: String`（离线建项目用） |
| `model.BodyAppendUndo` | `J1\C0422u` | `confirmationId: String`、`messageVersionId: String`、`previousUtf16Length: Int`、`appendedSuffix: String`、`resultSha256: String` |
| `data.BodyConflictBranch` | `I1\C0273d` | `version: Long`、`text: String` |
| `data.BodyRecoveryPoint` | `I1\C0303j` | `baseVersion: Long`、`baseText: String`、`localText: String`、`remote: BodyConflictBranch?` |
| `data.BodyLockSnapshot` | `I1\C0288g` | `id: String`、`start: Int`、`end: Int` |
| `data.OfflineBodyLock` | `I1\E0` | `id: String`、`start: Int`、`end: Int`、`deviceId: String`、`operationId: String` |
| `data.BodySyncOperation` | `I1\C0342s` | `id: String`、`deviceId: String`、`baseVersion: Long`、`start: Int`、`end: Int`、`replacement: String` |
| `data.BodySyncSession` | `I1\C0354v` | `coreIdentity/projectId/documentId: String`、`baseVersion: Long`、`baseText/localText: String`、`pending: BodySyncOperation?`、`conflict: String`、`deleted: Boolean`、`remoteConflict: BodyConflictBranch?`、`recovery: List<BodyRecoveryPoint>`、`creation: OfflineProjectSpec?`、`pendingLocks: List<OfflineBodyLock>`、`lockSyncError: String` |
| `data.IncrementalDraftJournal.Header` | `I1\Y` | `owner: Owner`、`epoch: String`、`snapshot: String`、`snapshotRevision: Long`、`revision: Long`、`lastBase: Long`、`lastHash: String`、`deleted: Boolean`、`publishedRevision: Long`、`retired: List<Retired>` |
| `data.IncrementalDraftJournal.Owner` | `I1\C0274d0` | `core: String`、`project: String`、`document: String` |
| `data.IncrementalDraftJournal.Scope` | `I1\C0309k0` | `core: String`、`project: String`、`documents: List<String>`、`deleted: Boolean` |
| `data.IncrementalDraftJournal.Snapshot` | `I1\C0324n0` | `owner: Owner`、`revision: Long`、`text: String`、`baseVersion: Long`、`baseText: String` |
| `data.IncrementalDraftJournal.Delta` | `I1\V` | `owner: Owner`、`base: Long`、`revision: Long`、`changes: List<Change>` |
| `data.IncrementalDraftJournal.Retired` | `I1\C0294h0` | `snapshot: String`、`from: Long`、`to: Long` |
| `data.IncrementalEditorBuffer.Change` | `I1\A0` | `from: Int`、`to: Int`、`insert: String` |
| `data.PreparedSave` | `I1\C0320m1` | `snapshotPayload/manuscript/sources: String`、`clearSources: Boolean`、`bodyHash/sourceHash: String`（内存结构，不落盘） |
| `data.EncodedSources` | `I1\C0310k1` | `row: ProjectSourceDocumentsEntity`、`blobs: List<SourceBlobEntity>`、`blobIds: Set<String>`（内存结构） |
| `data.ProjectStorageKey` | `I1\C0321m2` | `owner: String`、`projectId: String`（内存结构） |
| `data.StoredProjectMetadata` | `I1\C0329o1` | `snapshotLength: Int`、`manuscriptHash: String`、`manuscriptLength: Int`、`sourceHash: String`、`sourceLength: Int`、`revision: Long`（内存结构） |

### 6.2 世界书 / 人物 / 事件 / 仿写

| 类 | 混淆类 | 字段 |
|---|---|---|
| `model.WorldSummary` | `J1\B1` | `currentState: String`、`plotOutline: String`、`plotEvents: List<PlotEventCard>`、`imitationTemplate: String`、`characters: List<String>`、`relationships: List<String>`、`events: List<String>`、`materialChunkHashes: Map<String,String>`、`materialSourceProgress: Map<String,MaterialSourceProgress>` |
| `model.WorldbookEntry` | `J1\E1` | `id: String`、`title: String`、`keywords: String`、`content: String`、`enabled: Boolean`、`dynamic: Boolean` |
| `model.CharacterCard` | `J1\D` | `id: String`、`name: String`、`identity: String`、`personality: String`、`voice: String`、`goals: String`、`boundaries: String`、`enabled: Boolean`、`memories: List<CharacterMemory>`、`customEntries: List<CharacterEntry>`、`aliases: List<String>`、`groupId: String`、`personalMemory: String`、`relationshipAttitudes: String` |
| `model.CharacterDraft` | `J1\G` | `name/identity/personality/voice/goals/boundaries: String`、`aliases: List<String>`、`personalMemory: String`、`relationshipAttitudes: String` |
| `model.CharacterEntry` | `J1\J` | `id: String`、`name: String`、`content: String` |
| `model.CharacterMemory` | `J1\P` | `id: String`、`content: String`、`evidence: String`、`createdAt: Long` |
| `model.CharacterGroup` | `J1\M` | `id: String`、`name: String`、`enabled: Boolean` |
| `model.PlotEventCard` | `J1\V0` | `id/title/scene: String`、`characters: List<String>`、`cause/development/consequence: String` |
| `model.ImitationModule` | `J1\D0` | `key: String`、`title: String`、`content: String` |
| `model.MaterialSourceProgress` | `J1\O0` | `processedUtf16: Int`、`prefixHash: String`、`promptHash: String` |
| `model.CharacterAnalysisCheckpoint` | `J1\C0428x` | `sourceSha256: String`、`sourceCodePointCount: Int`、`totalSegments: Int`、`completedSegments: List<CharacterAnalysisSegmentResult>`、`mergedDraft: CharacterDraft?`、`mergedCards: List<CharacterCard>`、`characterBaselineSha256: String`、`worldMaterialSha256: String`、`worldRefreshComplete: Boolean` |
| `model.CharacterAnalysisSegmentResult` | `J1\A` | `index: Int`、`startCodePoint: Int`、`endCodePoint: Int`、`extractedFields: String` |

### 6.3 消息 / 版本 / 用量

| 类 | 混淆类 | 字段 |
|---|---|---|
| `model.ChatMessage` | `J1\U` | `id: String`=UUID / `kind: ChatMessageKind`（required）/ `title: String?`=null / `content: String`（required）/ `isAccepted: Boolean`= (`kind == DRAFT`) / `tokenUsage: TokenUsage?`=null / `segments: List<AgentTurnUi>`=[]（字段名为 segments，元素类型为 `AgentTurnUi`，依代码原样对齐）/ `versions: List<ChatMessageVersion>`=[] / `activeVersionId: String`=`""` |
| `model.ChatMessageVersion` | `J1\X` | `id: String`、`content: String`、`source: String`、`requestId: String`、`status: String`、`tokenUsage: TokenUsage?`、`createdAt: Long` |
| `model.TokenUsage` | `J1\r1` | `promptTokens: Long`、`completionTokens: Long`、`totalTokens: Long`、`estimated: Boolean`、`promptCacheHitTokens: Long?`、`promptCacheMissTokens: Long?`、`cacheMetricsRequests: Long` |
| `model.TokenUsageRecord` | `J1\w1` | `requestId: String`、`occurredAtMillis: Long`、`attemptCount: Int`、`credentialId: String`、`credentialName: String`、`provider: String`、`modelId: String`、`promptTokens/completionTokens: Long`、`promptCacheHitTokens/promptCacheMissTokens: Long?`、`estimated: Boolean` |
| `model.TokenUsageModelTotal` | `J1\t1` | `attribution: String`、`totals: TokenUsage` |
| `model.TokenUsageTrendPoint` | `J1\y1` | `promptTokens: Long`、`completionTokens: Long` |
| `model.ChatShortcut` | `J1\C0379a0` | `id: String`、`name: String`、`text: String`、`enabled: Boolean` |
| `model.ConversationSummary` | `J1\C0402j0` | `content: String`、`sourceMessageKeys: List<String>`、`sourceHash: String`、`enabled: Boolean`、`updatedAt: Long`、`previousRevisions: List<ConversationSummaryRevision>`、`rulesVersion: Int` |
| `model.ConversationSummaryRevision` | `J1\C0408m0` | `content: String`、`sourceMessageKeys: List<String>`、`sourceHash: String`、`enabled: Boolean`、`updatedAt: Long`、`rulesVersion: Int` |
| `model.CloudRequestSnapshot` | `J1\C0396g0` | `id: String`、`createdAt: Long`、`modelId: String`、`sourceIds: List<String>`、`messages: List<PromptMessageSnapshot>`、`estimatedInputTokens/inputBudgetTokens/configuredInputBudgetTokens: Int`、`modelContextWindowTokens: Int?`、`outputReserveTokens/omittedHistoryMessages: Int`、`actualPromptTokens/actualCompletionTokens/actualPromptCacheHitTokens/actualPromptCacheMissTokens: Long?` |
| `model.PromptMessageSnapshot` | `J1\g1` | `role: String`、`content: String`、`sourceId: String`、`blockType: PromptBlockType?`、`sourceScope: PromptSourceScope`、`sourceTitle: String`、`contentPoolIndex: Int`、`includedInRequest: Boolean` |
| `model.AgentTurnUi` | `J1\C0401j` | `id: String`、`index: Int`、`title/status/content: String`、`tools: List<String>`、`inputTokens/outputTokens/totalTokens: Long`、`usageEstimated: Boolean` |
| `model.AgentTaskUi` | `J1\C0395g` | `status/summary: String`、`canPause/visible/compact: Boolean`、`phase/currentTool/goalSummary/nextAction: String`、`evidenceCount/issueCount: Int`、`draftStatus: String` |

### 6.4 语料 / 技能 / 智能体

| 类 | 混淆类 | 字段 |
|---|---|---|
| `model.CorpusLibrary` | `J1\C0429x0` | `id: String`、`name: String`、`enabled: Boolean`、`collections: List<CorpusLibrary>`（**递归**）、`revision: Long`、`rules: String`（≤8000）、`entries: List<CorpusEntry>`、`processedKeys/deletedTextKeys/classifiedKeys: Set<String>` |
| `model.CorpusEntry` | `J1\C0423u0` | `id: String`=UUID、`title: String`、`text: String`、`category: String`、`tags: List<String>`、`origins: List<CorpusOrigin>`、`createdAt/updatedAt: Long` |
| `model.CorpusOrigin` | `J1\A0` | `projectId: String`、`messageId: String`、`versionId: String` |
| `runtime.CorpusCandidate` | `L1\C` | `source: String`、`title: String`、`text: String`、`category: String`、`tags: List<String>` |
| `runtime.CorpusExtraction` | `L1\H` | `entries: List<CorpusCandidate>`、`rejectedEntries: Int` |
| `runtime.CorpusExtractionPayload` | `L1\K` | `rules: String`、`categories: List<String>`、`fragments: List<CorpusSourcePayload>` |
| `runtime.CorpusSourcePayload` | `L1\N` | `source: String`、`text: String` |
| `model.SkillProfile` | `J1\o1` | `id: String`、`name: String`、`prompt: String`、`enabled: Boolean`、`boundAgentIds: List<String>` |
| `model.AgentProfile` | `J1\C0384c` | `id: String`、`name: String`、`role: String`、`systemPrompt: String`、`modelRole: String`、`enabled: Boolean`、`modelOverride: String` |

### 6.5 设置 / 凭证 / 模型

| 类 | 混淆类 | 字段 |
|---|---|---|
| `data.StoredSettings` | `I1\C0307j3` | 见 §6.6（41 字段） |
| `model.ApiCredentialProfile` | `J1\C0407m` | `id: String`、`name: String`、`platform: ApiPlatform`、`baseUrl: String`、`primaryModel/writingModel/summaryModel/translationModel/supportModel: String`、`availableModels: List<String>`、`modelCapabilities: List<CloudModelCapability>`、`favoriteModelIds: List<String>` |
| `model.CloudModelCapability` | `J1\C0388d0` | `id: String`（required）、`contextWindowTokens: Int?`=null、`maxOutputTokens: Int?`=null、`promptPricePerTokenUsd: **String?**`=null、`completionPricePerTokenUsd: **String?**`=null（价格是**字符串**不是 Double，`J1\C0388d0.java` 字段声明为 `String`） |
| `model.PromptBlockPreference` | `J1\C0383b1` | `type: PromptBlockType`、`enabled: Boolean`、`order: Int` |

枚举（`J1` 包）：

| 枚举 | 常量（序列化名） |
|---|---|
| `ChatMessageKind`（`J1\Q0`） | `USER`、`ASSISTANT`、`SYSTEM`、`DRAFT` |
| `PromptBlockType`（`J1\EnumC0389d1`） | `全局预设`、`智能体指令`、`用户输入`、`对话历史`、`正文`、`人物资料`、`世界资料`、`技能` |
| `ApiPlatform`（`J1\EnumC0413p`） | `DeepSeek`(默认 `https://api.deepseek.com`)、`OpenRouter`(`https://openrouter.ai/api/v1`)、`OpenAI 兼容`(`""`) |
| `MotionFrameRate`（`J1\S0`） | `FPS_60`、`FPS_120` |
| `ReaderFont`（`J1\k1`） | `黑体`、…（枚举体在 jadx 里被截断，其余常量未验证） |
| `PromptSourceScope`（`J1\i1`） | 单字段包装，未验证具体常量 |

> `ApiPlatform` 的枚举常量名被 R8 去掉了，但**序列化名用的是构造器第一个参数**（`"DeepSeek"` 等），
> 所以 JSON 里出现的是这些中文/英文显示名，而不是 `DEEPSEEK`。

### 6.6 `StoredSettings` 41 字段（`I1\C0307j3`，serializer `I1\C0297h3`）

字段名后带 **`*`** 的 = **required（没有默认值，JSON 里必须出现）**；不带 `*` 的 = 有默认值。
证据：`I1\C0297h3.java` 里 `q3.m(name, isOptional)` 第二个参数，`true` = 有默认、`false` = 必填；
前 24 个（#0–#23）是 `false`，后 17 个（#24–#40）是 `true`。
类型来自 `I1\C0307j3.java:331` 的构造器参数（`z`=boolean、`i`=int、`j`=long、`str`=String、`list`=List），
**全部非空**（没有 `?`）。

| # | 字段 | 类型 | # | 字段 | 类型 |
|---|---|---|---|---|---|
| 0 | `requireApproval` * | `Boolean` | 21 | `inputBudgetTokens` * | `Int` |
| 1 | `baseUrl` * | `String` | 22 | `autoConversationSummary` * | `Boolean` |
| 2 | `primaryModel` * | `String` | 23 | `conversationSummaryThresholdPercent` * | `Int` |
| 3 | `writingModel` * | `String` | 24 | `outputBudgetTokens` | `Int` |
| 4 | `supportModel` * | `String` | 25 | `promptCacheHitTokens` | `Long` |
| 5 | `availableModels` * | `List<String>` | 26 | `promptCacheMissTokens` | `Long` |
| 6 | `modelCapabilities` * | `List<CloudModelCapability>` | 27 | `cacheMetricsRequests` | `Long` |
| 7 | `composerDraft` * | `String` | 28 | `worldBuildInstruction` | `String` |
| 8 | `apiConfigured` * | `Boolean` | 29 | `readerFont` | `ReaderFont` |
| 9 | `promptTokens` * | `Long` | 30 | `hapticLevel` | `Int` |
| 10 | `completionTokens` * | `Long` | 31 | `favoriteModelIds` | `List<String>` |
| 11 | `credentials` * | `List<ApiCredentialProfile>` | 32 | `tokenUsageRecords` | `List<TokenUsageRecord>` |
| 12 | `activeCredentialId` * | `String` | 33 | `chatShortcuts` | `List<ChatShortcut>` |
| 13 | `agents` * | `List<AgentProfile>` | 34 | `excludeAssistantChatHistory` | `Boolean` |
| 14 | `skills` * | `List<SkillProfile>` | 35 | `summaryModel` | `String` |
| 15 | `worldbooks` * | `List<WorldbookEntry>` | 36 | `translationModel` | `String` |
| 16 | `globalPreset` * | `String` | 37 | `plotOutlineInstruction` | `String` |
| 17 | `aiFlavorRules` * | `String` | 38 | `imitationInstruction` | `String` |
| 18 | `aiFlavorRulesDraft` * | `String` | 39 | `streamingResponses` | `Boolean` |
| 19 | `promptBlocks` * | `List<PromptBlockPreference>` | 40 | `darkThemeEnabled` | `Boolean` |
| 20 | `motionFrameRate` * | `MotionFrameRate` | | | |

> 注意 `StoredSettings` **本身不单独落盘**，它只是：
> ① `FullFrthinkBackupPayload.settings` 的载体；② 运行时由 SharedPreferences 各键聚合出来的视图。
> 证据：`A\C0048y0.java:933,1309` 用各键构造 `new C0307j3(...)`。

### 6.7 诊断 / 运行时（非持久，但会进备份或日志）

| 类 | 混淆类 | 字段 |
|---|---|---|
| `data.DiagnosticReport` | `I1\F` | `format: String`、`appVersion: String`、`androidApi: Int`、`generatedAt: Long`、`events: List<DiagnosticEvent>` |
| `runtime.DiagnosticEvent` | `L1\C0512a0` | `timestamp: Long`、`taskRef: String`、`operation: DiagnosticOperation?`、`stage: DiagnosticStage?`、`result: DiagnosticResult?`、`failure: DiagnosticFailure?`、`httpStatus: Int?`、`completed/total: Int?`、`elapsedMs: Long?`、`streaming: Boolean?`、`compatibilityRetry: Boolean`、`outputBudget: Int?`、`inputTokens/outputTokens: Long?`、`responseChunks/visibleChunks/reasoningChunks/unrecognizedChunks: Int?`、`finish: String` |
| `runtime.TranslationView` | `L1\z3` | `sourceHash/text: String`、`completed/total: Int`、`busy: Boolean`、`error: String?`、`typesetSaving: Boolean`、`bookmarkOffset: Int`、`loaded/loading: Boolean`、`requestToken: Int` |
| `runtime.TranslationBrowserState` | `L1\t3` | `versions: List<SavedTranslationVersion>`、`selected: String?`、`loading: Boolean`、`error: String?` |
| `runtime.SavedTranslationVersion` | `L1\g3` | `hash: String`、`records: List<TranslationRecord>`、`text: String`、`total: Int`、`current: Boolean`、`error: String?` |
| `runtime.TranslationCache` | `L1\u3` | `source: String`、`records: List<TranslationRecord>` |
| `runtime.TranslationEditorContext` | `L1\G0` | `owner/hash/text: String`、`source: String` |
| `runtime.LlmMessage` | `L1\W2` | `role: String`、`content: String`、`blockType: String` |
| `runtime.Usage` | `L1\n3` | `promptTokens/completionTokens/totalTokens: Long`、`promptCacheHitTokens/promptCacheMissTokens: Long?` |
| `runtime.SourceTextChunk` | `L1\h3` | `index/startCodePoint/endCodePoint: Int`、`content: String` |
| `runtime.PromptBodyTail` | `L1\c3` | `text: String`、`totalCodePoints: Int`、`documentId: String`、`version: Long` |
| `runtime.PromptSource` | `L1\f3` | `id: String`、`type: PromptBlockType`、`content: String`、`mandatory: Boolean`、`title: String`、`scope: PromptSourceScope` |
| `runtime.CompiledCloudPrompt` | `L1\C0606y` | `snapshot: CloudRequestSnapshot`、`messages: List<LlmMessage>` |
| `runtime.ChatCompletionSseSummary` | `L1\C0602x` | `dataChunks/contentChunks/reasoningChunks/ignoredChunks: Int`、`finishReason: String?`、`receivedDone: Boolean`、`unrecognizedShapes: Int` |
| `runtime.AuthoritativeTextPatch` | `L1\C0511a` | `start: Int`、`end: Int`、`replacement: String`、`changed: Boolean` |
| `runtime.BoundaryOverlapResult` | `L1\C0515b` | `text: String`、`removedCodePoints: Int` |
| `runtime.CharacterCardToolResponse` | `L1\C0594v` | `card: CharacterCard`、`usage: Usage` |
| `runtime.CharacterCardToolMergeResult` | `L1\C0586t` | `cards: List<CharacterCard>`、`cardId: String`、`created: Boolean`、`changed: Int` |

---

## 7. 设置与凭证：`dream_machine_secrets`

### 7.1 载体

`I1\C0330o2.java:70-109` 构造 `androidx.security.crypto.EncryptedSharedPreferences`：

| 项 | 值 |
|---|---|
| 文件名 | `dream_machine_secrets` |
| 主密钥 | AndroidKeyStore 别名 `_androidx_security_master_key_`，AES-256-GCM（`A1\c.java:5`） |
| 键加密 | `AES256_SIV`，keyset 前缀 `__androidx_security_crypto_encrypted_prefs_key_keyset__` |
| 值加密 | `AES256_GCM`，keyset 前缀 `__androidx_security_crypto_encrypted_prefs_value_keyset__` |

### 7.2 键名全表（`I1\T2.java:27-143`）

| 键 | 类型 | 语义 |
|---|---|---|
| `require_world_approval` | bool | 世界观改动需确认 |
| `deepseek_model` | string | 主模型 |
| `base_url` | string | API 基址 |
| `writing_model` | string | 写作模型 |
| `summary_model` | string | 摘要模型 |
| `translation_model` | string | 翻译模型 |
| `support_model` | string | 辅助模型 |
| `available_models` | string | 可用模型列表 |
| `model_capabilities` | string | 模型能力 JSON |
| `composer_draft` | string | 输入框草稿 |
| `global_prompt_tokens` | long | 累计 prompt token |
| `global_completion_tokens` | long | 累计 completion token |
| `global_prompt_cache_hit_tokens` | long | |
| `global_prompt_cache_miss_tokens` | long | |
| `global_cache_metrics_requests` | long | |
| `global_token_usage_records_v1` | string | 用量记录 JSON 数组 |
| `global_chat_shortcuts_v1` | string | 快捷短语 JSON |
| `api_credentials_v2` | string | `List<ApiCredentialProfile>` JSON |
| `active_credential_id` | string | 当前凭证 id |
| `global_agents` | string | 智能体 JSON |
| `global_skills` | string | 技能 JSON |
| `global_worldbooks` | string | 共享世界书 JSON |
| `global_llm_preset` | string | 全局预设 |
| `global_ai_flavor_rules` | string | 去 AI 味规则 |
| `global_ai_flavor_rules_draft` | string | 规则草稿 |
| `prompt_block_preferences` | string | 提示块偏好 JSON |
| `motion_frame_rate` | string | 帧率枚举 |
| `streaming_responses` | bool | 流式 |
| `dark_theme_enabled` | bool | 深色 |
| `input_budget_tokens` | int | 输入预算 |
| `output_budget_tokens` | int | 输出预算 |
| `output_budget_migration_version` | int | 输出预算迁移版本 |
| `auto_conversation_summary` | bool | 自动摘要 |
| `exclude_assistant_chat_history` | bool | 摘要排除助手历史 |
| `conversation_summary_threshold_percent` | int | 摘要阈值 |
| `world_build_instruction` | string | 世界观构建指令 |
| `plot_outline_instruction` | string | 情节大纲指令 |
| `imitation_instruction` | string | 仿写指令 |
| `reader_font` | string | 阅读字体 |
| `haptic_level` | int | 震动强度 |
| `editor_device_id` | string | 设备标识（UUID，`T2.java:213`） |
| `pending_project_core` | string | 创建中项目的 coreIdentity |
| `pending_project_record` | string | 创建中项目的 `ProjectRecord` JSON |
| `deepseek_api_key` | string | **旧版**单一 API Key（迁移用） |
| `active_api_credential` | string | **旧版**当前凭证 id（迁移用） |
| `api_key_<credentialId>` | string | 每个凭证的 API Key（`T2.j()` = `"api_key_" + id`） |

### 7.3 API Key 的读取与迁移

```
当前 Key = getString("active_api_credential") 为空 ? getString("deepseek_api_key")
          : getString("api_key_" + activeCredentialId)
```
证据：`I1\T2.java:177-189`。

迁移（`A\C0048y0.java:585-599`）：

```java
String string = prefs.getString("deepseek_api_key", null);
... new ApiCredentialProfile("legacy-deepseek", "原 DeepSeek 凭证", platform, baseUrl,
        primaryModel, writingModel, summaryModel, translationModel, supportModel,
        availableModels, modelCapabilities, /* favoriteModelIds = */ 3072 位掩码默认值)
```

- 旧 Key 会被包成一个名为 **`原 DeepSeek 凭证`**、id 固定 **`legacy-deepseek`** 的凭证。
- 读取时 `legacy-deepseek` 的 Key 优先取 `api_key_legacy-deepseek`，取不到再回落到 `deepseek_api_key`（`T2.java:182-189`）。
- 备份恢复时会把 `api_key_*` + `deepseek_api_key` + `active_api_credential` 整组先删后写（`T2.java:328-352`），
  失败文案：`存档含有未声明的 API 凭证`、`存档的当前凭证无效`、`API 凭证恢复失败`。
- 导出时会检查存档里是否混入本机 Key，文案：`存档内容包含本机 API 密钥，已停止导出`。

---

## 8. 哈希

### 8.1 `contentHash`（项目内容哈希，Base64）

```kotlin
fun contentHash(storageId: String, serializedPayload: String): String {
    val md = MessageDigest.getInstance("SHA-256")
    md.update(storageId.toByteArray(UTF_8))
    md.update(0x00)                          // 分隔符
    md.update(serializedPayload.toByteArray(UTF_8))
    return Base64.getEncoder().encodeToString(md.digest())   // 标准 Base64，44 字符
}
```
证据：`p051o0\c.java:147-162`（参数名就是 `storageId` / `serializedPayload`）。

用途：
- `project_manuscripts.contentHash` = `contentHash(projectId, authoritativeBody)`
- `project_source_documents.contentHash` = `contentHash(projectId, JSON(List<LocalSourceDocument>))`

### 8.2 文本哈希（小写 hex，64 字符）

```kotlin
fun sha256Hex(text: String): String =
    MessageDigest.getInstance("SHA-256").digest(text.toByteArray(UTF_8))
        .joinToString("") { String.format("%02x", it) }     // 小写 hex
```
证据：`L1\E.java`（`MessageDigest("SHA-256")` + `l.N0(digest, "", null, null, new C0258a(19), 30)`），
`I1\C0258a.java` case 9/18/19 = `String.format("%02x", byte)`。

用途：`TranslationRecord.sourceHash` / `chunkHash`（强校验 `[a-f0-9]{64}`，`p051o0\c.java:597+`）、
`BodyAppendUndo.resultSha256`、`CharacterAnalysisCheckpoint.sourceSha256` / `characterBaselineSha256` / `worldMaterialSha256`。

### 8.3 blobId / owner / 文件名

```kotlin
// p000a\a.java:1495+  K(owner, content)
fun blobId(owner: String, content: String): String =
    "$owner:" + sha256Hex(content)          // owner 不能为空、不能含 ';'

// p000a\a.java  J(str) = sha256Hex(str)    —— 用于文件名
// A\C0034r0.java:302-310
fun sealedFile(identity: String) = File(dir, sha256Hex(identity) + ".sealed")
```

`ProjectStorageKey.owner`（`I1\C0321m2`）由 `I1.J.y(projectId)` 推导，`owner` 与 `projectId` 分离；
**具体推导公式未验证**（`I1\J.java:2138` 是超长合并方法，未能可靠还原）。

---

## 9. `.frthink` 存档格式

### 9.1 文件

| 类型 | 文件名 | format 字段 |
|---|---|---|
| 全量备份 | `frthink备份-yyyy-MM-dd-HHmm.frthink` | `frthink-full-backup` |
| 书项目存档 | `frthink书项目-yyyy-MM-dd-HHmm.frthink` | `writing-workspace-backup` |

证据：`M1\C0767r5.java:44`、`M1\Q.java:148`、`I1\O.java:30`。

### 9.2 结构

```
文件 = UTF-8( JSON( FrthinkArchiveEnvelope ) )
     {
       "format": "writing-workspace-backup" | "frthink-full-backup",
       "version": 1,
       "compression": "gzip+base64",
       "createdAt": <epoch millis>,
       "payload": "<base64(gzip(utf8(json)))>"
     }

payload 解压后：
  · 书项目 → ProjectArchivePayload   { formatVersion, createdAt, projects: [ProjectBackupPayload] }
  · 全量   → FullFrthinkBackupPayload{ formatVersion, createdAt, settings, credentialSecrets,
                                       projects, activeProjectId, corpusLibrary }
```

### 9.3 导入校验顺序与限制（`L1\C0569o1.java:78-145`、`I1\L0.java`）

1. 文件大小 `2 ≤ n < 314572801`（300 MiB），否则 `文件为空、损坏或超过 300 MiB`。
2. 整文件按 UTF-8 解 JSON → `FrthinkArchiveEnvelope`，失败 `不是有效的全量 .frthink 文件`。
3. `format ∈ {"writing-workspace-backup","frthink-full-backup"}` 或 endswith `"-full-backup"`；
   `version == 1`；否则 `不支持的 .frthink 文件格式`。
4. `compression == "gzip+base64"`，否则 `备份压缩格式无效`。
5. `Base64 → GZIP` 解压，解压后 ≤ 314572800 字节，否则 `解压后的备份超过 300 MiB`。
6. 解析 payload，失败 `全量备份数据结构无效` / `备份内容损坏或无法解压` / `备份内容损坏`。
7. 业务校验（见 §5.5 文案列表）。

> 其它上限文案：`书项目存档内容超过 300 MiB`、`书项目存档文件超过 300 MiB`、
> `全量备份内容超过 300 MiB`、`全量备份文件超过 300 MiB`、`全量备份数据结构无效`。

---

## 10. 语料库的检索索引

- 语料库持久化：`<filesDir>/universe-corpus-v1.enc`，AtomicFile，AAD `"frthink:universe:corpus:v1"`，
  内容是 `JSON(CorpusLibrary)` 的 sealed 字节（**无 `sealed-editor-v1:` 前缀**）。
- 检索：**内存** FTS4（`SQLiteDatabase.create(null)`），每次由 `entries` 重建：

```sql
PRAGMA temp_store=MEMORY
CREATE VIRTUAL TABLE corpus USING fts4(id, tokens, notindexed=id, tokenize=simple)
INSERT INTO corpus(id,tokens) VALUES(?,?)
SELECT id FROM corpus WHERE tokens MATCH ?
```
证据：`I1\B.java:30-45`、字符串表 2245/3274/10002。

> 移植提示：FTS4 `tokenize=simple` 对中文按空白切词，`tokens` 是把条目文本归一化后以空格拼接
> （`p015d2.n.E0(..., " ", ...)`）。Swift 端可用 SQLite FTS5 或自建倒排，**不必字节级兼容**，
> 因为这是可重建的派生索引。

---

## 11. 实体关系图（文字版）

```
projects (id PK)
├─1:1─ project_snapshots(projectId PK)         payload = sealed(JSON ProjectSnapshot)
├─1:1─ project_manuscripts(projectId PK)       payload = sealed(正文), contentHash
├─1:1─ project_source_documents(projectId PK)  payload = sealed(JSON SharedSourceManifest), contentHash
├─1:1─ project_deletion_tombstones(projectId PK)  markedAt
├─M:N─ source_blobs(id PK)  ◄── source_blob_links(projectId, blobId) [index: source_blob_lookup(blobId)]
└─1:N─ translation_segments(owner, project, target, sourceHash, segment)   [独立 DB]
                                    └── payload = Base64(sealed(JSON TranslationRecord))

projects.id  ──────────────┐
project_snapshots.coreIdentity ─ 同一身份的不同表述（owner/projectId 映射见 §8.3，未验证）

ProjectSnapshot（JSON 内嵌，不是表）
├── messages[]            → ChatMessage
│     ├── segments[]      → AgentTurnUi
│     └── versions[]      → ChatMessageVersion → tokenUsage: TokenUsage
├── world                 → WorldSummary
│     ├── plotEvents[]    → PlotEventCard
│     └── materialSourceProgress{} → MaterialSourceProgress
├── characterCards[]      → CharacterCard
│     ├── memories[]      → CharacterMemory
│     └── customEntries[] → CharacterEntry
├── characterGroups[]     → CharacterGroup
├── worldbooks[]          → WorldbookEntry
├── requestSnapshots[]    → CloudRequestSnapshot → messages[]: PromptMessageSnapshot
├── conversationSummary   → ConversationSummary → previousRevisions[]: ConversationSummaryRevision
├── characterAnalysisCheckpoint → CharacterAnalysisCheckpoint → completedSegments[]: CharacterAnalysisSegmentResult
├── localSourceDocuments[]→ LocalSourceDocument   （content 恒为 ""）
├── bodyLocks[]           → BodyLockSnapshot
├── lastBodyAppendUndo    → BodyAppendUndo
├── task / agentTurns[]   → AgentTaskUi / AgentTurnUi
└── formDrafts{}          → Map<String,String>

CorpusLibrary（递归树，落 universe-corpus-v1.enc）
├── collections[]         → CorpusLibrary
└── entries[]             → CorpusEntry → origins[]: CorpusOrigin

设置（dream_machine_secrets）
├── api_credentials_v2    → List<ApiCredentialProfile>
│     └── modelCapabilities[] → CloudModelCapability
├── global_agents         → List<AgentProfile>
├── global_skills         → List<SkillProfile>
├── global_worldbooks     → List<WorldbookEntry>
├── global_token_usage_records_v1 → List<TokenUsageRecord>
├── global_chat_shortcuts_v1      → List<ChatShortcut>
├── prompt_block_preferences      → List<PromptBlockPreference>
└── api_key_<credentialId>        → String（明文 Key，由 EncryptedSharedPreferences 加密）
```

---

## 12. JSON 负载样例

> 下面按「真实键名 + 合理示例值」给出。标 `TODO` 的是推不出来的。

### 12.1 `ProjectSnapshot`（`project_snapshots.payload` 解密后）

```json
{
  "schemaVersion": 20,
  "coreIdentity": "e2f1c0a4-...",
  "projectRevision": 42,
  "messages": [
    {
      "id": "6f0c2b1e-...",
      "kind": "USER",
      "title": null,
      "content": "继续写下一段",
      "isAccepted": true,
      "tokenUsage": {
        "promptTokens": 3200, "completionTokens": 800, "totalTokens": 4000,
        "estimated": false, "promptCacheHitTokens": 1024,
        "promptCacheMissTokens": 2176, "cacheMetricsRequests": 1
      },
      "segments": [],
      "versions": [
        {
          "id": "v-1", "content": "……", "source": "cloud", "requestId": "req-1",
          "status": "done", "tokenUsage": null, "createdAt": 1762300000000
        }
      ],
      "activeVersionId": "v-1"
    }
  ],
  "deletedChatMessageIds": [],
  "world": {
    "currentState": "主角刚抵达临江城。",
    "plotOutline": "第一幕：入城；第二幕：结识；第三幕：冲突。",
    "plotEvents": [ { "id": "pe-1", "title": "入城", "scene": "城门", "characters": ["沈砚"], "cause": "", "development": "", "consequence": "" } ],
    "imitationTemplate": "",
    "characters": ["沈砚", "柳氏"],
    "relationships": ["沈砚 → 柳氏：母子"],
    "events": [],
    "materialChunkHashes": { "chunk-0": "ab12…64hex" },
    "materialSourceProgress": { "src-1": { "processedUtf16": 12000, "prefixHash": "…", "promptHash": "…" } }
  },
  "projectAssistantPrompt": "",
  "characterCards": [
    {
      "id": "cc-1", "name": "沈砚", "identity": "落魄书生", "personality": "克制",
      "voice": "短句", "goals": "查清父案", "boundaries": "不滥杀", "enabled": true,
      "memories": [ { "id": "m-1", "content": "怕水", "evidence": "第三章", "createdAt": 1762300000000 } ],
      "customEntries": [], "aliases": ["阿砚"], "groupId": "g-1",
      "personalMemory": "", "relationshipAttitudes": ""
    }
  ],
  "characterGroups": [ { "id": "g-1", "name": "主角团", "enabled": true } ],
  "worldbooks": [ { "id": "wb-1", "title": "临江城", "keywords": "临江,城", "content": "……", "enabled": true, "dynamic": false } ],
  "enabledUniverseEntryIds": ["wb-1"],
  "requestSnapshots": [],
  "requestContentPool": [],
  "conversationSummary": { "content": "", "sourceMessageKeys": [], "sourceHash": "", "enabled": false, "updatedAt": 0, "previousRevisions": [], "rulesVersion": 1 },
  "characterAnalysisCheckpoint": {
    "sourceSha256": "…64hex", "sourceCodePointCount": 120000, "totalSegments": 4,
    "completedSegments": [], "mergedDraft": null, "mergedCards": [],
    "characterBaselineSha256": "", "worldMaterialSha256": "", "worldRefreshComplete": false
  },
  "localSourceDocuments": [
    { "id": "doc-1", "name": "原文.txt", "mediaType": "text/plain", "content": "",
      "enabledForPrompt": true, "sendWholeSource": false,
      "promptStartCodePoint": 0, "promptEndCodePoint": 0, "importedAt": 1762300000000 }
  ],
  "authoritativeBody": "……正文……",
  "bodyPromptTailCodePoints": 2000,
  "bodyPromptSendWhole": false,
  "bodyPromptStartCodePoint": 0,
  "bodyPromptEndCodePoint": 0,
  "bodyAppendReceiptIds": [],
  "lastBodyAppendUndo": null,
  "coreBodyDocumentId": "doc-body-1",
  "coreBodyVersion": 42,
  "coreBodyLoadedAll": true,
  "coreBodyContentLength": 184320,
  "coreBodyLoadedStart": 0,
  "coreBodyNextCursor": null,
  "bodyLocks": [],
  "pendingBodyLockIds": [],
  "lockSyncError": "",
  "composerDraft": "",
  "readerOffset": 0,
  "readerBookmarkOffset": -1,
  "continuationAnchorOffset": 0,
  "continuationAnchorPrefixHash": "",
  "formDrafts": {},
  "agentTaskId": "",
  "agentRequestKey": "",
  "agentTaskEventSeq": 0,
  "agentTaskStatus": "",
  "agentTaskSummary": "",
  "agentStreamingText": "",
  "agentStreamingMessageId": "",
  "agentStreamingAppend": false,
  "agentTurns": [],
  "agentTaskEvents": [],
  "task": { "status": "", "summary": "", "canPause": false, "visible": false, "compact": false,
            "phase": "", "currentTool": "", "goalSummary": "", "nextAction": "",
            "evidenceCount": 0, "issueCount": 0, "draftStatus": "" },
  "auditTaskId": "",
  "auditTaskStatus": "",
  "auditTaskSummary": "",
  "auditCompletedBatches": 0,
  "auditTotalBatches": 0,
  "auditChangedPatches": 0,
  "auditError": ""
}
```

> `readerBookmarkOffset` 示例用了 -1，是因为 `TranslationRecord.bodyBookmarkOffset` 的默认值是 -1；
> `ProjectSnapshot.readerBookmarkOffset` 的**默认值未验证**（合成构造器里是 `int` 分支，未取到常量）。

### 12.2 `SharedSourceManifest`（`project_source_documents.payload` 解密后）

```json
{
  "format": "shared-source-v1",
  "documents": [
    {
      "document": {
        "id": "doc-1", "name": "原文.txt", "mediaType": "text/plain", "content": "",
        "enabledForPrompt": true, "sendWholeSource": false,
        "promptStartCodePoint": 0, "promptEndCodePoint": 0, "importedAt": 1762300000000
      },
      "blobId": "default:9f2c…64hex"
    }
  ]
}
```

### 12.3 `TranslationRecord`（`translation_segments.payload` 解密后）

```json
{
  "target": "body",
  "sourceHash": "ab12cd34…（64 位小写 hex，= sha256(原文段)）",
  "index": 0,
  "chunkHash": "ef56…（64 位小写 hex）",
  "text": "译文……",
  "model": "deepseek-chat",
  "sourceDocument": "……原文第一段……",
  "bodyTypeset": false,
  "bodyChineseQuotes": true,
  "bodyEditedText": null,
  "bodyEditedSegments": 0,
  "bodyBookmarkOffset": -1
}
```

### 12.4 `.frthink` 全量备份

```json
{
  "format": "frthink-full-backup",
  "version": 1,
  "compression": "gzip+base64",
  "createdAt": 1762300000000,
  "payload": "H4sIAAAAAAAA/+3BAQACAAAAAAAA…（base64 of gzip of utf8 json）"
}
```

`payload` 解压后：

```json
{
  "formatVersion": 1,
  "createdAt": 1762300000000,
  "settings": { "baseUrl": "https://api.deepseek.com", "primaryModel": "deepseek-chat", "…": "…" },
  "credentialSecrets": { "cred-1": "sk-xxxx" },
  "projects": [
    {
      "formatVersion": 1, "createdAt": 1762300000000,
      "projectId": "proj-1", "title": "临江", "synopsis": "……",
      "snapshot": { "schemaVersion": 20, "…": "见 12.1" },
      "universeEntries": [],
      "coverImageBase64": "",
      "branchRootId": "", "branchOrder": 0, "trashedAt": 0,
      "translations": [ { "target": "body", "…": "见 12.3" } ]
    }
  ],
  "activeProjectId": "proj-1",
  "corpusLibrary": null
}
```

### 12.5 `TranslationRecord` 的 AAD（不是 JSON 负载，但必须逐字节一致）

```json
["default","proj-1","body","ab12cd34…64hex","0"]
```
> 紧凑 JSON 格式（`Json.encodeToString(List<String>)` 默认无空格）。移植时若 AAD 不一致，历史加密数据将无法成功解密。

---

## 13. 未验证 / TODO

| # | 项 | 现状 |
|---|---|---|
| 1 | `ProjectStorageKey.owner` 的推导公式 | `I1\J.y(projectId)` 落在超长合并方法里，未还原。已知 `owner` 与 `projectId` 分离、`owner` 不含 `;` 且非空 |
| 2 | `ProjectSnapshot.readerBookmarkOffset` / `readerOffset` 等 int 字段的默认值 | 只知类型 `Int`，默认常量未取到 |
| 3 | `ReaderFont`（`J1\k1`）除 `黑体` 外的枚举常量 | jadx 枚举还原不完整 |
| 4 | `PromptSourceScope`（`J1\i1`）的常量 | 同上 |
| 5 | `DiagnosticOperation` / `DiagnosticStage` / `DiagnosticResult` / `DiagnosticFailure` 枚举常量 | 同上 |
| 6 | 导出侧的 gzip 压缩级别 | 导入侧确定是 `GZIPInputStream`；导出侧未定位到写文件代码（`GZIPOutputStream` 只出现在 AES 助手 `A\C0034r0` 里），压缩级别 TODO |
| 7 | `editor-drafts-v1` / `editor-outbox-v1` 下 `.sealed` 文件的具体 identity 与内容结构 | 只确认目录名与文件名规则 `hex(sha256(identity)) + ".sealed"` |
| 8 | `ProjectSnapshot` 的 `schemaVersion` 兼容策略（读到 20 以外的值如何处理） | 只找到文案「项目数据版本不受支持」，未见具体分支 |
| 9 | `provider` 枚举（`DEEPSEEK`/`OPENROUTER`/`OPENAI_COMPATIBLE`/`CUSTOM_OPENAI_COMPATIBLE`）在 jadx 源码里未命中 | 可能只存在于 smali 或字符串表；BRIEF 已确认存在，本文件未采信为字段类型 |
| 10 | `projects.coverImagePayload` 明文的完整形态 | 已知：解密后是 **US-ASCII** 字符串（`I1\C0286f2.java:78,95` 用 `f18152d`），且写入前经过 `b3.d.O(...)` 校验；推测为 `data:image/...;base64,` 或裸 Base64，具体前缀未验证 |
| 11 | `StoredSettings` 是否曾被整体写成单个 JSON 落盘 | 目前只看到它作为备份载荷与聚合视图存在，未见单独 key |
| 12 | `source_blobs` 的 `blobId` 里 `owner` 具体取值 | 依赖第 1 项 |

---

## 14. Swift 端实现建议（基于既有事实）

1. **模型层**：严格依据 §5 与 §6 构建 `struct`，字段名保持原始拼写，均采用 `var` 并赋予默认值。
   `Codable` 实现 `init(from:)` 以支持「缺失字段回退默认值」，兼容未包含 `encodeDefaults` 新增键的历史数据。
2. **存储层**：
   - 新写入数据推荐采用**明文 JSON** 或基于 CryptoKit 的 AES-GCM 加密，**切勿**尝试复刻 `sealed-editor-v1` 绑定的
     AndroidKeyStore 密钥（硬件密钥无法导出）。
   - 如需读取历史数据：建议通过「Android 端导出 `.frthink`」再由 iOS 端导入的迁移链路，
     因 `.frthink` 归档中的 `payload` 均为**明文 JSON**（仅包含业务数据，不含加密密钥材料）。
3. **表结构**：`projects` 表的 9 个列定义及 3 个 DEFAULT 约束需严格对齐（尤其 `branchRootId DEFAULT ''`、
   `branchOrder DEFAULT 0`、`trashedAt DEFAULT 0`），以确保数据库迁移与结构兼容。
4. **时间戳**：一律采用 `Long` 类型的毫秒级时间戳（epoch millis），避免直接存储为 `Date` 类型。
5. **集合语义**：`Set<String>` 在 JSON 里是数组（`encodeDefaults` 下空集合也会输出 `[]`）。
6. **枚举**：JSON 里是**枚举的显示名/中文名**（见 §6.5 表），不是大写常量名。
