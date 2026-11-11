// 本文件负责：导入结果的摘要数据 —— 每本书的规模数字、整份备份里带了哪些设置。
//
// 只做展示用的派生值，不参与解码与落盘。导入完成页和自检都读这里，保证
// 「界面上报的数字」与「真正写进去的数据」是同一份。

import Foundation

/// 一本书导入后的规模摘要。
struct ArchiveBookSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let bodyCharacters: Int
    let messageCount: Int
    let characterCardCount: Int
    let worldbookCount: Int
    let eventCount: Int
    let sourceCharacters: Int
    let trashedAt: Date?

    var isTrashed: Bool { trashedAt != nil }
}

extension FrthinkArchive.ProjectBackup {
    /// 从已解码的存档条目算出上屏数字。
    var importSummary: ArchiveBookSummary {
        let payload = snapshot.projectPayload
        return ArchiveBookSummary(
            id: projectId,
            title: title.isEmpty ? "未命名书项目" : title,
            bodyCharacters: payload.manuscript.count,
            messageCount: payload.messages.count,
            characterCardCount: payload.world.characters.count,
            worldbookCount: payload.world.worldbookEntries.count,
            eventCount: payload.world.events.count,
            sourceCharacters: sourceText.count,
            trashedAt: trashedAt > 0
                ? Date(timeIntervalSince1970: TimeInterval(trashedAt) / 1000)
                : nil
        )
    }
}

extension FrthinkArchive.FullBackupPayload {
    /// 备份里实际带了哪些全局设置。空备份不该在完成页显示一堆「0 项」。
    var settingsHighlights: [String] {
        var lines: [String] = []
        if !settings.globalPreset.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("全局预设")
        }
        if !settings.aiFlavorRules.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("去 AI 味规则")
        }
        if !settings.skills.isEmpty {
            lines.append("技能 \(settings.skills.count) 个")
        }
        if !settings.universeEntries.isEmpty {
            lines.append("共享世界书 \(settings.universeEntries.count) 条")
        }
        if !settings.corpusLibraries.isEmpty {
            let entries = settings.corpusLibraries.reduce(0) { $0 + $1.entries.count }
            lines.append("语料库 \(settings.corpusLibraries.count) 个 / \(entries) 条")
        }
        if !settings.worldBuildInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("世界建立要求")
        }
        if settings.inputBudgetTokens != 32_768 {
            lines.append("输入预算 \(settings.inputBudgetTokens)")
        }
        if settings.reservedOutputTokens != 30_000 {
            lines.append("输出上限 \(settings.reservedOutputTokens)")
        }
        return lines
    }
}
