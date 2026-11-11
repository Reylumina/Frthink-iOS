# APK v0.8.213 差异审计（基线 v0.8.210）

本文记录 `Frthink-v0.8.213-debug.apk` 相对 v0.8.210 的可验证差异，供 iOS 对齐使用。基线证据仍在 `out/`，本文引用 `out-0.8.213/`。两套反编译产物都不进仓库（`.gitignore` 的 `out/`、`out-*/`）。

## 0. 基线与方法

| 项 | v0.8.210 | v0.8.213 |
|---|---|---|
| versionName / versionCode | 0.8.210 / 209 | **0.8.213 / 212** |
| dex 体积 | 4.48 MB | 4.73 MB（单 dex） |
| 类数量（smali） | 4881 | 4903（新增 27，删除 5） |
| 版本字面量 | `Frthink v0.8.210` | `Frthink v0.8.213`（`M1/J5.java:4858`） |

方法：`apktool 2.11.1 d` 全量 smali，`jadx 1.5.6 --show-bad-code` 正文，DEX 字符串表逐条 diff（`script/dex_strings.py`）。新增字符串 98 条、删除 42 条；其中中文新增 12 条、删除 1 条。R8 映射随新增类整体漂移，2102 个 smali 文件字节不同，但世界/写作核心类名稳定（`L1/W2`、`L1/K0`、`L1/Q2`、`L1/U2`、`M1/J5`、`M1/W1`）。

**结论先行**：0.8.213 是「世界素材归纳」维护版，没有改存档格式、导入导出、提示词库 P01–P64、五栏结构、宇宙页与自动摘要。主要变化是超大正文（≥ 50 万码点）改为按模型上下文单次分析，并把「已分析多少、下次是否继续」说清楚；另有三处 JSON 校验文案。

## 1. 新增中文文案（全量 12 条）

| 文案 | 位置 | 用途 |
|---|---|---|
| `整篇正文一次性分析：仅依据全文明确证据…不输出思考过程。` | `L1/W2.java:4933` | 大书模式的人物/素材提示词前缀 |
| `世界建立范围内没有正文` | `L1/W2.java:4890`、`:6025` | 发送范围裁出空文本 |
| `当前模型可用上下文不足，请调整输入或输出预算` | `L1/W2.java:4959`、`:6063` | 上下文连一段都放不下 |
| `只输出合法 JSON 对象。格式：{"characters":…,"style_notes":"全书可复用叙事视角与文风","plot_events":"…"}` | `L1/W2.java:4940` | 大书 + 全量契约的返回格式 |
| `已分析正文前 N 字，其余未分析` | `L1/K0.smali`（`已分析正文前 ` 字面量 + 拼接） | 人物刷新大书模式收尾 |
| `已保存部分正文，再次点击可继续` | `L1/Q2.smali:4379` | 素材归纳大书模式收尾 |
| `这是完整正文，请统观全书并仔细核对同一事件、角色称呼与重复规则，只输出结论，不输出思考过程。` | `L1/Q2.smali:1404` | 素材归纳大书模式正文前缀 |
| `事件卡结果必须包含唯一事件数组` | `s2/a.java:2258`（`out-0.8.213/jadx/sources/p068s2/a.java`） | 模型同时给了 `events` 和 `plot_events` 时直接报错 |
| `人物别称格式无效` | `L1/r.java` | 别称不是字符串数组 |
| `仿写模板保存失败，未推进归纳进度；当前内容仍在内存中` | `L1/K0.smali` | 模板落盘失败时不推进偏移 |
| `正文范围` / `正文范围需在 1–1000000 字之间` / `正文发送范围已保存` | `M1/W1.java:136`、`M1/C0773q5.java` | 写作台发送范围标签、校验与保存回执 |

删除的一条是 `仿写模板保存失败，当前内容仍在内存中`，被上面的新文案取代。

## 2. 世界刷新（人物卡）

入口 `L1/W2.public final void B(String raw, String sourceDocumentId, boolean z3, boolean z4, boolean z5, String targetCharacter)`（`L1/W2.java:4864`）：

- `z3`：全量契约。真时提示词要求同时返回 `characters`、`style_notes`、`plot_events`，任务类型 `f7386i`。
- `z5`：只增不减的增量刷新，追加「本次是只增不减的增量刷新…旧内容不得删除/改写」。
- `targetCharacter` 非空时只允许输出该角色，任务类型 `f7388k`；否则人物刷新 `f7387j`。
- UI 的编译产物里只有三处调用（`L1/C0592r0.java:27`、`M1/S0.java:60`、`M1/C1.java:61`），`z3` 全为 `false`。**0.8.213 的「刷新世界资料」仍然只写人物卡，不写文风/剧情**；全量契约分支在这版里依旧没有 UI 入口。
- 普通分段：`b3.d.K(min(4000, contextBudget × 0.2), 96, text)`，按 token 估算、换行优先、96 token 重叠（`out-0.8.213/jadx/sources/b3/d.java:195`）。未发现每轮段数上限。
- 大书模式：`sourceDocumentId == "current-manuscript"` 且正文码点数 ≥ 500000 时，`b3.d.J(text, budget)` 只取「当前上下文放得下的前缀」做**一次**请求（`b3/d.java:169` 返回单段）。收尾文案 `已分析正文前 N 字，其余未分析`（`L1/K0.smali`）。断点仍按已处理前缀落盘，再点一次从上次位置继续。
- 单人物刷新：`W2.C(..., targetCharacter: name)` 会在契约末尾追加「只允许输出目标角色…」。
- 合并：同名/别称命中后追加字段；别称为空或类型不对时抛 `人物别称格式无效`（`L1/r.java`）。去重仍是全部段完成后一次。

## 3. 素材归纳（剧情事件 / 仿写模板）

入口 `L1/W2.Q0(boolean plotMode)`（`L1/W2.java:5987`）：

| 维度 | 剧情（`plotMode=true`） | 仿写模板（`plotMode=false`） |
|---|---|---|
| 进度键 | `plot-events` | `imitation` |
| 已有基线 | 事件卡渲染文本 `F0(plotEvents)` | `imitationTemplate` |
| 起始偏移 | `materialSourceProgress[key]`，前缀哈希不符归零 | 同左 |
| 分段 | 3000 token、无重叠、最多 256 段 | 同左 |
| 大书（≥50 万码点） | 单次取上下文前缀；收尾「已保存部分正文，再次点击可继续」 | 同左 |
| 写入 | 事件卡合并进 `plotEvents`（`L1/B1.java` 字段 `plot_events`），**不写 `plotOutline`** | 生成/追加仿写模板；失败时保留内存中的笔记，不推进偏移 |

- 提示词由 `task:material-contract` / `task:material-baseline` / `task:material-body` 三块组成（`L1/Q2.smali:1306/1446/1508`），正文前缀在大书模式追加「这是完整正文…」。
- 返回解析：剧情只接受「事件数组」或「`events` / `plot_events` 恰好一个」；两个都出现时报 `事件卡结果必须包含唯一事件数组`（`s2/a.java:2248-2259`）。每个事件卡的 `characters` 可以是数组或分隔字符串，其它形态报 `事件卡人物格式无效`。
- 进度落盘：每段结束写 `materialChunkHashes` 与 `materialSourceProgress`；中途失败保留已完成段，重跑从断点继续。
- `plotOutline` 在 0.8.213 里仍**没有任何写入方**（全库只有序列化描述符、默认空串与 prompt 读取）。UI 上「剧情梗概」编辑器的保存回调写的是 `plotEvents`（`M1/J5.java:6053-6057` → `M1/S0` case 0 → `W2.D0`），不是 `plotOutline`。iOS 当前在刷新时把事件渲染成一张「剧情梗概」事件卡并回写 `plotOutline`，这是分叉，需要移除。

## 4. 校验与写作台

- 发送范围：`正文范围` 标签、允许 1–1,000,000 字，越界提示「正文范围需在 1–1000000 字之间」；保存回执「正文发送范围已保存」（`M1/C0773q5.java`、`M1/W1.java:136`）。
- 人物别称、事件卡的 JSON 校验见 §2/§3。
- 没有发现写作、阅读、翻译、设置页的其它文案或协议变化。

## 5. 没变的部分（本次核实）

- `.frthink` 存档：格式、字段、导入导出入口与 0.8.210 一致；字符串表无新增归档文案。iOS 的导入无响应不是 APK 协议问题。
- 宇宙页：条目、全局启用、本书启用、注入条件未变（`L1/U2.java` 注入段落字符串无差异）。
- 自动摘要 / 长期规则：P54、阈值触发、`sourceMessageKeys` 元数据未变；无新增文案。
- 提示词库 P01–P64：逐字未变（`script/prompt_check.py` 仍 61/61 命中；新增的只是上面列出的内联片段）。
- 写作请求 14 块顺序、7 个请求键、thinking / stream_options 互斥规则未变。

## 6. iOS 对齐清单

| 优先级 | 差异 | 动作 |
|---|---|---|
| P0 | 刷新世界资料时 iOS 还追加 `styleNotes` 和「剧情梗概」事件卡 | 刷新只写人物卡；剧情/文风走独立归纳入口 |
| P1 | 大书模式（≥50 万码点）iOS 仍按 4000 字符分段、人物每轮最多 8 段 | 对齐单次上下文前缀 + 截断提示 + 断点续跑 |
| P1 | 事件卡解析没有「唯一事件数组」校验 | 补校验与错误文案 |
| P1 | 人物别称非法时 iOS 静默丢弃 | 补 `人物别称格式无效` 报错 |
| P2 | iOS 把事件渲染回写 `plotOutline` | 移除；APK 里 `plotOutline` 无写入方，刷新只合并事件卡 |
| P2 | 发送范围上限/文案需核对 | 上限 1,000,000，标签「正文范围」，保存回执 |
| P2 | 文风模板保存失败时 iOS 仍推进偏移 | 失败不推进，保留内存笔记 |

## 7. 未验证 / 限制

- `L1/Q2.o`（素材归纳状态机，5292 指令）jadx 放弃反编译，本文关于它的分支是按 smali 读的；模板合成与「内存中笔记」的具体落盘时机未逐行验证。
- `L1/W2` 是 jadx 合并后的巨型类（9079 行），部分方法内联了其它类；行号只用于定位，不保证跨版本稳定。
- 大书模式的 500000 阈值是码点（`codePointCount`），不是 UTF-16 长度；iOS 的 `String.count` 与 `NSString.length` 在表情/罕见字上会不同，移植时按 Unicode 标量比较。
- 真机联网未验证；以上均为静态反编译结论。

## 8. 复现

```powershell
java -jar tools\apktool_2.11.1.jar d -f -o out-0.8.213\apktool Frthink-v0.8.213-debug.apk
java -cp tools\jadx\lib\jadx-1.5.6-all.jar jadx.cli.JadxCLI -d out-0.8.213\jadx --show-bad-code Frthink-v0.8.213-debug.apk
python script\dex_strings.py out\classes.dex out\dex-stringtable.txt
```

差异字符串见 `out-0.8.213/strings-added.txt` / `strings-removed.txt`。
