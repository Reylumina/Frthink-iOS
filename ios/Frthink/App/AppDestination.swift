import SwiftUI

/// 五个一级目的地。
///
/// 顺序和文案对齐原版 `J1.r`（`com.frthink.app.model.AppDestination`）：
/// 创作 / 阅读 / 世界 / 宇宙 / 设置。原版未使用路由库，直接通过该枚举
/// 配合 `AnimatedContent` 切换，此处采用 `TabView` 表达相同语义。
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
        // 宇宙页承载跨书共享的预设、共享世界书与技能：六边形网格象征共享条目集合，
        // 并与世界页的连接点图标形成视觉区隔。
        case .universe: return "circle.hexagongrid"
        case .settings: return "gearshape"
        }
    }
}
