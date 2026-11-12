// 书架页共用的小类型：编辑目标、时间格式化、书名的显示值。

import Foundation

/// 弹出输入框时，这次要改的是哪个字段。
///
/// 用 `Project` 快照而不是 id：弹窗关闭前用户可能已经在别处改动过书架，
/// 快照保证输入框里显示的是用户点开时看到的那本书。
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

/// 书架上的时间文案。
///
/// 不走 `DateFormatter`：这里只需要「刚刚 / n 分钟前 / n 小时前 / 年月日」，
/// 手写既省掉 locale 依赖，也不会在静态缓存上碰并发检查。
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
