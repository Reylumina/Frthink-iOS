// 书封缩略图：真实封面异步解码 + 缩略图缓存；没有封面时画一枚低饱和书脊。
//
// 书架每一行都会重绘，base64 解码不能放在 `body` 里逐帧做。这里只缓存
// 240×320 的缩略图，容量 32 张；真实封面按屏宽缩放也够清晰。
//
// 尺寸和形状只在本文件定义：3:4 书封比例 + 一个 `@ScaledMetric`，
// 继续写作、全部书稿、分支和回收站共用同一份封面语法，页面上不会出现两种画法。

import SwiftUI
import UIKit

struct LibraryCoverImage: View {
    /// `Project.coverImagePayload`，base64 编码的 PNG，可能为空。
    let payload: String?
    let title: String
    /// 用书项目 id 决定占位色，同名书也能区分。
    var seed: String = ""

    @State private var image: UIImage?

    /// 书封高度；宽度按 3:4 推出，随 Dynamic Type 缩放（§5.1 固定尺寸控件）。
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 70

    private var width: CGFloat {
        height * 3 / 4
    }

    /// 封面形状：iOS 26 跟随所在行的容器同心，17–25 回落到 8pt 圆角（§3.3）。
    private var shape: AnyShape {
        Theme.containerShape(minimum: Theme.Radius.small)
    }

    private var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Project.untitledTitle : trimmed
    }

    var body: some View {
        ZStack {
            shape.fill(placeholderColor)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholderMark
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .task(id: payload) { await loadThumbnail() }
        // 书名就在同一行，封面属于重复信息，VoiceOver 只读行内容。
        .accessibilityHidden(true)
    }

    /// 没有封面时的书脊标记：单色 `book.pages`，不加描边、投影和装饰线。
    ///
    /// 不用 `book.closed` 这类旧字形；`book.pages` 是 iOS 17 起可用的新书稿符号。
    private var placeholderMark: some View {
        Image(systemName: "book.pages")
            .symbolRenderingMode(.monochrome)
            .font(.callout.weight(.regular))
            .foregroundStyle(Color.white.opacity(0.9))
            .accessibilityHidden(true)
    }

    private var placeholderColor: Color {
        ShelfCoverPalette.color(for: seed.isEmpty ? displayTitle : seed)
    }

    @MainActor
    private func loadThumbnail() async {
        guard let raw = payload?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            image = nil
            return
        }

        let key = "\(raw.hashValue)-\(raw.count)"
        if let cached = CoverThumbnailCache.shared.image(for: key) {
            image = cached
            return
        }

        image = nil
        let decoded = await Task.detached(priority: .utility) {
            LibraryCoverImage.decodeThumbnail(raw: raw, key: key)
        }.value

        guard !Task.isCancelled else { return }
        image = decoded
    }

    /// 在后台把 base64 解成 240×320 缩略图。解不出来就返回 nil，界面退回书脊。
    private nonisolated static func decodeThumbnail(raw: String, key: String) -> UIImage? {
        if let cached = CoverThumbnailCache.shared.image(for: key) {
            return cached
        }

        // 兼容 `data:image/png;base64,xxx` 这种带前缀的存法。
        var base64 = raw
        if let marker = raw.range(of: "base64,") {
            base64 = String(raw[marker.upperBound...])
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let full = UIImage(data: data)
        else {
            return nil
        }

        let target = CGSize(width: 240, height: 320)
        let thumbnail = full.preparingThumbnail(of: target) ?? full
        CoverThumbnailCache.shared.store(thumbnail, for: key)
        return thumbnail
    }
}

// MARK: - 缩略图缓存

/// NSCache 本身线程安全；只在解码完成后写入，容量固定，内存可控。
private final class CoverThumbnailCache {
    static let shared = CoverThumbnailCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 32
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

// MARK: - 占位书脊配色

/// 书脊占位色：固定的 6 种低饱和纸色，只用于封面占位，不参与控件语义。
///
/// 这是内容身份（每本书有自己的颜色），不是品牌色：色相固定、饱和度压低，
/// 深色模式再暗一档，和系统语义色放在一起也不打架。
private enum ShelfCoverPalette {
    private static let colors: [Color] = [
        dynamic(light: 0x3C3A37, dark: 0x2B2926),
        dynamic(light: 0x8A5A46, dark: 0x6B4435),
        dynamic(light: 0x5C6B4F, dark: 0x47543D),
        dynamic(light: 0x4E5D6C, dark: 0x3C4957),
        dynamic(light: 0x6A4A5E, dark: 0x523A49),
        dynamic(light: 0x9A7C58, dark: 0x765E42),
    ]

    static func color(for seed: String) -> Color {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for scalar in seed.unicodeScalars {
            hash = (hash ^ UInt64(scalar.value)) &* 1_099_511_628_211
        }
        return colors[Int(hash % UInt64(colors.count))]
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        let red = CGFloat((hex >> 16) & 0xFF) / 255
        let green = CGFloat((hex >> 8) & 0xFF) / 255
        let blue = CGFloat(hex & 0xFF) / 255
        self.init(red: red, green: green, blue: blue, alpha: 1)
    }
}
