import Foundation

/// 运行时自检。
///
/// 用启动参数 `-runSelfCheck` 触发，跑完把结果打到 stdout 并退出。
/// CI 的 `xcrun simctl launch --console-pty` 会把输出抓下来，所以这是
/// **「逻辑真的执行了」**的证据，而不是「能编译」。
///
/// 只测纯逻辑：不联网、不依赖用户数据。目的是覆盖那些光看代码看不出错的地方——
/// 提示词块顺序、token 估算数值、预算推导、存档 gzip 往返。
enum SelfCheck {

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-runSelfCheck")
    }

    private struct Failure: Error {
        let message: String
    }

    private static var lines: [String] = []
    private static var failures = 0

    private static func check(_ name: String, _ body: () throws -> String) {
        do {
            let detail = try body()
            lines.append("PASS  \(name)  \(detail)")
        } catch let failure as Failure {
            failures += 1
            lines.append("FAIL  \(name)  \(failure.message)")
        } catch {
            failures += 1
            lines.append("FAIL  \(name)  \(error.localizedDescription)")
        }
    }

    private static func expect(
        _ condition: Bool,
        _ message: @autoclosure () -> String
    ) throws {
        if !condition { throw Failure(message: message()) }
    }

    @MainActor
    static func run() -> Int32 {
        #if DEBUG
        PayloadCipher.useSelfCheckKey()
        #endif
        lines.append("=== Frthink self check ===")

        // 1 · token 估算（权重照抄原版，结果应当完全一致）
        check("token.estimate") {
            // "你好" = 2 个汉字 → 2.0 * 1.2 = 2.4 → ceil 3 → +6 = 9
            let cjk = TokenEstimator.estimate("你好")
            try expect(cjk == 9, "「你好」应为 9，实际 \(cjk)")
            // "abc" = 3 个 ASCII 字母 → 0.84 * 1.2 = 1.008 → ceil 2 → +6 = 8
            let ascii = TokenEstimator.estimate("abc")
            try expect(ascii == 8, "「abc」应为 8，实际 \(ascii)")
            // 空串至少是固定开销
            let empty = TokenEstimator.estimate("")
            try expect(empty == 6, "空串应为 6，实际 \(empty)")
            return "cjk=\(cjk) ascii=\(ascii) empty=\(empty)"
        }

        // 2 · 预算推导
        check("budget.formula") {
            var settings = AppSettings()
            settings.inputBudgetTokens = 32_768
            settings.reservedOutputTokens = 30_000
            settings.contextWindowTokens = 64_000
            let plan = try PromptBudget.make(
                settings: settings,
                model: "deepseek-chat",
                contextWindowOverride: 64_000
            )
            // avail = 64000 - (30000 + 1024) = 32976；min(32768, 32976) = 32768
            try expect(plan.effectiveInputBudget == 32_768,
                       "有效输入预算应为 32768，实际 \(plan.effectiveInputBudget)")
            return "input=\(plan.inputBudget) out=\(plan.outputBudget) eff=\(plan.effectiveInputBudget)"
        }

        check("budget.followModel") {
            var settings = AppSettings()
            settings.inputBudgetTokens = 0
            settings.reservedOutputTokens = 30_000
            settings.contextWindowTokens = 1_000_000
            let plan = try PromptBudget.make(
                settings: settings,
                model: "deepseek-flash",
                contextWindowOverride: 1_000_000
            )
            let expected = 1_000_000 - 30_000 - 1_024
            try expect(plan.effectiveInputBudget == expected,
                       "跟随模型应为 \(expected)，实际 \(plan.effectiveInputBudget)")
            return "eff=\(plan.effectiveInputBudget)"
        }

        // 3 · 提示词块顺序（规格 §1 的 14 行）
        check("prompt.blockOrder") {
            var settings = AppSettings()
            settings.globalPreset = "GLOBAL_PRESET_MARKER"
            settings.aiFlavorRules = "AI_FLAVOR_MARKER"
            settings.skills = [
                Skill(name: "SKILL_MARKER", content: "skill body")
            ]
            var world = WorldBook()
            world.styleTemplate = "IMITATION_MARKER"
            world.longTermRules = "RULES_MARKER"
            world.characters = [
                CharacterCard(name: "CHARACTER_MARKER")
            ]
            world.worldbookEntries = [
                WorldbookEntry(title: "WORLDBOOK_MARKER", body: "wb body")
            ]
            let assembly = PromptAssembly.from(
                world: world,
                manuscript: "BODY_MARKER",
                assistantSupplement: "SUPPLEMENT_MARKER",
                settings: settings,
                projectID: "p1"
            )
            let system = PromptComposer.systemPrompt(
                from: PromptComposer.writingBlocks(assembly)
            )

            let order = [
                "SUPPLEMENT_MARKER",
                "GLOBAL_PRESET_MARKER",
                "SKILL_MARKER",
                "AI_FLAVOR_MARKER",
                "IMITATION_MARKER",
                "WORLDBOOK_MARKER",
                "CHARACTER_MARKER",
                "RULES_MARKER",
                "BODY_MARKER",
            ]
            var cursor = system.startIndex
            for marker in order {
                guard let range = system.range(of: marker, range: cursor..<system.endIndex)
                else {
                    throw Failure(message: "块顺序错：找不到 \(marker) 或其位置在 \(cursor) 之前")
                }
                cursor = range.upperBound
            }
            return "9 个块的先后顺序正确，system \(system.count) 字"
        }

        // 4 · 续写只发末尾 N 码点
        check("prompt.tailBody") {
            let body = String(repeating: "字", count: 20_000)
            let tail = PromptComposer.codePointTail(body, limit: 5000)
            try expect(tail.count == 5000, "末尾切片应为 5000，实际 \(tail.count)")
            return "20000 → \(tail.count) 码点"
        }

        // 5 · 存档 gzip 往返（RFC1952，Android 用的是同一个）
        check("archive.gzipRoundTrip") {
            let payload = String(repeating: "小说正文测试 ", count: 2_000)
            let data = Data(payload.utf8)
            let compressed = try FrthinkGzip.compress(data)
            try expect(Array(compressed.prefix(2)) == [0x1F, 0x8B], "gzip 魔数不对")
            let restored = try FrthinkGzip.decompress(compressed, maxOutputBytes: 10_000_000)
            try expect(restored == data, "往返后内容不一致")
            return "\(data.count) → \(compressed.count) → \(restored.count) 字节"
        }

        // 6 · CRC32 已知向量
        check("archive.crc32") {
            let crc = FrthinkGzip.crc32(Data("123456789".utf8))
            try expect(crc == 0xCBF4_3926, "crc32(123456789) 应为 0xCBF43926，实际 \(String(format: "%08X", crc))")
            return String(format: "0x%08X", crc)
        }

        // 7 · 章节识别正则
        check("chapter.regex") {
            let text = "第一章 · 旧书店\n正文\n第二章 未寄出的信\n楔子\n随便一行"
            let chapters = ChapterScanner.scan(text)
            try expect(chapters.count == 3, "应识别 3 个章节，实际 \(chapters.count): \(chapters.map(\.title))")
            return chapters.map(\.title).joined(separator: " / ")
        }

        // 8 · 空结果标记
        check("prompt.markers") {
            try expect(PromptMarkers.noAdditions.rawValue == "[NO_ADDITIONS]",
                       "noAdditions 标记被改动了")
            return PromptMarkers.noAdditions.rawValue
        }

        // 9 · Android 形状的全量备份：解码 → 映射 → 写盘 → 再读回
        check("archive.androidFullImport") {
            let data = try ArchiveFixture.androidFullBackup()
            let archive = try FrthinkArchive.openAny(data)
            guard case .full(let backup) = archive else {
                throw Failure(message: "chapleap-full-backup 应被识别成全量备份")
            }
            try expect(backup.projects.count == 2,
                       "应导入 2 本书，实际 \(backup.projects.count)")

            let first = backup.projects[0]
            let payload = first.snapshot.projectPayload
            try expect(payload.manuscript.contains("第一章"),
                       "正文没解出来：\(payload.manuscript.prefix(20))")
            // 4 条消息里 1 条在墓碑中，导入后应剩 3 条。
            try expect(payload.messages.count == 3,
                       "墓碑过滤后应 3 条消息，实际 \(payload.messages.count)")

            let branches = payload.messages.first { $0.id == "m-assistant-1" }
            try expect(branches?.variants.count == 2 && branches?.selectedVariant == 1,
                       "有两个版本的回复应选中第 2 版")
            try expect(branches?.content == "版本二（选中）",
                       "选中版本内容不对：\(branches?.content ?? "nil")")

            let failedVersion = payload.messages.first { $0.id == "m-assistant-2" }
            try expect(failedVersion?.content == "有正文的版本",
                       "失败版本（content 为 null）不应占掉选中位置")

            try expect(payload.world.characters.count == 2,
                       "人物卡应 2 张，实际 \(payload.world.characters.count)")
            try expect(payload.world.characters.first?.customEntries.count == 1,
                       "人物卡自定义词条丢失")
            try expect(payload.world.worldbookEntries.count == 1,
                       "世界书应 1 条，实际 \(payload.world.worldbookEntries.count)")
            try expect(payload.world.events.count == 1,
                       "world.plotEvents 应转成事件卡，实际 \(payload.world.events.count)")
            try expect(payload.world.plotOutline == "剧情梗概占位",
                       "剧情梗概丢失")
            try expect(payload.world.relationships == ["林昭 → 沈默：店主与客人"],
                       "人物关系丢失")
            try expect(
                payload.world.characterSummaries == ["林昭 · 旧书店店主", "沈默 · 找书的客人"],
                "world.characters 条目丢失"
            )
            try expect(payload.world.materialChunkHashes["chunk-0"] == "abc123",
                       "材料分块哈希丢失")
            try expect(payload.world.materialSourceProgress["src-1"]?.processedUtf16 == 12_000,
                       "材料进度丢失")
            try expect(payload.world.longTermRules == "长期规则占位",
                       "长期规则丢失")
            try expect(payload.world.characters.first?.memories?.first?.content
                        == "父亲留下的书店",
                       "人物卡 memories 丢失")
            try expect(payload.world.analysisSourceCodePointCount == 100
                        && payload.world.analysisSegments.count == 2
                        && payload.world.analysisSegments.first?.endCodePoint == 50,
                       "checkpoint 段详情丢失")
            try expect(payload.world.analysisMergedCards.count == 2,
                       "checkpoint mergedCards 丢失")
            try expect(payload.world.analysisCharacterBaselineSHA256 == "baseline-sha"
                        && payload.world.analysisWorldRefreshComplete,
                       "checkpoint 其余字段丢失")
            try expect(payload.world.summarySourceHash == "hash"
                        && payload.world.summaryRulesVersion == 2,
                       "摘要元数据丢失")
            try expect(payload.world.summaryPreviousRevisions.first?.content == "旧规则",
                       "摘要历史版本丢失")
            try expect(first.sourceText == "原文占位内容",
                       "原文没有从 localSourceDocuments 回填")
            try expect(payload.requestSnapshots.count == 1
                        && payload.requestSnapshots[0].omittedHistoryMessages == 3,
                       "请求快照没解出来")
            try expect(payload.readerOffset == 12 && payload.readerBookmarkOffset == 34,
                       "阅读位置丢失")
            try expect(payload.enabledUniverseEntryIDs == ["wb-global"],
                       "本书启用的宇宙条目丢失")
            try expect(payload.assistantSupplement == "补充指令",
                       "项目补充指令丢失")

            try expect(backup.settings.globalPreset == "FIXTURE_PRESET",
                       "全局预设没导入")
            try expect(backup.settings.skills.count == 1,
                       "技能应 1 个，实际 \(backup.settings.skills.count)")
            try expect(backup.settings.universeEntries.contains { $0.id == "wb-global" },
                       "共享世界书没进宇宙条目")
            try expect(backup.settings.corpusLibraries.contains {
                $0.name == "FIXTURE_CORPUS" && $0.entries.count == 1
            }, "顶层 corpusLibrary 没导入")
            try expect(backup.settings.inputBudgetTokens == 100_000,
                       "输入预算没导入：\(backup.settings.inputBudgetTokens)")
            try expect(
                backup.settings.plotOutlineInstruction == "FIXTURE_PLOT_INSTRUCTION"
                    && backup.settings.imitationInstruction == "FIXTURE_IMITATION",
                "剧情/仿写归纳预设没有导入"
            )

            // 写盘 + 读回：证明落盘链路真的能跑，而不只是解码成功。
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-selfcheck-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)
            let restored = try FrthinkArchive.restore(
                backup.projects,
                into: files,
                ownerID: "fixture-owner"
            )
            try expect(restored.count == 2, "应落盘 2 本书")
            try expect(files.loadProjects().count == 2, "书架读不回 2 本书")
            try expect(files.loadProjects().contains { $0.title == "旧稿" && $0.isTrashed },
                       "回收站状态没写进去")

            let reloaded = files.loadFullPayload(ArchiveFixture.firstProjectID)
            try expect(reloaded.manuscript == payload.manuscript, "正文写盘后不一致")
            try expect(reloaded.chapters.count == 2,
                       "导入后应扫出 2 章，实际 \(reloaded.chapters.count)")
            try expect(files.loadSource(ArchiveFixture.firstProjectID) == "原文占位内容",
                       "原文没有落盘")

            // 再导出一次：新字段按原版键名写回，重新打开后不丢。
            let exported = try FrthinkArchive.makeFullArchive(
                settings: backup.settings,
                projects: backup.projects,
                activeProjectID: backup.activeProjectID
            )
            let reopened = try FrthinkArchive.readFullBackup(exported)
            let exportedWorld = reopened.projects[0].snapshot.projectPayload.world
            try expect(exportedWorld.relationships == ["林昭 → 沈默：店主与客人"],
                       "导出后人物关系丢失")
            try expect(
                exportedWorld.characterSummaries == ["林昭 · 旧书店店主", "沈默 · 找书的客人"],
                "导出后 world.characters 丢失"
            )
            try expect(exportedWorld.characters.first?.memories?.first?.content
                        == "父亲留下的书店",
                       "导出后人物记忆丢失")
            try expect(exportedWorld.analysisSegments.count == 2
                        && exportedWorld.analysisMergedCards.count == 2,
                       "导出后 checkpoint 丢失")
            try expect(exportedWorld.summarySourceHash == "hash"
                        && exportedWorld.summaryPreviousRevisions.count == 1,
                       "导出后摘要元数据丢失")
            try expect(exportedWorld.materialSourceProgress["src-1"]?.processedUtf16 == 12_000,
                       "导出后材料进度丢失")
            return "2 本 / 正文 \(reloaded.manuscript.count) 字 / 章节 \(reloaded.chapters.count) / 人物卡 \(reloaded.world.characters.count) 张"
        }

        // 覆盖导入同名项目：第二次 restore 必须重写正文页，不能被旧 body.meta 盖住
        check("archive.restoreOverwrite") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-restore-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)
            let project = Project(id: "restore-book", title: "恢复测试")
            func backup(_ text: String) -> FrthinkArchive.ProjectBackup {
                FrthinkArchive.ProjectBackup(
                    project: project,
                    payload: ProjectPayload(manuscript: text),
                    sourceText: "",
                    translations: [],
                    universeEntries: []
                )
            }

            _ = try FrthinkArchive.restore([backup("第一版正文")], into: files, ownerID: "self")
            try expect(
                files.loadFullPayload(project.id).manuscript == "第一版正文",
                "首次导入正文不对"
            )
            _ = try FrthinkArchive.restore([backup("第二版正文")], into: files, ownerID: "self")
            let overwritten = files.loadFullPayload(project.id)
            try expect(
                overwritten.manuscript == "第二版正文",
                "覆盖导入后仍是旧正文：\(overwritten.manuscript)"
            )
            return "覆盖导入重写正文页 ok"
        }

        // 导入失败必须回滚：旧稿还在，暂存目录不留垃圾
        check("archive.importFailureRollsBack") {
            struct InjectedFailure: Error {}
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-rollback-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)
            let project = Project(id: "rollback-book", title: "回滚测试")
            func backup(_ text: String) -> FrthinkArchive.ProjectBackup {
                FrthinkArchive.ProjectBackup(
                    project: project,
                    payload: ProjectPayload(manuscript: text),
                    sourceText: "",
                    translations: [],
                    universeEntries: []
                )
            }
            _ = try FrthinkArchive.restore([backup("旧稿正文")], into: files, ownerID: "self")

            var didFail = false
            do {
                _ = try FrthinkArchive.restore(
                    [backup("新稿正文")],
                    into: files,
                    ownerID: "self"
                ) {
                    throw InjectedFailure()
                }
            } catch let error as FrthinkArchiveError {
                guard case .writeFailed = error else { throw error }
                didFail = true
            }
            try expect(didFail, "注入写盘失败后 restore 没有报错")
            let kept = files.loadFullPayload(project.id).manuscript
            try expect(kept == "旧稿正文", "导入失败后旧正文被改坏：\(kept)")
            let staging = root.appendingPathComponent("staging", isDirectory: true)
            let leftovers = (try? FileManager.default.contentsOfDirectory(
                atPath: staging.path
            )) ?? []
            try expect(leftovers.isEmpty, "暂存目录没有清理：\(leftovers)")
            return "失败回滚并清理暂存 ok"
        }

        // 项目 id 会被当成目录名，存档里的路径穿越必须直接拒绝
        check("archive.rejectUnsafeProjectID") {
            var payload = ArchiveFixture.payload()
            var projects = payload["projects"] as? [[String: Any]] ?? []
            projects[0]["projectId"] = "../escape"
            payload["projects"] = projects
            let data = try ArchiveFixture.envelope(payload: payload)
            do {
                _ = try FrthinkArchive.openAny(data)
            } catch let error as FrthinkArchiveError {
                guard case .invalidProjectID = error else {
                    throw Failure(message: "错误类型不对：\(error)")
                }
                return "拒绝 ../escape"
            }
            throw Failure(message: "带路径穿越的项目 id 没有被拒绝")
        }

        // 分支复制带的译文必须重打 project，否则导出后被自己的重复校验拒收
        check("archive.branchTranslations") {
            func project(_ id: String) -> Project {
                Project(id: id, title: "分支-\(id)")
            }
            func segment(_ index: Int, staleProject: String) -> TranslationSegment {
                TranslationSegment(
                    owner: "self",
                    project: staleProject,
                    sourceHash: "hash-\(index)",
                    segment: index,
                    payload: "译文 \(index)"
                )
            }
            let first = FrthinkArchive.ProjectBackup(
                project: project("branch-a"),
                payload: ProjectPayload(manuscript: "甲"),
                sourceText: "",
                translations: [segment(0, staleProject: "root-book")],
                universeEntries: []
            )
            let second = FrthinkArchive.ProjectBackup(
                project: project("branch-b"),
                payload: ProjectPayload(manuscript: "乙"),
                sourceText: "",
                translations: [segment(0, staleProject: "root-book")],
                universeEntries: []
            )
            let data = try FrthinkArchive.makeFullArchive(
                settings: AppSettings(),
                projects: [first, second]
            )
            let reopened = try FrthinkArchive.readFullBackup(data)
            for backup in reopened.projects {
                try expect(
                    backup.translations.allSatisfy { $0.project == backup.projectId },
                    "译文 project 没有重打：\(backup.translations.map(\.project))"
                )
            }
            return "2 本书译文归属 ok"
        }

        // snapshot 解不出来必须整本失败，不能静默用空快照覆盖同名书
        check("archive.rejectBrokenSnapshot") {
            var payload = ArchiveFixture.payload()
            var projects = payload["projects"] as? [[String: Any]] ?? []
            projects[0]["snapshot"] = NSNull()
            payload["projects"] = projects
            let data = try ArchiveFixture.envelope(payload: payload)
            do {
                _ = try FrthinkArchive.openAny(data)
            } catch let error as FrthinkArchiveError {
                let text = error.errorDescription ?? ""
                try expect(
                    text.contains("snapshot") || text.contains("无法解析"),
                    "错误文案没有指出 snapshot：\(text)"
                )
                return "坏 snapshot 被拒绝"
            }
            throw Failure(message: "snapshot 为 null 时仍然导入成功")
        }

        // Android 形状的译文、共享世界书与顶层人物分组要能映射进 iOS 模型
        check("archive.androidShapes") {
            var payload = ArchiveFixture.payload()
            var projects = payload["projects"] as? [[String: Any]] ?? []
            projects[0]["translations"] = [
                [
                    "target": "body",
                    "sourceHash": String(repeating: "a", count: 64),
                    "index": 0,
                    "chunkHash": String(repeating: "b", count: 64),
                    "text": "译文内容",
                    "model": "deepseek-chat",
                ],
            ]
            projects[0]["universeEntries"] = [
                [
                    "id": "shared-1",
                    "title": "共享设定",
                    "content": "共享正文",
                    "enabled": true,
                    "keywords": "",
                    "dynamic": false,
                ],
            ]
            var snapshot = projects[0]["snapshot"] as? [String: Any] ?? [:]
            snapshot["characterGroups"] = [
                ["id": "group-1", "name": "主角组", "enabled": true],
            ]
            snapshot["world"] = ["events": ["旧事件一", "旧事件二"]]
            projects[0]["snapshot"] = snapshot
            payload["projects"] = projects
            let data = try ArchiveFixture.envelope(payload: payload)
            let archive = try FrthinkArchive.openAny(data)
            guard case .full(let backup) = archive else {
                throw Failure(message: "fixture 应被识别为全量备份")
            }
            let first = backup.projects[0]
            try expect(first.translations.count == 1, "译文没有映射进来")
            try expect(
                first.translations[0].payload == "译文内容"
                    && first.translations[0].segment == 0
                    && first.translations[0].target == TranslationSegment.defaultTarget,
                "译文映射字段不对：\(first.translations[0])"
            )
            try expect(
                first.universeEntries.first?.body == "共享正文",
                "共享世界书正文没有映射：\(first.universeEntries.first?.body ?? "nil")"
            )
            try expect(
                first.snapshot.projectPayload.world.characterGroups.first?.name == "主角组",
                "顶层人物分组没有映射"
            )
            try expect(
                first.snapshot.projectPayload.world.events.map(\.title)
                    == ["旧事件一", "旧事件二"],
                "旧事件字符串没有映射"
            )
            return "译文 / 共享世界书 / 分组 / 旧事件 ok"
        }

        // Android 两份书都用 index 0 起排的 TranslationRecord；没有 project 字段，
        // 导入时必须按所属项目补齐，否则会被判成重复译文整份失败。
        check("archive.androidMultiBookTranslations") {
            var payload = ArchiveFixture.payload()
            var projects = payload["projects"] as? [[String: Any]] ?? []
            for index in projects.indices {
                projects[index]["translations"] = [
                    [
                        "target": "body",
                        "sourceHash": "hash-\(index)",
                        "index": 0,
                        "text": "第 \(index) 本译文",
                    ],
                ]
            }
            payload["projects"] = projects
            let data = try ArchiveFixture.envelope(payload: payload)
            let archive = try FrthinkArchive.openAny(data)
            guard case .full(let backup) = archive, backup.projects.count == 2 else {
                throw Failure(message: "两份 Android 书应能一起导入")
            }
            for project in backup.projects {
                try expect(
                    project.translations.first?.project == project.projectId,
                    "译文没有按所属项目补齐"
                )
                try expect(
                    project.translations.first?.payload.hasPrefix("第 ") == true,
                    "译文内容没有映射"
                )
            }
            return "2 本书各自 index 0 译文不撞键"
        }

        // Android 备份没有 providers 键：导入后必须保留本机供应方与外观偏好
        check("archive.fullRestoreKeepsLocalSettings") {
            var local = AppSettings(
                providers: [ProviderSetting(kind: .deepseek)]
            )
            local.theme = .dark
            local.bodyFontSize = 22
            var imported = AppSettings(providers: [])
            imported.theme = .system
            imported.bodyFontSize = 18
            let merged = FrthinkArchive.mergeSettings(imported, into: local)
            try expect(
                merged.providers.map(\.id) == local.providers.map(\.id),
                "导入后供应方 id 变了，Keychain 里的 Key 会失联"
            )
            try expect(merged.theme == .dark, "主题被存档默认值覆盖")
            try expect(merged.bodyFontSize == 22, "正文字号被存档默认值覆盖")
            return "供应方与外观偏好保留 ok"
        }

        // 分段要带正确的码点范围：P27/P28/P29 靠它告诉模型本段在全文的位置
        check("world.chunkRanges") {
            let line = "第一卷 雨夜\n她把伞收起来，走进书店。\n\n"
            let source = String(repeating: line, count: 12)
            let chunks = WorldDigest.chunks(of: source, tokenBudget: 24, overlapTokens: 6)
            try expect(chunks.count > 1, "测试正文应被切成多段")
            let scalars = Array(source.unicodeScalars)
            for chunk in chunks {
                try expect(
                    chunk.startCodePoint >= 0
                        && chunk.endCodePoint <= scalars.count
                        && chunk.startCodePoint < chunk.endCodePoint,
                    "码点范围越界：\(chunk.startCodePoint)..<\(chunk.endCodePoint)"
                )
                var view = String.UnicodeScalarView()
                for scalar in scalars[chunk.startCodePoint..<chunk.endCodePoint] {
                    view.append(scalar)
                }
                let slice = String(view)
                try expect(slice == chunk.text, "码点范围与段文本不一致")
            }
            try expect(chunks.first?.startCodePoint == 0, "首段起点应为 0")
            try expect(
                chunks.last?.endCodePoint == scalars.count,
                "末段终点应为全文字数"
            )
            return "\(chunks.count) 段范围 ok"
        }

        // 哈希字段用完整 SHA-256（64 hex），与 Android sourceSha256 对齐
        check("hash.sha256") {
            let hash = ContentHash.of("abc")
            try expect(
                hash == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                "SHA-256 向量不对：\(hash)"
            )
            return "SHA-256 64hex ok"
        }

        // 导出往返：消息多版本与文风笔记不能只剩当前一版/空串
        check("archive.roundTripVariants") {
            var payload = ProjectPayload()
            payload.world.styleNotes = "STYLE_NOTE"
            var message = ChatMessage(id: "m-roundtrip", role: .assistant, content: "v0")
            message.variants = ["v0", "v1", "v2"]
            message.selectedVariant = 1
            payload.messages = [message]
            let project = Project(id: "roundtrip", title: "往返")
            let backup = FrthinkArchive.ProjectBackup(
                project: project,
                payload: payload,
                sourceText: "",
                translations: [
                    TranslationSegment(
                        owner: "owner",
                        project: project.id,
                        sourceHash: "hash-1",
                        segment: 0,
                        payload: "第一段译文"
                    )
                ],
                universeEntries: []
            )
            let data = try FrthinkArchive.makeFullArchive(
                settings: AppSettings(),
                projects: [backup],
                activeProjectID: project.id
            )
            let reopened = try FrthinkArchive.readFullBackup(data)
            let restored = reopened.projects[0].snapshot.projectPayload
            try expect(
                restored.messages.first?.variants == ["v0", "v1", "v2"],
                "导出后消息版本丢失：\(restored.messages.first?.variants ?? [])"
            )
            try expect(
                restored.messages.first?.selectedVariant == 1,
                "导出后选中版本错位：\(restored.messages.first?.selectedVariant ?? -1)"
            )
            try expect(
                restored.world.styleNotes == "STYLE_NOTE",
                "导出后文风笔记丢失：\(restored.world.styleNotes)"
            )
            let restoredTranslation = reopened.projects[0].translations.first
            try expect(
                restoredTranslation?.payload == "第一段译文"
                    && restoredTranslation?.segment == 0
                    && restoredTranslation?.project == project.id,
                "导出后译文分段丢失或归属错位"
            )
            return "消息多版本 / 文风笔记 / 译文往返 ok"
        }

        // 10 · 解码失败要说出缺哪个键
        check("archive.decodeDetail") {
            var broken = ArchiveFixture.payload()
            broken.removeValue(forKey: "projects")
            let data = try ArchiveFixture.envelope(payload: broken)
            do {
                _ = try FrthinkArchive.openAny(data)
                throw Failure(message: "缺 projects 的存档不应导入成功")
            } catch let error as FrthinkArchiveError {
                let message = error.errorDescription ?? ""
                try expect(message.contains("projects"),
                           "错误信息应带缺失键名 projects，实际：\(message)")
                return message
            }
        }

        // 12 · 思考档位请求体（关闭时不追加、开启时按供应方发对字段）
        check("llm.thinkingLevel") {
            let base = LLMRequest(model: "m", messages: [.user("hi")], stream: false)

            func body(_ request: LLMRequest, kind: ProviderKind, level: ThinkingLevel) throws -> [String: Any] {
                let data = request.jsonBody(
                    isDeepSeek: kind == .deepseek,
                    kind: kind,
                    providerLevel: level
                )
                return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            }

            let off = try body(base, kind: .deepseek, level: .off)
            try expect((off["thinking"] as? [String: String])?["type"] == "disabled",
                       "DeepSeek 关闭时应发 thinking.disabled")
            try expect(off["reasoning_effort"] == nil, "关闭时不应发 reasoning_effort")

            let deep = try body(base, kind: .deepseek, level: .max)
            try expect((deep["thinking"] as? [String: String])?["type"] == "enabled",
                       "DeepSeek 开启时应发 thinking.enabled")
            try expect(deep["reasoning_effort"] as? String == "max",
                       "DeepSeek 应发 reasoning_effort=max")
            try expect(deep["temperature"] == nil, "思考开启时不应发 temperature")

            let router = try body(base, kind: .openRouter, level: .low)
            try expect((router["reasoning"] as? [String: String])?["effort"] == "low",
                       "OpenRouter 应发 reasoning.effort=low")
            try expect(router["reasoning_effort"] == nil,
                       "OpenRouter 不应同时发 reasoning_effort")

            let compat = try body(base, kind: .openAICompatible, level: .high)
            try expect(compat["reasoning_effort"] as? String == "high",
                       "OpenAI 兼容应发 reasoning_effort=high")

            // 显式关闭思考时，即使把供应方档位设为最高也必须覆盖。
            let forcedOff = LLMRequest(
                model: "m",
                messages: [.user("hi")],
                stream: false,
                thinking: false,
                failOnLength: true
            )
            let structured = try body(forcedOff, kind: .deepseek, level: .max)
            try expect(
                (structured["thinking"] as? [String: String])?["type"] == "disabled",
                "显式关闭时应覆盖供应方档位，关闭 thinking"
            )
            try expect(structured["reasoning_effort"] == nil,
                       "关闭 thinking 后不应再发 reasoning_effort")

            return "off/deep/router/compat/explicit-close ok"
        }

        // 200 流里的 error 块不能被静默丢弃
        check("llm.streamError") {
            let errorJSON = #"{"error":{"message":"rate limit exceeded","type":"rate_limit"}}"#
            try expect(
                OpenAICompatibleClient.streamErrorDetail(from: Data(errorJSON.utf8))
                    == "rate_limit：rate limit exceeded",
                "SSE 错误块没有解出详情"
            )
            let normalJSON = #"{"choices":[{"delta":{"content":"hi"}}]}"#
            try expect(
                OpenAICompatibleClient.streamErrorDetail(from: Data(normalJSON.utf8)) == nil,
                "正常 chunk 不应被当成错误"
            )
            try expect(
                LLMError.streamError(detail: "x").localizedDescription == "生成中断：x",
                "streamError 文案不对"
            )
            return "SSE 错误块识别 ok"
        }

        // 13 · 真实备份（Real Archive Verify 注入 fixture）：解码 → 再导出 → 重开 → 落盘读回
        check("archive.realBackup") {
            guard let url = Bundle.main.url(
                forResource: "fixture-backup",
                withExtension: "frthink"
            ) else {
                return "skipped (no fixture)"
            }
            let data = try Data(contentsOf: url)
            let archive = try FrthinkArchive.openAny(data)
            guard case .full(let original) = archive else {
                throw Failure(message: "真实备份应识别为全量备份")
            }
            try expect(original.projects.count == 2,
                       "应 2 本书，实际 \(original.projects.count)")

            let first = original.projects[0].snapshot.projectPayload
            let second = original.projects[1].snapshot.projectPayload
            try expect(first.manuscript.count == 564_212,
                       "第一本正文应为 564212，实际 \(first.manuscript.count)")
            try expect(second.manuscript.count == 554_514,
                       "第二本正文应为 554514，实际 \(second.manuscript.count)")
            try expect(first.messages.count == 46 && second.messages.count == 42,
                       "消息数不对：\(first.messages.count)/\(second.messages.count)")
            try expect(first.world.characters.count == 24
                        && second.world.characters.count == 24,
                       "人物卡数不对")
            try expect(first.world.worldbookEntries.count == 1,
                       "世界书数不对")
            try expect(first.world.events.isEmpty,
                       "事件卡数不对")
            try expect(original.settings.autoConversationSummary,
                       "自动摘要开关没导入")
            try expect(original.settings.conversationSummaryThresholdPercent == 95,
                       "自动摘要阈值没导入")
            try expect(original.settings.inputBudgetTokens == 1_000_000,
                       "输入预算没导入")

            let exported = try FrthinkArchive.makeFullArchive(
                settings: original.settings,
                projects: original.projects,
                activeProjectID: original.activeProjectID
            )
            let reopened = try FrthinkArchive.readFullBackup(exported)
            try expect(reopened.projects.count == original.projects.count,
                       "导出后书数变了")
            for (before, after) in zip(original.projects, reopened.projects) {
                let a = before.snapshot.projectPayload
                let b = after.snapshot.projectPayload
                try expect(a.manuscript == b.manuscript, "导出后正文变了")
                try expect(a.messages.count == b.messages.count, "导出后消息数变了")
                try expect(a.world.characters.count == b.world.characters.count,
                           "导出后人物卡数变了")
                try expect(a.world.events.count == b.world.events.count,
                           "导出后事件卡数变了")
                try expect(a.world.currentState == b.world.currentState,
                           "导出后世界状态变了")
                try expect(before.sourceText == after.sourceText, "导出后原文变了")
            }

            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-real-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)
            let restored = try FrthinkArchive.restore(
                original.projects,
                into: files,
                ownerID: "real-fixture"
            )
            try expect(restored.count == 2, "真实备份落盘失败")
            let reloaded = files.loadFullPayload(restored[0].id)
            try expect(reloaded.manuscript.count == first.manuscript.count,
                       "落盘正文长度变了")
            return "real backup import/export/restore PASS"
        }

        // 14 · 书稿落盘加密：密文、读回、旧明文迁移、篡改拒绝
        check("store.encryption") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-enc-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)
            let projectID = "enc-fixture"
            var payload = ProjectPayload()
            payload.manuscript = "ENCRYPTION_MARKER 正文"
            try files.savePayload(payload, projectID: projectID)

            let url = files.projectDirectory(projectID)
                .appendingPathComponent("payload.json")
            let sealed = try Data(contentsOf: url)
            try expect(PayloadCipher.isEncrypted(sealed), "payload.json 应带加密魔数")
            try expect(sealed.range(of: Data("ENCRYPTION_MARKER".utf8)) == nil,
                       "密文里不应出现正文标记")
            try expect(files.loadPayload(projectID).manuscript == payload.manuscript,
                       "解密读回不一致")

            // 旧明文要自动迁移：写一份明文，读一次，文件应变成密文。
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(payload).write(to: url, options: .atomic)
            try expect(files.loadPayload(projectID).manuscript == payload.manuscript,
                       "旧明文读不回")
            let migrated = try Data(contentsOf: url)
            try expect(PayloadCipher.isEncrypted(migrated), "旧明文没有加密迁移")

            // 认证标签被改动后必须解不开，不能静默返回错数据。
            var tampered = sealed
            tampered[tampered.count - 1] ^= 0xFF
            var rejected = false
            do { _ = try PayloadCipher.open(tampered) } catch { rejected = true }
            try expect(rejected, "被篡改的密文不应解密成功")

            // 原文、译文与 payload 用同一套落盘加密。
            let sourceText = "SOURCE_MARKER 原文"
            try files.saveSource(sourceText, projectID: projectID)
            let sourceURL = files.projectDirectory(projectID)
                .appendingPathComponent("source.json")
            let sealedSource = try Data(contentsOf: sourceURL)
            try expect(PayloadCipher.isEncrypted(sealedSource), "source.json 应带加密魔数")
            try expect(
                sealedSource.range(of: Data("SOURCE_MARKER".utf8)) == nil,
                "source 密文里不应出现原文标记"
            )
            try expect(files.loadSource(projectID) == sourceText, "source 解密读回不一致")

            let segment = TranslationSegment(
                owner: "owner",
                project: projectID,
                sourceHash: "h",
                segment: 0,
                payload: "TRANSLATION_MARKER 译文",
                // ISO-8601 只保留整秒；固定时间戳避免 Date 亚秒精度导致相等断言失败。
                updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try files.saveTranslations([segment], projectID: projectID)
            let translationURL = files.projectDirectory(projectID)
                .appendingPathComponent("translations.json")
            let sealedTranslation = try Data(contentsOf: translationURL)
            try expect(
                PayloadCipher.isEncrypted(sealedTranslation),
                "translations.json 应带加密魔数"
            )
            try expect(
                sealedTranslation.range(of: Data("TRANSLATION_MARKER".utf8)) == nil,
                "translations 密文里不应出现译文标记"
            )
            try expect(
                files.loadTranslations(projectID) == [segment],
                "translations 解密读回不一致"
            )

            // 旧明文迁移：source 与 translations 都要转成密文。
            try encoder.encode(FileStore.SourceDocument(text: "OLD_SOURCE"))
                .write(to: sourceURL, options: .atomic)
            try expect(files.loadSource(projectID) == "OLD_SOURCE", "旧 source 明文读不回")
            let migratedSource = try Data(contentsOf: sourceURL)
            try expect(
                PayloadCipher.isEncrypted(migratedSource),
                "旧 source 明文没有加密迁移"
            )

            try encoder.encode([segment])
                .write(to: translationURL, options: .atomic)
            try expect(
                files.loadTranslations(projectID) == [segment],
                "旧 translations 明文读不回"
            )
            let migratedTranslation = try Data(contentsOf: translationURL)
            try expect(
                PayloadCipher.isEncrypted(migratedTranslation),
                "旧 translations 明文没有加密迁移"
            )

            // 正文独立文件：优先于 payload.json 里的旧 manuscript。
            try files.saveBody(
                "BODY_MARKER 正文",
                chapters: [Chapter(title: "第一章", location: 0)],
                projectID: projectID
            )
            let pagesURL = files.projectDirectory(projectID)
                .appendingPathComponent("body.pages", isDirectory: true)
            let pageURL = pagesURL.appendingPathComponent("0000.bin")
            let metaURL = files.projectDirectory(projectID)
                .appendingPathComponent("body.meta.json")
            let sealedPage = try Data(contentsOf: pageURL)
            try expect(PayloadCipher.isEncrypted(sealedPage), "正文页应带加密魔数")
            try expect(
                sealedPage.range(of: Data("BODY_MARKER".utf8)) == nil,
                "正文页密文里不应出现正文标记"
            )
            let sealedMeta = try Data(contentsOf: metaURL)
            try expect(PayloadCipher.isEncrypted(sealedMeta), "body.meta.json 应加密")
            try expect(files.loadBodyMeta(projectID)?.pageCount == 1, "页数元数据不对")
            try expect(
                files.loadBodyPage(projectID, index: 0) == "BODY_MARKER 正文",
                "单页解密不一致"
            )
            let bodyLoaded = files.loadFullPayload(projectID)
            try expect(bodyLoaded.manuscript == "BODY_MARKER 正文", "正文文件读回不一致")
            try expect(bodyLoaded.chapters.first?.title == "第一章", "章节索引读回不一致")

            // 缺正文文件时回退到旧 payload.json，兼容拆分前的书。
            try FileManager.default.removeItem(at: pagesURL)
            try FileManager.default.removeItem(at: metaURL)
            try expect(
                files.loadPayload(projectID).manuscript == payload.manuscript,
                "缺正文页时应回退旧 payload"
            )

            return "落盘密文 / 读回 / 明文迁移 / 篡改拒绝 / 原文与译文 / 正文独立文件 均通过"
        }

        // 损坏的 payload 不能当空书：只读打开，且任何保存都不落盘
        check("store.corruptPayload") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-corrupt-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)
            let project = Project(id: "corrupt-book", title: "损坏测试")
            try files.saveProject(project)
            let payloadURL = files.projectDirectory(project.id)
                .appendingPathComponent("payload.json")
            try Data("这不是 JSON".utf8).write(to: payloadURL, options: .atomic)

            let store = AppStore(fileStore: files)
            let session = store.openSession(for: project)
            try expect(session.isReadOnly, "损坏 payload 应按只读打开")
            try expect(
                store.errorMessage?.contains("只读") == true,
                "应上屏只读原因：\(store.errorMessage ?? "nil")"
            )

            let before = try Data(contentsOf: payloadURL)
            session.payload.composerDraft = "不应落盘"
            session.saveNow()
            let after = try Data(contentsOf: payloadURL)
            try expect(before == after, "只读会话不应覆盖 payload.json")
            return "损坏 payload 只读保护 ok"
        }

        // 15 · 摘要元数据：键格式、sourceHash、历史版本
        check("summary.metadata") {
            let helloKey = SummaryKey.messageKey(id: "abc", content: "hello")
            try expect(
                helloKey
                    == "user:abc:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
                "summary key 格式不对：\(helloKey)"
            )
            var world = WorldBook(longTermRules: "旧规则", summaryUpdatedAt: 1)
            let changed = world.applySummaryUpdate(
                content: "新规则",
                newKeys: [helloKey],
                now: 123
            )
            try expect(changed && world.longTermRules == "新规则", "摘要内容没更新")
            try expect(
                world.summarySourceHash
                    == "942c595c944e9ab6c574e53335124f9a97e0a51602586b80a2aebfc80b57edb0",
                "sourceHash 不对：\(world.summarySourceHash)"
            )
            try expect(world.summarizedMessageIDs == ["abc"], "消息 id 没回填")
            try expect(
                world.summaryPreviousRevisions.last?.content == "旧规则",
                "旧内容没进历史版本"
            )
            try expect(
                world.summaryRulesVersion == 1 && world.summaryUpdatedAt == 123,
                "规则版本或更新时间不对"
            )

            let worldKey = SummaryKey.messageKey(id: "def", content: "world")
            _ = world.applySummaryUpdate(content: "再新", newKeys: [worldKey], now: 456)
            try expect(
                world.summarySourceHash
                    == "770926506986066dc43911ce2e4ef13f0e575124d24c1806db0db24f8b6dbe9a",
                "多键 sourceHash 不对：\(world.summarySourceHash)"
            )
            for index in 0..<12 {
                _ = world.applySummaryUpdate(
                    content: "v\(index)",
                    newKeys: [],
                    now: Int64(index)
                )
            }
            try expect(
                world.summaryPreviousRevisions.count == 10,
                "历史版本应只保留 10 条，实际 \(world.summaryPreviousRevisions.count)"
            )
            return "键 / SHA-256 / 历史版本 均通过"
        }

        // 恢复上一版摘要：弹出最后一条历史，内容与源键回滚，updatedAt 记为当前
        check("summary.restore") {
            var world = WorldBook()
            let key = SummaryKey.messageKey(id: "m1", content: "要求")
            _ = world.applySummaryUpdate(content: "第一版", newKeys: [key], now: 100)
            _ = world.applySummaryUpdate(content: "第二版", newKeys: [], now: 200)
            try expect(
                world.summaryPreviousRevisions.count == 1,
                "应用两次后应有一条历史，实际 \(world.summaryPreviousRevisions.count)"
            )
            try expect(world.restorePreviousSummary(now: 300), "应能恢复上一版")
            try expect(world.longTermRules == "第一版", "恢复内容不对：\(world.longTermRules)")
            try expect(
                world.summaryPreviousRevisions.isEmpty,
                "恢复后历史应弹出"
            )
            try expect(world.summaryUpdatedAt == 300, "恢复后更新时间应为当前")
            try expect(
                world.summarySourceMessageKeys == [key],
                "恢复后源键未回滚：\(world.summarySourceMessageKeys)"
            )
            try expect(
                !world.restorePreviousSummary(now: 400),
                "没有历史时不应恢复"
            )
            return "恢复上一版 / 时间戳 ok"
        }

        // 生成中断恢复：进程在生成中被杀后，下次启动把消息标成中断。
        check("generation.recovery") {
            var payload = ProjectPayload()
            payload.generatingMessageID = "msg-1"
            try expect(
                payload.recoverInterruptedGeneration() == "msg-1",
                "未恢复生成中的消息"
            )
            try expect(payload.generatingMessageID == nil, "generatingMessageID 未清空")
            try expect(
                payload.interruptedMessageIDs == ["msg-1"],
                "中断标记未写入"
            )
            try expect(
                payload.recoverInterruptedGeneration() == nil,
                "没有生成任务时不应重复标记"
            )
            return "生成中断恢复通过"
        }

        // 16 · 大正文 JSON 编解码耗时（只记录，不做硬门槛）
        check("perf.manuscriptCodec") {
            let body = String(repeating: "字", count: 200_000)
            let payload = ProjectPayload(manuscript: body)
            let started = Date()
            let data = try FrthinkArchive.jsonEncoder.encode(payload)
            let decoded = try FrthinkArchive.jsonDecoder.decode(
                ProjectPayload.self,
                from: data
            )
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            try expect(decoded.manuscript.count == body.count,
                       "编解码后正文长度不一致")
            return "20 万字 payload 编解码 \(milliseconds)ms，\(data.count / 1024)KB"
        }

        // 17 · 章节扫描耗时（正文是拼出来的，避免测到 I/O）
        check("perf.chapterScan") {
            var parts: [String] = []
            parts.reserveCapacity(2_000)
            for index in 0..<2_000 {
                parts.append("第\(index)章 测试\n这是一段正文。\n")
            }
            let body = parts.joined()
            let started = Date()
            let chapters = ChapterScanner.scan(body)
            let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
            try expect(chapters.count == 2_000,
                       "章节数不对：应 2000，实际 \(chapters.count)")
            return "\(body.count) 字扫出 \(chapters.count) 章，\(milliseconds)ms"
        }

        // 世界书空正文仍要生成块：APK 只按 enabled 过滤，不看 content
        check("prompt.emptyWorldbook") {
            var world = WorldBook()
            world.worldbookEntries = [
                WorldbookEntry(title: "EMPTY_WORLDBOOK", body: "")
            ]
            let assembly = PromptAssembly.from(
                world: world,
                manuscript: "",
                assistantSupplement: "",
                settings: AppSettings(),
                projectID: "p-empty"
            )
            let system = PromptComposer.systemPrompt(
                from: PromptComposer.writingBlocks(assembly)
            )
            try expect(
                system.contains("# EMPTY_WORLDBOOK"),
                "空正文世界书没有生成标题块"
            )
            return "空正文世界书块 ok"
        }

        // 世界字段追加：换行分隔，不能把新事实串成一排分号
        check("world.mergePunctuation") {
            let merged = WorldMerge.appended("旧事实。", "新事实一。新事实二。")
            try expect(
                merged == "旧事实。\n新事实一。\n新事实二。",
                "追加结果不应使用分号连接：\(merged)"
            )
            try expect(!merged.contains("；"), "追加结果里不应出现分号")
            return "换行追加 ok"
        }

        // 宇宙条目：全局启用 + 本书勾选，缺一不可
        check("universe.enabledGate") {
            var settings = AppSettings()
            settings.universeEntries = [
                UniverseEntry(id: "on", title: "启用"),
                UniverseEntry(id: "off", title: "停用", enabled: false),
            ]
            let injected = settings.enabledUniverseEntries(for: ["on", "off", "missing"])
            try expect(
                injected.map(\.id) == ["on"],
                "只应注入全局启用且本书勾选的条目，实际 \(injected.map(\.id))"
            )
            try expect(
                settings.enabledUniverseEntries(for: []).isEmpty,
                "本书未勾选时不应注入"
            )
            let legacy = Data(
                #"{"id":"x","title":"旧","body":"","kind":"worldbook","updatedAt":"2026-01-01T00:00:00Z"}"#
                    .utf8
            )
            let decoded = try FrthinkArchive.jsonDecoder.decode(
                UniverseEntry.self,
                from: legacy
            )
            try expect(decoded.enabled, "旧存档缺少 enabled 时应默认启用")
            return "宇宙全局启用 / 本书勾选 ok"
        }

        // 世界 JSON 校验：两个事件数组同时出现、别称类型不对都要报错
        check("world.jsonValidation") {
            let duplicated = """
            {"events":[{"title":"甲","cause":"因"}],\
            "plot_events":[{"title":"乙","cause":"因"}]}
            """
            do {
                _ = try WorldJSON.parseEvents(duplicated)
                throw WorldRunError(message: "同时给两个事件数组时应当报错")
            } catch let error as WorldJSONError {
                try expect(
                    error.localizedDescription.contains("唯一事件数组"),
                    "事件数组报错文案不对：\(error.localizedDescription)"
                )
            }

            let badAlias = #"{"characters":[{"name":"甲","aliases":42}]}"#
            do {
                _ = try WorldJSON.parseWorldRefresh(badAlias)
                throw WorldRunError(message: "别称类型错误时应当报错")
            } catch let error as WorldJSONError {
                try expect(
                    error.localizedDescription.contains("人物别称格式无效"),
                    "别称报错文案不对：\(error.localizedDescription)"
                )
            }

            let single = try WorldJSON.parseEvents(
                #"{"plot_events":[{"title":"乙","cause":"因"}]}"#
            )
            try expect(
                single.count == 1 && single[0].title == "乙",
                "只给 plot_events 时应能解析"
            )
            return "事件数组与别称校验 ok"
        }

        // 事件字段并段：模型一句一行时不能原样上屏成短句列表
        check("world.eventProse") {
            let raw = #"{"events":[{"title":"雨夜","scene":"旧书店。\n雨声很密。","development":"她推门。\n他抬头。","consequence":"两人相认。"}]}"#
            let events = try WorldJSON.parseEvents(raw)
            try expect(events.count == 1, "应解析出一条事件")
            try expect(
                events[0].scene == "旧书店。雨声很密。",
                "场景换行未并段：\(events[0].scene)"
            )
            try expect(
                events[0].development == "她推门。他抬头。",
                "经过换行未并段：\(events[0].development)"
            )

            // 漏标点、半角标点、列表符号都要在解析时修好
            let messy = #"{"events":[{"title":"雨夜。","scene":"- 旧书店\n- 雨声很密","development":"她推门.\n他抬头!","consequence":"两人相认"}]}"#
            let fixed = try WorldJSON.parseEvents(messy)
            try expect(fixed[0].title == "雨夜", "标题应去掉句读：\(fixed[0].title)")
            try expect(
                fixed[0].scene == "旧书店，雨声很密。",
                "列表符号或分隔标点未修：\(fixed[0].scene)"
            )
            try expect(
                fixed[0].development == "她推门。他抬头！",
                "半角标点未转全角：\(fixed[0].development)"
            )
            try expect(
                fixed[0].consequence == "两人相认。",
                "段末缺句号未补：\(fixed[0].consequence)"
            )

            // 反向宽度变换来自 Foundation；中文行里的半角标点靠它转全角
            try expect(
                ",".applyingTransform(.fullwidthToHalfwidth, reverse: true) == "，",
                "Foundation 反向宽度变换不可用"
            )

            let edge = #"{"events":[{"title":" 雨夜！！ ","scene":"她推门，。他抬头","development":"她推门 。他抬头。。","consequence":"他说：“走...”"}]}"#
            let cleaned = try WorldJSON.parseEvents(edge)
            try expect(cleaned[0].title == "雨夜", "标题未去句读：\(cleaned[0].title)")
            try expect(
                cleaned[0].scene == "她推门。他抬头。",
                "逗号紧贴句号未清：\(cleaned[0].scene)"
            )
            try expect(
                cleaned[0].development == "她推门。他抬头。",
                "重复句号或标点前空格未清：\(cleaned[0].development)"
            )
            try expect(
                cleaned[0].consequence == "他说：“走……”",
                "省略号未统一：\(cleaned[0].consequence)"
            )
            return "事件字段并段与标点修复 ok"
        }

        // 大书模式：≥50 万码点走单前缀，前缀按 1.2 安全系数卡预算
        check("world.wholeTextPlan") {
            let threshold = WorldDigest.wholeTextCodePointThreshold
            try expect(
                WorldDigest.usesWholeTextPass(String(repeating: "甲", count: threshold)),
                "达到阈值时应走大书模式"
            )
            try expect(
                !WorldDigest.usesWholeTextPass(String(repeating: "甲", count: threshold - 1)),
                "低于阈值时不应走大书模式"
            )
            let text = String(repeating: "甲", count: 200)
            let prefix = WorldDigest.prefixChunk(of: text, tokenBudget: 100)
            try expect(
                !prefix.isEmpty && prefix.count < text.count,
                "前缀应非空且短于全文，实际 \(prefix.count)"
            )
            try expect(
                TokenEstimator.estimate(prefix) <= 100,
                "前缀超出预算：\(TokenEstimator.estimate(prefix))"
            )
            try expect(
                WorldDigest.prefixChunk(of: text, tokenBudget: 10_000) == text,
                "预算充足时应返回全文"
            )
            return "大书阈值 / 前缀切分 ok"
        }

        // 19 · 正文尾部窗口保存：窗口之前的页不动，窗口页替换后能拼回全文
        check("store.windowSave") {
            let files = FileStore()
            let projectID = "selfcheck-window-\(UUID().uuidString)"
            let prefix = String(repeating: "甲", count: 32_000)
            let oldTail = String(repeating: "旧", count: 8_000)
            let newTail = String(repeating: "乙", count: 100)
            try files.saveBody(prefix + oldTail, chapters: [], projectID: projectID)
            try files.saveBodyWindow(
                newTail,
                startPage: 1,
                windowStart: 32_000,
                prefixCharacterCount: 32_000,
                chapters: [],
                projectID: projectID
            )
            let loaded = files.loadFullPayload(projectID)
            try expect(
                loaded.manuscript == prefix + newTail,
                "窗口保存后拼回的正文不对"
            )
            try expect(
                files.loadBodyMeta(projectID)?.pageCount == 2,
                "窗口保存后的页数不对"
            )
            try? FileManager.default.removeItem(
                at: files.projectDirectory(projectID)
            )
            return "窗口页替换 / 全文拼回 ok"
        }

        // 18 · 阅读分页取文：块索引稳定，块跨页时拼接正确
        check("stream.window") {
            var window = StreamingTextWindow(maxCharacters: 8, trimStep: 4)
            let first = window.rendered(String(repeating: "a", count: 10))
            try expect(first.reset, "首次超窗应重置")
            try expect(first.text.hasPrefix("…\n"), "超窗应带省略标记")
            let second = window.rendered(String(repeating: "a", count: 11))
            try expect(!second.reset, "窗口未满前应纯追加")
            try expect(second.text.hasPrefix(first.text), "追加结果应保留旧前缀")
            let trimmed = window.rendered(String(repeating: "b", count: 40))
            try expect(trimmed.reset, "超过 max+trimStep 应重置")
            try expect(
                trimmed.text == "…\n" + String(repeating: "b", count: 8),
                "重置后只保留窗口大小"
            )
            let shrunk = window.rendered(String(repeating: "c", count: 10))
            try expect(shrunk.reset, "文本缩短后应重置窗口")
            try expect(
                shrunk.text == "…\n" + String(repeating: "c", count: 8),
                "缩短后仍保留末尾窗口"
            )
            return "\(second.text.count) 字追加 / \(trimmed.text.count) 字重置 ok"
        }

        check("reader.pageSource") {
            let pages = ["0123456789", "abcdefghij", "KLMNOPQRST"]
            let source = ReaderPageSource(
                pageCount: pages.count,
                pageSize: 10,
                loader: { pages[$0] }
            )
            try expect(
                source.text(in: NSRange(location: 8, length: 6)) == "89abcd",
                "跨页切片不对"
            )
            try expect(source.fullText == pages.joined(), "整本读取不对")

            let blocks = BodyBlockIndex.blocks(from: "第一段\n\n第二段")
            try expect(blocks.count == 2, "块数不对：应 2，实际 \(blocks.count)")
            return "跨页切片 / 块索引 ok"
        }

        // 提示词组装移到后台后，输出结构必须保持：system + 历史 + 本轮指令；
        // 续写把正文片段回灌成 assistant 消息。
        check("writer.promptAssembly") {
            var settings = AppSettings()
            settings.globalPreset = "全局预设"
            var world = WorldBook()
            world.plotOutline = "旧梗概不应进提示词"
            world.events = [
                EventCard(
                    title: "雨夜来客",
                    scene: "旧书店",
                    characters: ["林昭"],
                    cause: "找书",
                    development: "陌生人进门",
                    consequence: "答应第二天帮忙"
                )
            ]
            let manuscript = "开头标记" + String(repeating: "甲", count: 6_000) + "末尾片段"
            var snapshot = WriterPromptSnapshot(
                action: .send(instruction: "写到雨停"),
                manuscript: manuscript,
                messages: [
                    ChatMessage(role: .user, content: "上一轮"),
                    ChatMessage(role: .assistant, content: "上一段回复"),
                ],
                world: world,
                assistantSupplement: "",
                settings: settings,
                projectID: "writer-check",
                enabledUniverseEntryIDs: [],
                bodyPromptSendWhole: false,
                bodyPromptTailCodePoints: 5_000,
                continuationAnchor: nil,
                explicitBodyRange: .full,
                inputBudget: 100_000
            )
            let prepared = WriterPromptBuilder.prepare(snapshot)
            try expect(!prepared.messages.isEmpty, "组装结果为空")
            try expect(prepared.messages.first?.role == "system", "首条应为 system")
            try expect(prepared.messages.last?.role == "user", "末条应为本轮指令")
            try expect(
                prepared.messages.last?.content.contains("写到雨停") == true,
                "本轮指令没有进请求"
            )
            try expect(
                prepared.sourceIds.contains("body:authoritative"),
                "正文块没有进来源列表"
            )
            let system = prepared.messages.first?.content ?? ""
            try expect(system.contains("末尾片段"), "正文末尾片段没有进请求")
            try expect(!system.contains("开头标记"), "只发末尾时仍带了正文开头")
            try expect(system.contains("雨夜来客"), "事件卡没有渲染进剧情梗概块")
            try expect(
                !system.contains("旧梗概不应进提示词"),
                "剧情梗概块错误地使用了 plotOutline 死字段"
            )

            // 没有事件卡时 P08 整块不出现，也不回落到 plotOutline。
            snapshot.world.events = []
            let withoutEvents = WriterPromptBuilder.prepare(snapshot)
            try expect(
                !withoutEvents.sourceIds.contains("world:plot-outline"),
                "没有事件卡时仍生成了剧情梗概块"
            )

            snapshot.action = .continueWriting
            let continuation = WriterPromptBuilder.prepare(snapshot)
            try expect(
                continuation.messages.contains {
                    $0.role == "assistant" && $0.content.hasSuffix("末尾片段")
                },
                "续写没有把正文片段回灌成 assistant"
            )
            return "\(prepared.messages.count) 条消息 / \(prepared.estimatedInputTokens) tokens"
        }

        // 提示词回看：大快照按 token 总量封顶，小快照仍按 30 条封顶
        check("writer.snapshotBudget") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-snapshot-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)
            let project = Project(id: "snapshot-book", title: "快照测试")
            let session = ProjectSession(
                project: project,
                payload: ProjectPayload(),
                source: "",
                translations: [],
                store: files
            )
            let big = String(repeating: "字", count: 120_000)
            for _ in 0..<4 {
                session.recordRequestSnapshot(
                    model: "deepseek-chat",
                    messages: [.user(big)],
                    sourceIds: [],
                    omittedHistoryMessages: 0,
                    maxTokens: 4_096,
                    inputBudgetTokens: 32_768,
                    contextWindow: 64_000
                )
            }
            try expect(
                session.payload.requestSnapshots.count <= 2,
                "大快照没有按 token 上限裁剪：\(session.payload.requestSnapshots.count)"
            )
            for index in 0..<40 {
                session.recordRequestSnapshot(
                    model: "deepseek-chat",
                    messages: [.user("短消息 \(index)")],
                    sourceIds: [],
                    omittedHistoryMessages: 0,
                    maxTokens: 4_096,
                    inputBudgetTokens: 32_768,
                    contextWindow: 64_000
                )
            }
            try expect(
                session.payload.requestSnapshots.count <= 30,
                "小快照没有按条数封顶：\(session.payload.requestSnapshots.count)"
            )
            return "\(session.payload.requestSnapshots.count) 条快照 ok"
        }

        lines.append("=== \(failures == 0 ? "ALL PASS" : "\(failures) FAILED") ===")
        for line in lines { print(line) }
        fflush(stdout)
        return failures == 0 ? 0 : 1
    }
}
