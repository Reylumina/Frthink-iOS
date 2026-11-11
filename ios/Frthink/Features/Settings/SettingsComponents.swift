import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 把一个 `AppSettings` 字段包成 Binding，写入就落盘。
///
/// 用于开关/离散选择这类一次只改一个值的控件；连续拖动（滑块）不要用它，
/// 否则每个 tick 都会编码整份 settings.json。
@MainActor
func settingsBinding<T>(
    _ store: AppStore,
    _ keyPath: WritableKeyPath<AppSettings, T>
) -> Binding<T> {
    Binding(
        get: { store.settings[keyPath: keyPath] },
        set: { value in
            store.settings[keyPath: keyPath] = value
            store.saveSettings()
        }
    )
}

/// 字节数，例如 `12.3 MB`。
func settingsByteText(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
}

/// 估算 token 数。
func settingsTokenText(_ tokens: Int) -> String {
    "\(tokens.formatted()) tokens"
}

extension AppTheme {
    /// 主题对应的配色方案；`nil` 表示跟随系统。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 文件面板被取消时也会走 failure；这不是错误，直接吞掉。
func settingsIsUserCancelled(_ error: Error) -> Bool {
    guard let cocoa = error as? CocoaError else { return false }
    return cocoa.code == .userCancelled
}

/// `.frthink` 的 FileDocument 包装，只为走系统的保存面板。
struct ArchiveFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    static var writableContentTypes: [UTType] { [.data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
