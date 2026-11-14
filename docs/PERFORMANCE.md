# PERFORMANCE.md · 性能、硬件利用与流式处理

本文记录 Frthink iOS 在性能优化、硬件资源利用和消息流式处理上的设计依据与工程实现，各项优化均对应 Apple 官方文档或可复现的性能基准。

## 1. 依据

| 主题 | 来源 | 结论 |
|---|---|---|
| ProMotion 120Hz | Apple《Optimizing iPhone and iPad apps to support ProMotion displays》 | `Info.plist` 需配置 `CADisableMinimumFrameDurationOnPhone = true`，否则 Core Animation 不采用高于系统默认的刷新率 |
| 生成式 Info.plist | Apple《Managing your app's information property list values》 | 用户自定义的 `INFOPLIST_KEY_*` 不保证写入最终生成的 plist，自定义键需通过标准的 `Info.plist` 合并机制处理 |
| SwiftUI 视图更新 | Apple WWDC25《Optimize SwiftUI performance with Instruments》 | `@Observable` 的依赖范围应尽量收窄，频繁变化的属性隔离到小型子视图或独立模型，避免在 `body` 中执行重负载计算 |
| SwiftUI 几何读取 | Apple `onGeometryChange(for:of:action:)` 文档 | 采用 `.onGeometryChange` 返回轻量级 `Equatable` 尺寸替代 `GeometryReader`，以避免额外的布局读取开销 |
| SwiftUI `Text` 流式渲染 | JuniperPhoton《Pro to SwiftUI: Text performance issue and workaround》 | `Text` 并非 `UITextView` 或 `NSTextView`。流式长文本每次追加均会触发全量文本重排，行数达到 50 至 100 行以上时主线程 CPU 占用显著升高，改用 `UITextView` 可明显优化渲染性能 |
| token 合并 | Tanay Shah《Why Your iOS Streaming Chat Is Cooking the GPU》 | 逐 token 渲染将频繁重复解析持续增长的长文本。按时间窗口合并批次，遇换行符立即触发刷新，兼顾呈现流畅度与段落语义完整性 |
| URLSession | SwiftLee《URLSessionConfiguration: Exploring opt-in configurations》和 Apple 文档 | 交互式请求配置 `waitsForConnectivity = false` 实现快速失败，流式响应禁用 URL 缓存，复用 session 以保持连接复用 |
| 省电和热管理 | Apple `ProcessInfo.thermalState`、`isLowPowerModeEnabled` | 设备过热或处于低电量模式时降低刷新频率，将 CPU 与 GPU 算力优先保障前台交互 |

本地无 Mac 与 Instruments 分析环境，上述结论源自官方技术文档与社区实践基准。模拟器仅可验证代码编译与纯逻辑，真实运行帧率与硬件能耗仍须在真机环境中实测，详见 [`DEVELOPMENT.md`](DEVELOPMENT.md) 的未验证项清单。

## 2. 已落地的做法

### 2.1 消息流式

SSE 增量数据优先写入 `WriterController` 的内部缓冲区，即 `displayBuffer` 与 `pendingDelta`，避免逐 token 频繁触发 SwiftUI 状态写入。

默认按 33ms 合并刷新一次（约 30 帧/秒），收到换行符立即刷新，避免将段落边界截断在时间片内部。低电量模式下降频至 100ms；`thermalState` 为 serious 或 critical 时降为 80ms，fair 时为 50ms。滚动跟踪同步绑定同一个 `displayTick`。

流式气泡独立渲染。`WriterStreamingBubble` 仅监听控制器流式文本，不触发正文及其他气泡的视图重算。流式文本基于 `StreamingTextView`（`UITextView`）呈现，与完成态共用 `WriterTypography`：内部维护已完成段落列表（`completedParagraphs`）及其在 `NSTextStorage` 中的 UTF-16 结束偏移（`completedUTF16PrefixEnds`），每帧仅对新增完成的段落与当前末尾进行中段落构建属性字符串并调用 `NSTextStorage.replaceCharacters` 增量替换尾部，将每帧排版复杂度从 `O(窗口全文)` 降至 `O(末段)`；仅在超出滑窗容量或样式参数变更时执行整窗重建。生成结束后切换为完成态气泡，同样通过 TextKit 渲染（`JustifiedText`）；气泡内文本不开放零散选词，整条文本复制统一由长按菜单触发。

生成阶段的 3 秒检查点策略详见 §2.5。流式与完成态共用 `MarkdownInline.runs(_:)` 解析行内加粗和斜体；仅在文本包含 `*` 字符时执行解析，普通正文保持纯文本渲染。

### 2.2 主线程与依赖

正文编辑器停止输入 400ms 后再将完整字符串同步至 session，光标位置同步设置 120ms 防抖。外部插入、撤销与导入操作通过 `manuscriptRevision` 触发回流，避免每次视图重绘对比 56 万字文本。

正文字数统计在后台线程与章节扫描合并执行，`body` 仅读取缓存统计值。`String.count` 时间复杂度为 O(n)，严禁置于视图渲染的关键路径。

输入控制条独立封装为 `WriterComposerBar`，文本状态与聚焦管理均收敛于子视图，键入指令时不触发写作台整页重算。该设计符合 WWDC25 推荐的收窄依赖范围范式。

阅读页利用持久化时生成的分块索引，打开书稿时仅加载当前可见分块；翻译模式由后台线程执行分块。设置页的钥匙串读取在启动阶段预缓存，目录占用统计与 token 估算移至后台执行；阅读搜索基于页面滚动按需扫描，仅缓存相邻两页；停止输入 220ms 后再触发搜索扫描。语料行高亮依据条目建立缓存，章节列表通过偏移量差值计算字数。导入备份时，文件读取、解压、解码与写盘均在后台线程执行，主线程仅负责更新进度状态。

### 2.3 网络与硬件

全局复用单一 `URLSession`，配置设为 `ephemeral`、`urlCache = nil`、`waitsForConnectivity = false`、`httpMaximumConnectionsPerHost = 4`。每次生成任务不重建 session，充分复用 TCP 连接与 TLS 会话。

请求配置 `cachePolicy = .reloadIgnoringLocalCacheData`，SSE 数据流不写入磁盘缓存。SSE 解析循环使用 `autoreleasepool` 严格控制每行临时对象的生命周期，整条流生命周期内复用解码器实例。

ProMotion 支持在 `ios/Info.plist` 中配置 `CADisableMinimumFrameDurationOnPhone = true`。CI 构建产物中通过 `plutil` 自动化校验该配置键。

### 2.4 内存

备份导入按书稿逐本写入磁盘，避免一次性在内存中全量编码所有项目。大文件解码置于后台线程执行，`Data` 对象读取完毕后立即释放内存。

阅读正文按块渲染并采用 `LazyVStack`；块模型仅保留 range 范围信息，可见段落按页解密并加载至内存缓存。全屏编辑器仅持有窗口文本，保持较低内存占用。章节与字数扫描基于 COW 快照机制，扫描完成后比对引用变化，以此校验统计结果是否失效。

流式气泡仅排版末尾滑动窗口（6000 字窗口，约 8000 字触发重置），`sizeThatFits` 布局尺寸不随全文无限膨胀。生成结束后平滑切换回完整文本气泡。

### 2.5 生成阶段检查点仅操作 payload

`appendDelta` 仅更新内存中的 `payload` 数据，不执行逐字落盘。生成过程中约每 3 秒将增量数据合并并执行一次 `payload.json` 写入：仅持久化 payload（`.payloadOnly`），不重写正文分页，亦不将整本正文重新编码嵌入 payload（正文分页独立存储，移除了旧版本中的冗余兜底字段）。正文存在未落盘修改时才提升为全量保存。离开页面、停止生成或正常结束时执行一次全量落盘。

### 2.6 落盘与打开

`saveNow` 实行串行化控制，同一时间仅允许单个编码任务执行；编码进行中的新变更通过 `SaveKind` 合并记录，完成后统一持久化最新快照。`body.meta.json` 仅存储字数、UTF-16 长度及章节信息，打开书稿时不解密正文密文；正文按页分散存储于 `body.pages/*.bin`；全屏编辑器仅载入书末两页且仅落盘窗口对应页面，阅读器仅按需读取可见页，提示词拼装阶段才组装全文正文。逐字编辑仅重写从首个变动页起始的正文页，`payload.json` 仅在结构变动、手动保存或退入后台时重新写入。

磁盘落盘防抖设定为 2 秒，正文提交防抖 400ms，章节与字数统计扫描防抖 1.5 秒。

打开书稿时，`AppStore.openSessionAsync` 将 `Data` 读取与 JSON 解码移至后台线程处理。`RootView` 优先展示书稿框架与「正在打开」状态，解码完成后挂载 `WriterPane`。此前在 `body` 视图求值阶段同步调用 `loadPayload`，在处理 56 万字大体量内容时会造成首帧卡顿。

## 3. 可测的证据

`-runSelfCheck` 中包含两项性能测试指标：

- `perf.manuscriptCodec`：20 万字 payload 的 JSON 编解码耗时与体积基准。
- `perf.chapterScan`：约 3.5 万字、2000 章规模的章节扫描耗时基准。

模拟器实测表现：编解码耗时 2–3ms、体积 586KB，章节扫描耗时 12–15ms。这两项指标仅反映数据模型层的处理性能，不包含 UI 渲染开销，不设硬性门槛，用于评估后续迭代的性能回归趋势。

`ui-screenshots.yml` 中集成了 `plutil` 校验 ProMotion 键配置，若缺失该键则判定构建失败。

真机环境下的流式帧率、CPU 占用、能耗表现、56 万字输入响应以及键盘避让收起交互尚未实测，暂不列入已验证状态。

## 4. 尚未实现

- 基于 Mac 环境的 Instruments View Body 及 Time Profiler 实际性能分析。
- 请求快照在 30 条历史保留之外另设有 200k token 总量上限（`ProjectSession.requestSnapshotTokenBudget`），但单条快照体积仍随发送正文线性增长，尚未设立字节数硬性上限或基于块引用的动态重构机制。
