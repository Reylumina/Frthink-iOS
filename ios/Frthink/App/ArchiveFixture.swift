// 本文件负责：自检用的 Android 形状全量备份样本。
//
// 真实备份 9.3 MB 且含用户作品，不能进仓库。这里按 2026-10-30 那份备份的实际
// 键名和类型造一份小样本（54 键快照、全量信封、gzip+base64、顶层 corpusLibrary），
// 让「导入」这条链路在模拟器里真的跑一遍。内容全部是占位文本。

import Foundation

/// 生成 Android 端 `.frthink` 全量备份的测试字节。
///
/// 结构与真实备份一致，规模缩小到几 KB：
/// ```
/// 信封 chapleap-full-backup → base64(gzip(载荷))
/// 载荷 { formatVersion, createdAt, settings, projects, activeProjectId, corpusLibrary }
/// ```
enum ArchiveFixture {

    static let firstProjectID = "p-fixture-1"
    static let secondProjectID = "p-fixture-2"

    /// 完整的全量备份文件（UTF-8 JSON 字节）。
    static func androidFullBackup() throws -> Data {
        try envelope(payload: payload())
    }

    /// 载荷对象。单独暴露出来，便于测试「缺字段」等坏档场景。
    static func payload() -> [String: Any] {
        [
            "formatVersion": 1,
            "createdAt": 1_793_326_810_543,
            "settings": settings(),
            "projects": [firstProject(), secondProject()],
            "activeProjectId": firstProjectID,
            "corpusLibrary": corpusLibrary(),
            "credentialSecrets": [String: Any](),
        ]
    }

    /// 把任意载荷包成真实信封。
    static func envelope(payload: [String: Any]) throws -> Data {
        let payloadJSON = try JSONSerialization.data(withJSONObject: payload)
        let compressed = try FrthinkGzip.compress(payloadJSON)
        let envelope: [String: Any] = [
            "format": "chapleap-full-backup",
            "version": 1,
            "compression": "gzip+base64",
            "createdAt": 1_793_326_810_543,
            "payload": compressed.base64EncodedString(),
        ]
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    // MARK: - 载荷各部分

    private static func settings() -> [String: Any] {
        [
            "globalPreset": "FIXTURE_PRESET",
            "aiFlavorRules": "FIXTURE_FLAVOR",
            "worldBuildInstruction": "FIXTURE_WORLD_BUILD",
            "plotOutlineInstruction": "FIXTURE_PLOT_INSTRUCTION",
            "imitationInstruction": "FIXTURE_IMITATION",
            "inputBudgetTokens": 100_000,
            "outputBudgetTokens": 8_192,
            "skills": [
                [
                    "id": "skill-1",
                    "name": "测试技能",
                    "prompt": "FIXTURE_SKILL",
                    "enabled": true,
                ]
            ],
            "worldbooks": [
                [
                    "id": "wb-global",
                    "title": "共享设定",
                    "keywords": "",
                    "content": "共享世界书正文",
                    "enabled": true,
                ]
            ],
            "credentials": [String: Any](),
        ]
    }

    private static func corpusLibrary() -> [String: Any] {
        [
            "id": "corpus-root",
            "name": "",
            "enabled": true,
            "entries": [Any](),
            "collections": [
                [
                    "id": "corpus-collection-1",
                    "name": "FIXTURE_CORPUS",
                    "enabled": true,
                    "entries": [
                        [
                            "source": "C0",
                            "title": "雨",
                            "text": "雨从傍晚开始下，一直没停。",
                            "category": "环境",
                            "tags": ["雨", "开场"],
                        ]
                    ],
                    "collections": [Any](),
                ]
            ],
        ]
    }

    private static func firstProject() -> [String: Any] {
        [
            "formatVersion": 1,
            "createdAt": 1_793_326_810_262,
            "projectId": firstProjectID,
            "title": "雨夜之后",
            "synopsis": "测试简介",
            "snapshot": firstSnapshot(),
            "translations": [Any](),
            "universeEntries": [Any](),
            "coverImageBase64": "",
            "branchRootId": "",
            "branchOrder": 0,
            "trashedAt": 0,
        ]
    }

    private static func secondProject() -> [String: Any] {
        [
            "formatVersion": 1,
            "createdAt": 1_793_326_810_531,
            "projectId": secondProjectID,
            "title": "旧稿",
            "synopsis": "回收站里的旧稿",
            "snapshot": secondSnapshot(),
            "translations": [Any](),
            "universeEntries": [Any](),
            "coverImageBase64": "",
            "branchRootId": "root-branch",
            "branchOrder": 2,
            "trashedAt": 1_793_326_810_531,
        ]
    }

    // MARK: - 快照

    /// 第一本书：54 个键全部给齐，覆盖消息版本、人物卡、世界书、剧情事件、
    /// 长期规则、原文、请求快照、分析断点、阅读位置。
    private static func firstSnapshot() -> [String: Any] {
        let body = """
        第一章 · 旧书店
        雨从傍晚开始下，一直没停。

        第二章 · 未寄出的信
        男人说他要找一本 ninety-two 年出版的书。
        """
        let messages: [[String: Any]] = [
            [
                "id": "m-user-1",
                "kind": "USER",
                "title": "你",
                "content": "接着写第二章。",
                "isAccepted": false,
                "versions": [
                    [
                        "id": "v-user-1",
                        "content": "接着写第二章。",
                        "source": "local",
                        "requestId": "",
                        "status": "completed",
                        "createdAt": 1_791_340_753_258,
                    ]
                ],
                "activeVersionId": "v-user-1",
            ],
            [
                "id": "m-assistant-1",
                "kind": "ASSISTANT",
                "title": "码字机",
                "content": "版本二（选中）",
                "isAccepted": false,
                "versions": [
                    [
                        "id": "v-a-1",
                        "content": "版本一",
                        "createdAt": 1_791_340_760_000,
                    ],
                    [
                        "id": "v-a-2",
                        "content": "版本二（选中）",
                        "createdAt": 1_791_340_770_000,
                    ],
                ],
                "activeVersionId": "v-a-2",
            ],
            // 有失败版本（content 为 null）的回复：选中项必须落在有正文的那版。
            [
                "id": "m-assistant-2",
                "kind": "ASSISTANT",
                "title": "码字机",
                "content": "有正文的版本",
                "isAccepted": false,
                "versions": [
                    [
                        "id": "v-b-1",
                        "content": NSNull(),
                        "createdAt": 1_791_340_780_000,
                    ],
                    [
                        "id": "v-b-2",
                        "content": "有正文的版本",
                        "createdAt": 1_791_340_790_000,
                    ],
                ],
                "activeVersionId": "v-b-2",
            ],
            // 墓碑里记着的消息，导入后应被过滤掉。
            [
                "id": "m-deleted-1",
                "kind": "ASSISTANT",
                "title": "码字机",
                "content": "这条已被删除",
                "versions": [
                    [
                        "id": "v-del-1",
                        "content": "这条已被删除",
                        "createdAt": 1_791_340_800_000,
                    ]
                ],
                "activeVersionId": "v-del-1",
            ],
        ]

        return snapshot(
            body: body,
            messages: messages,
            deletedMessageIDs: ["m-deleted-1"],
            cards: [
                [
                    "id": "card-1",
                    "name": "林昭",
                    "identity": "旧书店店主",
                    "personality": "克制",
                    "voice": "短句",
                    "goals": "守住书店",
                    "boundaries": "不长篇独白",
                    "aliases": ["小林"],
                    "memories": [
                        [
                            "id": "mem-1",
                            "content": "父亲留下的书店",
                            "evidence": "第一章",
                            "createdAt": 1_700_000_000_000,
                        ]
                    ],
                    "customEntries": [
                        ["id": "ce-1", "name": "外貌", "content": "常穿深色衬衫"]
                    ],
                    "enabled": true,
                    "groupId": "",
                ],
                [
                    "id": "card-2",
                    "name": "沈默",
                    "identity": "找书的客人",
                    "aliases": [String](),
                    "memories": [String](),
                    "customEntries": [Any](),
                    "enabled": true,
                ],
            ],
            worldbook: [
                [
                    "id": "wb-1",
                    "title": "旧书店",
                    "keywords": "",
                    "content": "两层木结构，一楼卖书，二楼存库。",
                    "enabled": true,
                    "dynamic": false,
                ]
            ]
        )
    }

    /// 第二本书：回收站状态、不带人物卡与世界书，验证空结构不会让解码失败。
    private static func secondSnapshot() -> [String: Any] {
        snapshot(
            body: "第一章\n旧稿正文。",
            messages: [Any](),
            deletedMessageIDs: [String](),
            cards: [Any](),
            worldbook: [Any]()
        )
    }

    private static func snapshot(
        body: String,
        messages: [Any],
        deletedMessageIDs: [String],
        cards: [Any],
        worldbook: [Any]
    ) -> [String: Any] {
        [
            "schemaVersion": 20,
            "coreIdentity": "fixture-identity",
            "projectRevision": 34,
            "messages": messages,
            "deletedChatMessageIds": deletedMessageIDs,
            "world": [
                "currentState": "世界设定占位",
                "plotOutline": "剧情梗概占位",
                "imitationTemplate": "仿写模板占位",
                "characters": ["林昭 · 旧书店店主", "沈默 · 找书的客人"],
                "relationships": ["林昭 → 沈默：店主与客人"],
                "events": [Any](),
                "materialChunkHashes": ["chunk-0": "abc123"],
                "materialSourceProgress": [
                    "src-1": [
                        "processedUtf16": 12_000,
                        "prefixHash": "prefix-hash",
                        "promptHash": "prompt-hash",
                    ]
                ],
                "plotEvents": [
                    [
                        "id": "pe-1",
                        "title": "雨夜来客",
                        "scene": "旧书店一楼",
                        "characters": ["林昭", "沈默"],
                        "cause": "沈默冒雨找书",
                        "development": "两人第一次照面",
                        "consequence": "约定第二天再找",
                    ]
                ],
            ],
            "projectAssistantPrompt": "补充指令",
            "characterCards": cards,
            "characterGroups": [Any](),
            "worldbooks": worldbook,
            "enabledUniverseEntryIds": ["wb-global"],
            "requestSnapshots": [
                [
                    "id": "rs-1",
                    "createdAt": 1_791_716_318_046,
                    "modelId": "deepseek-flash",
                    "sourceIds": ["body:authoritative", "preset:global"],
                    "messages": [
                        ["role": "system", "content": "系统提示词"],
                        ["role": "user", "content": "用户指令"],
                    ],
                    "estimatedInputTokens": 1_234,
                    "inputBudgetTokens": 32_768,
                    "configuredInputBudgetTokens": 32_768,
                    "modelContextWindowTokens": 64_000,
                    "outputReserveTokens": 8_192,
                    "omittedHistoryMessages": 3,
                ]
            ],
            "requestContentPool": [String: Any](),
            "conversationSummary": [
                "content": "长期规则占位",
                "sourceMessageKeys": ["k1"],
                "sourceHash": "hash",
                "enabled": true,
                "updatedAt": 1_791_716_300_000,
                "previousRevisions": [
                    [
                        "content": "旧规则",
                        "sourceMessageKeys": ["k0"],
                        "sourceHash": "old-hash",
                        "enabled": false,
                        "updatedAt": 1_791_000_000_000,
                        "rulesVersion": 1,
                    ]
                ],
                "rulesVersion": 2,
            ],
            "characterAnalysisCheckpoint": [
                "sourceSha256": "checkpoint-sha",
                "sourceCodePointCount": 100,
                "totalSegments": 2,
                "completedSegments": [
                    [
                        "index": 0,
                        "startCodePoint": 0,
                        "endCodePoint": 50,
                        "extractedFields": "{}",
                    ],
                    ["index": 1],
                ],
                "mergedDraft": NSNull(),
                "mergedCards": cards,
                "characterBaselineSha256": "baseline-sha",
                "worldMaterialSha256": "material-sha",
                "worldRefreshComplete": true,
            ],
            "localSourceDocuments": [
                [
                    "id": "doc-1",
                    "name": "原文",
                    "mediaType": "text/plain",
                    "content": "原文占位内容",
                    "enabledForPrompt": false,
                    "sendWholeSource": false,
                    "promptStartCodePoint": 0,
                    "promptEndCodePoint": 10,
                    "importedAt": 1_791_000_000_000,
                ]
            ],
            "authoritativeBody": body,
            "bodyPromptTailCodePoints": 5_000,
            "bodyPromptSendWhole": false,
            "bodyPromptStartCodePoint": 0,
            "bodyPromptEndCodePoint": (body as NSString).length,
            "bodyAppendReceiptIds": ["receipt-1"],
            "lastBodyAppendUndo": NSNull(),
            "coreBodyDocumentId": "doc-body-1",
            "coreBodyVersion": 1,
            "coreBodyLoadedAll": true,
            "coreBodyContentLength": (body as NSString).length,
            "coreBodyLoadedStart": 0,
            "coreBodyNextCursor": 0,
            "bodyLocks": [Any](),
            "pendingBodyLockIds": [Any](),
            "lockSyncError": "",
            "composerDraft": "草稿占位",
            "readerOffset": 12,
            "readerBookmarkOffset": 34,
            "formDrafts": [Any](),
            "agentTaskId": "",
            "agentRequestKey": "",
            "agentTaskEventSeq": 0,
            "agentTaskStatus": "",
            "agentTaskSummary": "",
            "agentStreamingText": "",
            "agentStreamingMessageId": "",
            "agentStreamingAppend": false,
            "agentTurns": [Any](),
            "agentTaskEvents": [Any](),
            "task": [String: Any](),
            "auditTaskId": "",
            "auditTaskStatus": "",
            "auditTaskSummary": "",
            "auditCompletedBatches": 0,
            "auditTotalBatches": 0,
            "auditChangedPatches": [Any](),
            "auditError": "",
        ]
    }
}
