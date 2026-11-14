import Foundation

/// 演示数据。
///
/// 仅用于 CI 截图流水线（启动参数 `-seedDemo`），正常启动时不执行。
/// 空状态无法展示界面的排版、层级与真实文本视觉效果。
enum DemoSeed {

    /// 截图流水线指定打开的书稿；其余演示项目仅用于填充书架展示。
    static let primaryTitle = "雨夜之后"

    static var isRequested: Bool {
        LaunchArguments.seedsDemo
    }

    /// 已注入演示数据则不再重复注入。
    @MainActor
    static func seedIfNeeded(store: AppStore) {
        guard isRequested, store.projects.isEmpty else { return }

        guard let project = store.createProject(title: primaryTitle) else { return }
        let session = store.openSession(for: project)

        store.setSynopsis(project, to: "一个关于旧书店与未寄出的信的故事。")
        session.payload.assistantSupplement = "保持克制的第三人称，不要抒情过度。"

        session.updateManuscript("""
        第一章 · 旧书店

        雨从傍晚开始下，一直没停。林昭把最后一摞书搬上二楼，手心的汗把书脊的烫金蹭花了一小块。

        她站在窗边看了很久。街对面的霓虹在水汽里化开，像谁把一团颜料按进了玻璃。

        「打烊了吗？」

        声音从楼梯口传来。她回过头，看见一个撑黑伞的男人，伞尖还在滴水，鞋面上沾着半片梧桐叶。

        第二章 · 未寄出的信

        男人说他要找一本 ninety-two 年出版的书。
        """)

        session.payload.messages = [
            makeMessage(role: .user, text: "接着写第二章，让林昭发现那本书里夹着一封信。"),
            makeMessage(role: .assistant, text: """
                林昭把梯子挪到最里侧的书架前。灰尘在手电的光柱里浮着，像静止的雪。

                ninety-two 年的那批书堆在最底层，纸页边缘已经发脆。她抽出第三本的时候，有什么东西从书页间滑了出来，轻飘飘地落在她脚边。

                是一封信。信封上写着地址，邮票还在，却从来没有盖过邮戳。

                「这个……」她把信捡起来，指尖有点抖。
                """),
            makeMessage(role: .user, text: "这里节奏太快了，把她的反应拉长一点。"),
        ]

        session.payload.world.characters = [
            CharacterCard(
                name: "林昭",
                identity: "旧书店店主，二十七岁",
                personality: "克制、观察力强，习惯把情绪收在动作里",
                voice: "短句，少形容词，说话前有停顿",
                goals: "守住父亲留下的书店",
                boundaries: "不长篇独白，不主动示弱",
                aliases: ["小林", "昭昭"],
                personalMemory: "父亲在她二十岁那年病逝，书店是他留下的唯一东西。",
                relationshipAttitudes: "对陌生男人保持礼貌的距离；提起父亲时会避开视线。",
                customEntries: [
                    .init(title: "外貌", body: "个子不高，常穿深色衬衫，左手腕有一道旧疤。")
                ]
            ),
            CharacterCard(
                name: "沈默",
                identity: "自称找书的客人，身份不明",
                personality: "耐心，话少，提问比回答多",
                voice: "语速慢，句子完整，偶尔用书面语",
                goals: "找到 ninety-two 年那本书",
                boundaries: "不主动解释自己的来历",
                aliases: ["黑伞男人"]
            ),
        ]

        session.payload.world.events = [
            EventCard(
                title: "雨夜来客",
                scene: "旧书店一楼",
                characters: ["林昭", "沈默"],
                cause: "沈默冒雨找一本旧书",
                development: "林昭准备打烊时被他叫住，两人第一次照面",
                consequence: "林昭答应第二天帮他找书"
            ),
            EventCard(
                title: "信封落地",
                scene: "二楼书架前",
                characters: ["林昭"],
                cause: "翻找 ninety-two 年的旧书",
                development: "信封从书页间滑落，没有邮戳",
                consequence: "林昭开始怀疑这本书的来历"
            ),
        ]

        session.payload.world.styleTemplate = """
        ## 叙事视角
        第三人称限知，紧贴林昭的感官；不进入沈默的内心。

        ## 句式节奏
        长短交替。场景描写用长句铺开，人物反应用短句切断。

        ## 对白
        少用解释性台词，让动作承担信息。

        ## 应避免
        不写「她心里一紧」这类直接命名情绪的表达。
        """

        session.payload.world.plotOutline = """
        ## 一、雨夜相遇
        林昭准备打烊，沈默冒雨进店找一本 ninety-two 年的旧书。

        ## 二、信封
        翻书时发现一封没有邮戳的信，成为全篇的引子。
        """

        session.payload.world.longTermRules = """
        # 长期写作规则

        *   **视角**：始终第三人称限知，只跟林昭。
        *   **情绪**：用动作和物件承载，禁止直接命名情绪。
        *   **节奏**：每章不少于两个场景，避免单一空间内的长篇对白。
        """

        session.payload.world.worldbookEntries = [
            WorldbookEntry(title: "旧书店", body: "两层木结构，一楼卖书，二楼存库。楼梯窄，扶手开裂。"),
            WorldbookEntry(title: "雨", body: "全篇的天气基调，象征人物之间尚未说出口的东西。"),
        ]

        session.payload.chapters = [
            Chapter(title: "第一章 · 旧书店", location: 0),
            Chapter(title: "第二章 · 未寄出的信", location: 160),
        ]

        session.payload.readerOffset = 0
        session.payload.composerDraft = "让沈默说出他真正在找什么。"
        session.saveNow()

        // 书架截图需要多部作品展示：补充两部进行中作品、一个分支项目及回收站草稿。
        if let second = store.createProject(title: "长夜将尽") {
            store.setSynopsis(second, to: "民国背景的悬疑长篇，双线叙事。")
        }
        if let third = store.createProject(title: "海边的房间") {
            store.setSynopsis(third, to: "关于回声、潮汐与记忆的短篇集。")
        }
        _ = store.duplicate(project)

        if let trashed = store.createProject(title: "旧稿 · 未命名实验") {
            store.setSynopsis(trashed, to: "试写的开头，暂时放进回收站。")
            store.trash(trashed)
        }
    }

    private static func makeMessage(role: ChatMessage.Role, text: String) -> ChatMessage {
        ChatMessage(role: role, content: text)
    }
}


