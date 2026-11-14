import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 行

/// 二级、三级页的导航行：标题 + 行尾的值。
///
/// 二级页面采用简洁导航行样式，避免无明确语义的图标干扰内容展示，与系统设置保持一致。
struct SettingsLabelRow: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        // 无障碍字号下放不下一行时改竖排：标题在上、值在下。
        ViewThatFits(in: .horizontal) {
            horizontal
            vertical
        }
        .contentShape(Rectangle())
        .frame(minHeight: Theme.Layout.rowContentHeight)
    }

    private var horizontal: some View {
        HStack(spacing: Theme.Spacing.m) {
            label
            Spacer(minLength: Theme.Spacing.s)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(Theme.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
    }

    private var vertical: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            label
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(Theme.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var label: some View {
        Text(title)
            .font(Theme.label)
            .foregroundStyle(.primary)
    }
}

// MARK: - 长文编辑页

/// 文本编辑页：提供多行输入，支持 0.6 秒输入防抖自动保存及离开页面强制落盘。
///
/// 采用导航页面承载，左滑返回时自动持久化非空修改。
struct SettingsTextEditorPage: View {
    let title: String
    var placeholder: String = ""

    @State private var text: String
    @State private var saveTask: Task<Void, Never>?
    private let onCommit: (String) -> Void

    init(
        title: String,
        text: String,
        placeholder: String = "",
        onCommit: @escaping (String) -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        _text = State(initialValue: text)
        self.onCommit = onCommit
    }

    var body: some View {
        AppTextEditor(text: $text, placeholder: placeholder, minHeight: 240, expands: true)
            .padding(Theme.Spacing.l)
            .pageBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: text) { _, _ in
                scheduleSave()
            }
            .onDisappear {
                saveTask?.cancel()
                saveTask = nil
                commit()
            }
    }

    @MainActor
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    @MainActor
    private func commit() {
        onCommit(text)
    }
}

// MARK: - 宽度

extension View {
    /// 常规宽度下将表单限制为 640pt 并水平居中。
    ///
    /// 紧凑模式下自适应宽度，宽屏模式下限制表单最大宽度以优化可读性。
    @ViewBuilder
    func settingsFormColumn() -> some View {
        modifier(SettingsFormColumnModifier())
    }
}

private struct SettingsFormColumnModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @ViewBuilder
    func body(content: Content) -> some View {
        if horizontalSizeClass == .regular {
            content
                .frame(maxWidth: Theme.Layout.formMaxWidth)
                .frame(maxWidth: .infinity)
                .background(Theme.groupedPageColor.ignoresSafeArea())
        } else {
            content
        }
    }
}

/// 将 `AppSettings` 字段包装为 Binding，值变更时触发持久化。
///
/// 适用于离散单值控件；连续变化的滑块控件需避免使用，以防止高频序列化写入配置文件。
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

func settingsByteText(_ bytes: Int64) -> String {
    bytes.formatted(.byteCount(style: .file))
}

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

/// 文件选择器取消时回调返回 failure，判定是否为用户主动取消以忽略该事件。
func settingsIsUserCancelled(_ error: Error) -> Bool {
    guard let cocoa = error as? CocoaError else { return false }
    return cocoa.code == .userCancelled
}

/// `.frthink` 文件的 FileDocument 包装类型，用于系统保存面板。
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
