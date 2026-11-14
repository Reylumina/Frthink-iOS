import Foundation

extension FrthinkArchive {
    /// 全量存档载荷（`FullFrthinkBackupPayload`，`I1\S`）。
    ///
    /// `credentialSecrets` 故意不实现：API Key 只在系统钥匙串里，导出永远不带
    /// （原版界面文案就是「不含 API 信息」）。
    struct FullBackupPayload: Codable {
        var formatVersion: Int
        var createdAt: Int64
        var settings: AppSettings
        var projects: [ProjectBackup]
        /// 原版字段叫 `activeProjectId`；iOS 的当前书由根视图持有，导出时留空。
        var activeProjectID: String
        /// 存档 `settings` 对象里实际出现的键（iOS 属性名与 Android 原版键名都算）。
        ///
        /// 只给 `mergeSettings` 用：Android 备份没有 iOS 独有的流式开关、上下文
        /// 窗口、累计用量等键，解出的数据为默认值；合并时缺失键保留本地配置，
        /// 不能拿这些默认值把用户设置重置。不写进存档（不在 CodingKeys 里）。
        var settingsKeyNames: Set<String> = []

        private enum CodingKeys: String, CodingKey {
            case formatVersion, createdAt, settings, projects
            case corpusLibrary
            case activeProjectID = "activeProjectId"
        }

        init(
            settings: AppSettings,
            projects: [ProjectBackup],
            activeProjectID: String = ""
        ) {
            self.formatVersion = FrthinkArchive.payloadVersion
            self.createdAt = FrthinkArchive.nowMillis
            self.settings = settings
            self.projects = projects
            self.activeProjectID = activeProjectID
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = (try? c.decode(Int.self, forKey: .formatVersion)) ?? 1
            createdAt = (try? c.decode(Int64.self, forKey: .createdAt)) ?? 0
            // settings / projects 是必填：原版的全量导入也接受
            // `writing-workspace-backup` 这个 format，书项目存档正好也叫这个，
            // 靠「有没有 settings」把两者分开，避免把本机设置清空。
            // 缺键必须抛给 decodeFullBackup，不能在这里补 AppSettings()，
            // 否则书项目存档会被当成全量备份，本机供应方与 Keychain 引用一起丢。
            guard c.contains(.settings),
                  (try? c.decodeNil(forKey: .settings)) != true else {
                throw DecodingError.keyNotFound(
                    CodingKeys.settings,
                    DecodingError.Context(
                        codingPath: c.codingPath,
                        debugDescription: "全量备份缺少 settings"
                    )
                )
            }
            // 先按 iOS 自己的结构宽松解，再用原版的真实字段覆盖。
            // Android 的 StoredSettings 键名和 iOS 不同，这一步是能不能把
            // 全局预设 / 技能 / 世界书 / 语料库读进来的关键。
            var merged = (try? c.decode(AppSettings.self, forKey: .settings)) ?? AppSettings()
            if let extra = try? c.decode(SettingsExtra.self, forKey: .settings) {
                extra.apply(to: &merged)
            }
            // 语料库同时兼容顶层 `corpusLibrary`（库 → 集合嵌套）与 `settings` 内嵌列表，顶层优先。
            if let topLevelCorpus = try? c.decode(
                SettingsExtra.CorpusLibraryJSON.self,
                forKey: .corpusLibrary
            ) {
                let libraries = topLevelCorpus.libraries()
                if !libraries.isEmpty {
                    merged.corpusLibraries = libraries
                    if libraries.contains(where: \.enabled) {
                        merged.corpusEnabled = true
                    }
                }
            }
            settings = merged
            // 记下存档里明确出现的设置键。iOS 导出的存档用属性名，Android 备份
            // 用原版键名，`mergeSettings` 两种都认；缺键的字段保留本机值。
            // 解析不出来时留空集合，方向是「什么也不覆盖」，不会写坏设置。
            var keyNames: Set<String> = []
            if let rawSettings = try? c.decode(
                [String: AnyCodable].self,
                forKey: .settings
            ) {
                keyNames = Set(rawSettings.keys)
            }
            if c.contains(.corpusLibrary) { keyNames.insert("corpusLibrary") }
            settingsKeyNames = keyNames
            projects = try c.decode([ProjectBackup].self, forKey: .projects)
            activeProjectID = (try? c.decode(String.self, forKey: .activeProjectID)) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(formatVersion, forKey: .formatVersion)
            try c.encode(createdAt, forKey: .createdAt)
            try c.encode(androidSettingsObject, forKey: .settings)
            try c.encode(projects, forKey: .projects)
            try c.encode(activeProjectID, forKey: .activeProjectID)
            if let corpus = androidCorpusNode {
                try c.encode(corpus, forKey: .corpusLibrary)
            }
        }

        /// 导出同时保留 iOS 键和 Android 读得懂的键；Android 忽略多余键。
        private var androidSettingsObject: AnyCodable {
            let data = (try? FrthinkArchive.jsonEncoder.encode(settings)) ?? Data()
            var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let provider = settings.activeProvider
            dict["globalPreset"] = settings.globalPreset
            dict["aiFlavorRules"] = settings.aiFlavorRules
            dict["worldBuildInstruction"] = settings.worldBuildInstruction
            dict["plotOutlineInstruction"] = settings.plotOutlineInstruction
            dict["imitationInstruction"] = settings.imitationInstruction
            dict["inputBudgetTokens"] = settings.inputBudgetTokens
            dict["outputBudgetTokens"] = settings.reservedOutputTokens
            dict["autoConversationSummary"] = settings.autoConversationSummary
            dict["conversationSummaryThresholdPercent"] =
                settings.conversationSummaryThresholdPercent
            dict["excludeAssistantChatHistory"] = settings.excludeAssistantChatHistory
            dict["primaryModel"] = provider?.resolvedModel ?? ""
            dict["writingModel"] = provider?.resolvedModel ?? ""
            dict["summaryModel"] = settings.summaryModel
            // 原版 `translationModel` 是模型名，不是 iOS 的供应方 id；跟随当前时留空。
            dict["translationModel"] = settings.providers
                .first { $0.id == settings.translationProviderID }?
                .resolvedModel ?? ""
            dict["baseUrl"] = provider?.baseURLForDisplay ?? ""
            dict["apiKey"] = ""
            dict["temperature"] = provider?.temperature ?? 0.2
            dict["maxTokens"] = provider?.maxTokens ?? 4_096
            dict["useStream"] = true
            dict["owner"] = settings.ownerID
            dict["corpusEnabled"] = settings.corpusEnabled
            dict["writingFontSize"] = Int(settings.bodyFontSize)
            dict["readingFontSize"] = Int(settings.bodyFontSize)
            dict["requireApproval"] = false
            dict["supportModel"] = ""
            dict["availableModels"] = [] as [Any]
            dict["modelCapabilities"] = [:] as [String: Any]
            dict["composerDraft"] = ""
            dict["apiConfigured"] = !settings.providers.isEmpty
            dict["promptTokens"] = 0
            dict["completionTokens"] = 0
            dict["credentials"] = [] as [Any]
            dict["activeCredentialId"] = ""
            dict["agents"] = [] as [Any]
            dict["aiFlavorRulesDraft"] = settings.aiFlavorRules
            dict["promptBlocks"] = [] as [Any]
            dict["motionFrameRate"] = "FPS_120"
            dict["skills"] = settings.skills.map {
                [
                    "id": $0.id,
                    "name": $0.name,
                    "prompt": $0.content,
                    "enabled": $0.enabled,
                ]
            }
            dict["worldbooks"] = settings.universeEntries
                .filter { $0.kind == .worldbook }
                .map {
                    FrthinkArchive.androidWorldbookJSON(
                        id: $0.id,
                        title: $0.title,
                        content: $0.body,
                        enabled: $0.enabled
                    )
                }
            return AnyCodable(raw: dict)
        }

        private var androidCorpusNode: AnyCodable? {
            guard !settings.corpusLibraries.isEmpty else { return nil }
            let node: [String: Any] = [
                "id": "ios-corpus",
                "name": "本机语料库",
                "enabled": settings.corpusEnabled,
                "collections": settings.corpusLibraries.map(Self.encodeCorpusLibrary),
            ]
            return AnyCodable(raw: node)
        }

        private static func encodeCorpusLibrary(_ library: CorpusLibrary) -> [String: Any] {
            [
                "id": library.id,
                "name": library.name,
                "enabled": library.enabled,
                "rules": library.rules,
                "processedKeys": library.processedKeys,
                "deletedTextKeys": library.deletedTextKeys,
                "classifiedKeys": library.classifiedKeys,
                "entries": library.entries.map(encodeCorpusEntry),
            ]
        }

        private static func encodeCorpusEntry(_ entry: CorpusEntry) -> [String: Any] {
            [
                "id": entry.id,
                "source": entry.source,
                "origins": entry.source.isEmpty ? [] : [entry.source],
                "title": entry.title,
                "text": entry.text,
                "category": entry.category,
                "tags": entry.tags,
                "createdAt": 0,
                "updatedAt": 0,
            ]
        }
    }

    // MARK: - 原版 settings 的适配层

    /// Android `StoredSettings` 里 iOS 也需要的那部分字段。
    ///
    /// 键名以真实备份文件为准（2026-10-30 导出的全量备份）。只声明要映射的，
    /// 其余交给 Decodable 忽略。
    struct SettingsExtra: Decodable {
        struct SkillJSON: Decodable {
            var id: String?
            var name: String?
            /// 原版字段叫 `prompt`，iOS 叫 `content`。
            var prompt: String?
            var enabled: Bool?
        }
        struct WorldbookJSON: Decodable {
            var id: String?
            var title: String?
            var content: String?
            var enabled: Bool?
        }
        struct CorpusEntryJSON: Decodable {
            var source: String?
            var title: String?
            var text: String?
            var category: String?
            var tags: [String]?
        }
        /// 语料库。原版允许「库 → 集合 → 子集合」任意嵌套，iOS 侧平铺成
        /// 多个 `CorpusLibrary`，每一层有自己的名字和条目。
        struct CorpusLibraryJSON: Decodable {
            struct NodeJSON: Decodable {
                var id: String?
                var name: String?
                var enabled: Bool?
                var entries: [CorpusEntryJSON]?
                var collections: [NodeJSON]?
            }
            var id: String?
            var name: String?
            var enabled: Bool?
            var entries: [CorpusEntryJSON]?
            var collections: [NodeJSON]?

            /// 把嵌套结构压平成 iOS 的库列表；没有名字也没有条目的节点跳过。
            func libraries() -> [CorpusLibrary] {
                var result: [CorpusLibrary] = []
                append(
                    id: id,
                    name: name,
                    enabled: enabled ?? true,
                    entries: entries ?? [],
                    into: &result
                )
                for collection in collections ?? [] {
                    flatten(collection, into: &result)
                }
                return result
            }

            private func flatten(_ node: NodeJSON, into result: inout [CorpusLibrary]) {
                append(
                    id: node.id,
                    name: node.name,
                    enabled: node.enabled ?? true,
                    entries: node.entries ?? [],
                    into: &result
                )
                for child in node.collections ?? [] {
                    flatten(child, into: &result)
                }
            }

            private func append(
                id: String?,
                name: String?,
                enabled: Bool,
                entries rawEntries: [CorpusEntryJSON],
                into result: inout [CorpusLibrary]
            ) {
                let mapped = rawEntries.compactMap { raw -> CorpusEntry? in
                    guard let text = raw.text, !text.isEmpty else { return nil }
                    return CorpusEntry(
                        source: raw.source ?? "",
                        title: raw.title ?? "",
                        text: text,
                        category: raw.category ?? "",
                        tags: raw.tags ?? []
                    )
                }
                let trimmedName = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedName.isEmpty || !mapped.isEmpty else { return }
                result.append(
                    CorpusLibrary(
                        id: id.flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString,
                        name: trimmedName.isEmpty ? "导入语料" : trimmedName,
                        entries: mapped,
                        enabled: enabled
                    )
                )
            }
        }

        var globalPreset: String?
        var aiFlavorRules: String?
        var worldBuildInstruction: String?
        var plotOutlineInstruction: String?
        var imitationInstruction: String?
        var skills: [SkillJSON]?
        var worldbooks: [WorldbookJSON]?
        var corpusLibrary: CorpusLibraryJSON?
        /// 原版 `inputBudgetTokens`（长上下文预算里的输入上限）。
        var inputBudgetTokens: Int?
        /// 原版 `outputBudgetTokens`（单次生成的最大输出）。
        var outputBudgetTokens: Int?
        var autoConversationSummary: Bool?
        var conversationSummaryThresholdPercent: Int?
        var excludeAssistantChatHistory: Bool?
        var summaryModel: String?

        func apply(to settings: inout AppSettings) {
            if let globalPreset, !globalPreset.isEmpty {
                settings.globalPreset = globalPreset
            }
            if let aiFlavorRules, !aiFlavorRules.isEmpty {
                settings.aiFlavorRules = aiFlavorRules
            }
            if let worldBuildInstruction, !worldBuildInstruction.isEmpty {
                settings.worldBuildInstruction = worldBuildInstruction
            }
            if let plotOutlineInstruction, !plotOutlineInstruction.isEmpty {
                settings.plotOutlineInstruction = plotOutlineInstruction
            }
            if let imitationInstruction, !imitationInstruction.isEmpty {
                settings.imitationInstruction = imitationInstruction
            }
            if let inputBudgetTokens, inputBudgetTokens > 0 {
                settings.inputBudgetTokens = min(max(inputBudgetTokens, 1024), 1_000_000)
            }
            if let outputBudgetTokens, outputBudgetTokens > 0 {
                settings.reservedOutputTokens = min(max(outputBudgetTokens, 1024), 100_000)
            }
            if let autoConversationSummary {
                settings.autoConversationSummary = autoConversationSummary
            }
            if let conversationSummaryThresholdPercent {
                settings.conversationSummaryThresholdPercent =
                    min(max(conversationSummaryThresholdPercent, 1), 100)
            }
            if let excludeAssistantChatHistory {
                settings.excludeAssistantChatHistory = excludeAssistantChatHistory
            }
            if let summaryModel {
                settings.summaryModel = summaryModel
            }
            if let skills {
                settings.skills = skills.compactMap { raw -> Skill? in
                    guard let name = raw.name, !name.isEmpty else { return nil }
                    return Skill(
                        id: raw.id ?? UUID().uuidString,
                        name: name,
                        content: raw.prompt ?? "",
                        enabled: raw.enabled ?? true
                    )
                }
            }
            if let worldbooks, !worldbooks.isEmpty, settings.universeEntries.isEmpty {
                // 只有 iOS 形状没解出任何条目时才用 Android 映射：否则会把
                // 用户自建的 .preset/.skill 宇宙条目覆盖掉，还会把停用的世界书
                // 重新启用。iOS 自己的条目已经带 kind/enabled/updatedAt。
                settings.universeEntries = worldbooks.compactMap { raw in
                    guard let title = raw.title, !title.isEmpty else { return nil }
                    return UniverseEntry(
                        id: raw.id ?? UUID().uuidString,
                        title: title,
                        body: raw.content ?? "",
                        kind: .worldbook,
                        enabled: raw.enabled ?? true
                    )
                }
                // 全局启用状态已经落在条目的 `enabled` 上；项目勾选由
                // `enabledUniverseEntryIds` 单独导入，不能再拿它当全局闸门。
            }
            if let corpusLibrary {
                let libraries = corpusLibrary.libraries()
                if !libraries.isEmpty {
                    settings.corpusLibraries = libraries
                    if libraries.contains(where: \.enabled) {
                        settings.corpusEnabled = true
                    }
                }
            }
        }
    }

    // MARK: - 导出

    /// 组一个书项目存档（整份文件的 UTF-8 字节）。
    static func makeProjectArchive(_ backups: [ProjectBackup]) throws -> Data {
        try makeEnvelope(
            format: projectFormat,
            payload: ProjectArchivePayload(projects: normalizedTranslations(backups))
        )
    }

    /// 组一个全量存档。
    static func makeFullArchive(
        settings: AppSettings,
        projects: [ProjectBackup],
        activeProjectID: String = ""
    ) throws -> Data {
        let payload = FullBackupPayload(
            settings: settings,
            projects: normalizedTranslations(projects),
            activeProjectID: activeProjectID
        )
        return try makeEnvelope(format: fullFormat, payload: payload)
    }

    /// 导出前统一译文归属。译文主键是 `(owner, project, target, segment)`，
    /// 分支复制或遗留数据可能包含其他 project id，导出备份时可能触发导入端的重复校验。
    private static func normalizedTranslations(
        _ backups: [ProjectBackup]
    ) -> [ProjectBackup] {
        backups.map { backup in
            var normalized = backup
            normalized.translations = backup.translations.map { segment in
                var copy = segment
                copy.project = backup.projectId
                return copy
            }
            return normalized
        }
    }

    /// 经由 JSON 序列化、gzip 压缩及 base64 编码后封装至信封结构。任一步骤失败均归类为「无法创建存档」。
    private static func makeEnvelope<T: Encodable>(format: String, payload: T) throws -> Data {
        let json: Data
        do {
            json = try jsonEncoder.encode(payload)
        } catch {
            throw FrthinkArchiveError.createFailed
        }
        let compressed: Data
        do {
            compressed = try FrthinkGzip.compress(json)
        } catch {
            throw FrthinkArchiveError.createFailed
        }
        let envelope = Envelope(
            format: format,
            createdAt: nowMillis,
            payload: compressed.base64EncodedString()
        )
        do {
            return try jsonEncoder.encode(envelope)
        } catch {
            throw FrthinkArchiveError.createFailed
        }
    }

    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    /// 原版文件名：`frthink书项目-yyyy-MM-dd-HHmm.frthink` /
    /// `frthink备份-yyyy-MM-dd-HHmm.frthink`。
    static func filename(kind: Kind, at date: Date = Date()) -> String {
        let stamp = filenameFormatter.string(from: date)
        let prefix = kind.isFull ? "frthink备份" : "frthink书项目"
        return "\(prefix)-\(stamp).\(fileExtension)"
    }

    // MARK: - 导入

    /// 读书项目存档：解信封 → 解压 → 解载荷 → 语义校验。
    static func readProjectArchive(_ data: Data) throws -> ProjectArchivePayload {
        try decodeProjectArchive(openEnvelope(data, kind: .project))
    }

    private static func decodeProjectArchive(_ json: Data) throws -> ProjectArchivePayload {
        let payload: ProjectArchivePayload
        do {
            payload = try jsonDecoder.decode(ProjectArchivePayload.self, from: json)
        } catch {
            throw FrthinkArchiveError.corruptedDetail(
                isFull: false,
                detail: decodeDetail(error)
            )
        }
        try validate(payload)
        return payload
    }

    /// 自动识别格式并用正确的读取器打开。
    ///
    /// 原版是两个导入入口（书项目存档 / 全量存档），格式白名单不同。用户拿到
    /// 一个 `chapleap-full-backup` 却点了书项目导入，只会得到「不是有效存档」——
    /// 那不是用户的错。这里先按格式判定，再分派。
    ///
    /// 两种格式的白名单有交集（`writing-workspace-backup`），旧实现先试全量、
    /// 失败再试书项目，同一份文件要解压 + 解析两遍。现在内层 JSON 只解一次，
    /// 两个解码器共用它。
    static func openAny(_ data: Data) throws -> FrthinkArchive.AnyArchive {
        let envelope = try? jsonDecoder.decode(Envelope.self, from: data)
        let looksFull = envelope.map { isAcceptedFormat($0.format, kind: .full) } ?? false
        let looksProject = envelope.map { isAcceptedFormat($0.format, kind: .project) } ?? false
        // 两种都接受时按全量口径解压（错误文案更贴合「可能是全量备份」）。
        // 信封只解这一次：`openEnvelope` 复用同一份，同一份文件不再把
        // base64 payload 字符串完整构造两遍（大备份的内存峰值少一份）。
        let json = try openEnvelope(
            data,
            kind: looksFull ? .full : .project,
            decoded: envelope
        )

        // 先按信封里的 format 走对应读取器；失败则记住它的错误，
        // 两项均失败时抛出包含具体细节的错误原因，避免提示过于宽泛。
        var lastError: Error?
        if looksFull {
            do { return .full(try decodeFullBackup(json)) } catch { lastError = error }
        }
        if looksProject {
            do { return .projects(try decodeProjectArchive(json)) } catch {
                if lastError == nil { lastError = error }
            }
        }
        throw lastError ?? FrthinkArchiveError.notAnArchive(isFull: true)
    }

    /// `openAny` 的结果。
    enum AnyArchive {
        case full(FullBackupPayload)
        case projects(ProjectArchivePayload)

        var projects: [ProjectBackup] {
            switch self {
            case .full(let payload): return payload.projects
            case .projects(let payload): return payload.projects
            }
        }
    }

    /// 读全量存档。
    static func readFullBackup(_ data: Data) throws -> FullBackupPayload {
        try decodeFullBackup(openEnvelope(data, kind: .full))
    }

    private static func decodeFullBackup(_ json: Data) throws -> FullBackupPayload {
        let payload: FullBackupPayload
        do {
            payload = try jsonDecoder.decode(FullBackupPayload.self, from: json)
        } catch DecodingError.keyNotFound(let key, _) where key.stringValue == "settings" {
            // 书项目存档的 format 也在全量白名单里，但它没有 settings：
            // 按「不是有效的全量 .frthink 文件」处理，避免清空本地配置。
            throw FrthinkArchiveError.notAnArchive(isFull: true)
        } catch {
            throw FrthinkArchiveError.corruptedDetail(
                isFull: true,
                detail: decodeDetail(error)
            )
        }
        try validate(payload)
        return payload
    }

    /// 校验顺序严格对齐原版（spec 03 §9.3）：文件体积 → JSON 结构 → format/version →
    /// compression → base64/gzip → 载荷。
    ///
    /// `decoded` 仅供 `openAny` 使用：其判定格式时已完成信封解析，此处直接复用，
    /// 避免对同一文件重复执行 base64 payload 解析。其他调用方传入 nil 自行解码。
    private static func openEnvelope(
        _ data: Data,
        kind: Kind,
        decoded: Envelope? = nil
    ) throws -> Data {
        // 1. 2 ≤ n ≤ 300 MiB。
        guard data.count >= 2 else { throw FrthinkArchiveError.emptyOrDamaged }
        guard data.count <= maxBytes else {
            throw FrthinkArchiveError.fileTooLarge(isFull: kind.isFull)
        }

        // 2. 整份文件当 JSON 信封读。
        let envelope: Envelope
        if let decoded {
            envelope = decoded
        } else {
            do {
                envelope = try jsonDecoder.decode(Envelope.self, from: data)
            } catch {
                throw FrthinkArchiveError.notAnArchive(isFull: kind.isFull)
            }
        }

        // 3. format + version。
        guard envelope.version == envelopeVersion,
              isAcceptedFormat(envelope.format, kind: kind)
        else {
            throw FrthinkArchiveError.unsupportedFormat
        }

        // 4. 压缩标记。
        guard envelope.compression == compressionName else {
            throw FrthinkArchiveError.unsupportedCompression
        }

        // 5. base64 → gzip。Java 的 Base64 默认每 76 字符换行，用宽容模式解。
        guard let compressed = Data(
            base64Encoded: envelope.payload,
            options: .ignoreUnknownCharacters
        ) else {
            throw FrthinkArchiveError.corrupted(isFull: kind.isFull)
        }
        do {
            return try FrthinkGzip.decompress(compressed, maxOutputBytes: maxBytes)
        } catch FrthinkGzipError.outputLimitExceeded {
            throw FrthinkArchiveError.decompressedTooLarge
        } catch {
            throw FrthinkArchiveError.corrupted(isFull: kind.isFull)
        }
    }

    /// 原版的接受规则：
    /// - 书项目存档只认 `writing-workspace-backup`；
    /// - 全量存档认 `writing-workspace-backup`、`frthink-full-backup`，以及任何
    ///   以 `-full-backup` 结尾的 format（给后续版本留的兼容口）。
    static func isAcceptedFormat(_ format: String, kind: Kind) -> Bool {
        switch kind {
        case .project:
            return format == projectFormat
        case .full:
            return format == projectFormat
                || format == fullFormat
                || format.hasSuffix("-full-backup")
        }
    }

    // MARK: - 语义校验

    /// 书项目存档的语义校验（`I1\L0.b`）。
    static func validate(_ payload: ProjectArchivePayload) throws {
        guard payload.formatVersion == payloadVersion else {
            throw FrthinkArchiveError.projectVersionUnsupported
        }
        guard !payload.projects.isEmpty else {
            throw FrthinkArchiveError.emptyProjectArchive
        }
        try validateProjects(payload.projects, isFull: false)
    }

    /// 全量存档的语义校验（`I1\L0.a`）。
    static func validate(_ payload: FullBackupPayload) throws {
        guard payload.formatVersion == payloadVersion else {
            throw FrthinkArchiveError.payloadVersionUnsupported
        }
        try validateProjects(payload.projects, isFull: true)
    }

    private static func validateProjects(_ projects: [ProjectBackup], isFull: Bool) throws {
        var projectIDs = Set<String>()
        for backup in projects {
            guard backup.formatVersion == payloadVersion else {
                throw FrthinkArchiveError.projectVersionUnsupported
            }
            guard !backup.projectId.isEmpty else {
                throw FrthinkArchiveError.corrupted(isFull: isFull)
            }
            guard isSafeProjectID(backup.projectId) else {
                throw FrthinkArchiveError.invalidProjectID(backup.projectId)
            }
            guard projectIDs.insert(backup.projectId).inserted else {
                throw FrthinkArchiveError.duplicateProjects(isFull: isFull)
            }
        }
        try validateTranslations(projects)
    }

    /// 项目 id 直接用作目录名。仅拦截路径遍历等安全风险，不限制 id 的字符集：
    /// 历史存档可能包含非 UUID 格式 id，收紧字符集会导致有效备份无法导入。
    private static func isSafeProjectID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        guard id != ".", id != ".." else { return false }
        guard !id.contains("/"), !id.contains("\\"), !id.contains("\0") else {
            return false
        }
        return !id.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// 译文分段的主键是 `(owner, project, target, segment)`。
    private static func validateTranslations(_ projects: [ProjectBackup]) throws {
        var keys = Set<String>()
        for backup in projects {
            for segment in backup.translations {
                let key = [
                    segment.owner,
                    segment.project,
                    segment.target,
                    segment.sourceHash,
                    String(segment.segment),
                ].joined(separator: "\u{1F}")
                guard keys.insert(key).inserted else {
                    throw FrthinkArchiveError.duplicateTranslations
                }
            }
        }
    }

    // MARK: - 落盘

    /// 把校验过的书项目写进 `FileStore`，返回真正落盘的 `Project`。
    ///
    /// 同 id 的项目被覆盖（「恢复存档」语义），其余项目不动——原版导入也不
    /// 清空现有数据。译文按本机 `ownerID` 重打归属：Android 的 `owner` 是设备/
    /// 账号标识，跨端带过来会触发「存档项目归属不匹配」。
    ///
    /// 每本书先写进 UUID 暂存目录，全部文件成功后才整体换进正式目录；
    /// `beforeCommit` 只给自检注入失败用，正常导入传 nil。
    @discardableResult
    static func restore(
        _ backups: [ProjectBackup],
        into files: FileStore,
        ownerID: String,
        beforeCommit: (() throws -> Void)? = nil
    ) throws -> [Project] {
        var restored: [Project] = []
        let stagingRoot: URL
        do {
            stagingRoot = try files.makeImportStagingRoot()
        } catch {
            throw FrthinkArchiveError.writeFailed(error.localizedDescription)
        }
        defer { files.discardImportStagingRoot(stagingRoot) }
        let stagedFiles = FileStore(root: stagingRoot)
        for backup in backups {
            let project = Project(
                id: backup.projectId,
                title: backup.title.isEmpty ? Project.untitledTitle : backup.title,
                synopsis: backup.synopsis,
                updatedAt: Date(),
                revision: 0,
                coverImagePayload: backup.coverImageBase64.isEmpty
                    ? nil
                    : backup.coverImageBase64,
                branchRootId: backup.branchRootId,
                branchOrder: backup.branchOrder,
                trashedAt: backup.trashedAt > 0
                    ? Date(timeIntervalSince1970: TimeInterval(backup.trashedAt) / 1000)
                    : nil
            )

            var payload = backup.snapshot.projectPayload
            // 锚点为 UTF-16 偏移量，若存档来自其他版本可能出现越界，此时直接丢弃。
            if let anchor = payload.continuationAnchor,
               anchor < 0 || anchor > payload.manuscript.utf16.count {
                payload.continuationAnchor = nil
            }
            // 原版存档未包含 iOS 端章节索引（章节为扫描正文生成的派生数据）。若不执行此项补充，
            // 导入后创作台章节栏与阅读页目录将显示为空，直至用户手动编辑正文。
            if payload.chapters.isEmpty, !payload.manuscript.isEmpty {
                payload.chapters = ChapterScanner.scan(payload.manuscript)
            }

            let translations = backup.translations.map { segment -> TranslationSegment in
                var copy = segment
                copy.owner = ownerID
                copy.project = project.id
                return copy
            }

            do {
                try stagedFiles.saveProject(project)
                try stagedFiles.savePayload(payload, projectID: project.id)
                // payload.json 里的正文只是兜底；正文实际由分页文件承载。
                // 覆盖导入时必须一并重写，否则旧 body.pages 会盖住新正文。
                try stagedFiles.saveBody(
                    payload.manuscript,
                    chapters: payload.chapters,
                    projectID: project.id
                )
                try stagedFiles.saveSource(backup.sourceText, projectID: project.id)
                try stagedFiles.saveTranslations(translations, projectID: project.id)
                try beforeCommit?()
                // 仅在单本书稿全部文件写入成功后，才原子替换至正式目录。发生失败或取消时，
                // 暂存目录将被清理并保留原始书稿，避免出现数据不一致。
                try files.commitStagedProject(projectID: project.id, stagingRoot: stagingRoot)
            } catch {
                throw FrthinkArchiveError.writeFailed(error.localizedDescription)
            }
            restored.append(project)
        }
        return restored
    }

    /// 全量存档里的设置并进本机。
    ///
    /// 规则：
    /// - 本机身份（译文 `owner`）不换；
    /// - 存档未包含供应方信息（Android 备份仅包含 `credentials`）时保留本地供应方，
    ///   API Key 存储于 Keychain 并通过供应方 id 索引，替换 id 会导致凭据丢失；
    /// - 存档未指定当前供应方（或指定了本地不存在的项）时保留本地选中项，兜底采用列表首项；
    /// - 宇宙条目按 id 合并，不删本机条目；
    /// - 外观类本机偏好（主题、正文字号、动效、触感）保留本机值；
    /// - 存档里没有写出的字段保留本机值：Android 备份没有 iOS 的流式开关、
    ///   上下文窗口、累计用量等键，解出来是出厂默认值，整份替换会把这些设置重置。
    ///
    /// `archivedKeys` 是存档 `settings` 对象里实际出现的键；传空集合时按「什么都没写」
    /// 处理，即只覆盖供应方/宇宙条目，其余保留本机——宁可少覆盖，也不写坏设置。
    static func mergeSettings(
        _ imported: AppSettings,
        into local: AppSettings,
        archivedKeys: Set<String> = []
    ) -> AppSettings {
        var result = imported
        result.ownerID = local.ownerID
        if result.providers.isEmpty {
            result.providers = local.providers
        }
        // 存档未包含 activeProviderID（如 Android 备份）时保留本地选中的供应方；
        // 禁止直接回退至 providers.first，避免切换至未配置 API Key 的供应方。
        if !result.providers.contains(where: { $0.id == result.activeProviderID }) {
            result.activeProviderID = result.providers.contains(where: { $0.id == local.activeProviderID })
                ? local.activeProviderID
                : (result.providers.first?.id ?? "")
        }
        result.universeEntries = mergedUniverseEntries(
            imported.universeEntries,
            with: local.universeEntries
        )
        result.theme = local.theme
        result.bodyFontSize = local.bodyFontSize
        result.limitAnimationFrameRate = local.limitAnimationFrameRate
        result.hapticsEnabled = local.hapticsEnabled

        // 未映射 / 缺键的字段：Android 备份没有对应键，解出来是出厂默认值。
        func archived(_ names: String...) -> Bool {
            names.contains { archivedKeys.contains($0) }
        }
        if !archived("streamByDefault", "streamingResponses") {
            result.streamByDefault = local.streamByDefault
        }
        // 语料库依据「是否存在条目」判定，而非仅检查键名是否存在：Android 备份顶层
        // `corpusLibrary` 字段类型为 `CorpusLibrary?` 且默认为 null（spec 03 §5.1），仓库
        // fixture 中亦仅包含无条目的空节点。若键存在但无任何条目，不视为存档提供了该字段，
        // 避免全量导入时清空本地语料库并直接持久化。
        let hasCorpusContent = imported.corpusLibraries.contains { !$0.entries.isEmpty }
        if !hasCorpusContent {
            result.corpusLibraries = local.corpusLibraries
            result.corpusEnabled = local.corpusEnabled
        }
        if !archived("enabledUniverseEntryIDs") {
            result.enabledUniverseEntryIDs = local.enabledUniverseEntryIDs
        }
        if !archived("defaultTemperature") {
            result.defaultTemperature = local.defaultTemperature
        }
        if !archived("defaultMaxTokens") {
            result.defaultMaxTokens = local.defaultMaxTokens
        }
        if !archived("contextWindowTokens") {
            result.contextWindowTokens = local.contextWindowTokens
        }
        if !archived("inputBudgetTokens") {
            result.inputBudgetTokens = local.inputBudgetTokens
        }
        if !archived("reservedOutputTokens", "outputBudgetTokens") {
            result.reservedOutputTokens = local.reservedOutputTokens
        }
        if !archived("tokenUsageTotal") {
            result.tokenUsageTotal = local.tokenUsageTotal
        }
        if !archived("translationProviderID") {
            result.translationProviderID = local.translationProviderID
        }
        if !archived("summaryModel") {
            result.summaryModel = local.summaryModel
        }
        if !archived("worldBuildInstruction") {
            result.worldBuildInstruction = local.worldBuildInstruction
        }
        if !archived("plotOutlineInstruction") {
            result.plotOutlineInstruction = local.plotOutlineInstruction
        }
        if !archived("imitationInstruction") {
            result.imitationInstruction = local.imitationInstruction
        }
        if !archived("autoConversationSummary") {
            result.autoConversationSummary = local.autoConversationSummary
        }
        if !archived("conversationSummaryThresholdPercent") {
            result.conversationSummaryThresholdPercent =
                local.conversationSummaryThresholdPercent
        }
        if !archived("excludeAssistantChatHistory") {
            result.excludeAssistantChatHistory = local.excludeAssistantChatHistory
        }
        if !archived("globalPreset") {
            result.globalPreset = local.globalPreset
        }
        if !archived("aiFlavorRules") {
            result.aiFlavorRules = local.aiFlavorRules
        }
        if !archived("skills") {
            result.skills = local.skills
        }
        return result
    }

    /// 存档里带的宇宙条目按 id 并入本机设置，已有条目不覆盖。
    static func mergedUniverseEntries(
        _ imported: [UniverseEntry],
        with existing: [UniverseEntry]
    ) -> [UniverseEntry] {
        var result = existing
        var ids = Set(existing.map { $0.id })
        for entry in imported where ids.insert(entry.id).inserted {
            result.append(entry)
        }
        return result
    }

}
