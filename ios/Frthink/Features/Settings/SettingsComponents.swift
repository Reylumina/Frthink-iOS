import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 行

/// 二级、三级页的导航行：实底方块图标 + 标题 + 行尾的值（DESIGN §2.4、§5.1）。
///
/// 方块颜色按标题稳定取：同一行每次进来都是同一个色相，不同行自动分开。
/// 调用方可以显式传 `symbolTint` 覆盖。
struct SettingsLabelRow: View {
    let title: String
    var symbol: String? = nil
    /// 显式色相；不传就按标题从身份色里稳定取一个。
    var symbolTint: Color? = nil
    var detail: String? = nil

    private var tint: Color {
        symbolTint ?? Theme.Identity.color(for: title)
    }

    var body: some View {
        // 无障碍字号下放不下一行时改竖排：标题在上、值在下（DESIGN §5.5）。
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
        HStack(spacing: Theme.Spacing.m) {
            if let symbol {
                IconTile(symbol: symbol, tint: tint, filled: true)
            }
            Text(title)
                .font(Theme.label)
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - 长文编辑页

/// 长文编辑页：整页只有一个多行编辑框，自动保存（停手 0.6 秒），离开页面强制落盘。
///
/// 长文编辑不进 sheet（DESIGN §5.8），列表里只留一行入口；只有「保存」没有
/// 「取消」，所以左滑返回也保存非空改动。
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
    /// 常规宽度下把表单收窄到 640pt 并居中（DESIGN §5.3）。
    ///
    /// 紧凑宽度原样返回；iPad 宽窗口下两侧露出分组页底，不把行宽拉长。
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
