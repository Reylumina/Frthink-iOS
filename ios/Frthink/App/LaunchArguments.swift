import Foundation

/// 启动参数集中解析。
///
/// 截图流水线通过 `-initialTab` / `-worldTab` / `-readerPanel` 等参数使界面
/// 直接导航至指定状态；演示数据通过 `-seedDemo` 注入。
enum LaunchArguments {
    static var initialTab: String? { value(after: "-initialTab") }
    static var worldTab: String? { value(after: "-worldTab") }
    static var readerPanel: String? { value(after: "-readerPanel") }
    static var writerFocus: String? { value(after: "-writerFocus") }
    static var settingsPage: String? { value(after: "-settingsPage") }
    static var settingsEditor: String? { value(after: "-settingsEditor") }
    static var opensLibrary: Bool { contains("-openLibrary") }
    static var opensTrash: Bool { contains("-openTrash") }
    /// 启动即打开人物卡列表里的第一张卡。
    static var opensWorldCard: Bool { contains("-openWorldCard") }
    static var focusComposer: Bool { contains("-focusComposer") }
    static var streamPreview: Bool { contains("-streamPreview") }
    /// DEBUG：用本地 URLProtocol 伪装 SSE，走真实客户端与控制器。
    static var mockStream: Bool { contains("-mockStream") }
    /// DEBUG：进入创作页后自动发一条指令。
    static var mockAutoSend: Bool { contains("-mockAutoSend") }
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
