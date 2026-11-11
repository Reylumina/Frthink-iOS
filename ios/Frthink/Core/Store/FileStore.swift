import CryptoKit
import Foundation

/// 磁盘布局：
///
/// ```
/// Application Support/Frthink/
///   settings.json
///   projects/<projectID>/project.json      — Project 元数据
///   projects/<projectID>/payload.json      — ProjectPayload，AES-256-GCM 密文
///   projects/<projectID>/body.pages/*.bin  — 正文分页，逐页 AES-256-GCM 密文
///   projects/<projectID>/body.json         — 旧版单文件正文，仅迁移用
///   projects/<projectID>/body.meta.json    — 字数/UTF-16 长度/章节/页数/块索引，AES-256-GCM 密文
///   projects/<projectID>/source.json       — 原文（翻译源），AES-256-GCM 密文
///   projects/<projectID>/translations.json — [TranslationSegment]，AES-256-GCM 密文
/// ```
///
/// Android 端用 Room。这里按项目分文件：payload 本身就是整块 JSON，
/// 文件读写比数据库直接，也省掉 Schema 迁移。
struct FileStore {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.root = base.appendingPathComponent("Frthink", isDirectory: true)
        }
        try? FileManager.default.createDirectory(
            at: self.root.appendingPathComponent("projects", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    // MARK: - 编码器

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - 路径

    func projectDirectory(_ id: String) -> URL {
        root
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    private func file(_ name: String, in projectID: String) -> URL {
        projectDirectory(projectID).appendingPathComponent(name)
    }

    // MARK: - 原子写

    /// 先写临时文件再 `replaceItemAt`，避免中途崩溃留下半个 JSON。
    ///
    /// 临时文件名带 UUID：会话自动保存和导入写盘可能同时写同一个目标
    /// （例如覆盖导入时旧会话的挂起保存），固定名会让两个写者互相覆盖临时文件，
    /// 一路传成「文件不存在」或写到对方的内容。
    func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let tmp = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: - 导入暂存

    /// 导入时先写这一份暂存根目录，成功后才整体换进 `projects/`。
    ///
    /// 直接往正式目录写，任何一步失败都会让「恢复存档」变成「删掉旧书再留一堆
    /// 半个文件」；覆盖导入尤其致命，旧稿已经没了，新稿又没写完。
    func makeImportStagingRoot() throws -> URL {
        let root = self.root
            .appendingPathComponent("staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 用暂存目录整体替换（或新建）一个书项目目录。
    ///
    /// `replaceItemAt` 在同一卷上做目录级替换，失败时旧目录仍在；文件系统不支持
    /// 目录替换时退回「旧目录改名备份 → 新目录改名到位 → 删备份」，后两步失败会把
    /// 旧目录改回来。
    func commitStagedProject(projectID: String, stagingRoot: URL) throws {
        let staged = FileStore(root: stagingRoot).projectDirectory(projectID)
        let destination = projectDirectory(projectID)
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        guard FileManager.default.fileExists(atPath: destination.path) else {
            try FileManager.default.moveItem(at: staged, to: destination)
            return
        }
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } catch {
            let backup = parent.appendingPathComponent(
                ".\(projectID).\(UUID().uuidString).bak",
                isDirectory: true
            )
            try FileManager.default.moveItem(at: destination, to: backup)
            do {
                try FileManager.default.moveItem(at: staged, to: destination)
            } catch {
                try? FileManager.default.moveItem(at: backup, to: destination)
                throw error
            }
            try? FileManager.default.removeItem(at: backup)
        }
    }

    /// 导入结束（成功、失败或取消）都要清掉暂存目录。
    func discardImportStagingRoot(_ stagingRoot: URL) {
        try? FileManager.default.removeItem(at: stagingRoot)
    }

    // MARK: - 加密读写

    /// 读一个加密文件；没有魔数的旧明文按原样返回并顺手加密写回。
    ///
    /// 返回 nil 表示文件不存在或密文损坏，调用方按空值处理。
    private func readEncrypted(_ url: URL) -> Data? {
        guard let fileData = try? Data(contentsOf: url) else { return nil }
        if PayloadCipher.isEncrypted(fileData) {
            return try? PayloadCipher.open(fileData)
        }
        if let sealed = try? PayloadCipher.seal(fileData) {
            try? write(sealed, to: url)
        }
        return fileData
    }

    private func writeEncrypted(_ data: Data, to url: URL) throws {
        try write(try PayloadCipher.seal(data), to: url)
    }

    // MARK: - 项目

    func loadProjects() -> [Project] {
        let dir = root.appendingPathComponent("projects", isDirectory: true)
        guard let ids = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var out: [Project] = []
        for id in ids {
            let url = file("project.json", in: id)
            guard let data = try? Data(contentsOf: url),
                  let p = try? decoder.decode(Project.self, from: data)
            else { continue }
            out.append(p)
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    func saveProject(_ project: Project) throws {
        let data = try encoder.encode(project)
        try write(data, to: file("project.json", in: project.id))
    }

    func deleteProject(_ id: String) throws {
        try FileManager.default.removeItem(at: projectDirectory(id))
    }

    // MARK: - 负载

    /// payload 的读取结果。缺失和损坏必须分开：损坏时不能当空书再覆盖写回。
    enum PayloadLoadState {
        case missing
        case corrupted
        case loaded(ProjectPayload)
    }

    func loadPayloadState(_ projectID: String) -> PayloadLoadState {
        let url = file("payload.json", in: projectID)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let plain = readEncrypted(url),
              let payload = try? decoder.decode(ProjectPayload.self, from: plain)
        else { return .corrupted }

        // 正文独立成文件后，payload.json 里的 manuscript 只是旧数据或兜底。
        // `body.meta.json` 只含长度和章节，打开书不需要解密整份正文。
        if let meta = loadBodyMeta(projectID) {
            // 上一版只有 body.json、meta 里没有页信息：顺手迁成页文件。
            if meta.pageCount == nil, let legacy = loadLegacyBody(projectID) {
                try? saveBody(
                    legacy.text,
                    chapters: legacy.chapters,
                    projectID: projectID
                )
            }
            var merged = payload
            merged.manuscript = ""
            merged.chapters = meta.chapters
            return .loaded(merged)
        }
        if let body = loadLegacyBody(projectID) {
            // 旧版单个 body.json：迁成页文件；失败时退回整份正文。
            do {
                try saveBody(body.text, chapters: body.chapters, projectID: projectID)
                var merged = payload
                merged.manuscript = ""
                merged.chapters = body.chapters
                return .loaded(merged)
            } catch {
                var merged = payload
                merged.manuscript = body.text
                merged.chapters = body.chapters
                return .loaded(merged)
            }
        }
        return .loaded(payload)
    }

    func loadPayload(_ projectID: String) -> ProjectPayload {
        if case .loaded(let payload) = loadPayloadState(projectID) {
            return payload
        }
        return ProjectPayload()
    }

    func savePayload(_ payload: ProjectPayload, projectID: String) throws {
        try writeEncrypted(
            try encoder.encode(payload),
            to: file("payload.json", in: projectID)
        )
    }

    /// 导出用：把正文密文也读进来。日常打开书不要用它。
    func loadFullPayload(_ projectID: String) -> ProjectPayload {
        var payload = loadPayload(projectID)
        if let body = loadBody(projectID) {
            payload.manuscript = body.text
            payload.chapters = body.chapters
        }
        return payload
    }

    /// 导出用：拼回全文并校验页数与 UTF-16 长度。
    ///
    /// `loadFullPayload` 缺页时只返回 `nil` 再静默留下空正文；导出如果照此打包，
    /// 用户会拿到一份「成功」但没有正文的备份。这里把缺页和长度不符报出来。
    func loadVerifiedFullPayload(_ projectID: String) throws -> ProjectPayload {
        var payload = loadPayload(projectID)
        guard let meta = loadBodyMeta(projectID),
              let count = meta.pageCount,
              count > 0
        else {
            if let legacy = loadLegacyBody(projectID) {
                payload.manuscript = legacy.text
                payload.chapters = legacy.chapters
            }
            return payload
        }
        var text = ""
        text.reserveCapacity(meta.utf16Length)
        for index in 0..<count {
            guard let page = loadBodyPage(projectID, index: index) else {
                throw BodyLoadError.missingPage(index)
            }
            text += page
        }
        let actualLength = (text as NSString).length
        guard actualLength == meta.utf16Length else {
            throw BodyLoadError.lengthMismatch(
                expected: meta.utf16Length,
                actual: actualLength
            )
        }
        payload.manuscript = text
        payload.chapters = meta.chapters
        return payload
    }

    enum BodyLoadError: LocalizedError {
        case missingPage(Int)
        case lengthMismatch(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .missingPage(let index):
                return "正文第 \(index + 1) 页文件缺失，无法导出完整备份。"
            case .lengthMismatch(let expected, let actual):
                return "正文拼回长度不一致（应为 \(expected)，实际 \(actual)），无法导出完整备份。"
            }
        }
    }

    // MARK: - 正文

    /// 单页 UTF-16 长度。56 万字约 18 页，编辑器/阅读器只需解密用到的页。
    static let bodyPageSize = 32_000

    private func bodyPagesDirectory(_ projectID: String) -> URL {
        projectDirectory(projectID).appendingPathComponent("body.pages", isDirectory: true)
    }

    private func bodyPageURL(_ projectID: String, index: Int) -> URL {
        bodyPagesDirectory(projectID)
            .appendingPathComponent(String(format: "%04d.bin", index))
    }

    /// 页边界不能切在代理对中间。
    private static func pageRanges(_ text: String) -> [NSRange] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location < ns.length {
            var length = min(bodyPageSize, ns.length - location)
            if location + length < ns.length, length > 1 {
                let next = ns.character(at: location + length)
                if next >= 0xDC00, next <= 0xDFFF {
                    length -= 1
                }
            }
            guard length > 0 else { break }
            ranges.append(NSRange(location: location, length: length))
            location += length
        }
        return ranges
    }

    /// 旧版单文件正文，仅用于迁移。
    private func loadLegacyBody(_ projectID: String) -> BodyDocument? {
        guard let plain = readEncrypted(file("body.json", in: projectID)) else {
            return nil
        }
        return try? decoder.decode(BodyDocument.self, from: plain)
    }

    func loadBodyPage(_ projectID: String, index: Int) -> String? {
        guard let data = readEncrypted(bodyPageURL(projectID, index: index)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// 编辑器/导出用：把所有页拼回完整正文。打开书不要调用。
    func loadBody(_ projectID: String) -> BodyDocument? {
        if let meta = loadBodyMeta(projectID), let count = meta.pageCount, count > 0 {
            var text = ""
            text.reserveCapacity(meta.utf16Length)
            for index in 0..<count {
                guard let page = loadBodyPage(projectID, index: index) else {
                    return loadLegacyBody(projectID)
                }
                text += page
            }
            return BodyDocument(text: text, chapters: meta.chapters)
        }
        return loadLegacyBody(projectID)
    }

    func saveBody(
        _ text: String,
        chapters: [Chapter],
        projectID: String,
        changedFromPage: Int = 0
    ) throws {
        let ns = text as NSString
        let ranges = Self.pageRanges(text)
        let directory = bodyPagesDirectory(projectID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let start = max(0, min(changedFromPage, ranges.count))
        for index in start..<ranges.count {
            try writeEncrypted(
                Data(ns.substring(with: ranges[index]).utf8),
                to: bodyPageURL(projectID, index: index)
            )
        }
        // 删掉上次多出来的页。
        let existing = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )) ?? []
        let keep = Set(ranges.indices.map { String(format: "%04d.bin", $0) })
        for name in existing where !keep.contains(name) {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(name)
            )
        }

        let meta = BodyMeta(
            characterCount: text.count,
            utf16Length: ns.length,
            chapters: chapters,
            blocks: BodyBlockIndex.blocks(from: text),
            pageSize: Self.bodyPageSize,
            pageCount: ranges.count
        )
        try writeEncrypted(
            try encoder.encode(meta),
            to: file("body.meta.json", in: projectID)
        )
        // 元数据写成功后再删旧单文件，迁移失败还能回退。
        try? FileManager.default.removeItem(at: file("body.json", in: projectID))
    }

    /// 只重写正文尾部窗口：窗口从整页边界开始，窗口之前的页原样保留。
    ///
    /// 编辑器只持有这一段，保存时不必把整本书拼进内存。
    func saveBodyWindow(
        _ text: String,
        startPage: Int,
        windowStart: Int,
        prefixCharacterCount: Int,
        chapters: [Chapter],
        projectID: String
    ) throws {
        let ns = text as NSString
        let ranges = Self.pageRanges(text)
        let directory = bodyPagesDirectory(projectID)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for index in ranges.indices {
            try writeEncrypted(
                Data(ns.substring(with: ranges[index]).utf8),
                to: bodyPageURL(projectID, index: startPage + index)
            )
        }
        let lastPage = startPage + ranges.count
        let existing = (try? FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )) ?? []
        for name in existing {
            guard let page = Int(name.prefix(4)), page >= lastPage else { continue }
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(name)
            )
        }

        let oldMeta = loadBodyMeta(projectID)
        var prefixBlocks = (oldMeta?.blocks ?? []).filter { $0.start < windowStart }
        for index in prefixBlocks.indices {
            let limit = windowStart - prefixBlocks[index].start
            prefixBlocks[index].length = min(prefixBlocks[index].length, max(0, limit))
        }
        prefixBlocks.removeAll { $0.length <= 0 }
        let windowBlocks = BodyBlockIndex.blocks(from: text).map {
            BodyBlock(start: $0.start + windowStart, length: $0.length)
        }
        let meta = BodyMeta(
            characterCount: prefixCharacterCount + text.count,
            utf16Length: windowStart + ns.length,
            chapters: chapters,
            blocks: prefixBlocks + windowBlocks,
            pageSize: Self.bodyPageSize,
            pageCount: lastPage
        )
        try writeEncrypted(
            try encoder.encode(meta),
            to: file("body.meta.json", in: projectID)
        )
        try? FileManager.default.removeItem(at: file("body.json", in: projectID))
    }

    struct BodyDocument: Codable {
        var text: String
        var chapters: [Chapter]
    }

    /// 正文的轻量元数据：打开书时只读它，不碰正文密文。
    struct BodyMeta: Codable {
        var characterCount: Int
        var utf16Length: Int
        var chapters: [Chapter]
        /// 块索引，阅读页按块取页用；旧数据没有，回退全文切块。
        var blocks: [BodyBlock]?
        var pageSize: Int?
        var pageCount: Int?
    }

    func loadBodyMeta(_ projectID: String) -> BodyMeta? {
        guard let plain = readEncrypted(file("body.meta.json", in: projectID)) else {
            return nil
        }
        return try? decoder.decode(BodyMeta.self, from: plain)
    }

    // MARK: - 原文

    func loadSource(_ projectID: String) -> String {
        guard let plain = readEncrypted(file("source.json", in: projectID)),
              let s = try? decoder.decode(SourceDocument.self, from: plain)
        else { return "" }
        return s.text
    }

    func saveSource(_ text: String, projectID: String) throws {
        try writeEncrypted(
            try encoder.encode(SourceDocument(text: text)),
            to: file("source.json", in: projectID)
        )
    }

    struct SourceDocument: Codable {
        var text: String
    }

    // MARK: - 译文

    func loadTranslations(_ projectID: String) -> [TranslationSegment] {
        guard let plain = readEncrypted(file("translations.json", in: projectID)),
              let list = try? decoder.decode([TranslationSegment].self, from: plain)
        else { return [] }
        return list.sorted { $0.segment < $1.segment }
    }

    func saveTranslations(_ list: [TranslationSegment], projectID: String) throws {
        try writeEncrypted(
            try encoder.encode(list),
            to: file("translations.json", in: projectID)
        )
    }

    // MARK: - 设置

    func loadSettings() -> AppSettings {
        let url = root.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let s = try? decoder.decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return s
    }

    func saveSettings(_ settings: AppSettings) throws {
        let data = try encoder.encode(settings)
        try write(data, to: root.appendingPathComponent("settings.json"))
    }
}

/// 文本哈希。Android 端 `contentHash` / `sourceHash` 用于判断内容是否变化，
/// 译文分段靠它做缓存命中；`sourceSha256` 字段要求完整 SHA-256。
enum ContentHash {
    /// 完整 SHA-256 的小写十六进制。CryptoKit 实现，不再手写短哈希。
    static func of(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
