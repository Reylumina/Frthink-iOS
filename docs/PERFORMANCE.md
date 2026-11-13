# PERFORMANCE.md · 性能、硬件利用与流式处理

本文记录 Frthink iOS 在性能、硬件利用和消息流式上的依据与做法。先有 Apple 文档或可复现的实践，再改代码，没有依据的优化不做。

## 1. 依据

| 主题 | 来源 | 结论 |
|---|---|---|
| ProMotion 120Hz | Apple《Optimizing iPhone and iPad apps to support ProMotion displays》 | `Info.plist` 要设 `CADisableMinimumFrameDurationOnPhone = true`，否则 Core Animation 不采用高于系统默认的帧率 |
| 生成式 Info.plist | Apple《Managing your app's information property list values》 | 用户自定义的 `INFOPLIST_KEY_*` 不保证写进生成的 plist，自定义键要走真正的 `Info.plist` 合并 |
| SwiftUI 视图更新 | Apple WWDC25《Optimize SwiftUI performance with Instruments》 | `@Observable` 的依赖尽量窄，频繁变化的属性隔离到小视图或独立模型，避免在 `body` 中执行重负载操作 |
| SwiftUI `Text` 流式渲染 | JuniperPhoton《Pro to SwiftUI: Text performance issue and workaround》 | `Text` 不是 `UITextView` 或 `NSTextView`。流式长文本每追加一次都会全量重排，行数到 50 到 100 以上时主线程 CPU 显著升高，改用 `UITextView` 可明显改善 |
| token 合并 | Tanay Shah《Why Your iOS Streaming Chat Is Cooking the GPU》 | 逐 token 渲染等于反复解析越来越长的字符串。按时间窗口合并，遇到换行立即刷新，兼顾流畅和段落语义 |
| URLSession | SwiftLee《URLSessionConfiguration: Exploring opt-in configurations》和 Apple 文档 | 交互式请求用 `waitsForConnectivity = false` 快速失败，流式响应不写 URL 缓存，复用 session 复用连接 |
| 省电和热管理 | Apple `ProcessInfo.thermalState`、`isLowPowerModeEnabled` | 过热或低电量时降低刷新频率，将 CPU 和 GPU 保留给前台交互 |

本机无 Mac 和 Instruments，上面的结论来自文档与社区实测。模拟器只能验证编译和纯逻辑，真机帧率和能耗仍需在真机测试，见 [`DEVELOPMENT.md`](DEVELOPMENT.md) 的未验证部分。

## 2. 已落地的做法

### 2.1 消息流式

SSE 增量先进入 `WriterController` 的缓冲，也就是 `displayBuffer` 和 `pendingDelta`，不逐 token 写 SwiftUI 状态。

默认 33ms 合并一次（约 30 帧/秒），收到换行立即刷新，避免把段落边界切在时间片里。低电量时降到 100ms，`thermalState` 为 serious 或 critical 时 80ms，fair 时 50ms。滚动跟随同一个 `displayTick`。

流式气泡单独渲染。`WriterStreamingBubble` 只读控制器文本，不触发正文和其他气泡重算。流式文本用 `StreamingTextView`（`UITextView`），每帧先算整段排版再按显示串求公共前缀，只替换尾部差异，窗口攒满才整段重置。生成结束后切到完成态气泡，同样是 TextKit 渲染（`JustifiedText`），气泡内文字不开放选词，整条复制走长按菜单。

生成期间的 3 秒检查点策略见 §2.5。流式与完成态共用 `MarkdownInline.runs(_:)` 解析行内加粗和斜体；仅在文本含 `*` 时走解析，普通正文保持纯文本。

### 2.2 主线程与依赖

正文编辑器停止输入 400ms 后才把整串交给 session，光标同步 120ms 防抖。外部插入、撤销和导入通过 `manuscriptRevision` 回灌，避免每次重绘都比较 56 万字。

正文字数在后台和章节扫描一起算，`body` 只读缓存值。`String.count` 是 O(n)，不能放在渲染路径里。

输入框拆成 `WriterComposerBar`，文本和焦点都在子视图，写指令时不触发写作台整页重算。这是 WWDC25 缩小依赖范围的做法。

阅读页用保存时落下的块索引，打开不拼全文；翻译模式仍需全文切块，放后台做。设置页的钥匙串读取在启动时缓存，目录大小和 token 估算放后台；阅读搜索按页滚动扫描，只保留相邻两页，不再先把整本拼成 `String`；输入停止 220ms 后才扫。语料行高亮按条目缓存，章节列表用偏移差算字数，不再为列表拼全文。导入时，读文件、解压、解码和写盘都在后台，主线程只更新进度。

### 2.3 网络与硬件

共享一条 `URLSession`，配置是 `ephemeral`、`urlCache = nil`、`waitsForConnectivity = false`、`httpMaximumConnectionsPerHost = 4`。每次生成不新建 session，复用连接和 TLS。

请求用 `cachePolicy = .reloadIgnoringLocalCacheData`，SSE 不写缓存。SSE 解析循环用 `autoreleasepool` 控制每行临时对象的生命周期，解码器整条流复用。

ProMotion 在 `ios/Info.plist` 设 `CADisableMinimumFrameDurationOnPhone = true`。CI 在构建产物里用 `plutil` 校验这个键。

### 2.4 内存

导入按书逐本写盘，避免一次性编码全部项目。大文件解码放后台，`Data` 用完就释放。

阅读正文按块渲染，用 `LazyVStack`；块模型只存 range，可见段按页解密并缓存。全屏编辑器同样只持有窗口文本，不再把整本书塞进 UITextView。章节和字数扫描用 COW 快照，扫完看引用有没有变，判断结果是否过期。

流式气泡只排版末尾滑窗（6000 字窗口，约 8000 字才重置），`sizeThatFits` 不随全文无限增长。生成结束后切回完整气泡。

### 2.5 生成期检查点只碰 payload

`appendDelta` 只改内存里的 `payload`，不逐字落盘。生成期间每约 3 秒把增量并回并写一次 `payload.json`：只写 payload（`.payloadOnly`），不重写正文页，也不再把整本正文重新编码进 payload（正文页独立存在，裁掉的是旧版兜底字段）。正文有未落盘改动时才升级成全量保存。离开页面、停止或结束时全量写一次。

### 2.6 落盘与打开

`saveNow` 串行化，同一时间只编码一次；编码期间的新改动用 `SaveKind` 合并，完成后再写最新快照。`body.meta.json` 只存字数、UTF-16 长度和章节，打开书不碰正文密文；正文按页写在 `body.pages/*.bin`；全屏编辑器只载入书末两页并只写窗口页，阅读器只取可见页，拼提示词时才拼全文。逐字编辑只重写从首个变化页开始的正文页，`payload.json` 只在结构改动、手动保存或退后台时重写。

落盘防抖 2 秒，正文提交 400ms，章节和字数扫描 1.5 秒。

打开书时，`AppStore.openSessionAsync` 把 `Data` 读取和 JSON 解码放后台。`RootView` 先显示书稿框架和「正在打开」，解码完再挂 `WriterPane`。之前是在 `body` 求值里同步 `loadPayload`，56 万字会卡住首帧。

## 3. 可测的证据

`-runSelfCheck` 里有两项性能检查：

- `perf.manuscriptCodec`：20 万字 payload 的 JSON 编解码耗时和大小。
- `perf.chapterScan`：约 3.5 万字、2000 章的章节扫描耗时。

模拟器实测：编解码 2–3ms、586KB，章节扫描 12–15ms。这两个数只代表模型层，不含 UI 渲染，不做硬门槛，用来看回归趋势。

`ui-screenshots.yml` 里加了 `plutil` 校验 ProMotion 键，键丢了就失败。

真机上的流式帧率、CPU 和能耗、56 万字输入、键盘收起都尚未测试，不能算通过。

## 4. 尚未实现

- Instruments 的 View Body / Time Profiler 实测，需要 Mac。
- 请求快照在 30 条之外另有 200k token 总量上限（`ProjectSession.requestSnapshotTokenBudget`），但单条快照仍随发送的正文线性增长，没有字节上限或按块键重建。
