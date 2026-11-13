import SwiftUI

/// 五个一级目的地。
///
/// 顺序和文案照抄原版的 `J1.r`（`com.frthink.app.model.AppDestination`）：
/// 创作 / 阅读 / 世界 / 宇宙 / 设置。原版没有用路由库，就是这一个枚举
/// 配 `AnimatedContent` 切换，这里用 `TabView` 表达同样的语义。
enum AppDestination: String, CaseIterable, Identifiable {
    case compose = "创作"
    case reader = "阅读"
    case world = "世界"
    case universe = "宇宙"
    case settings = "设置"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .compose: return "square.and.pencil"
        // `book.pages` 是新版字号的书本符号；`book` 的旧字形在 iOS 26 上显得过时。
        case .reader: return "book.pages"
        case .world: return "point.3.connected.trianglepath.dotted"
        // 宇宙页是跨书共享的预设、共享世界书和技能：六边形网格读作「一堆共享条目」，
        // 也和世界页的连接点图标区分开。
        case .universe: return "circle.hexagongrid"
        case .settings: return "gearshape"
        }
    }
}
