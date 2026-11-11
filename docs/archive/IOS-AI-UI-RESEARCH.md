# Frthink iOS · 二/三/四级界面设计参考

调研日期 2026-11-09。外部参考，不作为本项目现行规则；界面规则以 [`UI.md`](../DESIGN.md) 为准。
范围：设置分类、连接与模型、供应方编辑、世界书/人物/事件编辑器、语料库、技能编辑器、阅读显示设置、模型选择、导入确认、提示词块预览、分支面板。

**读法**：每条 = 名称 / 适用页面 / 做法 / 反例 / 来源。「做法」是按参考改写的处方，不是对参考应用源码的描述。标「未验证」= 没找到一手来源。

---

## 1. 模式库

### P1 两级模型选择：先选"要什么"，再选"哪个型号"
- **适用页面**：模型选择、连接与模型
- **做法**：第一屏 3 档（快速 / 深度思考 / 最强），行尾 `chevron`；第二屏「更多模型」列完整型号 ID + 上下文长度。选中态用 `Label` + `checkmark`，不用整行填充色。档位行下面加一行 `.caption` 说清换取什么（「更慢，更少跑题」）。
- **反例**：20 个型号平铺让用户背型号名；只写 `deepseek-chat` 不写它换来什么。
- **来源**：[OpenAI Help · 模型选择器更新](https://help.openai.com/en/articles/10128477-chatgpt-enterprise-edu-release-notes)（Instant/Thinking/Pro 三档，进阶项收进 Configure）；[TechRadar](https://www.techradar.com/ai-platforms-assistants/chatgpt/chatgpt-might-not-be-using-the-model-you-think-and-its-also-hiding-others-in-settings)。Configure 内具体项（自动切换、legacy 模型）见 [devicebase 转述](https://devicebase.net/en/openai-chatgpt/updates/updates-to-the-model-picker-in-chatgpt/8za)（二手）。

### P2 模型选择器贴在输入区，不埋在设置深处
- **适用页面**：模型选择、写作台
- **做法**：写作台输入条上方放一个胶囊按钮，显示「DeepSeek · chat」，点开 `sheet(.medium)`；设置里只留"默认模型"。Claude 把「已选模型 + 努力度」直接放在发送键旁边。
- **反例**：改一次模型要点 设置 → 连接与模型 → 模型列表 三层，写作时没人会去改。
- **来源**：[Claude Help · 改模型/努力度/thinking](https://support.claude.com/en/articles/8664678-change-the-model-effort-and-thinking-settings)（"The selected model and effort level appear next to the send button"）；[OpenAI Help](https://help.openai.com/en/articles/10128477-chatgpt-enterprise-edu-release-notes)（"On iOS and Android, the picker appears at the top of the conversation"）。

### P3 模型之外再加一条"努力度/深度"轴
- **适用页面**：模型选择、连接与模型
- **做法**：同一模型给 2~3 档 effort，用 `.segmented` 或三行单选；档位旁用小字标注后果（耗时、token 消耗）。Claude 把 Effort 作为模型菜单的第二层，并在模型名旁常显当前档。
- **反例**：为"深度"再造一个模型条目，列表越滚越长；把 effort 做成隐藏开关，用户不知道当前跑在哪档。
- **来源**：[Claude Help](https://support.claude.com/en/articles/8664678-change-the-model-effort-and-thinking-settings)；[Anthropic · Opus 4.8 公告](https://www.anthropic.com/news/claude-opus-4-8)（"A new control alongside the model selector lets users choose how much effort…"）。注：基础请求体仍是 7 键；iOS 的思考档位开启时按 provider 追加 `thinking` / `reasoning` / `reasoning_effort`，关闭时不发。

### P4 供应方 = 一条可命名的记录，可切换、可见用量
- **适用页面**：连接与模型、供应方编辑
- **做法**：供应方列表每行 = 自定义名字 + 基址 host + 状态点；当前项 `checkmark`；列表末尾「添加供应方」用纯文字行。会话内可一键切模型，Token 数与预估费用常显。
- **反例**：全局只有一个 API Key 输入框；切换供应方要重填 Key。
- **来源**：[Pal Chat App Store](https://apps.apple.com/us/app/pal-chat-ai-chat-client/id6447545085)（"Easily switch between models"、"See the token length and cost of the conversation"、支持 custom endpoints）。

### P5 最小表单：一个 URL 就能跑
- **适用页面**：供应方编辑
- **做法**：新建供应方默认展开最小三项：名称、基址、Key；其余（温度、系统提示、超时）折进「高级」。保存后立刻发一次 `GET /models`，成功就在行尾显示模型数。Enchanted 的文档只有一句"In App Settings specify your server endpoint"。
- **反例**：一上来 12 个字段全展开，用户不知道哪些必填；保存后没有任何反馈，直到第一次生成才报错。
- **来源**：[Enchanted README](https://github.com/AugustDev/enchanted)；[Pal Chat](https://apps.apple.com/us/app/pal-chat-ai-chat-client/id6447545085)（用户评论称其"walks you through how to add each AI model's API keys"，属用户证言）。

### P6 保存前先测连接，错误要带服务端原文
- **适用页面**：供应方编辑、连接与模型
- **做法**：编辑器底部一条「测试连接」，测试中 `ProgressView` + 禁用保存；结果就地展开三行：HTTP 状态、耗时、服务端返回的前 200 字（等宽字体）。失败不解散表单。TypingMind 用的是 "Test & Save" 合并动作。
- **反例**：只报「连接失败」；失败后清空已填内容；把测试做成弹窗，用户看不到原文。
- **来源**：[TypingMind 配置指南](https://www.typingmind.com/guide/use-perplexity-api-key-to-chat-with-ai)（"Test & Save"）；错误需带原文的本地依据见 `docs/DESIGN.md` §4.6。

### P7 分组表单 + 页脚解释 + 没有保存按钮
- **适用页面**：所有编辑器、供应方编辑、语料库
- **做法**：`Form` + 多 `Section`；区块标题 `.headline`，区块 `footer` 写一句为什么（「只在本机保存」）；自动保存，用 `.caption` 显示「已保存 · 12:40」，不写「保存」按钮。字段标签放输入框上方（三级页），`TextField` 尾部给清除按钮。
- **反例**：每页一个右上角「保存」；把解释写在字段名里（「API Key（用于鉴权，不会上传）」）。
- **来源**：[HIG · Settings](https://developer.apple.com/design/human-interface-guidelines/settings)（设置区只放不常改的项）；[HIG · Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)（grouped 样式用 header/footer + 留白分组）；[HIG · Text fields](https://developer.apple.com/design/human-interface-guidelines/text-fields)（iOS 尾部 Clear 按钮）。

### P8 世界资料编辑器把"AI 可见性"当一等字段
- **适用页面**：世界书/人物/事件编辑器、语料库
- **做法**：每个条目除名字、别名、正文外，必带三态「AI 上下文」：总是发送 / 被提及时发送 / 从不发送；再加「追踪提及」开关（关掉就不高亮、不计数）。提及数做成一行元信息「正文 12 处 · 章节 4 章」。Novelcrafter 的 Codex 正是这套：Aliases、Track this entry、Case-sensitive、Exclusion list、AI Context。
- **反例**：所有条目默认全量塞进提示词，token 爆掉；用户无法表达"这条只是备查"。
- **来源**：[Novelcrafter · Anatomy of a Codex Entry](https://www.novelcrafter.com/help/docs/codex/anatomy-codex-entry)；[Codex Tracking](https://www.novelcrafter.com/help/docs/codex/codex-tracking)。

### P9 生成物必须有版本与"从此处继续"，禁止静默覆盖
- **适用页面**：技能编辑器、分支面板、提示词块预览
- **做法**：每次生成落一个不可变快照，面板列出「v3 · 14:02 · 320 字」，行内动作「查看 / 从此处继续 / 删除」。用新结果替换正文前弹一次确认。Lex 的做法是「新建版本时，之前的内容连同批注一起保留」；ChatGPT canvas 靠左上返回键回退版本。
- **反例**：AI 直接改写当前文本，用户只能靠撤销；版本列表无限增长没有清理入口。
- **来源**：[OpenAI · Introducing canvas](https://openai.com/index/introducing-canvas)（"You can also restore previous versions of your work by using the back button in canvas"）；[Lex 演示（创始人）](https://www.youtube.com/watch?v=G_wV03K7pfQ)（约 1:13 处讲版本保留批注）。用户对静默覆盖的投诉见 [OpenAI 社区](https://community.openai.com/t/canvas-overwrites-work-without-warning-major-issue-for-creators/1231713)（用户证言，非官方）。

### P10 长文编辑用独立页面，不用 sheet
- **适用页面**：技能编辑器、世界书编辑器、语料库条目
- **做法**：正文编辑走 `NavigationStack` push 的全屏页，`TextEditor` 铺满 + 键盘上方一条工具条（字数、完成）；sheet 只留给"一个决定"（命名、删除、选择）。HIG 明确：多步或长时间的流程不要用 sheet，改用全屏 modal。
- **反例**：把 3000 字正文塞进 `.sheet`，键盘弹出后只剩 3 行可视区。
- **来源**：[HIG · Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)（"For complex or prolonged user flows, consider alternatives to sheets"）。

### P11 阅读显示设置 = 浮层 + 即时预览 + 一键还原
- **适用页面**：阅读显示设置
- **做法**：正文上方浮出小面板（不是整页设置），调字号/行距/字体/主题，改完正文立刻变；底部「还原默认」。Apple Books 的做法是 A- / A+ 两个按钮 + 主题 tile + Customize 里的 Reset Text Size / Reset Theme。
- **反例**：跳出去到设置页调字号，回来找不到刚才读到的位置；没有重置，用户调坏了只能一个个改回。
- **来源**：[Apple Support · Change a book's appearance](https://support.apple.com/guide/books/change-a-books-appearance-ibks8923126d/mac)（A 按钮、主题、Reset Text Size / Reset Theme、Light/Dark/Automatic）。iOS 端名为 aA 菜单，与本文同一组控件，**未验证**于一手文档。

### P12 破坏性操作分级：确认弹窗只放一个决定
- **适用页面**：导入确认、分支面板、所有删除入口
- **做法**：单个破坏性动作 → `alert`（标题说后果，按钮「删除」`.destructive` / 「取消」）；多选项 → `confirmationDialog`；滑动删除不弹窗，但给 Undo。HIG：iOS 上"提供选择"用 action sheet 而不是 alert；警示三角符号只用在真正会丢数据时。
- **反例**：删除也弹「确定吗？」三连；导入直接把整库覆盖掉——Bear 的「恢复备份」正是这种写法，文档自己写着"all notes currently in Bear… will be permanently deleted"。
- **来源**：[HIG · Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts)；[HIG · Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)（难以恢复的操作要求确认两次）；[Bear · Backup and Restore](https://bear.app/faq/backup-restore)。

---

## 2. iOS AI 应用设计共识

- **模型选择器靠近输入区，设置里只放默认值。** ChatGPT 在会话顶部，Claude 在发送键旁，两家都不把它埋进设置。([OpenAI](https://help.openai.com/en/articles/10128477-chatgpt-enterprise-edu-release-notes)、[Claude](https://support.claude.com/en/articles/8664678-change-the-model-effort-and-thinking-settings))
- **型号之上必须有"档位"这一层，且档位要写人话。** Instant/Thinking/Pro 与 Effort 都是这个方向；纯型号名对普通用户无效。[TechRadar](https://www.techradar.com/ai-platforms-assistants/chatgpt/chatgpt-might-not-be-using-the-model-you-think-and-its-also-hiding-others-in-settings)
- **进阶参数一律折叠，默认路径一次点击完成。** Configure / More models / 高级 是同一套模式。([devicebase](https://devicebase.net/en/openai-chatgpt/updates/updates-to-the-model-picker-in-chatgpt/8za))
- **BYO-key 应用的信任来自"看得见"：当前供应方、模型、token 与费用常显。** [Pal Chat](https://apps.apple.com/us/app/pal-chat-ai-chat-client/id6447545085)
- **生成结果是资产，不是临时输出：要版本、要可回退、要禁止静默覆盖。** [canvas](https://openai.com/index/introducing-canvas)；反面案例见[用户投诉](https://community.openai.com/t/canvas-overwrites-work-without-warning-major-issue-for-creators/1231713)
- **AI 写作用的资料库，核心不是"存"，是"哪条进上下文"。** Novelcrafter 把可见性、追踪、排除词做成条目字段。[Novelcrafter](https://www.novelcrafter.com/help/docs/codex/anatomy-codex-entry)
- **写作类应用普遍不再暴露"保存"。** 内容即状态，界面只留"最近保存时间"。HIG 的 sheet 指南也预设了"有未保存改动→下滑关闭时用 action sheet 确认"。[HIG · Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)
- **Liquid Glass 稀缺使用：只给导航与控件层，内容层一律普通表面。** Apple 原文要求"sparingly"、"limit these effects to the most important functional elements"。[HIG · Materials](https://developer.apple.com/design/human-interface-guidelines/materials)（与本仓库 `docs/UI.md` §1b 一致）

---

## 3. 对 Frthink 的 12 条可执行建议（按影响排序）

1. **Settings 首页**（`SettingsView.swift`）：改成 5 行分类列表，每行右侧显示当前值（「DeepSeek · deepseek-chat」）。缺 Key 只在首行留一条可点提醒，不做卡片。一屏看完，不超过 6 行。
2. **模型选择**：改成两级 sheet（`.medium` detent + grabber）。第一屏 3 档，第二屏「更多模型」带上下文长度；底部固定一行「默认模型」跳设置。
3. **连接与模型**（`SettingsConnectionPage.swift`）：供应方列表行 = 名字 + host + 状态点，当前项 `checkmark`；行尾「编辑」进三级页。整页最多 4 个区块。
4. **供应方编辑**（`ProviderEditorView.swift`）：默认展开 名称/基址/Key，其余进「高级」；底部「测试连接」，结果就地展开状态码 + 服务端原文前 200 字。保存按钮与测试结果解耦，失败不清空表单。
5. **世界书/人物/事件编辑器**（`WorldCharacterEditor.swift` / `WorldEventEditor.swift` / `WorldbookEntryEditor.swift`）：字段固定为 名称、别名、正文、AI 可见性三态、追踪开关；头部一行元信息「提及 12 处 · 4 章」。别名用 `WorldTagsField` 的胶囊输入，回车提交。
6. **技能编辑器**（`PromptSkillEditor.swift`）：正文编辑走 push 全屏页而不是 sheet；顶部显示「已保存 · 12:40」；关闭前若有未保存改动，`confirmationDialog` 给「放弃 / 继续编辑」。
7. **提示词块预览**（`PromptBlocksPreview.swift`）：等宽字体只读，块标题 + 首行摘要，点块展开全文；顶部一条预算条（input / output / 剩余）。不写实现说明。
8. **阅读显示设置**（`ReaderDisplaySettings.swift`）：从正文上浮的小面板进入，字号用 A-/A+，改完即时生效；底部「还原默认」。常驻控件 ≤ 4，其余进菜单。
9. **导入确认**（`ArchiveImportSupport.swift`）：先给摘要页（书名、章数、字数、将被覆盖的对象与条数），再二次确认；覆盖类操作把确认按钮文案写成动作（「覆盖并导入」），不用「确定」。
10. **分支面板**（`LibraryBranchesSheet.swift`）：分支 = 不可变快照，行内显示创建时间与字数，动作为「查看 / 从此处继续」；正文被 AI 替换前弹一次确认。
11. **语料库**（`CorpusEntryEditor.swift` / `CorpusPane.swift`）：空状态给结构骨架（示例行 + 「导入语料」按钮），不写「暂无数据」；规模用计数行呈现，点行切分栏。
12. **所有确认弹窗**：单决定用 `alert`，多选用 `confirmationDialog`；`exclamationmark.triangle` 只在真会丢数据时出现；滑动删除配 Undo，不弹窗。

---

## 4. HIG 硬约束速查

| 项 | 要求 | 来源 |
|---|---|---|
| Sheet 按钮 | 单页 sheet：Cancel 在左，Done 在右；三者不同时出现；支持下滑关闭 | [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets) |
| Sheet 层数 | 主界面同时只显示一个 sheet；开第二个前先关第一个 | 同上 |
| 未保存改动 | 下滑关闭前用 action sheet 确认 | 同上 |
| Alert | iOS 上"给选择"用 action sheet；alert 只做确认；警示符合少用 | [Alerts](https://developer.apple.com/design/human-interface-guidelines/alerts) |
| 难恢复动作 | 「二次确认」写在 Assistive Access 语境下，但可作为破坏性动作的通用上限 | [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) |
| 工具栏 | 用标准控件；别给工具栏加自定义底色与同色文字；可临时隐藏做无干扰写作 | [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) |
| 材质 | Liquid Glass 少用，只给最重要的功能元素；内容层不用 | [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) |
| 设置 | 只放不常改的项；任务级选项留在使用现场 | [Settings](https://developer.apple.com/design/human-interface-guidelines/settings) |

---

## 5. 未验证与来源缺口

- **未验证**：iOS 版 Apple Books 的 aA 面板逐项文案，只核到 macOS 版指南；iOS 与之一致属推断。
- **未验证**：ChatGPT 2026 年 3 月改版后 `Configure` 菜单的内部结构，只有 devicebase 的二手转述，OpenAI 官方帮助页仅覆盖 Enterprise/Edu 条目。
- **未验证**：canvas 已在 2026 年被下线（社区帖多处提及，未见 OpenAI 官方公告），本文只取其"版本回退 + 快捷改稿菜单"的交互思路。
- **未验证**：Bear / Ulysses / Craft / Things / Day One 的未保存改动与空状态实现，本次只核到 Bear 的备份说明，其余未见一手文档，故未写入模式库。
- **失败来源**：`developer.apple.com` 的 `human-interface-guidelines/entering-data`、`/patterns` 索引页均返回空壳（JS 渲染），`support.apple.com` 的 Books iPhone 变体返回 404；相关结论已改用同域可用页面支撑。
