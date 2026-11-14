// 本文件负责：提示词块模型 —— 分类、块、装配结果。

import Foundation

// MARK: - 块模型（规格 §0 / §1）

/// 规格 §0 的 8 个块分类（`J1/EnumC0389d1`）。
///
/// 分类决定块落在哪一侧：智能体指令 / 全局预设 / 技能是 system 侧固定提示词；
/// 用户输入是本轮 user 消息；对话历史是真正的历史 messages；世界资料 / 人物资料 /
/// 正文是随请求附带的只读数据块。
enum PromptCategory: String {
    case preset = "全局预设"
    case agentPrompt = "智能体指令"
    case userInput = "用户输入"
    case chatHistory = "对话历史"
    case authoritativeBody = "正文"
    case character = "人物资料"
    case worldbook = "世界资料"
    case skill = "技能"
}

/// 一条提示词块（Android 端是 `LL1/f3`：键 + 分类 + 正文 + 是否锁定 + 标题 + 优先级）。
struct PromptBlock {
    var key: String
    var category: PromptCategory
    var title: String
    var body: String
    var locked: Bool = false
    /// 正文自带 `# <名称>` 标题（P04/P06/P09/P10/P11），渲染时不再补一行 `# <标题>`。
    var hasOwnHeading: Bool = false

    /// 块的渲染形态：`# <标题>` + 换行 + 正文。
    ///
    /// 标题行用 `# ` 前缀，是因为规格里世界资料 / 技能 / 人物卡块的正文本身就是
    /// `# <名称>\n<内容>`（P04/P06/P09/P10/P11），块标题沿用的是同一套 Markdown 写法。
    var rendered: String {
        if body.isEmpty { return "" }
        if hasOwnHeading || title.isEmpty { return body }
        return "# " + title + "\n" + body
    }
}

/// 规格 §1「主写作请求的块顺序」的装配输入。
///
/// 字段与 §1 的 14 行一一对应（第 14 行是历史消息，不进这里）。iOS 侧
/// `WorldBook` 没有的设置项留空即可，空字段对应的块不会出现（规格 §1 各条都写明「空 → 不生成块」）。
struct PromptAssembly {
    struct Skill {
        var id: String
        var name: String
        var content: String
    }

    struct Universe {
        var id: String
        var name: String
        var content: String
    }

    struct Corpus {
        var libraryID: String
        var libraryName: String
        var entryID: String
        var entryName: String
        var category: String
        var text: String
    }

    struct Worldbook {
        var id: String
        var name: String
        var content: String
    }

    /// 项目 ID，只用于第 1 块的键 `assistant:project:<projectId>`。
    var projectID: String = ""
    /// 第 1 块：项目级补充指令（P02）。区别于全局预设。
    var projectAssistantInstruction: String = ""
    /// 第 2 块：全局预设（P03），正文即用户填写原文，不加前后缀。
    var globalPreset: String = ""
    /// 第 3 块：启用的技能（P04）。
    var skills: [Skill] = []
    /// 第 4 块：去 AI 味规则（P05）。标题叫「全局审查规则」。
    var aiFlavorRules: String = ""
    /// 第 5 块：宇宙共享世界书（P06）。
    var universes: [Universe] = []
    /// 第 6 块：本书仿写模板（P07）。
    var imitationTemplate: String = ""
    /// 第 7 块：剧情梗概（P08）。
    var plotOutline: String = ""
    /// 第 8 块：语料条目（P09）。
    var corpus: [Corpus] = []
    /// 第 9 块：项目世界书词条（P10）。
    var worldbooks: [Worldbook] = []
    /// 第 10 块：人物卡（P11）。
    var characters: [CharacterCard] = []
    /// 第 11 块：长期规则摘要（P12）。为空则整块不出现。
    var conversationSummary: String = ""
    /// 第 12 块：正文（P13）。
    var body: String = ""
    /// 第 12 块标题里的 `<范围>`（P13 只有三种取值）。
    var bodyRange: PromptLibrary.BodyRange = .full
    /// 第 13 块：调用方追加的块。
    var appendedBlocks: [PromptBlock] = []

    /// 这次真正进了提示词的块键，供「提示词回看」展示来源。
    var sourceIds: [String] {
        var ids: [String] = []
        if !projectAssistantInstruction.isEmpty {
            ids.append("assistant:project:\(projectID)")
        }
        if !globalPreset.isEmpty { ids.append("preset:global") }
        ids.append(contentsOf: skills.map { "skill:\($0.id)" })
        if !aiFlavorRules.isEmpty { ids.append("rules:ai-flavor") }
        ids.append(contentsOf: universes.map { "universe:\($0.id)" })
        if !imitationTemplate.isEmpty { ids.append("world:imitation-template") }
        if !plotOutline.isEmpty { ids.append("world:plot-outline") }
        ids.append(contentsOf: corpus.map { "corpus:\($0.libraryID):\($0.entryID)" })
        ids.append(contentsOf: worldbooks.map { "worldbook:\($0.id)" })
        ids.append(contentsOf: characters.map { "character:\($0.id)" })
        if !conversationSummary.isEmpty { ids.append("summary:long-term") }
        if !body.isEmpty { ids.append("body:authoritative") }
        return ids
    }

    /// 从 iOS 的 `WorldBook` 映射，统一复用完整装配逻辑以保证门控规则一致。
    static func from(
        world: WorldBook,
        manuscript: String,
        bodyRange: PromptLibrary.BodyRange = .full
    ) -> PromptAssembly {
        from(
            world: world,
            manuscript: manuscript,
            assistantSupplement: "",
            settings: AppSettings(),
            projectID: "",
            enabledUniverseEntryIDs: [],
            bodyRange: bodyRange
        )
    }
}
