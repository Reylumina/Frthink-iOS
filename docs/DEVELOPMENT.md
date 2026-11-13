# DEVELOPMENT.md · 开发与验证

本文说明开发环境、验证命令、CI、未验证项和工程约定。架构见 [ARCHITECTURE.md](ARCHITECTURE.md)，界面与视觉设计见 [DESIGN.md](DESIGN.md)，性能实现见 [PERFORMANCE.md](PERFORMANCE.md)。

## 1. 环境

本地无 Swift 编译器，验证通过 CI 或模拟器执行。

| 用途 | 位置 |
|---|---|
| Python | `C:\Users\Token\AppData\Roaming\uv\python\cpython-3.15.1-windows-x86_64-none\python.exe` |
| JDK 21 | `tools/jdk/jdk-21.0.13+9/bin/java.exe` |
| GitHub CLI | `C:\Users\Token\AppData\Local\Programs\GitHub CLI\gh.exe` |
| 未签名 IPA | `C:\Users\Token\Downloads\Frthink-unsigned.ipa` |

反编译产物在 `out/`、`tools/`、`script/`，不进仓库，但本机保留，用来查原版行为。

SwiftLint 只在 CI 的 lint job 里跑（`brew install swiftlint`），本机不装：Windows 没有 Swift 工具链，`script/design_check.py` 是 `.swiftlint.yml` 的本机预筛版本。

## 2. 验证命令

```bash
python script/swift_check.py ios/Frthink
python script/prompt_check.py
python script/design_check.py
python script/archive_import_check.py <备份路径>
python script/pbxproj_check.py
```

本机 `python` 不在 PATH 上，用 `py script/...` 代替；CI 里用 `python3`。以上都是本地秒级检查，改完一批就跑，不依赖 CI。CI 按批次跑：一个功能点或一组相关改动做完，跑一次 `Self Check`；需要 IPA 时跑 `iOS Build`；界面批次末尾才跑 `UI Screenshots`，按 `DESIGN.md` §9 目检；流式相关的改动跑 `Stream Check`。

CI 的运行时自检在启动时传 `-runSelfCheck`，执行 65 项纯逻辑检查（清单见 `ios/Frthink/App/SelfCheck.swift`）。结果写入 stdout 后退出，工作流用 `grep -q "ALL PASS"` 断言。真实备份检查需要 `fixture-backup.frthink`，缺少该文件时跳过。

## 3. CI 流水线

| 文件 | 产物 | 触发 |
|---|---|---|
| `.github/workflows/self-check.yml` | SwiftLint 结果 + 自检日志（65 项） | push main、手动 |
| `.github/workflows/real-import.yml` | 真实备份导入/导出/重开/落盘 | 手动 |
| `.github/workflows/ios.yml` | 未签名 IPA | 手动 |
| `.github/workflows/ui-screenshots.yml` | 各 Tab 与二、三级页截图（出图前先跑自检） | 手动、push main |
| `.github/workflows/stream-check.yml` | mock SSE 连跑三次 + 正文行数/段落断言 | 手动 |
| `.github/workflows/cleanup-runs.yml` | 删除旧的已完成运行（保留最近 N 次） | 每周一 03:00 UTC、手动 |

分支上的改动不会自动跑 CI，用 `gh workflow run self-check.yml --ref <分支>` 手动触发；同 workflow 同 ref 只保留最新一次，重复触发会取消正在排队/运行的那次，别在它跑的时候再发。

仓库为 public，标准 macOS runner 免费。private 仓库额度耗尽时，job 将在 3 至 5 秒内被拒绝，annotation 是 `The job was not started because recent account payments have failed...`。该失败属于额度问题，与代码无关。

截图流水线用启动参数控制：

- `-seedDemo`：一本书、两张人物卡、两条事件卡、三条消息。
- `-initialTab <创作|阅读|世界|宇宙|设置>`：启动落到哪个 Tab。
- `-worldTab setting|worldbook|characters|events|rules`：世界分栏。
- `-runSelfCheck`：跑自检后退出。

这些参数只在 DEBUG 用，正常启动不带。

## 4. 未验证项

以下路径尚未在真机验证：

1. 所有 LLM 调用：续写、世界刷新、人物去重、事件抽取、译文、长期规则。
2. 真机文件选择器、覆盖确认、导入进度界面。
3. 文件落盘的实际写入，自检只写临时目录。
4. 阅读页滚动定位、搜索和书签。
5. 提示词回看面板的真机交互。
6. 键盘避让和收起：写作台输入条、正文编辑器、滚动。
7. 56 万字书的输入、滚动流畅度和内存峰值。
8. 世界刷新取消后断点续跑。
9. 人物分组和去重在真实数据上的行为。
10. 设置和各二级页逐级进出，返回不丢状态。
11. Android 端读取 iOS 导出的全量备份。
12. iOS 26 的 sheet 关闭用 `Button(role: .close)`（×）、确认用 `.confirm`（✓）——只能在模拟器/真机上看。
13. 用户气泡白字对比度（浅色 4.9:1），以及深色模式下同一套 token 的表现。
14. 摇一摇撤销、⌘Z/⇧⌘Z、编辑菜单里的撤销重做。
15. 退后台 30 秒后回到前台，最后一段输入仍在（`beginBackgroundTask` 包着 flush，实际额度由系统给）。
16. iPad 常规宽度：正文 36 字宽、对话列 720、表单 640 的居中观感。

验证方式：安装至真机，在设置页填 API Key，测试连接，然后按 A1 到 A3 逐条跑。

已知问题：DeepSeek 思考开启时，输出会落在 `reasoning_content`，关闭档位时显式发 `thinking: disabled`。思考档位在供应方编辑页设置，默认关闭。

## 5. 查原版行为

实现依据来自反编译，不是猜的：

```
out/apktool/smali/…       字节码，R8 混淆后的类名是 A、L1、M1 等（v0.8.210 基线）
out/jadx/sources/…        Java 反编译，部分类失败
out/dex-stringtable.txt   全部字符串，18580 条
out-0.8.213/…             v0.8.213 反编译，差异见 archive/APK-0.8.213-DELTA.md
docs/spec/                已整理的规格：架构、协议、数据模型、提示词
```

| 想知道 | 看哪里 |
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
| 56 万字正文全量进 `UITextView` | 打开长书有内存峰值；保存已拆正文文件，输入已防抖 | `ManuscriptTextEditor` |
| 人物卡 memories 与检查点 | 已在导入导出中建模；App 内编辑卡片不会同步更新 checkpoint 的 mergedCards | `Archive.swift` |
| 长书首次发送仍主线程整本解密 | 第一次续写/世界刷新会卡一下；后续走缓存 | `ProjectSession.manuscript` 是副作用 getter |
| 生成检查点每 3 秒改 `payload.messages` | 写作台每 3 秒可能整页重算一次，与 PERFORMANCE §2.1 的描述不一致 | `WriterController.persistPendingDelta` |
| P19 归纳预设只存不用 | 导入导出保真，但不进任何提示词；原版消费点未取证前不接线 | `Archive.swift`、`PromptComposer+Material.swift` |
| 长文编辑仍有一处在 sheet | `ManuscriptReaderSheet` 全屏读正文，DESIGN §5.10 要求 push | `ManuscriptReaderSheet` |

## 7. 约定

- 提示词文本内嵌在 `PromptLibrary.swift`，逐字对齐原版，不为通顺改写。
- token 估算照抄原版公式，不换成 tokenizer。换了裁剪点就变。
- 采样参数保持原版：`temperature = 0.2`，不跟随模型卡建议。
- 颜色、字号、间距只用 `docs/DESIGN.md` 的 token。
- 存档格式要能和原版互认，改动前先跑 `archive_import_check.py` 和真实备份自检。
- 文档保持直接，不写实现说明和口号。
