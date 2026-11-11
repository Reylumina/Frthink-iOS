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

/// 覆盖导入后，把可能还挂在内存里的会话换成刚写盘的内容。
///
/// `AppStore` 只在 `openSession` 时读盘：导入覆盖同名项目后，写作台里那个会话
/// 还拿着旧稿，它 2 秒的防抖保存随时会把导入的正文盖回去。这里只替换**已缓存**
/// 的会话，并且复位正文分页缓存/编辑器窗口，避免用旧状态再写盘。
///
/// 只对导入前就存在的项目 id 调用，新建的 id 不可能有会话。
@MainActor
func settingsRefreshSessions(_ store: AppStore, projectIDs: Set<String>) {
    guard !projectIDs.isEmpty else { return }
    for id in projectIDs {
        guard let project = store.projects.first(where: { $0.id == id }),
              let session = store.cachedSession(for: id) else { continue }
        session.replaceLoadedState(project: project, fileStore: store.fileStore)
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
