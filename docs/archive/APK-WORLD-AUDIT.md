# APK「世界」功能审计（对比 iOS 移植）

原版 v0.8.210 的证据快照，不代表 iOS 当前实现；差异与状态见 [`../PLAN.md`](../../PLAN.md)。

只读审计。Java 路径相对 `out/jadx/sources/`，smali 标注 `out/apktool/smali/`，纯文本证据标注 `out/dex-stringtable.txt:N`。jadx 未反编译的方法一律标 **未验证**。

## 0. 证据基线与反编译限制

- 入口：`J5.m1` = 底部第 3 个 Tab「世界」（`M1/Q2.java:66-70`）。页面标题不在此方法内，见 `M1/C0738o.java:167-168` 的 `"世界"` / `"这本书的设定与人物"`。
- 反编译缺口（本审计的主要不确定性来源）：
  - `M1/C0707k0.java:160-166`（`h` 方法，3158 units）→ 世界页第 2/5/6 项的内容**未验证**。
  - `M1/Q4.java:62-68`（580 units）→ 人物行卡片细节**未验证**。
  - `L1/K0.java:2394`（世界刷新执行器 `o`）、`L1/O2.java:155+`（素材归纳执行器）、`L1/U2.y`（`U2.java:5029-5034`）均**未反编译**。
- jadx 的输出目录里同一个「分发器类」被合并（如 `f9035e` 默认值 1），**不要**用构造器参数推断 case 分支；本文只在有直接字面量或调用点时下结论。
- `out/dex-stringtable.txt` 与 jadx 同源（`J5.java:177` 与 `M1/J5.smali:893` 的 `"worldbooks:"` 一致）。

## 1. Android 世界页结构（`M1/J5.java:10788` 起，`LazyColumn`）

顺序即 lambda 插入顺序（`J5.java:10945-10986`）：

| # | 区块 | 证据 | 内容 |
|---|---|---|---|
| 1 | 本书写作资料卡 | `J5.java:10945` → `J5.f1`（`:8422-8431`）→ `C0799v5.java:203,231,247,266-268` | 标题「本书写作资料」；仿写模板、剧情梗概（各带展开/编辑回调）、`人物 N`、`世界书 N`、`正文 N 字` |
| 2 | 人物整理进度卡 | `J5.java:10946` → `C0707k0.java:68-118` | 「正在整理资料」+ 进度文案（空则「正在准备分段资料…」）+ `i/total` + 取消（`cancelCharacterAnalysis`，`:112-117`） |
| 3 | 本书写作助手 | `J5.java:10947` → `C0725m2.java:191-199` | 「项目独立 · 使用默认基础指令 / 已添加补充指令」+「编辑」 |
| 4 | 本书原作 + 原文存档 | `J5.java:10950` → `J5.l1`（`:10294-10318`）→ `B5.java:223,314-315,320` | 「本书原作」、导入按钮、`原文存档 N 份` |
| 5 | 刷新中卡片 | `J5.java:10952`（仅 `c4.f4935d1`） | 宿主未反编译，**未验证**是否为「刷新世界资料」卡 |
| 6 | 原文存档列表 | `J5.java:10956-10961` | `c6.G` = `localSourceDocuments`（`J1/C0.java:1055` toString），空态由 `C0707k0(12)`，内容**未验证** |
| 7 | 本项目世界书标题 | `J5.java:10963` → `Y1.java:92-100` | 「本项目世界书」+ `启用数/总数 条启用` |
| 8 | 世界书空态/列表 | `J5.java:10966`（空态文案在 `AbstractC0809x.f10506s1`，**未验证**）、`:10968` | 行渲染 `C0621a2`（世界书行 `W1`） |
| 9 | 人物卡 | `J5.java:10972` → `D5.java:115-159` | 「人物卡」+ `N 张` + 3 个图标按钮；行列表 `:10974-10985` |
| 10 | 人物卡编组 | `J5.java:10982` → `X1.java:419-475` → `J5.p` | 编组增删改、按组启用 |

- **没有事件卡列表**：第 9 项的列表数据是 `c6.f4976s`（`J5.java:10974,10985`），而 `f4976s` 在 `D5.java:117`（人物卡计数）和 `C0799v5.java:266`（`人物 N`）里都是人物卡。spec `01-architecture.md:108-110` 把 `Q4` 标成「事件卡（逐条）」与本证据冲突。
- 世界书编辑器：`J5.o1`（`J5.java:11163-11215`），只有「词条名 / 内容」两个字段；标题为「创建/编辑本项目世界书」，`z3` 为真时是「创建/编辑宇宙共享资料」（`:11211-11213`）。
- 空态「当前项目还没有世界书」+「添加设定后，只保存在这本书中。」（`M1/C0722m.java:366`）。
- 事件/剧情编辑器：`J5.Y`（`J5.java:5812-5943`），「编辑事件」（`:5917`）与「剧情梗概」（`:5930`）二选一。spec 说编辑面板是 `J5.T`（`01-architecture.md:114`）——`J5.T` 实为聊天气泡（`J5.java:5748-5754`，参数 `J1.U`），spec 该行错误。

## 2. 「世界设定」在 Android 上不存在单段文本

- 全库 grep `世界设定|worldSetting|world.setting` **0 命中**；`dex-stringtable.txt` 也没有该短语（只有 `str:17279 世界建立要求`）。iOS 的 `WorldBook.setting`（`ios/.../World.swift:8`）是**移植新增**，没有 Android 对应物。
- Android 三个近似物，语义互不相同：
  1. 「世界建立要求」= 全局设置项 `f5144C`，注入为 P18 块（`L1/K0.java:426-429`）；保存按钮「保存世界建立要求」（`M1/C0777t.java:353`），标题「世界建立与人物去重要求」（`M1/r.java:296`），默认串 `str:17240`。
  2. 「本书写作助手」= 项目级补充指令 `f4973r`，注入为 P02（`L1/U2.java:647-650`，正文前缀「本书写作助手补充指令（仅当前项目）：」），持久化键 `world.project-assistant-prompt`（`M1/T0.java:50`）。
  3. 世界书词条 `E1`（多条，见 §4）。
- 「刷新」不会覆盖上述任何一项：它只读正文（`f4922Z`），
  `L1/U2.java:398-542`：入口 `U2.B(raw=正文, "current-manuscript", z3=false, z4=true)`（`L1/C0576q0.java:35`）。
  - `z4=true` → 追加 P24 增量句（`U2.java:467-469`）+ P26 增量用户句（`:466-468`）；
  - `z3=false` → 使用 **P21 精简契约**（只要 `characters`，`U2.java:472`），任务类型 `人物卡 f7194j`（`:428`）；
  - 清空/覆盖：否。合并 `L1/r.n(existing, incoming, incremental)`（`L1/r.java:558-624`）：同名卡更新、无同名且增量时按别称命中（`:584-607`），命中多个直接抛错（`:580,606`），字段只做句子级追加 `b()`（`r.java:138+`）。
- 真正产出「仿写模板 / 剧情梗概」的是另一条素材归纳流程 `U2.P0(z3)`（`L1/U2.java:5976-6067`）：剧情版 `f7196l` / 仿写版 `f7197m`（`:5985`），从已归纳偏移之后取正文（`:6005-6006`），按 3000 token、**无重叠**切段（`:6008`），最多 256 段（`:6015`），执行器 `L1/O2` 未反编译。
- 「世界建立」入口是 `U2.B(raw=输入文本, z3=false, z4=false)`（`M1/D1.java:60`），契约同样是 P21——**首次建立也不产出 `style_notes/plot_events`**。
- `z3=true`（P20 全量契约 + 任务类型「世界刷新 f7193i」`U2.java:428,472`）在全部反编译调用点中无人传入 → 要么死代码、要么在未反编译分支，**未验证**。

## 3. 刷新流程对照

| 维度 | Android（证据） | iOS（证据） | 判定 |
|---|---|---|---|
| 来源 | 当前正文 `f4922Z`（`U2.java:483` 传参、`C0576q0.java:35`） | `session.payload.manuscript`（`WorldWorkflow.swift:99`） | 对齐 |
| 增量判定 | 调用方固定 `z4=true`；契约层恒「只增不减」（`U2.java:467`） | `hasBaseline && !forceFull`（`WorldWorkflow.swift:106-111`），另有「从头重刷」 | 部分（iOS 多一个全量开关） |
| 切段 | `b3.d.J(min(4000, budget*0.2), 96, text)`（`U2.java:483`）；按 token 估算、换行优先（≥58% 预算才断）、96 token 回退重叠（`b3/d.java:226-301`） | 固定 4000 **字符**、仅换行优先、**无重叠**（`WorldDigest.swift:8,15-39`） | **不一致** |
| 每次上限 | 反编译路径未找到段数上限；进度为「准备 N 段」（`U2.java:539`） | `maxChunksPerRun = 8`（`WorldDigest.swift:11`，`WorldWorkflow.swift:132-136`） | **不一致（Android 未验证）** |
| 断点键 | 源哈希 + 字数 + 段数 + 已完成段 + 已恢复卡（`J1/C0428x.java:26-47`；`U2.java:498-527`） | 源哈希 + 段数 + 已完成段（`World.swift:29-33`；`WorldWorkflow.swift:117-131`） | 基本对齐 |
| 段结果落盘 | 每段 `u6.o0(...)`（`K0.java:655,725`）；失败串「世界刷新进度保存失败，请重试」（`str:17276`，宿主未反编译） | 每段 append 已完成段 + `refreshedUpTo` + `lastRefreshedAt` + `scheduleSave`（`WorldWorkflow.swift:233-244`） | 对齐 |
| 已完成语义 | 全段完成且正文哈希一致 →「当前正文已完成世界刷新」（`U2.java:506-510`） | 无「已完成」标记；`refreshedUpTo` 取**已完成段字数之和**（`:240-242`），非连续前缀，状态行会显示「已整理 X/Y 字」（`WorldSettingSection.swift:237-241`） | **部分（iOS 文案会误导）** |
| 已恢复 | 「已从本机恢复并自动整理 N 张人物卡；未发起新云请求」（`U2.java:521`） | 无对应 UI | 缺 |
| 去重 | 分段完成后、写库前跑全书人物去重（P32→P33→P34：`str:17612/17580/18005`；校验错误 `str:17348-17353`）；执行处仅 smali，**未验证** | 合并后本地去重（`WorldDedupe.swift:32-35`）：只传姓名、`existingNames: []`、无 `existing_id`，可改名/删卡（`:93-137`） | **不一致** |
| 单段契约 | P17 契约 + P18 要求 + P31 基线 + P29 正文 + P30 已有卡（`K0.java:422-447`） | 同结构（`PromptComposer.swift:425-494`） | 对齐（文案逐字一致） |
| 失败处理 | 无人物 JSON→「停止本次整理，没有自动重试」（`K0.java:710`）；缺文风/剧情→「本段未提交」（`:713-714`）；触顶/结束异常校验（`:682,685,693`）；已有段保留 | 抛 `WorldRunError`，保留已完成段，附带原始响应（`WorldWorkflow.swift:178-186`；`WorldPane.swift:283-295`） | 语义近似；Android 是「整轮停」，iOS 是「抛错给 UI」 |
| 写 style/plot | 刷新**不写**；素材归纳单独一条流程 | 刷新内直接追加 `styleNotes`（`:197-207`）与「剧情梗概」事件卡（`:211-229`，上限 6000 字 `:423`） | **分叉** |

## 4. 世界书词条（`J1.E1`）

- 字段：`id / title / keywords / content / enabled / dynamic`（`J1/E1.java:17-23`；`toString` 确认 `:99`）；`enabled` 默认 true（`:43`）。
- `keywords` 与 `dynamic` **是死字段**：仅参与序列化（`J1/C1.java:18-23,38-50`），全库无读取点（grep `f5017c/f5020f` 只命中模型与序列化）；编辑 UI 只有标题+正文（`J5.java:11163-11215`）。
- 注入：`enabled==true` → 块键 `worldbook:<id>`，正文 `# <title>\n<content>`（`L1/U2.java:769-777`）；**不做空正文过滤**（与人物块一致）。
- 顺序 = 列表顺序；世界书块在仿写模板/剧情梗概/语料之后、人物卡之前（`U2.java:716-843`）。
- 行 UI：标题 +「本轮可注入 | 当前不注入」+ 开关 + 编辑 + 删除（`M1/W1.java:386-425`）。删除走 `J5.E`（`:378`）→ 确认对话框 `J5.A`（`:147-166`，只有标题没有正文说明）。
- iOS 对照：
  - 模型 `WorldbookEntry(title/body/enabled/updatedAt)`（`ios/.../Worldbook.swift:8-27`），缺 keywords/dynamic——由于 Android 侧也是死字段，**不构成功能缺口**。
  - iOS 现在也只过滤 `enabled`，空正文仍发 `# 标题` 空块（2026-11-10 对齐）。
  - iOS 额外把 `world.setting` 变成一条伪词条 `worldbook:setting`，固定排在世界书列表最前（`PromptComposer.swift:935-943`）——Android 无此块。
  - iOS 有「预览提示词块」sheet（`WorldbookPane.swift:238-293`），Android 未见等价预览（`C0707k0` 未反编译，**未验证**）。
  - iOS 删除有 alert（`WorldbookPane.swift:55-63`）；Android 有标题确认（`J5.A`），对齐。

## 5. 宇宙共享条目

- Android 注入条件：条目 `enabled==true` **且** 被当前项目 `enabledUniverseEntryIds` 选中
  `L1/U2.java:699-708`（`set = c4.f4984v`，`U2.java:666`；字段名由 `J1/C0.java:1055` 的 `enabledUniverseEntryIds=` 与 `:406` 确认）。
- 注入格式 `# 宇宙共享：<名称>\n<内容>`（`:707`），块键 `universe:<id>`；顺序在全局预设/技能/去重规则之后、仿写模板之前。
- 空集合 = 一条都不发，没有「全局启用就全发」的回退（条件是与集合交集）。
- UI：宇宙 Tab（`J5.c`，`M1/J5.java:7309`）的条目行有「本书启用」开关（`W1.java:211,314`），条目本身另有全局启用状态（来自设置编辑器）。删除宇宙条目会同时清全局与项目引用（`W1.java:179/285`）。
- **iOS 现状**：`settings.enabledUniverseEntries.filter { project.enabledUniverseEntryIDs.contains(id) }`（`PromptComposer.swift:897-905`），双闸门与 Android 结构一致；但
  1. `UniverseEntry` 没有 `enabled` 字段（`Universe.swift:12-36`），全局层只剩 `settings.enabledUniverseEntryIDs`（`Settings.swift:281-283`），默认 `[]`（`:214`）；
  2. 有书稿时 `UniversePane` 的开关只写项目列表（`UniversePane.swift:202-229`），全局列表在该界面上**不可达**；
  3. 因此「改成 per-project-only」之后，P06 实际恒为 0 块——**这是当前最高危的行为回归**（Android 侧项目勾选后立即能注入）。

## 6. 人物 / 事件 / 规则

- 人物模型 `J1.D`：`id/name/identity/personality/voice/goals/boundaries/enabled/aliases/customEntries/groupId/personalMemory/relationshipAttitudes`（`J1/D.java:16-55`），`enabled` 默认 true（`:69`）。
- 注入过滤：`enabled` + 分组标志 `f5058c`（`L1/U2.java:788-796`）；字段标签与逐行空值丢弃见 `:804-840`（「身份：/性格：/说话方式：/目标：/边界：/人物记忆（仅角色已知）：/对其他人物的印象与态度（本角色视角）：」）。
- 合并：只在同名/别称命中时更新，ID 与主名不变，字段追加（`r.java:558-624`）；歧义直接抛错（`:580,606`）。
- 事件/剧情：模型 `J1.V0 PlotEventCard`（id/title/scene/characters/cause/development/consequence；`J1/V0.java:13-25`，序列化名见 `J1/T0.java:17-21`）；手工编辑后**整表替换**（`U2.C0`，`L1/U2.java:5059-5079`，丢弃空标题 `:5073`）。P08 用 `a.F0(list)` 渲染（`U2.java:719`）：`【标题】` + `场景：/人物：/起因：/经过：/结果：`，事件间 `\n\n`（`L1/C0587t0.java:87-111`）。
- 长期规则：P12 日志块（`U2.java:887`，`【长期写作规则日志】…【日志结束…】`）+ 对话摘要增量整理（`X1.java:317,402` → `summarizeNextConversationBatch`）。
- iOS 缺口：
  - `CharacterCard` 无 `enabled`、无 `groupId`（`World.swift:96-152`）→ 无法按卡停用/按组过滤，P11 恒发全部（`PromptComposer.swift:946`）。
  - 刷新写 `plot_events` 时压成一张标题为「剧情梗概」的事件卡（`WorldWorkflow.swift:211-229`），而 `world.plotOutline` 全工程**没有写入方**（只在 `World.swift:80` 解码、`WorldSettingSection.swift:175` 展示、`PromptComposer.swift:912-914` 读）。结果：P08 永远走事件渲染回退，且格式是 `### 标题`（`PromptComposer.swift:824`）≠ Android `【标题】`；「剧情梗概 已建立」状态也基本恒为「未建立」。
  - P08 的选取逻辑 `plotOutline.isEmpty ? renderEvents : plotOutline`（`:912-914`），与 Android「有卡就渲染卡」不同源。
  - 长期规则 iOS 整段覆盖（`WorldWorkflow.swift:401-416`），Android 是「日志 + 摘要」两套（见上）。
  - 去重见 §3 表。

## 7. UI/UX 差异清单

| 项 | Android | iOS |
|---|---|---|
| 页面形态 | 单页 `LazyColumn` 堆叠（`J5.java:10945-10986`） | 五段 Picker：设定/世界书/人物/事件/规则（`WorldPane.swift:7-26,61-68`） |
| 设定编辑 | 无单段设定；词条编辑是 sheet 内两字段（`J5.java:11163-11215`） | 单段大文本 + 全屏编辑 sheet（`WorldSettingSection.swift:248-285`） |
| 刷新入口 | 组件文案「刷新世界资料」/「正在刷新世界资料…」（`C0717l2.java:158-167`）；宿主在未反编译分支，**未验证** | 胶囊「刷新」→ 菜单二选一：增量 / 从头重刷（`WorldSettingSection.swift:58-89`） |
| 进度 | `i/total` 进度条 + 取消（`C0707k0.java:106-117`）；世界刷新进度文案**未验证** | 单行 `ProgressView` + 「正在整理第 i/n 段正文…」（`WorldPane.swift:116-125,187-189`） |
| 取消 | 人物整理可取消；世界刷新卡片可能也有（**未验证**） | **无取消**（`WorldPane.swift:170-178` 只做 `busy` 置位） |
| 错误 | 状态串 + snackbar（`transientNotice`）；原始响应展示未找到（**未验证**） | `store.errorMessage` + 「查看上一次原始响应」sheet（`WorldPane.swift:150-164,283-295`） |
| 删除确认 | 全部有标题确认（`J5.E`/`J5.A`：`J5.java:378,147`） | 编辑器内有确认（`WorldCharacterEditor.swift:29-40`、`WorldEventEditor.swift:29-40`）；**列表左滑删除无确认**（`WorldCharactersSection.swift:133`、`WorldEventsSection.swift:138`） |
| 计数文案 | 「人物卡 N 张」「本项目世界书 N/M 条启用」（`D5.java:115-117`、`Y1.java:92-100`） | 「共 N 张人物卡」「N / M 已启用」（`WorldCharactersSection.swift:49`、`WorldbookPane.swift:76`） |
| 条目状态 | 世界书行显示「本轮可注入/当前不注入」（`W1.java:386-397`） | 只有开关，无注入可达性提示 |
| 空态 | 「当前项目还没有世界书」+ 说明（`C0722m.java:366`）；「暂无人物卡」（`:386`） | 同文案（`WorldbookPane.swift:31-32`）；人物/事件空态文案不同（`WorldCharactersSection.swift:183-187`、`WorldEventsSection.swift:191-195`） |
| 死链 | — | 「剧情梗概 已建立」行跳 `.rules`（`WorldSettingSection.swift:173-189`），但规则页没有剧情梗概编辑器（`WorldRulesSection.swift:14-33` 三个卡片） |

## 8. 对齐表与修复顺序（核心正确性优先）

| Android 行为 | 证据 | iOS | 状态 |
|---|---|---|---|
| 刷新只抽人物，不写模板/梗概 | `U2.java:467-472` | 刷新内写 `styleNotes`+`plot_events` | **分叉** |
| 素材归纳（3000 token、偏移续跑、256 段） | `U2.java:5976-6067` | 无（只有刷新内的 6000/8000 token 尾巴抽取） | **缺** |
| 分段按预算 20% token + 96 重叠 | `U2.java:483`、`b3/d.java:226-301` | 4000 字符、无重叠 | **不一致** |
| 每次运行段数 | 未找到上限（未验证） | 8 段 | 待定 |
| 人物去重（模型、existing_id、不可删改） | `str:17612/17580`；`r.java:558-624` | 本地按名分组、可删改 | **不一致** |
| 人物 `enabled` + 分组过滤 | `U2.java:788-796` | 无字段、全发 | **缺** |
| 世界书空正文仍发块 | `U2.java:769-777` | 过滤空正文 | 部分 |
| 宇宙双闸门（条目启用 + 项目勾选） | `U2.java:699-708` | 双闸门，但全局闸门在有书时不可达 | **回归** |
| 剧情梗概是结构化事件卡（`【标题】`） | `V0.java:13-25`、`C0587t0.java:87-111` | `plotOutline` 永不写入；回退 `### 标题` | **缺/失真** |
| 项目写作助手补充指令 | `U2.java:647-650` | 同块同文案（`PromptComposer.swift:148-157`） | 对齐 |
| P18 世界建立要求 | `K0.java:426-429` | 同块、可设置（`PromptComposer.swift:437-447`） | 对齐 |
| 删除确认 | `J5.A` | 列表删除缺确认 | 部分 |

**历史修复顺序（1–6 已完成，状态以 §10 为准；仅保留作追溯）**

1. **P0 宇宙注入**：让「本书启用」能真正生效——`UniversePane` 在有书稿时同时维护全局可达状态，或在 `PromptComposer.swift:900-902` 去掉对 `enabledUniverseEntries` 的二次全局过滤（二选一，需产品确认；当前双默认值必然 0 块）。
2. **P0 剧情梗概真相源**：给 `world.plotOutline` 一个写入方（素材归纳流程），或删除该字段并让 `WorldSettingSection.swift:173-179` 的状态与 P08（`PromptComposer.swift:912-914`）统一到事件卡；同时把事件渲染标题改回 `【标题】` 以对齐 `C0587t0.java:91`。
3. **P1 刷新职责拆分**：从 `WorldWorkflow.refreshWorld` 移除 `styleNotes`/`plot_events` 写入（`:197-229`），改为 Android 同构的独立素材归纳入口；保留刷新只产出人物。
4. **P1 分段参数**：把 `WorldDigest.chunkSize` 的 4000 字符换成「min(4000, 输入预算×0.2) token + 96 token 重叠」，并明确 `maxChunksPerRun` 是否保留（Android 未验证，需真机确认）。
5. **P1 人物注入**：给 `CharacterCard` 补 `enabled` 与 `groupId`，`PromptComposer.from` 按 `enabled` 过滤（对齐 `U2.java:788-796`）。
6. **P2 去重语义**：`WorldDedupe` 增加 `existing_id` 与「候选必须全覆盖」校验，禁止改名/删卡；失败保持原卡（对齐 `str:17348-17353`）。
7. **P2 UI**：列表左滑删除加确认；`WorldSettingSection` 的「剧情梗概」跳转指向真实编辑器；iOS 状态行 `refreshedUpTo` 改为「已完成段数/总段数」或连续前缀，避免「已整理 X/Y 字」误导。

## 9. 未验证清单（需要 smali/真机补证）

1. 世界页第 5 项（`J5.java:10952`）与 `C0707k0` case 11/12 的文案与按钮，以及「刷新世界资料」的宿主。
2. 刷新每次运行的段数上限、取消路径、进度文案（`L1/K0` 主循环未反编译）。
3. `P31` 只读基线的实际构成（是否含世界书/剧情梗概）；`U2.B` 传给 `K0` 的两块动态 key/正文。
4. 素材归纳 `L1/O2` 的落库目标（写 `plotOutline` 文本还是 `V0` 列表）。
5. 人物去重的触发点与失败回退粒度（仅 smali 证据）。
6. spec `01-architecture.md:108-114` 对 `Q4`/`J5.T` 的归因错误，需回改 spec。

## 8. 2026-11-10 复核记录

- 刷新契约改为 P21 精简版，只写人物卡；不再把 `style_notes`/`plot_events` 当刷新结果入库。依据 `L1/U2.java:472` 的 `z3=false` 与执行器 `L1/K0.java:710-714`。
- 文风笔记改为 P40 分段提炼 + P41 合并（`PromptComposer.segmentStyleNotesMessages` / `styleNotesMergeMessages`），段长 3000 token、无重叠，对齐 `L1/U2.java:6008`。
- 事件卡改为 3000 token、无重叠分段，段间以已有事件作增量基线，对齐 P48/P49 的增量契约。
- 已补：素材归纳用 `materialSourceProgress` 的 `plot-events` / `imitation` 键从上次偏移继续，最多 256 段（`U2.java:6005,6015`）；`plotOutline` 为空时用事件卡渲染。
- 2026-11-10：P08 改为事件卡优先（对齐 `L1/U2.java:719`）；人物 `enabled`/`groupId` 已存在并按组过滤。


## 10. 2026-11-10 当前实现复核（覆盖上文过期判定）

上文保留为反编译证据与历史差异；以下状态以当前代码为准：

| 条目 | 当前 iOS | 结论 |
|---|---|---|
| 刷新职责 | `refreshWorld` 固定 P21，只写人物卡；文风/剧情走独立素材归纳 | 对齐 |
| 刷新切段 | `WorldDigest.chunks` 按 token 权重、4000 上限、96 token 重叠 | 对齐（`maxChunksPerRun=8` 保留，Android 上限未验证） |
| 素材归纳 | `plot-events` / `imitation` 从 `materialSourceProgress.processedUtf16` 续跑，3000 token、无重叠、最多 256 段 | 对齐 |
| 文风模板 | P40 分段 → P41 合并 → P42/P43 首建或 P44/P45 增量追加 | 对齐 |
| 人物去重 | P32 模型分组，支持 `existing_id`、候选全覆盖校验，不改已有卡主名/不删卡 | 对齐 |
| 人物注入 | `CharacterCard.enabled` + `groupId`，按组状态过滤后进 P11 | 对齐 |
| 世界书空正文 | 只过滤 `enabled`，空正文仍发 `# 标题` 块 | 对齐 |
| 剧情梗概 P08 | 有事件卡时用 `【标题】` 渲染，没有才用 `plotOutline` | 对齐 |
| 宇宙双闸门 | 项目勾选写 `payload.enabledUniverseEntryIDs`，`PromptAssembly.from` 用它过滤 | 对齐 |
| 长期规则 | P12 日志 + P54/P55 增量整理，写 `sourceMessageKeys`/历史版本 | 对齐 |
| 刷新完成状态 | `analysisWorldRefreshComplete` 已落盘，但 UI 文案仍可能按 `refreshedUpTo` 显示 | 待核 |
| 列表删除确认 | 人物/事件列表左滑删除均弹确认框 | 对齐 |
| 素材落库 | 事件卡逐段合并/推进偏移/落盘；文风笔记逐段保存原文，模板批次末合成 | 基本对齐 |
| 素材执行器输出 | `L1/O2` 主方法未反编译，无法逐字比对模板合成 | 未验证 |

仍待处理的是 `maxChunksPerRun` 与 O2 落库细节（未反编译）和真机手测；不再按上文“缺/分叉”条目重复返工。
