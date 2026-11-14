# DEVELOPMENT.md · 开发与验证

本文说明开发环境、验证命令、CI、未验证项和工程约定。架构参见 [ARCHITECTURE.md](ARCHITECTURE.md)，界面与视觉设计参见 [DESIGN.md](DESIGN.md)，性能实现参见 [PERFORMANCE.md](PERFORMANCE.md)。

## 1. 环境

本地无 Swift 编译器，验证通过 CI 或模拟器执行。

| 用途 | 位置 |
|---|---|
| Python | `C:\Users\Token\AppData\Roaming\uv\python\cpython-3.15.1-windows-x86_64-none\python.exe` |
| JDK 21 | `tools/jdk/jdk-21.0.13+9/bin/java.exe` |
| GitHub CLI | `C:\Users\Token\AppData\Local\Programs\GitHub CLI\gh.exe` |
| 未签名 IPA | `C:\Users\Token\Downloads\Frthink-unsigned.ipa` |

反编译产物位于 `out/`、`tools/` 与 `script/`，不纳入版本控制，但保留在本地用于核对原版行为。

SwiftLint 仅在 CI 的 lint 任务中执行（通过 `brew install swiftlint`），本地不作安装：Windows 环境未配置 Swift 工具链，`script/design_check.py` 作为 `.swiftlint.yml` 在本地的预检脚本。

## 2. 验证命令

```bash
python script/swift_check.py ios/Frthink
python script/prompt_check.py
python script/design_check.py
python script/archive_import_check.py <备份路径>
python script/pbxproj_check.py
```

本机 `python` 不在 PATH 上，用 `py script/...` 代替；CI 里用 `python3`。以上均为本地秒级检查，每批代码变更后即可运行，不依赖 CI。CI 按批次执行：完成单个功能点或一组相关变更后，触发一次 `Self Check`；需要 IPA 产物时触发 `iOS Build`；界面变更批次完成后执行 `UI Screenshots` 并按 `DESIGN.md` §9 进行人工目检；流式相关变更则执行 `Stream Check`。

CI 的运行时自检在启动时传 `-runSelfCheck`，执行 65 项纯逻辑检查（清单见 `ios/Frthink/App/SelfCheck.swift`）。结果写入 stdout 后退出，工作流用 `grep -q "ALL PASS"` 断言。真实备份检查需要 `fixture-backup.frthink`，缺少该文件时跳过。

## 3. CI 流水线

| 文件 | 产物 | 触发 |
|---|---|---|
| `.github/workflows/self-check.yml` | SwiftLint 结果 + 自检日志（65 项） | push main、手动 |
| `.github/workflows/real-import.yml` | 真实备份导入/导出/重开/落盘 | 手动 |
| `.github/workflows/ios.yml` | 未签名 IPA | 手动 |
| `.github/workflows/ui-screenshots.yml` | 各 Tab 与二、三级页截图（出图前先跑自检） | 手动、push main |
| `.github/workflows/stream-check.yml` | mock SSE 连续执行三次 + 正文行数/段落断言 | 手动 |
| `.github/workflows/cleanup-runs.yml` | 删除旧的已完成运行（保留最近 N 次） | 每周一 03:00 UTC、手动 |

分支上的变更不会自动触发 CI，需使用 `gh workflow run self-check.yml --ref <分支>` 手动执行；同 workflow 同 ref 仅保留最新一次，重复触发会取消正在排队或运行中的任务，避免在运行期间重复触发。

仓库为 public，标准 macOS runner 免费。private 仓库额度耗尽时，job 将在 3 至 5 秒内被拒绝，annotation 是 `The job was not started because recent account payments have failed...`。该失败属于额度问题，与代码无关。

截图流水线用启动参数控制：

- `-seedDemo`：一本书、两张人物卡、两条事件卡、三条消息。
- `-initialTab <创作|阅读|世界|宇宙|设置>`：启动落到哪个 Tab。
- `-worldTab setting|worldbook|characters|events|rules`：世界分栏。
- `-runSelfCheck`：执行自检后退出。

上述参数仅在 DEBUG 模式下生效，常规启动时不附带。

## 4. 未验证项

以下路径尚未在真机验证：

1. 所有 LLM 调用：续写、世界刷新、人物去重、事件抽取、译文、长期规则。
2. 真机文件选择器、覆盖确认、导入进度界面。
3. 文件落盘的实际写入，自检只写临时目录。
4. 阅读页滚动定位、搜索和书签。
5. 提示词回看面板的真机交互。
6. 键盘避让和收起：写作台输入条、正文编辑器、滚动。
7. 56 万字长篇小说的输入交互、滚动流畅度与内存峰值表现。
8. 世界刷新取消后的断点恢复继续执行。
9. 人物分组和去重在真实数据上的行为。
10. 设置和各二级页逐级进出，返回不丢失状态。
11. Android 端读取 iOS 导出的全量备份。
12. iOS 26 的 sheet 关闭用 `Button(role: .close)`（×）、确认用 `.confirm`（✓）——需在模拟器或真机环境中确认。
13. 用户气泡（`.systemGray5` 底 + `.label` 字）在浅色与深色模式下的实际观感与对比度。
14. 摇一摇撤销、⌘Z/⇧⌘Z、编辑菜单里的撤销重做。
15. 应用退入后台 30 秒后再切回前台，确认末尾输入内容未丢失（通过 `beginBackgroundTask` 保护落盘过程，实际后台时长由系统分配）。
16. iPad 常规宽度：正文 36 字宽、对话列 720、表单 640 的居中观感。

验证方式：安装至真机，在设置页填 API Key，测试连接，然后按 A1 至 A3 逐项执行验证。

已知问题：DeepSeek 思考开启时，输出会落在 `reasoning_content`，关闭档位时显式发 `thinking: disabled`。思考档位在供应方编辑页设置，默认关闭。

## 5. 原版行为核对

各项实现均以反编译结论为依据，避免主观臆测：

```
out/apktool/smali/…       字节码，R8 混淆后的类名是 A、L1、M1 等（v0.8.210 基线）
out/jadx/sources/…        Java 反编译，部分类失败
out/dex-stringtable.txt   全部字符串，18580 条
docs/APK-NOTES.md         v0.8.213 APK 拆解总览
docs/spec/                已整理的规格：架构、协议、数据模型、提示词
```

| 核对项 | 参考文档 |
|---|---|
| 请求体有哪些键 | `spec/02-llm-protocol.md` 第 2 节 |
| 提示词原文 | `spec/04-prompts.md`（P01 到 P64） |
| 存档 54 个键的含义 | `spec/03-data-model.md` 第 9 节 |
| 某个中文字符串 | `grep "文案" out/dex-stringtable.txt` |
| 某段逻辑 | `grep -r "关键字" out/jadx/sources/` |

jadx 的 jar 里 `Main-Class` 指向图形界面，命令行要显式指定：

```bash
java -cp tools/jadx-1.5.6-all.jar jadx.cli.JadxCLI -d out/jadx dx/classes.dex
```

## 6. 已知工程问题

| 问题 | 影响 | 线索 |
|---|---|---|
| 编辑器窗口只覆盖书末 | 跳到更早章节会扩窗口至书末；改写仍拼全文 | `ProjectSession.editorWindow` |
| 结构改动仍整份写 `payload.json` | 打字只写正文，世界/对话改动仍全量编码 | `ProjectSession.flushSave()` |
| 后台执行只有约 30 秒额度 | 系统收回后流式中断，已收内容保留 | `WriterController.beginBackgroundTask()` |
| 人物卡 memories 与检查点 | 已在导入导出中建模；App 内编辑卡片不会同步更新 checkpoint 的 mergedCards | `Archive.swift` |
| 长书首次发送仍主线程整本解密 | 初次执行续写或世界刷新时存在短暂卡顿，后续调用复用内存缓存 | `ProjectSession.manuscript` 是副作用 getter |
| 生成检查点每 3 秒改 `payload.messages` | 写作台每 3 秒可能整页重算一次，与 PERFORMANCE §2.1 的描述不一致 | `WriterController.persistPendingDelta` |
| P19 归纳预设只存不用 | 导入导出保持完整保真，但未注入任何提示词；在原版消费逻辑完成逆向取证前，暂不接入实际业务流程 | `Archive.swift`、`PromptComposer+Material.swift` |
| 长文编辑仍有一处在 sheet | `ManuscriptReaderSheet` 全屏读正文，DESIGN §5.10 要求 push | `ManuscriptReaderSheet` |

## 7. 约定

- 提示词文本内嵌在 `PromptLibrary.swift`，逐字对齐原版，不为通顺改写。
- token 估算逻辑严格沿用原版算法，不替换为分词器（tokenizer），以防文本截断边界发生偏移。
- 采样参数保持原版：`temperature = 0.2`，不跟随模型卡建议。
- 颜色、字号、间距只用 `docs/DESIGN.md` 的 token。
- 存档格式需与原版保持互通兼容，修改前须先执行 `archive_import_check.py` 及真实备份自检。
- 文档表述保持客观严谨，避免口语化说明与空泛修辞。
