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

    /// 没有封面时的书脊标记：一枚固定的书本类符号。
    ///
    /// 不用书名首字：中文首字在封面上像错字，也不是图标语言。这里从 10 枚
    /// 书本/文稿符号里按书 id 稳定取一枚，同一本书永远同一个标记。
    private var placeholderMark: some View {
        Image(systemName: symbol)
            // 字形占宽度 46%：封面是缩略图，图标压过一半就压住了「书脊」的比例。
            .font(.system(size: width * 0.46, weight: .medium))
            // 占位纸色在深浅两档都是压暗的，图标固定白色，是 §1.4 记下的例外。
            .foregroundStyle(Color.white)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        ShelfCoverSymbols.symbol(for: seed.isEmpty ? displayTitle : seed)
    }

    private var placeholderColor: Color {
        Theme.Identity.color(for: seed.isEmpty ? displayTitle : seed)
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

// MARK: - 占位书脊符号

/// 占位封面上的 10 枚符号：都是书本/文稿类，风格统一（单色、同一字重）。
///
/// 和纸色一样按书 id 稳定取，同一本书不会每次打开换一个图标。
/// 纸色在 Theme.Identity，和一级分类图标共用一套。
private enum ShelfCoverSymbols {
    /// 只收纯形状的容器类符号：不带字、不带横线、不带嵌套小图。
    ///
    /// 带「字」或文字行的符号缩到 30pt 就糊成一团，一眼看不出是图标。
    private static let symbols: [String] = [
        "book.closed",
        "book.pages",
        "books.vertical",
        "book",
        "doc",
        "square.stack",
        "rectangle.stack",
        "folder",
        "archivebox",
        "tray",
    ]

    static func symbol(for seed: String) -> String {
        // 用加盐的哈希：颜色和符号共用同一个哈希时，相近的 id（比如「分支 1」）
        // 会同时撞色又撞图标，一排书看着像同一本。
        symbols[Int(Theme.Identity.stableHash(seed + "#icon") % UInt64(symbols.count))]
    }
}
