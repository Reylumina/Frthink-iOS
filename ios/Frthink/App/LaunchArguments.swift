import Foundation

/// 启动参数集中解析。
///
/// 截图流水线用 `-initialTab` / `-worldTab` / `-readerPanel` 等参数把界面
/// 直接摆到某个状态；演示数据用 `-seedDemo`。之前每个页面各写一遍
/// `firstIndex(of:) + 1`，参数名散落在五处，改一个名字要全仓库找。
enum LaunchArguments {
    static var initialTab: String? { value(after: "-initialTab") }
    static var worldTab: String? { value(after: "-worldTab") }
    static var readerPanel: String? { value(after: "-readerPanel") }
    static var writerFocus: String? { value(after: "-writerFocus") }
    static var settingsPage: String? { value(after: "-settingsPage") }
    static var settingsEditor: String? { value(after: "-settingsEditor") }
    /// 启动即打开书架。
    static var opensLibrary: Bool { contains("-openLibrary") }
    /// 启动即打开回收站。
    static var opensTrash: Bool { contains("-openTrash") }
    /// 启动即打开人物卡列表里的第一张卡。
    static var opensWorldCard: Bool { contains("-openWorldCard") }
    static var focusComposer: Bool { contains("-focusComposer") }
    static var streamPreview: Bool { contains("-streamPreview") }
    static var seedsDemo: Bool { contains("-seedDemo") }
    static var runsSelfCheck: Bool { contains("-runSelfCheck") }

    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else {
            return nil
        }
        return args[index + 1]
    }

    private static func contains(_ flag: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }
}
