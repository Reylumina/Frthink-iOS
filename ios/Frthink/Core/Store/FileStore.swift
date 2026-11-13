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
            // 备份放 staging/ 而不是 projects/：projects/ 下任何带 project.json 的
            // 目录都会被 `loadProjects()` 当成一本书，`.bak` 删除失败时书架会出现
            // 同 id 的重复项。staging/ 不参与书架扫描。
            let backup = root
                .appendingPathComponent("staging", isDirectory: true)
                .appendingPathComponent(
                    ".\(projectID).\(UUID().uuidString).bak",
                    isDirectory: true
                )
            try FileManager.default.createDirectory(
                at: backup.deletingLastPathComponent(),
                withIntermediateDirectories: true
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

    private enum EncryptedReadResult {
        case missing
        case loaded(Data)
        case unreadable
    }

    private func readEncryptedResult(_ url: URL) -> EncryptedReadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let fileData = try? Data(contentsOf: url) else {
            return .unreadable
        }
        if PayloadCipher.isEncrypted(fileData) {
            guard let plain = try? PayloadCipher.open(fileData) else {
                return .unreadable
            }
            return .loaded(plain)
        }
        if let sealed = try? PayloadCipher.seal(fileData) {
            try? write(sealed, to: url)
        }
        return .loaded(fileData)
    }

    /// 读一个加密文件；没有魔数的旧明文按原样返回并顺手加密写回。
    ///
    /// 返回 nil 表示文件不存在或密文损坏，调用方按空值处理。
    private func readEncrypted(_ url: URL) -> Data? {
        if case .loaded(let data) = readEncryptedResult(url) {
            return data
        }
        return nil
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
        // 跳过点开头的条目：`commitStagedProject` 的回退备份目录里也有
        // project.json，不跳过会在书架里冒出同 id 的重复书。
        for id in ids where !id.hasPrefix(".") {
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
        let state = loadPayloadState(projectID)
        var payload: ProjectPayload
        switch state {
        case .loaded(let loaded):
            payload = loaded
        case .missing:
            throw BodyLoadError.payloadUnavailable("payload.json 不存在")
        case .corrupted:
            throw BodyLoadError.payloadUnavailable("payload.json 无法解密或解析")
        }
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
        case payloadUnavailable(String)
        case missingPage(Int)
        case lengthMismatch(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .payloadUnavailable(let detail):
                return "对话与世界数据不可用（\(detail)），无法导出完整备份。"
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

    enum BodyLoadResult {
        case loaded(BodyDocument)
        case missing
        case corrupted
    }

    /// 区分「正文尚未创建」与「页文件或元信息损坏/无法解密」，避免用空串覆写原稿。
    func loadBodyResult(_ projectID: String) -> BodyLoadResult {
        switch readEncryptedResult(file("body.meta.json", in: projectID)) {
        case .unreadable:
            return .corrupted
        case .loaded(let metaPlain):
            guard let meta = try? decoder.decode(BodyMeta.self, from: metaPlain) else {
                return .corrupted
            }
            if let count = meta.pageCount, count > 0 {
                var text = ""
                text.reserveCapacity(meta.utf16Length)
                for index in 0..<count {
                    switch readEncryptedResult(bodyPageURL(projectID, index: index)) {
                    case .loaded(let data):
                        guard let page = String(data: data, encoding: .utf8) else {
                            return .corrupted
                        }
                        text += page
                    case .missing, .unreadable:
                        return .corrupted
                    }
                }
                return .loaded(BodyDocument(text: text, chapters: meta.chapters))
            }
        case .missing:
            break
        }

        switch readEncryptedResult(file("body.json", in: projectID)) {
        case .missing:
            return .missing
        case .unreadable:
            return .corrupted
        case .loaded(let plain):
            guard let doc = try? decoder.decode(BodyDocument.self, from: plain) else {
                return .corrupted
            }
            return .loaded(doc)
        }
    }

    /// 编辑器/导出用：把所有页拼回完整正文。打开书不要调用。
    func loadBody(_ projectID: String) -> BodyDocument? {
        if case .loaded(let doc) = loadBodyResult(projectID) {
            return doc
        }
        return nil
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
              let decoded = try? decoder.decode(AppSettings.self, from: data)
        else { return AppSettings() }
        // `providers` 在 AppSettings 里是整组解码：只要一条坏掉（字段类型变化、
        // 手工改档），整份设置仍能解，但供应方会变成空数组，下一次保存又把空列表
        // 写回。读本机设置时逐条补解，至少保住能解的那几条；全坏才补回出厂供应方，
        // ownerID 与其它设置保持原样（换 ownerID 会让译文归属对不上）。
        guard decoded.providers.isEmpty else { return decoded }
        let rawProviders = Self.providerObjects(in: data)
        guard !rawProviders.isEmpty else { return decoded }
        let recovered = rawProviders.compactMap { object -> ProviderSetting? in
            guard let item = try? JSONSerialization.data(withJSONObject: object) else {
                return nil
            }
            return try? decoder.decode(ProviderSetting.self, from: item)
        }
        var settings = decoded
        settings.providers = recovered.isEmpty ? AppSettings().providers : recovered
        if !settings.providers.contains(where: { $0.id == settings.activeProviderID }) {
            settings.activeProviderID = settings.providers.first?.id ?? ""
        }
        return settings
    }

    /// `settings.json` 里 `providers` 数组的原始元素；结构不对时返回空。
    private static func providerObjects(in data: Data) -> [[String: Any]] {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let root = json as? [String: Any],
              let raw = root["providers"] as? [Any]
        else { return [] }
        return raw.compactMap { $0 as? [String: Any] }
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

/// 协调读取文件选择器提供的安全作用域 URL，读取前校验体积上限。
enum SecurityScopedFileReader {
    static let bytesPerMiB = 1_048_576

    static func read(
        _ url: URL,
        maxBytes: Int,
        tooLargeError: (Int) -> Error
    ) throws -> Data {
        var coordinationError: NSError?
        var readResult: Result<Data, Error>?
        NSFileCoordinator().coordinate(
            readingItemAt: url,
            options: [],
            error: &coordinationError
        ) { readableURL in
            readResult = Result {
                try readBounded(readableURL, maxBytes: maxBytes, tooLargeError: tooLargeError)
            }
        }
        if let readResult {
            return try readResult.get()
        }
        if let coordinationError {
            throw coordinationError
        }
        return try readBounded(url, maxBytes: maxBytes, tooLargeError: tooLargeError)
    }

    private static func readBounded(
        _ url: URL,
        maxBytes: Int,
        tooLargeError: (Int) -> Error
    ) throws -> Data {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maxBytes {
            throw tooLargeError(size)
        }
        return try Data(contentsOf: url)
    }
}
