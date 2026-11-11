# UI-ROUND2 · 第二轮执行记录（历史）

本文记录 2026-11-09 第二轮的改造过程与逐屏要求；现行规则以 [UI.md](../DESIGN.md) 为准，键盘/状态行/字号已按后续反馈调整。本文是历史记录，不再作为任务清单。

该轮目标：在**不改功能、不改模型/存档/提示词**的前提下，把五个 Tab 之下的所有二、三、四级界面
做成同一套 iOS 体验。依据：`UI.md`、`EXPERIENCE.md`、`IOS-AI-UI-RESEARCH.md`、
`AUDIT-SECONDARY-UI.md`。

## 0. 一句话方向

**原生结构 + 克制的细节**：用系统 `Form` / `List` / `NavigationStack` / `Toolbar` 承担行为与滚动，
用 `Core/Design/AppComponents.swift` 补中文区块标题、图标印章、字段框、状态行与危险动作。
不手搓导航、不手搓滚动、不在内容层加玻璃。

情绪目标仍是 **calm / focused / trustworthy**。任何让作者多读一句解释、多找一次入口的装饰都删。

## 1. 页面类型与底板

| 类型 | 例子 | 结构 | 底板 |
|---|---|---|---|
| 二级·索引/设置 | 设置首页、连接与模型、存档、存储、外观、关于、世界书面板、语料库 | `List` / `Form`，`Section` 最多 4 个，一屏一个主操作 | `.groupedPageBackground()`（浅色分组灰 / 深色纯黑） |
| 三级·编辑器 | 供应方、人物卡、事件卡、世界书词条、语料条目、技能、世界建立 | `Form` + 多个 `Section`；长正文用一个整页编辑器 | 同上 |
| 四级·弹层 | 模型选择、删除确认、导入确认、恢复默认、分组编辑 | `sheet`/`confirmationDialog`/`alert`，只放一个决定 | 系统默认；长流程用 `.large` |

**不再用**：`SettingsPageScroll` + 手写分隔线的「网页式」长页；同一页 4 张以上 `CardContainer`；
`ScrollView` 里套 4–6 个 `TextEditor`；页面级 `.frame(width: 320)`。

正文/阅读页继续白/黑打底（`pageBackground()`），不改成分组灰。

## 2. 组件契约（`Core/Design/AppComponents.swift`）

| 组件 | 用途 | 约束 |
|---|---|---|
| `groupedPageBackground()` | 表单页底板 | 只用于二/三级表单页 |
| `IconTile` | 设置行、分类入口图标 | 28pt 控件尺寸；tint 默认系统 accent；不五颜六色 |
| `AppSectionHeader(title:subtitle:)` | Section 头 | subtitle 只写用户需要的一句，不写实现 |
| `AppSettingsRow(title:subtitle:symbol:detail:)` | 导航行 | 放在 `NavigationLink` 里，chevron 交给系统 |
| `AppValueRow(title:value:symbol:tone:)` | 只读数值行 | 数字等宽、右对齐 |
| `StatusPill(text:tone:)` | 当前/停用/未填 Key | 只有 5 种 tone，颜色只用系统语义色 |
| `AppStatusLine(kind:text:)` | 测试连接、保存结果 | 固定最小高度，状态切换不跳 |
| `AppTextField` | 单行字段 | 标题在上、框在下；带 maxLength 与计数 |
| `AppTextArea` | 多行字段 | `TextField(axis:.vertical)`，最多 10 行后框内滚动 |
| `AppSecureField` | API Key | 默认掩码，眼睛按钮切换 |
| `AppTextEditor` | 整页长正文 | 外层不要再包 ScrollView |
| `PrimaryActionButton` | 一屏唯一主操作 | 最多一个/屏 |
| `SecondaryActionButton` | 次要操作 | 不与主操作并排抢权重 |
| `DestructiveActionRow` | 删除/清除 | 独立 Section 的最后一行，前置确认 |
| `InlineEmptyState` | 区块内空态 | 一句说明 + 可选一个动作 |
| `AutosaveBadge` | 自动保存回执 | 只写「已自动保存 / 正在保存…」 |

现有 `CardContainer` / `SettingsSection` 只给尚未迁移的页面用；迁移后不再新增使用。

## 3. 文案规则

**删掉**：P02–P05 编号、块键 `worldbook:<id>`、预算公式、`TODO`、`# 词条名` 的拼接方式、
「渲染成…排在…之前」「只影响新建的供应方」这类实现解释。

**保留**：会影响用户决定的领域规则（例：「语料只作表达参考，不当成已发生的事实」；
「世界刷新只整理人物卡」；「Key 只存本机钥匙串」），但压到一句、放在 footer 或 hint。

**动作词**：主按钮写结果（「保存」「开始改写」「覆盖并导入」），不写「确定」「提交」。
删除确认里写出对象名与后果。

## 4. 统一语义

| 语义 | 规则 |
|---|---|
| 自动保存页 | 只有「完成」，底部/工具栏给 `AutosaveBadge`；删除在最后，二次确认 |
| 显式保存页 | 「取消」丢弃、「保存」提交；保存按钮只做提交，不兼职「设为当前」等动作 |
| 只读/选择页 | 只有「关闭」或「完成」；点行即选、即返回 |
| 危险操作 | 清除 Key、清零用量、恢复默认、删除分组/词条：一律先确认；能撤销的给撤销 |
| 搜索/键盘 | 有输入就有「完成」；列表滚动收键盘 |
| 空态 | 一句说明 + 一个动作；不写「暂无数据」 |

## 5. 逐屏要求

### A. 设置（Lead）
- 首页：4 组 6 行；每行 `IconTile` + 标题 + 一句说明 + 当前值（连接页显示「DeepSeek · flash」）；
  缺 Key 只在首行一条可点提醒；大标题。
- 连接与模型：当前供应方 + 测试连接放首段；供应方列表改成三行一条的导航行（名称 / 地址·模型 / Key 状态），
  当前项 `checkmark`；翻译模型、全局响应、上下文预算改成三个三级页入口。
- 供应方编辑：`Form` 三段（连接 / 生成 / 状态与动作）；Key 清除移到底部危险区；
  「测试连接」结果就地显示，成功/失败用 `AppStatusLine`；保存只保存。
- 提示词与资料：两个导航入口 + 三个开关 + 「世界建立」三级页 + 长期规则三级页。
- 存档与备份：单本与全量分成两个 Section，各只有一个主操作；导入确认说明覆盖范围。
- 存储与用量：只读数值 + 两个刷新动作；清零点确认。
- 外观：主题/字号/预览一块，动画与触感一块；字号与阅读页范围一致（13–28）。
- 关于：版本、署名、移植声明三行，层级拉开；DEBUG 自检收进 DisclosureGroup。

### B. 世界 / 世界书（Builder A）
- 世界面板：5 段控件保留；状态条固定高度；成功不再同时 toast；原始响应入口改成按钮。
- 世界设定：删掉重复的「刷新只整理人物」；资料计数行保留跳转；编辑弹层加「取消」与自动保存说明。
- 人物卡：搜索/排序/加号收进一行；分组菜单接回 `WorldGroupEditor`（现在点了没反应）；
  行信息保留首字、姓名、别称、身份/性格；删除只走确认；空态给「新建人物」。
- 人物/事件编辑器：改用 `Form` + `AppTextField` / `AppTextArea`；删除在最后一节；自动保存回执。
- 事件卡：抽取按钮降为次要（`SecondaryActionButton` 或 toolbar），列表行保留标题/日期/人物/摘要。
- 模板与规则：四段正文改成四个可折叠区块或四个三级页入口；所有解释编号删除。
- 世界书：去掉重复标题与长说明；`+` 与预览进 toolbar/紧凑头部；行整行可点；
  预览页不再显示块键。
- 世界书词条编辑：标题在上、正文整页编辑器、启用开关在 footer 上方；空正文校验说清。

### C. 语料 / 提示词 / 书架 / 宇宙（Builder B）
- 语料库：总开关只留一处；库切换与「管理」合并成一个菜单；「取用」改成 swipe/toolbar 次要按钮；
  搜索/筛选保留；空态给「新增语料」。
- 语料条目编辑：`Form` + `AppTextField/AppTextArea`；分类建议改成自适应换行（不用横向滚动）；
  键盘「完成」。
- 语料库管理：保留当前/启用/重命名/删除；删除确认写清条数；两层 sheet 改为 push 或单层。
- 提示词管理器：删掉 P02–P05 与装配顺序；技能/预设/去 AI 味/项目指令各自成 Section；
  项目书选择器保留；body 里不再 `openSession`（改成 `.task`）。
- 技能编辑：全屏 push 或 `.large` sheet；正文用 `AppTextEditor`；顶部「已保存」；删除放底部（如保留）。
- 提示词块预览：块键降为脚注或移除；预算条保留；正文可选中。
- 书架：只保留一套菜单入口（contextMenu 或 ⋯，不要两套）；「创建分支」与「分支 N」改名区分；
  回收站行主次分开。
- 分支面板：创建分支前确认/命名；行信息保留；说明文字改正文体。
- 宇宙：按类型分组保留；编辑页「保存」后关闭并回执；新建/编辑字段一致（类型可改）；
  滑动删除保留确认。

### D. 写作/阅读/翻译（Builder C）
- 正文页：接回 `ManuscriptRewriteSheet`（现在点了没反应）；工具栏语义统一；
  底栏字号/控件不写死；改写入口只在有选区时出现。
- 改写弹层：结果区空态、停止/替换状态清楚；快捷短语追加而不是覆盖。
- 章节列表、阅读目录：合并重复实现（共用行组件）；去掉写死字号；当前章高亮保留。
- 写作资料：只读分组保留；「去哪里填」改成可点跳转（能跳就跳）。
- 提示词回看：加「来源类型」标签；删掉审计解释。
- 正文发送范围：两端标签改成「只发末尾」/「发全文」；footer 保留一句影响范围。
- 阅读搜索：面板改成不推正文的 overlay 或固定高度；截断时显示「还有 N 条」。
- 阅读显示设置：保留实时预览；「恢复默认」移到底部并确认；与外观页共用字号范围。
- 翻译：加关闭按钮；原文编辑器与页面滚动解耦；「翻译全部」为唯一主操作；
  「更多」菜单去掉或补足；逐段操作降级。
- 创作页「导入正文」：接回 `bodyImportBinding`（现在没有 alert 绑定，导入后不生效）。

## 6. 不许动

- 模型、存档格式、提示词文本、token 估算、请求体、世界刷新/去重/翻译逻辑。
- 五个一级 Tab 的信息架构、主题 token 的语义色、`Theme` 之外的字号/颜色。
- 各页已有动作与字段：可以换位置、换控件、换层级，不能删。
- 不新增第三方依赖；不加 UIKit 视图（正文编辑器已有的 `UIViewRepresentable` 除外）。

## 7. 验证

每个 builder 完成前：

```bash
python script/swift_check.py ios/Frthink
python script/pbxproj_check.py
```

Lead 汇总后：

1. 全量 `swift_check.py` 0 issue。
2. push 分支 → `iOS Build` workflow 绿。
3. `UI Screenshots` workflow 跑二/三级代表页（新增启动参数，见下），人工看：
   底板、卡片、字号层级、按钮主次、删除隔离、空态、深色模式。
4. 真机项（未验证也要写明）：键盘收起、Dynamic Type 最大档、sheet 高度、导入/联网。

### 截图入口（该轮新增，仅 DEBUG）

- `-settingsPage connection|prompts|archive|storage|appearance|about`（已有）
- `-settingsEditor provider|worldbuild|modelResponse|contextBudget`（新增，落到三级页）
- `-worldTab setting|worldbook|characters|events|rules`（新增，世界页初始分栏）
- `-openWorldCard first`（新增，打开第一张人物卡）
- `-readerPanel display|chapters|search`（新增，阅读页打开对应面板）

截图脚本由 Lead 统一改，builder 不要动 `.github/workflows/` 与 `App/`。
