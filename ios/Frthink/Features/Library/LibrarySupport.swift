// 书架页共用的小类型：编辑目标、时间格式化、书名的显示值。

import Foundation

/// 编辑目标枚举，标识待修改的字段与目标项目。
///
/// 传入 `Project` 快照而非 ID：防止弹窗期间外部数据变动引起状态不一致，确保展示触发时的项目状态。
enum LibraryEditTarget: Identifiable {
    case newProject
    case rename(Project)
    case synopsis(Project)

    var id: String {
        switch self {
        case .newProject:
            return "new"
        case .rename(let project):
            return "rename-\(project.id)"
        case .synopsis(let project):
            return "synopsis-\(project.id)"
        }
    }
}

extension Project {
    /// 新建时允许空书名；列表与回收站只显示占位，不写回模型。
    var shelfTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Project.untitledTitle : trimmed
    }
}

/// 书架上的时间文案格式化。
///
/// 自定义相对时间格式化：提供精简的时间描述，避免 `DateFormatter` 的 Locale 依赖与并发缓存开销。
enum LibraryFormat {
    static func updatedText(_ date: Date) -> String {
        "更新于 " + relativeText(date)
    }

    static func trashedText(_ date: Date) -> String {
        "移入于 " + relativeText(date)
    }

    static func relativeText(_ date: Date, now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(date)
        if delta < 60 {
            return "刚刚"
        }
        if delta < 3_600 {
            return "\(Int(delta / 60)) 分钟前"
        }
        if delta < 86_400 {
            return "\(Int(delta / 3_600)) 小时前"
        }
        return absoluteText(date)
    }

    static func absoluteText(_ date: Date) -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        let hour = components.hour ?? 0
        let minute = components.minute ?? 0
        return String(
            format: "%04d/%02d/%02d %02d:%02d",
            year, month, day, hour, minute
        )
    }

    static func branchText(_ count: Int) -> String {
        "\(count) 分支"
    }
}
