import Foundation

/// `.frthink` 存档：信封 + gzip/base64 载荷，以及导入导出用的数据结构。
///
/// 外层格式必须和 Android 互认（`FrthinkArchiveEnvelope`，`I1\M` / `I1\O`）：
/// ```
/// {
///   "format": "writing-workspace-backup" | "frthink-full-backup",
///   "version": 1,
///   "compression": "gzip+base64",
///   "createdAt": <epoch 毫秒>,
///   "payload": "<base64(gzip(utf8(json)))>"
/// }
/// ```
/// gzip 容器由 `FrthinkGzip` 自行实现：`Compression` 框架的 `COMPRESSION_ZLIB` 仅
/// 输出裸 DEFLATE 流（RFC 1951），`NSData.compressed(using: .zlib)` 输出的是 zlib 格式
/// （RFC 1950），两者均不可直接作为 gzip（RFC 1952）使用。Android 端导入依赖
/// `GZIPInputStream`、导出依赖 `GZIPOutputStream`，因此头部与尾部必须按 RFC 1952 规范补齐。
///
/// 内层载荷为 iOS 本地数据结构：Android 的 `ProjectSnapshot` 为包含 56 个字段的内部
/// 结构，与 `ProjectPayload` 并非一一对应（参见 spec 03 §5.1），此处针对可对应的数据
/// 字段进行映射（`ArchivedSnapshot`），跨端兼容仅保证「信封 + gzip + 正文」可完整读回。
enum FrthinkArchive {

    // MARK: - 常量

    /// 单个 `.frthink` 文件的字节上限：300 MiB（原版判定 `n < 314572801`）。
    static let maxBytes = 314_572_800
    /// 信封版本，只接受 1。
    static let envelopeVersion = 1
    /// 内层载荷的结构版本。
    static let payloadVersion = 1
    /// 唯一接受的压缩标记。
    static let compressionName = "gzip+base64"
    /// 书项目存档的 `format`。
    static let projectFormat = "writing-workspace-backup"
    /// 全量存档的 `format`。
    static let fullFormat = "frthink-full-backup"
    /// 导出的文件后缀。
    static let fileExtension = "frthink"

    /// 存档粒度。两个方向的校验规则只在文案和 format 上不同。
    enum Kind {
        case project
        case full

        var isFull: Bool { self == .full }
    }

    /// 当前时间戳（epoch 毫秒）。信封里的 `createdAt` 用这个单位。
    static var nowMillis: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// 归档 JSON 里的日期串，与 `jsonEncoder` 的 `.iso8601` 保持一致。
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - 信封

    /// 最外层信封，字段命名严格对齐原版（`I1\M`）。
    struct Envelope: Codable {
        var format: String
        var version: Int
        var compression: String
        /// epoch 毫秒。
        var createdAt: Int64
        /// `base64(gzip(utf8(json)))`。
        var payload: String

        init(format: String, createdAt: Int64, payload: String) {
            self.format = format
            self.version = FrthinkArchive.envelopeVersion
            self.compression = FrthinkArchive.compressionName
            self.createdAt = createdAt
            self.payload = payload
        }
    }

    // MARK: - 载荷

    /// 书项目存档载荷（`ProjectArchivePayload`，`I1\K0`）。
    struct ProjectArchivePayload: Codable {
        var formatVersion: Int
        var createdAt: Int64
        var projects: [ProjectBackup]

        init(projects: [ProjectBackup], createdAt: Int64 = FrthinkArchive.nowMillis) {
            self.formatVersion = FrthinkArchive.payloadVersion
            self.createdAt = createdAt
            self.projects = projects
        }
    }

    /// 单本书的存档内容（字段对齐 `I1\O0`）。
    ///
    /// iOS 增加 `sourceText` 字段：Android 端原文存储于 source blob 中按哈希去重，
    /// iOS 端直接内联完整原文，省略 blob 表结构。
    struct ProjectBackup: Codable {
        var formatVersion: Int
        var createdAt: Int64
        var projectId: String
        var title: String
        var synopsis: String
        var snapshot: ArchivedSnapshot
        var sourceText: String
        var translations: [TranslationSegment]
        var universeEntries: [UniverseEntry]
        /// Android 端叫 `coverImageBase64`；iOS 的 `Project.coverImagePayload` 同义。
        var coverImageBase64: String
        var branchRootId: String
        var branchOrder: Int
        /// epoch 毫秒，0 表示不在回收站。
        var trashedAt: Int64

        private enum CodingKeys: String, CodingKey {
            case formatVersion, createdAt, projectId, title, synopsis, snapshot
            case sourceText, translations, universeEntries, coverImageBase64
            case branchRootId, branchOrder, trashedAt
        }

        init(
            project: Project,
            payload: ProjectPayload,
            sourceText: String,
            translations: [TranslationSegment],
            universeEntries: [UniverseEntry]
        ) {
            self.formatVersion = FrthinkArchive.payloadVersion
            self.createdAt = FrthinkArchive.nowMillis
            self.projectId = project.id
            self.title = project.title
            self.synopsis = project.synopsis
            let availableUniverseIDs = Set(universeEntries.map(\.id))
            var filteredPayload = payload
            filteredPayload.enabledUniverseEntryIDs = payload.enabledUniverseEntryIDs.filter {
                availableUniverseIDs.contains($0)
            }
            self.snapshot = ArchivedSnapshot(payload: filteredPayload, sourceText: sourceText)
            self.sourceText = sourceText
            self.translations = translations
            self.universeEntries = universeEntries
            self.coverImageBase64 = project.coverImagePayload ?? ""
            self.branchRootId = project.branchRootId
            self.branchOrder = project.branchOrder
            self.trashedAt = project.trashedAt.map {
                Int64($0.timeIntervalSince1970 * 1000)
            } ?? 0
        }

        /// 容错解码：缺失字段使用默认值补充，异常字段（例如 Android 端译文记录结构差异）
        /// 仅忽略该项，避免整体解码失败。
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = (try? c.decode(Int.self, forKey: .formatVersion)) ?? 1
            createdAt = (try? c.decode(Int64.self, forKey: .createdAt)) ?? 0
            let backupProjectId = (try? c.decode(String.self, forKey: .projectId)) ?? ""
            projectId = backupProjectId
            title = (try? c.decode(String.self, forKey: .title)) ?? ""
            synopsis = (try? c.decode(String.self, forKey: .synopsis)) ?? ""
            // snapshot 为书稿核心数据：解码失败必须终止整部作品导入，禁止静默替换为空快照，
            // 避免覆盖导入时以空内容覆盖本地同名书稿。
            guard let decodedSnapshot = try? c.decode(
                ArchivedSnapshot.self,
                forKey: .snapshot
            ) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .snapshot,
                    in: c,
                    debugDescription: "snapshot 缺失或无法解析"
                )
            }
            snapshot = decodedSnapshot
            // 原版没有顶层 sourceText：原文在 snapshot.localSourceDocuments 里，
            // 已经由 ArchivedSnapshot 解出来了，这里回填。
            let ownSource = (try? c.decode(String.self, forKey: .sourceText)) ?? ""
            sourceText = ownSource.isEmpty ? snapshot.sourceText : ownSource
            translations = {
                let iosShape =
                    (try? c.decode([TranslationSegment].self, forKey: .translations)) ?? []
                if !iosShape.isEmpty {
                    // iOS 自己的存档带 project；Android 的 TranslationRecord 没有
                    // owner/project，按所属项目补齐，否则多本书会撞主键被判重复。
                    return iosShape.map { segment in
                        var stamped = segment
                        if stamped.project.isEmpty { stamped.project = backupProjectId }
                        return stamped
                    }
                }
                // Android 存档的 translations 是 TranslationRecord 列表
                // （target/sourceHash/index/text/chunkHash），没有 owner/project；
                // 解成 iOS 模型时按所属项目补 project，owner 留空由 restore 重打。
                let androidShape =
                    (try? c.decode([ArchivedTranslationJSON].self, forKey: .translations)) ?? []
                return androidShape.compactMap { raw in
                    guard let index = raw.index,
                          let text = raw.text,
                          !text.isEmpty,
                          let sourceHash = raw.sourceHash,
                          !sourceHash.isEmpty
                    else { return nil }
                    let rawTarget = raw.target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let target = rawTarget.isEmpty ? TranslationSegment.defaultTarget : rawTarget
                    return TranslationSegment(
                        owner: "",
                        project: backupProjectId,
                        target: target,
                        sourceHash: sourceHash,
                        segment: index,
                        payload: text
                    )
                }
            }()
            // Android 的项目级共享世界书是 WorldbookEntry（正文键是 `content`），
            // iOS 自己写的是 UniverseEntry（`body`/`kind`）。两套形状都读，
            // 只解出一堆空 body 时按 Android 形状重映射。
            let iosEntries =
                (try? c.decode([UniverseEntry].self, forKey: .universeEntries)) ?? []
            let rawBooks =
                (try? c.decode([ArchivedUniverseJSON].self, forKey: .universeEntries)) ?? []
            if !rawBooks.isEmpty, iosEntries.allSatisfy({ $0.body.isEmpty }) {
                universeEntries = rawBooks.compactMap { raw in
                    guard let title = raw.title, !title.isEmpty else { return nil }
                    let content = raw.content ?? ""
                    guard !content.isEmpty else { return nil }
                    return UniverseEntry(
                        id: raw.id ?? UUID().uuidString,
                        title: title,
                        body: content,
                        kind: .worldbook,
                        enabled: raw.enabled ?? true,
                        updatedAt: Date()
                    )
                }
            } else {
                universeEntries = iosEntries
            }
            coverImageBase64 = (try? c.decode(String.self, forKey: .coverImageBase64)) ?? ""
            branchRootId = (try? c.decode(String.self, forKey: .branchRootId)) ?? ""
            branchOrder = (try? c.decode(Int.self, forKey: .branchOrder)) ?? 0
            trashedAt = (try? c.decode(Int64.self, forKey: .trashedAt)) ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(formatVersion, forKey: .formatVersion)
            try c.encode(createdAt, forKey: .createdAt)
            try c.encode(projectId, forKey: .projectId)
            try c.encode(title, forKey: .title)
            try c.encode(synopsis, forKey: .synopsis)
            try c.encode(snapshot, forKey: .snapshot)
            try c.encode(sourceText, forKey: .sourceText)
            try c.encode(
                translations.map(ArchivedTranslationEntry.init),
                forKey: .translations
            )
            // 同时写 iOS 的 body/kind 和 Android 的 content：两端各取所需。
            try c.encode(
                universeEntries.map { entry in
                    ArchivedUniverseEntry(
                        id: entry.id,
                        title: entry.title,
                        body: entry.body,
                        kind: entry.kind.rawValue,
                        content: entry.body,
                        keywords: "",
                        enabled: entry.enabled,
                        updatedAt: FrthinkArchive.iso8601.string(from: entry.updatedAt)
                    )
                },
                forKey: .universeEntries
            )
            try c.encode(coverImageBase64, forKey: .coverImageBase64)
            try c.encode(branchRootId, forKey: .branchRootId)
            try c.encode(branchOrder, forKey: .branchOrder)
            try c.encode(trashedAt, forKey: .trashedAt)
        }
    }


    private struct ArchivedUniverseJSON: Decodable {
        var id: String?
        var title: String?
        var content: String?
        var enabled: Bool?
        var keywords: String?
        var dynamic: Bool?
    }

    /// 导出时的共享世界书：iOS 与 Android 字段同时存在。
    private struct ArchivedUniverseEntry: Encodable {
        var id: String
        var title: String
        var body: String
        var kind: String
        var content: String
        var keywords: String
        var enabled: Bool
        var updatedAt: String
    }

    /// Android 存档里的 `TranslationRecord`（12 字段里只映射 iOS 用得上的）。
    private struct ArchivedTranslationJSON: Decodable {
        var target: String?
        var sourceHash: String?
        var index: Int?
        var chunkHash: String?
        var text: String?
        var model: String?
    }

    /// 导出时的译文条目：同时写 iOS 的 `segment`/`payload` 与 Android 的
    /// `index`/`text`，两端都能直接读回，不会把译文丢在跨端迁移路上。
    private struct ArchivedTranslationEntry: Encodable {
        var id: String
        var owner: String
        var project: String
        var target: String
        var sourceHash: String
        var segment: Int
        var payload: String
        var updatedAt: Date
        var index: Int
        var chunkHash: String
        var text: String
        var model: String

        init(_ segment: TranslationSegment) {
            self.id = segment.id
            self.owner = segment.owner
            self.project = segment.project
            self.target = segment.target
            self.sourceHash = segment.sourceHash
            self.segment = segment.segment
            self.payload = segment.payload
            self.updatedAt = segment.updatedAt
            self.index = segment.segment
            self.chunkHash = ContentHash.of(segment.payload)
            self.text = segment.payload
            self.model = ""
        }
    }


    // MARK: 编解码


    /// 任意 JSON 的透传包装。
    struct AnyCodable: Codable {
        let raw: Any

        init(from decoder: Decoder) throws {
            let single = try decoder.singleValueContainer()
            if let v = try? single.decode([String: AnyCodable].self) {
                raw = v.mapValues(\.raw)
            } else if let v = try? single.decode([AnyCodable].self) {
                raw = v.map(\.raw)
            } else if let v = try? single.decode(String.self) {
                raw = v
            } else if let v = try? single.decode(Int.self) {
                raw = v
            } else if let v = try? single.decode(Double.self) {
                raw = v
            } else if let v = try? single.decode(Bool.self) {
                raw = v
            } else if single.decodeNil() {
                raw = NSNull()
            } else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "不支持的 JSON 值"
                )
            }
        }

        init(raw: Any) { self.raw = raw }

        func encode(to encoder: Encoder) throws {
            var single = encoder.singleValueContainer()
            switch raw {
            case let v as [String: Any]:
                try single.encode(v.mapValues { AnyCodable(raw: $0) })
            case let v as [Any]:
                try single.encode(v.map { AnyCodable(raw: $0) })
            case let v as String:
                try single.encode(v)
            case let v as Int:
                try single.encode(v)
            case let v as Int64:
                try single.encode(v)
            case let v as Double:
                try single.encode(v)
            case let v as Bool:
                try single.encode(v)
            default:
                try single.encodeNil()
            }
        }
    }

    // MARK: - 编解码器

    /// 内部日期统一走 ISO8601，和 `FileStore` 落盘时一致。
    static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 将 `DecodingError` 转换为用户可读的提示信息：明确指出缺失的具体键名或类型不匹配的字段。
    ///
    /// 导入失败时避免只报「备份内容损坏」导致用户无法排查，供 `corruptedDetail` 拼接具体字段原因。
    static func decodeDetail(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return error.localizedDescription
        }
        func path(_ codingPath: [CodingKey], appending key: String? = nil) -> String {
            var keys = codingPath.map(\.stringValue)
            if let key { keys.append(key) }
            return keys.isEmpty ? "根 JSON" : keys.joined(separator: ".")
        }
        switch decoding {
        case .keyNotFound(let key, let context):
            return "缺少字段 \(path(context.codingPath, appending: key.stringValue))"
        case .typeMismatch(let type, let context):
            return "字段 \(path(context.codingPath)) 的类型不是 \(type)"
        case .valueNotFound(let type, let context):
            return "字段 \(path(context.codingPath)) 是 null，应为 \(type)"
        case .dataCorrupted(let context):
            return "\(path(context.codingPath)) 无法解析：\(context.debugDescription)"
        @unknown default:
            return decoding.localizedDescription
        }
    }
}
