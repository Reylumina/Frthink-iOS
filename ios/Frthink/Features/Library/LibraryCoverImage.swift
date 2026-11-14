// 书封缩略图：真实封面异步解码与缩略图缓存；无封面时绘制低饱和度书脊占位。
//
// 书架列表项重绘频繁，Base64 解码在后台异步执行。此处维护
// 240×320 规格缩略图缓存（容量 32 张），兼顾清晰度与内存占用。
//
// 尺寸与样式由本文件规范：3:4 比例配合 @ScaledMetric，
// 继续写作、全部书稿、分支与回收站共用统一封面规范，保持视觉一致。

import SwiftUI
import UIKit

struct LibraryCoverImage: View {
    /// `Project.coverImagePayload`，base64 编码的 PNG，可能为空。
    let payload: String?
    let title: String
    /// 基于书项目 ID 计算占位色，避免同名项目颜色重复。
    var seed: String = ""

    @State private var image: UIImage?

    /// 书封高度；宽度按 3:4 比例推导，支持 Dynamic Type 缩放。
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 70

    private var width: CGFloat {
        height * 3 / 4
    }

    /// 封面形状：iOS 26+ 与所在行容器保持同心圆角，iOS 17–25 回退至 8pt 圆角。
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

    /// 无封面时的书脊占位符号。
    ///
    /// 避免使用书名首字；根据书项目 ID 从预置书本/文稿符号中确定性选取，确保单本书标记固定。
    private var placeholderMark: some View {
        Image(systemName: symbol)
            // 图标宽度占比 46%，保证缩略图下书脊布局比例协调。
            .font(.system(size: width * 0.46, weight: .medium))
            // 占位底色在深浅色模式下均做暗化处理，图标固定为白色。
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

        // 缓存键采用长度与前 64 字符组合，避免滚动书架时在主线程对完整 Base64 字符串执行耗时哈希计算。
        let key = "\(raw.count)-\(raw.prefix(64))"
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

    /// 在后台将 Base64 解码为 240×320 缩略图；解码失败返回 nil 并降级显示书脊占位。
    private nonisolated static func decodeThumbnail(raw: String, key: String) -> UIImage? {
        if let cached = CoverThumbnailCache.shared.image(for: key) {
            return cached
        }

        // 兼容带前缀的格式（如 data:image/png;base64,...）。
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

/// 占位封面符号集合：采用风格统一的书本与文稿类单色符号。
///
/// 根据书项目 ID 确定性获取，确保同一书项目图标固定。
/// 纸色定义于 Theme.Identity，与一级分类图标共用色盘。
private enum ShelfCoverSymbols {
    /// 仅使用纯书本轮廓符号，排除非书籍类图形以保持语义一致。
    ///
    /// 系统纯书本轮廓符号结合 12 种主题纸色可提供充足的区分度。
    private static let symbols: [String] = [
        "book",
        "book.closed",
        "book.pages",
        "books.vertical",
    ]

    static func symbol(for seed: String) -> String {
        // 采用加盐哈希：避免颜色与符号共用同一哈希导致相近 ID（如分支项目）同时出现颜色与图标冲突。
        symbols[Int(Theme.Identity.stableHash(seed + "#icon") % UInt64(symbols.count))]
    }
}
