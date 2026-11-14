import Foundation

/// 提示词集成管理器里的一条「技能」（规格 D · P04，原版 `SkillProfile`）。
///
/// 技能是跨项目复用的指令模板：启用后按 `# <技能名>\n<内容>` 封装为技能块，
/// 顺序在「全局预设」之后、「去 AI 味规则」之前（规格 §1 第 3 块）。
struct Skill: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var content: String
    var enabled: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        content: String = "",
        enabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.enabled = enabled
    }

    /// P04 · `# <技能名>\n<内容>`。没启用或没名字 → 不生成块。
    var promptBlock: String? {
        guard enabled,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return PromptLibrary.render(PromptLibrary.skillBlockTemplate, [
            "技能名": name,
            "技能内容": content,
        ])
    }

    /// P01 的自由写作 Agent 基础规范：默认技能，也是没有自定义技能时的兜底人格。
    static var builtinFreeWritingAgent: Skill {
        Skill(
            id: "builtin-free-writing-agent",
            name: "自由写作 Agent 基础规范",
            content: PromptLibrary.freeWritingAgentBase,
            enabled: true
        )
    }

    /// 新建设置时的默认技能列表。
    static var defaults: [Skill] {
        [builtinFreeWritingAgent]
    }
}

/// 提示词集成管理器负责的四类可编辑指令（P02 / P03 / P04 / P05）。
///
/// 装配顺序严格遵循规格 §1：项目补充指令 → 全局预设 → 技能 → 去 AI 味规则。
/// 此处不手动拼接字符串，而是构造 `PromptAssembly` 委托 `PromptComposer` 处理，
/// 保证预览与真正发出去的提示词逐字一致。
enum PromptIntegration {
    static func blocks(
        projectID: String,
        assistantSupplement: String,
        globalPreset: String,
        skills: [Skill],
        aiFlavorRules: String
    ) -> [PromptBlock] {
        var assembly = PromptAssembly()
        assembly.projectID = projectID
        assembly.projectAssistantInstruction = assistantSupplement
        assembly.globalPreset = globalPreset
        assembly.skills = skills
            .filter { $0.enabled && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                PromptAssembly.Skill(id: $0.id, name: $0.name, content: $0.content)
            }
        assembly.aiFlavorRules = aiFlavorRules
        return PromptComposer.writingBlocks(assembly)
    }
}
