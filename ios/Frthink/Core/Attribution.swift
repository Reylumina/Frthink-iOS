import Foundation

/// 原作者署名。
///
/// 原版 Android 应用设置页底部的两行字面量：
/// `"Frthink v0.8.210"` 与 `"Power by Fr33"`（DEX 字符串表 str:3052、str:9804）。
/// 移植版在所有展示版本号的地方都带上原作者，不要只写自己的名字。
enum Attribution {
    /// 原应用名。
    static let appName = "Frthink"
    /// 原应用版本号。
    static let originalVersion = "v0.8.210"
    /// 原作者署名。原版的写法就是 `Power by Fr33`。
    static let originalAuthor = "Fr33"

    /// 原版设置页的版本行，逐字保留。
    static let versionLine = "Frthink v0.8.210"
    /// 原版设置页的署名行，逐字保留。
    static let creditLine = "Power by Fr33"

    /// 移植说明。出现在设置页底部和关于页。
    static let portNotice = """
    本应用是 Android 版 Frthink（原作者 Fr33）的 SwiftUI 移植，非官方版本。
    原应用及其提示词由原作者创作，版权归原作者所有。
    """
}
