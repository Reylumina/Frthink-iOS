import Foundation

extension SelfCheck {

    @MainActor
    static func runNarrativeChecks() {
        // 验证剧情图 DAG 拓扑构建、因果汇合及环/重复/断链防护。
        check("narrative.storyGraphDAGAndCycleGuard") {
            let t0 = Date(timeIntervalSince1970: 1_795_000_000)
            var graph = StoryGraph.makeInitial(
                rootID: "root",
                branchLabel: "主线",
                summary: "开篇",
                now: t0
            )
            try graph.appendNode(
                PlotNode(id: "n1", parentID: "root", summary: "入城", createdAt: t0.addingTimeInterval(10))
            )
            try graph.appendNode(
                PlotNode(id: "n2", parentID: "n1", summary: "夜探", createdAt: t0.addingTimeInterval(20))
            )
            try graph.appendNode(
                PlotNode(
                    id: "n_side",
                    parentID: "root",
                    branchLabel: "支线",
                    summary: "线人送信",
                    createdAt: t0.addingTimeInterval(15)
                ),
                moveHead: false
            )
            try graph.appendNode(
                PlotNode(
                    id: "merge",
                    parentID: "n2",
                    secondaryCausalParentIDs: ["n_side"],
                    summary: "两线汇合",
                    createdAt: t0.addingTimeInterval(30)
                )
            )
            try graph.validateAcyclic()

            let order = try graph.lineage(to: "merge").map(\.id)
            let idxRoot = order.firstIndex(of: "root") ?? -1
            let idxN1 = order.firstIndex(of: "n1") ?? -1
            let idxN2 = order.firstIndex(of: "n2") ?? -1
            let idxSide = order.firstIndex(of: "n_side") ?? -1
            let idxMerge = order.firstIndex(of: "merge") ?? -1
            try expect(
                idxRoot >= 0
                    && idxRoot < idxN1
                    && idxN1 < idxN2
                    && idxRoot < idxSide
                    && idxN2 < idxMerge
                    && idxSide < idxMerge,
                "DAG 拓扑序应保证所有因果父节点先于汇合节点，实际：\(order)"
            )

            var cycleRejected = false
            do {
                try graph.addCausalEdge(from: "merge", to: "n1")
            } catch StoryGraphError.cycleDetected {
                cycleRejected = true
            }
            try expect(cycleRejected, "制造二跳因果环时必须抛出 cycleDetected")
            try expect(
                graph.nodes["n1"]?.secondaryCausalParentIDs.isEmpty == true,
                "环检测拒绝后不得残留脏边污染图结构"
            )

            var selfLoopRejected = false
            do {
                try graph.addCausalEdge(from: "n1", to: "n1")
            } catch StoryGraphError.cycleDetected {
                selfLoopRejected = true
            }
            try expect(selfLoopRejected, "自环边必须被拒绝")

            var duplicateRejected = false
            do {
                try graph.appendNode(PlotNode(id: "n1", parentID: "root"))
            } catch StoryGraphError.duplicateNodeID("n1") {
                duplicateRejected = true
            }
            try expect(duplicateRejected, "重复节点 ID 必须抛出 duplicateNodeID")

            var missingParentRejected = false
            do {
                try graph.appendNode(PlotNode(id: "orphan", parentID: "ghost"))
            } catch StoryGraphError.missingParent {
                missingParentRejected = true
            }
            try expect(missingParentRejected, "缺失父节点必须抛出 missingParent")

            return "DAG 汇合拓扑 + 环/重复/断链防护 ok"
        }

        // 验证分支重放、检查点复用、客观事实与角色认知分离及无损回滚。
        check("narrative.branchReplayLosslessRollback") {
            let t0 = Date(timeIntervalSince1970: 1_795_100_000)
            let linEntity = EntityPage(
                id: "c_lin",
                kind: .character,
                name: "林昭",
                aliases: ["阿昭"],
                summary: "旧书店店主",
                voiceProfile: "短句克制，少用虚词",
                hardBoundaries: ["绝不在外人面前暴露左手旧伤"]
            )
            let rootDelta = PlotNodeDelta(
                directiveAdds: [
                    AuthorDirective(
                        id: "d_no_slang",
                        verbatimRule: "禁止使用现代网络流行语。",
                        scope: .global,
                        sourceNodeID: "root",
                        createdAt: t0
                    )
                ],
                entityPageUpserts: [linEntity],
                factEvents: [
                    WorldFactEvent(
                        id: "f_loc_root",
                        entityID: "c_lin",
                        attribute: WorldFactEvent.StandardAttribute.location,
                        value: "雾港旧书店",
                        nodeID: "root",
                        authority: .canonProseQuote,
                        quoteAnchor: TextSpanAnchor.make(
                            utf16Start: 0,
                            utf16Length: 10,
                            quote: "林昭坐在雾港旧书店柜台后"
                        ),
                        createdAt: t0
                    )
                ],
                epistemicBeliefs: [
                    EpistemicBelief(
                        id: "b_seal_root",
                        characterID: "c_lin",
                        topic: "玄铁令",
                        believedTruth: "只当是寻常铁牌当物",
                        knowsSecret: false,
                        authority: .canonProseQuote,
                        updatedAtNodeID: "root",
                        updatedAt: t0
                    )
                ],
                threadEvents: [
                    ProspectiveThreadEvent(
                        id: "te_plant_seal",
                        threadID: "th_seal",
                        kind: .plant,
                        goal: "玄铁令引出南疆旧部",
                        activationCue: "雨夜访客亮出同源家徽",
                        recurrence: .once,
                        relatedEntityIDs: ["c_lin"],
                        authority: .canonProseQuote,
                        nodeID: "root",
                        createdAt: t0
                    )
                ],
                pyramidPatch: NarrativePyramidPatch(addedVolumeOneLiners: ["第一卷：雾港起风"])
            )

            var graph = StoryGraph.makeInitial(rootID: "root", initialDelta: rootDelta, now: t0)
            _ = try graph.recordCheckpoint(at: "root", now: t0)

            let branchADelta1 = PlotNodeDelta(
                directiveSupersedes: [
                    DirectiveSupersede(
                        targetID: "d_no_slang",
                        replacement: AuthorDirective(
                            id: "d_secret_argot",
                            verbatimRule: "黑市暗号桥段允许使用江湖切口，旁白仍保持冷峻。",
                            scope: .global,
                            sourceNodeID: "a1",
                            createdAt: t0.addingTimeInterval(30)
                        )
                    )
                ],
                factEvents: [
                    WorldFactEvent(
                        id: "f_loc_a1",
                        entityID: "c_lin",
                        attribute: WorldFactEvent.StandardAttribute.location,
                        value: "南疆祭坛",
                        nodeID: "a1",
                        authority: .canonProseQuote,
                        createdAt: t0.addingTimeInterval(30)
                    )
                ],
                epistemicBeliefs: [
                    EpistemicBelief(
                        id: "b_seal_a1",
                        characterID: "c_lin",
                        topic: "玄铁令",
                        believedTruth: "确认其为南疆王族失落的调兵符",
                        knowsSecret: true,
                        authority: .canonProseQuote,
                        updatedAtNodeID: "a1",
                        updatedAt: t0.addingTimeInterval(30)
                    )
                ],
                threadEvents: [
                    ProspectiveThreadEvent(
                        id: "te_ready_seal",
                        threadID: "th_seal",
                        kind: .promoteReady,
                        authority: .canonProseQuote,
                        nodeID: "a1",
                        createdAt: t0.addingTimeInterval(30)
                    )
                ]
            )
            try graph.appendNode(
                PlotNode(
                    id: "a1",
                    parentID: "root",
                    branchLabel: "南疆线",
                    delta: branchADelta1,
                    createdAt: t0.addingTimeInterval(30)
                )
            )
            _ = try graph.recordCheckpoint(at: "a1", now: t0.addingTimeInterval(35))

            let branchADelta2 = PlotNodeDelta(
                factEvents: [
                    WorldFactEvent(
                        id: "f_cond_a2",
                        entityID: "c_lin",
                        attribute: WorldFactEvent.StandardAttribute.condition,
                        value: "右肩中箭",
                        nodeID: "a2",
                        authority: .canonProseQuote,
                        createdAt: t0.addingTimeInterval(60)
                    )
                ],
                threadEvents: [
                    ProspectiveThreadEvent(
                        id: "te_enacted_seal",
                        threadID: "th_seal",
                        kind: .markEnacted,
                        authority: .canonProseQuote,
                        nodeID: "a2",
                        createdAt: t0.addingTimeInterval(60)
                    )
                ]
            )
            try graph.appendNode(
                PlotNode(
                    id: "a2",
                    parentID: "a1",
                    branchLabel: "南疆线",
                    delta: branchADelta2,
                    createdAt: t0.addingTimeInterval(60)
                )
            )

            let stateA2 = try graph.replay(to: "a2")
            try expect(
                stateA2.facts(for: "c_lin")
                    .first(where: { $0.attribute == WorldFactEvent.StandardAttribute.location })?.value == "南疆祭坛"
                    && stateA2.facts(for: "c_lin")
                    .first(where: { $0.attribute == WorldFactEvent.StandardAttribute.condition })?.value == "右肩中箭",
                "分支 A2 应累计位置与伤势状态"
            )
            try expect(
                stateA2.beliefs(for: "c_lin").first?.knowsSecret == true
                    && stateA2.threads["th_seal"]?.state == .enacted,
                "分支 A2 角色认知与伏笔状态未推进"
            )
            let activeRuleIDsA2 = stateA2.directiveLedger.activeDirectives().map(\.id)
            try expect(
                activeRuleIDsA2 == ["d_secret_argot"],
                "废止替换后生效指令应为 d_secret_argot，实际：\(activeRuleIDsA2)"
            )
            let md = stateA2.entityPages["c_lin"]?.renderedMarkdown(
                resolvedFacts: stateA2.facts(for: "c_lin"),
                beliefs: stateA2.beliefs(for: "c_lin")
            ) ?? ""
            try expect(
                md.contains("南疆祭坛") && md.contains("南疆王族失落的调兵符"),
                "实体页 Markdown 渲染应同时包含世界事实与角色认知"
            )

            // 从根节点分叉到并行分支，确认无跨分支状态残留。
            let branchBDelta = PlotNodeDelta(
                factEvents: [
                    WorldFactEvent(
                        id: "f_loc_b1",
                        entityID: "c_lin",
                        attribute: WorldFactEvent.StandardAttribute.location,
                        value: "长安西市",
                        nodeID: "b1",
                        authority: .canonProseQuote,
                        createdAt: t0.addingTimeInterval(90)
                    )
                ]
            )
            try graph.appendNode(
                PlotNode(
                    id: "b1",
                    parentID: "root",
                    branchLabel: "长安线",
                    delta: branchBDelta,
                    createdAt: t0.addingTimeInterval(90)
                )
            )
            try graph.checkout(nodeID: "b1")
            let stateB1 = try graph.replay()
            try expect(
                stateB1.facts(for: "c_lin")
                    .first(where: { $0.attribute == WorldFactEvent.StandardAttribute.location })?.value == "长安西市"
                    && stateB1.facts(for: "c_lin")
                    .first(where: { $0.attribute == WorldFactEvent.StandardAttribute.condition }) == nil,
                "切换分支 B1 后不得残留分支 A2 的右肩伤势"
            )
            try expect(
                stateB1.beliefs(for: "c_lin").first?.knowsSecret == false
                    && stateB1.threads["th_seal"]?.state == .pending
                    && stateB1.directiveLedger.activeDirectives().map(\.id) == ["d_no_slang"],
                "回滚至根节点后分叉，认知、伏笔与作者指令必须无损还原"
            )

            let stateRoot = try graph.replay(to: "root")
            try expect(
                stateRoot.facts(for: "c_lin").first?.value == "雾港旧书店",
                "根节点原始状态必须随时无损重放"
            )
            return "分支重放 + 事实/认知分离 + 无损回滚 ok"
        }

        // 验证三级权威仲裁优先级与一次性伏笔重入锁止。
        check("narrative.authorityRankProtection") {
            let t0 = Date(timeIntervalSince1970: 1_795_200_000)
            let rootDelta = PlotNodeDelta(
                entityPageUpserts: [EntityPage(id: "c_lin", kind: .character, name: "林昭")],
                factEvents: [
                    WorldFactEvent(
                        id: "f_auth_loc",
                        entityID: "c_lin",
                        attribute: WorldFactEvent.StandardAttribute.location,
                        value: "洛阳古塔",
                        nodeID: "root",
                        authority: .authorDirective,
                        createdAt: t0
                    )
                ],
                epistemicBeliefs: [
                    EpistemicBelief(
                        id: "b_auth",
                        characterID: "c_lin",
                        topic: "师父下落",
                        believedTruth: "仍在北境闭关",
                        knowsSecret: true,
                        authority: .authorDirective,
                        updatedAtNodeID: "root",
                        updatedAt: t0
                    )
                ],
                threadEvents: [
                    ProspectiveThreadEvent(
                        id: "te_once_p",
                        threadID: "th_once",
                        kind: .plant,
                        goal: "古塔钟声示警",
                        recurrence: .once,
                        relatedEntityIDs: ["c_lin"],
                        authority: .canonProseQuote,
                        nodeID: "root",
                        createdAt: t0
                    ),
                    ProspectiveThreadEvent(
                        id: "te_once_e",
                        threadID: "th_once",
                        kind: .markEnacted,
                        authority: .canonProseQuote,
                        nodeID: "root",
                        createdAt: t0
                    ),
                    ProspectiveThreadEvent(
                        id: "te_rec_p",
                        threadID: "th_rec",
                        kind: .plant,
                        goal: "月圆夜旧疾复发",
                        recurrence: .recurring,
                        relatedEntityIDs: ["c_lin"],
                        authority: .canonProseQuote,
                        nodeID: "root",
                        createdAt: t0
                    ),
                    ProspectiveThreadEvent(
                        id: "te_rec_e",
                        threadID: "th_rec",
                        kind: .markEnacted,
                        authority: .canonProseQuote,
                        nodeID: "root",
                        createdAt: t0
                    ),
                ]
            )

            var graph = StoryGraph.makeInitial(rootID: "root", initialDelta: rootDelta, now: t0)
            let attackDelta = PlotNodeDelta(
                factEvents: [
                    WorldFactEvent(
                        id: "f_ai_loc",
                        entityID: "c_lin",
                        attribute: WorldFactEvent.StandardAttribute.location,
                        value: "街头客栈",
                        nodeID: "n1",
                        authority: .inferredByAI,
                        createdAt: t0.addingTimeInterval(10)
                    ),
                    WorldFactEvent(
                        id: "f_prose_loc",
                        entityID: "c_lin",
                        attribute: WorldFactEvent.StandardAttribute.location,
                        value: "港口码头",
                        nodeID: "n1",
                        authority: .canonProseQuote,
                        createdAt: t0.addingTimeInterval(11)
                    ),
                ],
                epistemicBeliefs: [
                    EpistemicBelief(
                        id: "b_ai_override",
                        characterID: "c_lin",
                        topic: "师父下落",
                        believedTruth: "已死于魔教伏击",
                        knowsSecret: false,
                        authority: .inferredByAI,
                        updatedAtNodeID: "n1",
                        updatedAt: t0.addingTimeInterval(12)
                    )
                ],
                threadEvents: [
                    ProspectiveThreadEvent(
                        id: "te_once_rearm",
                        threadID: "th_once",
                        kind: .promoteReady,
                        authority: .inferredByAI,
                        nodeID: "n1",
                        createdAt: t0.addingTimeInterval(13)
                    ),
                    ProspectiveThreadEvent(
                        id: "te_rec_rearm",
                        threadID: "th_rec",
                        kind: .promoteReady,
                        authority: .canonProseQuote,
                        nodeID: "n1",
                        createdAt: t0.addingTimeInterval(14)
                    ),
                ]
            )
            try graph.appendNode(
                PlotNode(id: "n1", parentID: "root", delta: attackDelta, createdAt: t0.addingTimeInterval(10))
            )

            let afterAttack = try graph.replay(to: "n1")
            try expect(
                afterAttack.facts(for: "c_lin").first?.value == "洛阳古塔",
                "低权威推断与常规引用不得覆盖作者手改设定"
            )
            try expect(
                afterAttack.beliefs(for: "c_lin").first?.believedTruth == "仍在北境闭关",
                "低权威推断不得覆盖高权威角色认知"
            )
            try expect(
                afterAttack.conflictWarnings.count >= 4
                    && !(afterAttack.entityPages["c_lin"]?.conflictWarnings.isEmpty ?? true),
                "拦截低权威覆写后应记录温和冲突标警"
            )
            try expect(
                afterAttack.threads["th_once"]?.state == .enacted,
                "一次性伏笔处于 enacted 时应阻止重复激活"
            )
            try expect(
                afterAttack.threads["th_rec"]?.state == .ready,
                "可重复伏笔允许再次回到 ready"
            )

            let authorOverrideDelta = PlotNodeDelta(
                factEvents: [
                    WorldFactEvent(
                        id: "f_auth_loc_updated",
                        entityID: "c_lin",
                        attribute: WorldFactEvent.StandardAttribute.location,
                        value: "剑阁密室",
                        nodeID: "n2",
                        authority: .authorDirective,
                        createdAt: t0.addingTimeInterval(20)
                    )
                ]
            )
            try graph.appendNode(
                PlotNode(
                    id: "n2",
                    parentID: "n1",
                    delta: authorOverrideDelta,
                    createdAt: t0.addingTimeInterval(20)
                )
            )
            let afterAuthor = try graph.replay(to: "n2")
            let updatedFact = afterAuthor.facts(for: "c_lin").first
            try expect(
                updatedFact?.value == "剑阁密室" && updatedFact?.supersedesEventID == "f_auth_loc",
                "同级最高权威修改必须生效并记录 supersedesEventID 替换链"
            )
            return "三级权威仲裁 + 冲突标警 + 一次性伏笔锁止 ok"
        }

        // 验证分文件 AES-256-GCM 加密写盘、单实体孤立更新及密文篡改拦截。
        check("narrative.encryptedStoreRoundTrip") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-narrative-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }

            let files = FileStore(root: root)
            let projectID = "book-enc"
            let t0 = Date(timeIntervalSince1970: 1_795_300_000)

            let e1 = EntityPage(id: "实体/测试:A", kind: .character, name: "林昭", summary: "初版摘要")
            let e2 = EntityPage(id: "loc_tower", kind: .location, name: "洛阳古塔", summary: "九层废塔")
            let delta = PlotNodeDelta(
                directiveAdds: [AuthorDirective(id: "d1", verbatimRule: "禁用水字旁废词", createdAt: t0)],
                entityPageUpserts: [e1, e2],
                factEvents: [
                    WorldFactEvent(
                        id: "f1",
                        entityID: "实体/测试:A",
                        attribute: WorldFactEvent.StandardAttribute.location,
                        value: "洛阳古塔",
                        nodeID: "root",
                        createdAt: t0
                    )
                ]
            )
            let graph = StoryGraph.makeInitial(rootID: "root", initialDelta: delta, now: t0)
            let anchorIndex = AnchorIndex(
                version: 1,
                anchors: [
                    MechanicalAnchor(
                        id: "anc_past",
                        kind: .location,
                        surfaceText: "雾港旧书店",
                        span: TextSpanAnchor.make(utf16Start: 10, utf16Length: 5, quote: "雾港旧书店")
                    ),
                    MechanicalAnchor(
                        id: "anc_future",
                        kind: .location,
                        surfaceText: "未来皇城",
                        span: TextSpanAnchor.make(utf16Start: 120, utf16Length: 4, quote: "未来皇城")
                    ),
                ],
                indexedUTF16Length: 140
            )
            var workspace = NarrativeWorkspace(
                storyGraph: graph,
                anchorIndex: anchorIndex,
                reFoldBoundary: ReFoldBoundary(
                    boundaryTurnIndex: 3,
                    stride: 3,
                    foldedStepNotes: [0: "开篇设定完成"]
                ),
                preservedStyle: PreservedStyleDistillation(styleTemplate: "短句冷峻")
            )
            try workspace.synchronizeMaterializedHead()

            try files.narrative.saveWorkspace(workspace, projectID: projectID)

            let storeDir = files.narrative.narrativeDirectory(projectID)
            let entityFiles = [
                files.narrative.entityFileURL(entityID: e1.id, projectID: projectID),
                files.narrative.entityFileURL(entityID: e2.id, projectID: projectID),
            ]
            let allEncryptedURLs = [
                storeDir.appendingPathComponent("manifest.json"),
                storeDir.appendingPathComponent("story_graph.json"),
                storeDir.appendingPathComponent("directives.json"),
                storeDir.appendingPathComponent("pyramid.json"),
            ] + entityFiles

            for url in allEncryptedURLs {
                let raw = try Data(contentsOf: url)
                try expect(
                    PayloadCipher.isEncrypted(raw),
                    "叙事工作区文件必须经过 AES-256-GCM 加密：\(url.lastPathComponent)"
                )
            }

            // 单实体孤立写盘后，确认兄弟实体密文完全未被重写。
            let towerRawBefore = try Data(contentsOf: entityFiles[1])
            var updatedE1 = e1
            updatedE1.summary = "修订后摘要"
            try files.narrative.saveEntityPage(updatedE1, projectID: projectID)
            let towerRawAfter = try Data(contentsOf: entityFiles[1])
            try expect(towerRawBefore == towerRawAfter, "单实体独立更新不得重写兄弟实体文件")
            try expect(
                files.narrative.loadEntityPage(id: e1.id, projectID: projectID)?.summary == "修订后摘要",
                "孤立读取单实体页应返回最新修订"
            )

            try files.narrative.saveEntityPage(e1, projectID: projectID)
            guard case .loaded(let loaded) = files.narrative.loadWorkspaceState(projectID: projectID) else {
                throw UnexpectedStoreStateError.notLoaded
            }
            try expect(loaded.entityPages.count == 2, "实体页往返数量应为 2")
            try expect(loaded.reFoldBoundary.foldedStepNotes[0] == "开篇设定完成", "折叠边界信息丢失")
            try expect(
                loaded.anchorIndex.anchors(beforeUTF16: 50).map(\.id) == ["anc_past"],
                "机械索引查询必须遵循因果偏移截断"
            )
            let loadedState = try loaded.materializedState()
            try expect(
                loadedState.facts(for: e1.id).first?.value == "洛阳古塔",
                "落盘读回后重放剧情图应保持一致"
            )

            // 破坏密文字节时必须明确报损坏，不可静默回退空白工作区。
            var tampered = try Data(contentsOf: entityFiles[0])
            tampered[tampered.count - 1] ^= 0xFF
            try tampered.write(to: entityFiles[0])
            let corruptedState = files.narrative.loadWorkspaceState(projectID: projectID)
            var isCorrupted = false
            if case .corrupted = corruptedState { isCorrupted = true }
            try expect(isCorrupted, "密文损坏时必须返回 .corrupted")

            return "分文件加密 + 孤立实体读写 + 损坏拦截 ok"
        }

        // 验证旧版存档导入可初始化叙事工作区并完整保留深度蒸馏资产与逐字规则。
        check("narrative.legacyArchiveImport") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-legacy-import-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)

            let androidData = try ArchiveFixture.androidFullBackup()
            let androidImported = try LegacyArchiveImporter.importFromArchiveData(
                androidData,
                into: files,
                ownerID: "local-owner"
            )
            try expect(androidImported.count == 2, "全量备份样本应导入 2 本书")
            var firstLoaded = false
            if case .loaded(let firstWS) = files.narrative.loadWorkspaceState(
                projectID: ArchiveFixture.firstProjectID
            ) {
                firstLoaded = firstWS.migratedFromLegacyAt != nil
                    && firstWS.entityPages.count >= 3
                    && !firstWS.directives.activeDirectives().isEmpty
            }
            try expect(firstLoaded, "备份首本书应自动初始化并落盘叙事工作区")

            let projectID = "distill-book"
            let title = "雾港夜行录"
            let project = Project(id: projectID, title: title, synopsis: "测试长篇")
            var world = WorldBook()
            world.styleTemplate = "短句压迫感为主；对白不加多余副词；感官锚定雨声与铁锈。"
            world.styleNotes = "动作桥段切忌空洞四字堆砌"
            world.longTermRules = "主角左手有旧伤不可无故使重剑。\n全书严格保持第一人称限知视角。"
            world.summaryEnabled = true
            world.characters = [
                CharacterCard(
                    id: "c_lin",
                    name: "林昭",
                    identity: "旧书店店主",
                    personality: "冷静寡言",
                    voice: "句尾常收在名词，反问克制",
                    goals: "查明玄铁令来源",
                    boundaries: "绝不出卖师兄\n不伤无辜百姓",
                    aliases: ["阿昭"],
                    personalMemory: "十年前见过同一枚家徽",
                    dynamicSnapshot: CharacterDynamicSnapshot(
                        location: "旧书店地窖",
                        condition: "左臂微麻",
                        possessions: ["玄铁令"]
                    )
                )
            ]
            world.worldbookEntries = [
                WorldbookEntry(
                    id: "wb_on",
                    title: "雾港潮汐历",
                    body: "每月初一雾港退潮露出一截古石阶。",
                    enabled: true
                ),
                WorldbookEntry(
                    id: "wb_off",
                    title: "废弃设定",
                    body: "不应导入禁用词条。",
                    enabled: false
                ),
            ]
            world.openThreads = [
                PlotThread(
                    id: "t_open",
                    title: "地窖铜锁",
                    obligation: "用祖传铜匙开启夹层",
                    plantedContext: "地窖墙砖后藏着一把铜锁",
                    relatedCharacters: ["林昭"],
                    status: .open
                ),
                PlotThread(
                    id: "t_done",
                    title: "当铺暗号",
                    obligation: "已对上暗号",
                    status: .resolved
                ),
            ]

            let payload = ProjectPayload(
                manuscript: "第一章 夜雨\n林昭推开木门，檐角雨水顺着石阶滴落。",
                chapters: [Chapter(title: "第一章 夜雨", location: 0)],
                world: world,
                assistantSupplement: "禁止跳过打斗细节直接总结结果。"
            )
            let backup = FrthinkArchive.ProjectBackup(
                project: project,
                payload: payload,
                sourceText: "",
                translations: [],
                universeEntries: []
            )

            var settings = AppSettings()
            settings.corpusLibraries = [
                CorpusLibrary(
                    id: "lib-style",
                    name: "本书节选 · \(title)",
                    entries: [
                        CorpusEntry(
                            source: title,
                            title: "质心段·动作短句",
                            text: "风声掠过砖缝。他反手扣住刀柄，没回头。",
                            category: "仿写样本"
                        ),
                        CorpusEntry(
                            source: title,
                            title: "变奏段·茶席对白",
                            text: "“茶凉了。”\n“那就添炭。”",
                            category: "仿写样本"
                        ),
                    ],
                    enabled: true,
                    projectID: projectID
                )
            ]
            let customArchive = try FrthinkArchive.makeFullArchive(
                settings: settings,
                projects: [backup],
                activeProjectID: projectID
            )
            let customImported = try LegacyArchiveImporter.importFromArchiveData(
                customArchive,
                into: files,
                ownerID: "local-owner"
            )
            try expect(customImported.count == 1, "自定义存档应导入 1 本书")
            let result = customImported[0]
            try expect(
                result.workspace.preservedStyle.styleTemplate == world.styleTemplate
                    && result.workspace.preservedStyle.styleNotes == world.styleNotes
                    && result.workspace.preservedStyle.exemplars.count == 2
                    && result.workspace.preservedStyle.centroidExemplar?.title == "质心段·动作短句",
                "深度蒸馏模板、笔记与代表节选必须原封保留"
            )

            let renderedRules = result.workspace.directives.renderedAuthorityBlock()
            try expect(
                renderedRules.contains("主角左手有旧伤不可无故使重剑。")
                    && renderedRules.contains("禁止跳过打斗细节直接总结结果。")
                    && !renderedRules.contains("参考"),
                "长期规则与补充指令应逐字进入规则账本且不含弱化表述"
            )

            let state = try result.workspace.materializedState()
            try expect(
                state.entityPages["c_lin"]?.hardBoundaries.count == 2
                    && state.entityPages["wb_on"]?.kind == .lore
                    && state.entityPages["wb_off"] == nil,
                "角色独立页、启用世界书应落位，禁用词条应跳过"
            )
            try expect(
                state.threads["t_open"]?.state == .pending
                    && state.threads["t_done"]?.state == .satisfied
                    && state.threads["t_open"]?.relatedEntityIDs == ["c_lin"],
                "未决/已决伏笔状态及角色 ID 关联不正确"
            )
            try expect(
                state.bookIndexLines(maxLines: 200).count <= 200
                    && files.loadBody(projectID)?.text == payload.manuscript,
                "目录索引行数不得越界且分页正文须完整还原"
            )

            return "深度蒸馏保留 + 逐字规则 + 独立页/伏笔导入 ok"
        }

        // 验证单步增量解析：原文凭据升级权威、无引用降级保护高权威、并丢弃臆断计划条目。
        check("narrative.typedDeltaExtraction") {
            let excerpt = "雨夜里，林昭踏进南疆祭坛，握紧了袖中的半枚玄铁印。"
            let lin = EntityPage(id: "c_lin", kind: .character, name: "林昭")
            let thread = ProspectiveThread(
                id: "th_seal",
                goal: "辨认玄铁印来源",
                state: .pending,
                plantedAtNodeID: "root",
                updatedAtNodeID: "root"
            )
            let messages = NarrativeDeltaExtractor.buildExtractionMessages(
                excerpt: excerpt,
                knownEntities: [lin],
                activeThreads: [thread]
            )
            try expect(messages.count == 2 && messages[0].role == "system", "增量抽取消息应包含系统与用户两段")

            let rawResponse = """
            ```json
            {
              "facts": [
                {
                  "entity_id": "c_lin",
                  "attribute": "location",
                  "value": "南疆祭坛",
                  "quote": "林昭踏进南疆祭坛"
                },
                {
                  "entity_id": "c_lin",
                  "attribute": "goal",
                  "value": "投靠反派",
                  "quote": "这段原文里根本没有的话"
                }
              ],
              "beliefs": [
                {
                  "character_id": "c_lin",
                  "topic": "印章归属",
                  "believed_truth": "确认印章与南疆相关",
                  "knows_secret": true,
                  "quote": "半枚玄铁印"
                }
              ],
              "threads": [
                {
                  "thread_id": "th_seal",
                  "action": "ready",
                  "quote": "半枚玄铁印"
                },
                {
                  "thread_id": "th_fake",
                  "action": "todo",
                  "goal": "下一章再买壶茶"
                }
              ],
              "todos": ["后续计划偷袭祭坛"],
              "scene_card": "林昭雨夜进入南疆祭坛并确认半枚玄铁印线索"
            }
            ```
            """
            let extracted = try NarrativeDeltaExtractor.parseDelta(
                from: rawResponse,
                excerpt: excerpt,
                nodeID: "n1"
            )
            try expect(extracted.droppedSpeculativeCount == 2, "必须丢弃全部臆断 todo/计划项")
            try expect(extracted.ungroundedFactCount == 1, "无原文引用的条目应计为 ungrounded")
            try expect(
                extracted.delta.factEvents.first?.authority == .canonProseQuote
                    && extracted.delta.factEvents.last?.authority == .inferredByAI,
                "quote 命中正文应为 canonProseQuote，未命中应降为 inferredByAI"
            )

            var state = MaterializedNarrativeState(
                atNodeID: "root",
                pathNodeIDs: ["root"],
                entityPages: ["c_lin": lin],
                activeFacts: [
                    "c_lin\u{1F}goal": WorldFactEvent(
                        id: "f_goal_auth",
                        entityID: "c_lin",
                        attribute: WorldFactEvent.StandardAttribute.goal,
                        value: "守护师门秘密",
                        nodeID: "root",
                        authority: .authorDirective
                    )
                ],
                threads: ["th_seal": thread]
            )
            NarrativeStateReducer.apply(delta: extracted.delta, nodeID: "n1", to: &state)
            try expect(
                state.facts(for: "c_lin").first(where: { $0.attribute == "location" })?.value == "南疆祭坛"
                    && state.facts(for: "c_lin").first(where: { $0.attribute == "goal" })?.value == "守护师门秘密"
                    && state.threads["th_seal"]?.state == .ready
                    && state.pyramid.recentSceneCards.count == 1,
                "归约器应放行带引用事实、拦截无引用覆写并推进伏笔与场景卡"
            )
            return "单步增量抽取 + quote 鉴权 + 丢弃臆断 ok"
        }

        // 验证零模型调用的机械锚点抽取、增量翻页追加与因果截断。
        check("narrative.mechanicalAnchorExtraction") {
            let lin = EntityPage(id: "c_lin", kind: .character, name: "林昭", aliases: ["阿昭"])
            let shop = EntityPage(id: "loc_shop", kind: .location, name: "雾港旧书店")
            let p0 = "第三章 夜风\n林昭带着两枚玄铁令走进雾港旧书店。"
            let p1 = "阿昭在三更时分听见街外钟声。"
            var index = MechanicalAnchorExtractor.rebuildIndex(
                fromPages: [p0],
                knownEntities: [lin, shop]
            )
            try expect(
                index.anchors.contains { $0.canonicalEntityID == "c_lin" && $0.surfaceText == "林昭" }
                    && index.anchors.contains { $0.canonicalEntityID == "loc_shop" }
                    && index.anchors.contains { $0.kind == .timeMarker && $0.surfaceText.contains("第三章") }
                    && index.anchors.contains { $0.kind == .artifactOrCount && $0.surfaceText.contains("两枚玄铁") },
                "首页应精准抽取人物、地点、章回时间与计数物件"
            )

            let p0Len = (p0 as NSString).length
            MechanicalAnchorExtractor.appendPage(
                p1,
                pageIndex: 1,
                baseUTF16Offset: p0Len,
                knownEntities: [lin, shop],
                to: &index
            )
            let beforeP1 = index.anchors(beforeUTF16: p0Len)
            let afterP1 = index.anchors(matching: "阿昭")
            try expect(
                !beforeP1.contains { $0.surfaceText == "阿昭" }
                    && afterP1.first?.canonicalEntityID == "c_lin"
                    && index.anchors.contains { $0.kind == .timeMarker && $0.surfaceText == "三更" },
                "追加页应识别别名与时间词并受因果偏移截断"
            )
            return "机械锚点抽取 + 增量追加 + 因果截断 ok"
        }

        // 验证旁白去 AI 味静态检查与对话引号严格豁免。
        check("narrative.proseStyleLinter") {
            let cleanBody = String(repeating: "雨水顺着青石台阶缓缓流下，屋檐铜铃一声接一声轻响，旧木门在夜风里微微晃动。", count: 2)
            let dirtyNarration = cleanBody
                + "他不由得停下脚步，心里莫名地浮现出一丝凉意，某种程度上觉得某种东西仿佛某种预示。这个念头、那个声音、这些痕迹、那些旧账都在这一刻涌来，其实不是畏惧，而是警觉——可他还是伸手推开木门——"
            let dirtyReport = ProseStyleLinter.lint(dirtyNarration)
            try expect(
                (dirtyReport.metricsPer1KChars["hollow_pronouns"] ?? 0) > StyleLintThresholds.literaryP90.hollowPronounsPer1K
                    && (dirtyReport.metricsPer1KChars["demonstrative_clutter"] ?? 0) > StyleLintThresholds.literaryP90.demonstrativeClutterPer1K
                    && (dirtyReport.metricsPer1KChars["contrastive_negation"] ?? 0) > StyleLintThresholds.literaryP90.contrastiveNegationPer1K
                    && (dirtyReport.metricsPer1KChars["narration_em_dash"] ?? 0) > StyleLintThresholds.literaryP90.narrationEmDashPer1K
                    && !dirtyReport.flaggedSpans.isEmpty,
                "高密度模板化句式与旁白破折号应全部标红定位"
            )

            let dialogueHeavy = cleanBody
                + "\n“某种程度上我也不禁有些疑惑——其实不是针对你，而是那个、这个、这些、那些旧事让人不由得在意。”"
                + "\n「仿佛某种说不清的预感——并非故意隐瞒，而是还没到时候。」"
            let dialogueReport = ProseStyleLinter.lint(dialogueHeavy)
            try expect(
                dialogueReport.flaggedSpans.isEmpty
                    && (dialogueReport.metricsPer1KChars["hollow_pronouns"] ?? -1) == 0
                    && (dialogueReport.metricsPer1KChars["contrastive_negation"] ?? -1) == 0
                    && (dialogueReport.metricsPer1KChars["narration_em_dash"] ?? -1) == 0,
                "双引号与直角引号内的人物对白必须完全豁免"
            )
            return "旁白四维标红 + 对白严格豁免 ok"
        }

        // 验证无索引因果截断 grep 与按页缓存增量 BM25 检出精度。
        check("narrative.manuscriptGrepAndIncrementalBM25") {
            let page0 = "第一章 雨夜\n雾港北岸苇荡深处泊着一艘旧乌篷船。\n船舱暗格里藏着半册账簿。船夫姓沈，左眉有一道刀疤。"
            let currentLine = "第五章 对峙\n林昭站在石阶上。"
            let spoilerLine = "\n第十章剧透\n原来旧乌篷船里藏着皇室密库钥匙。"
            let page1 = currentLine + spoilerLine
            let cutoff = (page0 as NSString).length + (currentLine as NSString).length

            let plainHits = ManuscriptIndex.grepManuscript(
                pages: [page0, page1],
                pattern: "乌篷船",
                contextLines: 1,
                regex: false,
                causalLimit: cutoff
            )
            try expect(
                plainHits.count == 1
                    && plainHits[0].pageIndex == 0
                    && !plainHits[0].contextSnippet.contains("皇室密库"),
                "因果截断 grep 不得命中或上下文泄露锚点之后的正文"
            )

            let regexHits = ManuscriptIndex.grepManuscript(
                pages: [page0, page1],
                pattern: "第[一五十]+章",
                contextLines: 0,
                regex: true,
                causalLimit: cutoff
            )
            try expect(
                regexHits.count == 2 && !regexHits.contains { $0.matchedText.contains("十") },
                "正则 grep 应精确匹配锚点前章节，过滤未来剧透章回"
            )

            var bm25 = ManuscriptIndex.IncrementalBM25Index()
            let updated0 = bm25.updatePage(index: 0, text: page0, utf16Start: 0)
            let hitCache0 = bm25.updatePage(index: 0, text: page0, utf16Start: 0)
            let updated1 = bm25.updatePage(index: 1, text: page1, utf16Start: (page0 as NSString).length)
            try expect(
                updated0 && !hitCache0 && updated1,
                "相同分页再次更新应命中内容哈希缓存跳过重算"
            )

            let recalled = bm25.recall(
                queryTerms: ["乌篷船", "暗格"],
                instructionText: "暗格里藏了什么",
                causalLimit: cutoff
            )
            try expect(
                recalled.count == 1
                    && recalled[0].text.contains("账簿")
                    && !recalled.map(\.text).joined(separator: "\n").contains("皇室密库"),
                "增量 BM25 应召回对应句窗且遵守因果截断"
            )
            return "因果 grep + 按页缓存增量 BM25 ok"
        }

        // 验证多轮写作间冻结系统前缀字节恒定、深度蒸馏静动态分流与在场最小状态裁剪。
        check("narrative.cacheFirstPrefixInvariance") {
            let t0 = Date(timeIntervalSince1970: 1_795_400_000)
            let onStageA = EntityPage(id: "c_lin", kind: .character, name: "林昭", summary: "店主")
            let onStageB = EntityPage(id: "c_shen", kind: .character, name: "沈默", summary: "访客")
            let offStage = EntityPage(id: "c_far", kind: .character, name: "北境将领", summary: "未出场角色")
            let offStage2 = EntityPage(id: "c_far2", kind: .character, name: "南疆巫祝", summary: "未出场角色")

            let rootDelta = PlotNodeDelta(
                directiveAdds: [
                    AuthorDirective(
                        id: "d_rule",
                        verbatimRule: "动作场面一律使用短句，严禁直接抒情议论。",
                        scope: .global,
                        sourceNodeID: "root",
                        createdAt: t0
                    )
                ],
                entityPageUpserts: [onStageA, onStageB, offStage, offStage2],
                factEvents: [
                    WorldFactEvent(
                        id: "f_far",
                        entityID: "c_far",
                        attribute: WorldFactEvent.StandardAttribute.location,
                        value: "极北雪原",
                        nodeID: "root",
                        createdAt: t0
                    )
                ]
            )
            var graph = StoryGraph.makeInitial(rootID: "root", initialDelta: rootDelta, now: t0)
            _ = try graph.recordCheckpoint(at: "root", now: t0)

            let centroid = CorpusEntry(
                id: "ex_centroid",
                source: "原著",
                title: "全书质心·冷峻白描",
                text: "雨点砸在瓦面上。林昭垂眼看着炉火。",
                category: "仿写样本"
            )
            let dialogueSample = CorpusEntry(
                id: "ex_dlg",
                source: "原著",
                title: "对白试探与言外之意留白",
                text: "“茶凉了。”\n“那就添炭，不急着谈旧账。”",
                category: "仿写样本"
            )
            let workspace = NarrativeWorkspace(
                storyGraph: graph,
                preservedStyle: PreservedStyleDistillation(
                    styleTemplate: "短句推进，零多余修辞",
                    centroidExemplar: centroid,
                    exemplars: [centroid, dialogueSample]
                )
            )
            var settings = AppSettings()
            settings.globalPreset = "保持悬疑氛围。"
            settings.skills = Skill.defaults

            let turn1 = NarrativeContextOrchestrator.compose(
                workspace: workspace,
                manuscript: "第一章\n林昭擦亮油灯，听见石阶外传来脚步声。",
                history: [],
                userInstruction: "写林昭在门口迎接来人",
                settings: settings,
                enabledUniverseEntryIDs: [],
                tailTier: .short,
                inputBudget: 16_000,
                enableTools: true
            )
            let turn2 = NarrativeContextOrchestrator.compose(
                workspace: workspace,
                manuscript: "第一章\n林昭擦亮油灯，听见石阶外传来脚步声。门开了，沈默抖落蓑衣上的雨水。",
                history: [.user("写林昭在门口迎接来人"), .assistant("门轴轻响，沈默走了进来。")],
                userInstruction: "写一段林昭与沈默喝茶试探的对白",
                settings: settings,
                enabledUniverseEntryIDs: [],
                tailTier: .short,
                inputBudget: 16_000,
                enableTools: true
            )

            try expect(
                turn1.frozenSystemPrefix == turn2.frozenSystemPrefix
                    && turn1.frozenSystemPrefix.contains("短句推进，零多余修辞")
                    && turn1.frozenSystemPrefix.contains("雨点砸在瓦面上"),
                "连续两轮请求的冻结系统前缀必须字节完全一致，并包含静态文风模板与全书质心样本"
            )
            let turn2TailAndUser = turn2.messages.dropFirst().map(\.content).joined(separator: "\n")
            try expect(
                turn2TailAndUser.contains("动作场面一律使用短句，严禁直接抒情议论。")
                    && turn2TailAndUser.contains("林昭")
                    && turn2TailAndUser.contains("沈默")
                    && turn2TailAndUser.contains("那就添炭")
                    && !turn2TailAndUser.contains("参考")
                    && !turn2TailAndUser.contains("极北雪原"),
                "尾部工作区应放置逐字作者规则、在场实体与动态对白样本，且隔离无关离场实体"
            )
            try expect(
                turn2.onStageEntityIDs == Set(["c_lin", "c_shen"]),
                "在场实体集合应精准命中林昭与沈默"
            )
            return "前缀字节恒定 + 蒸馏分流 + 在场裁剪 ok"
        }

        // 验证 ReFold 重复工具去重、k=3 边界折叠与 restore_turn 尾部恢复不改动前部前缀。
        check("narrative.reFoldAndRestoreTurnCacheSafety") {
            let lossless: [LLMMessage] = [
                .user("请帮我设定第零轮背景铺垫：" + String(repeating: "旧日恩怨。", count: 55)),
                .assistant("好的，先铺陈雾港早年的码头争端。" + String(repeating: "细节推演。", count: 55)),
                .toolResult(callID: "tc_1", content: "第 1 页：旧船契写明归属沈家。"),
                .user("再查一遍那份契约有没有重复条目。" + String(repeating: "复核确认。", count: 55)),
                .assistant("收到，我重新核对原文脚注。" + String(repeating: "推敲润色。", count: 55)),
                .toolResult(callID: "tc_2", content: "第 1 页：旧船契写明归属沈家。"),
                .user("保持最近第一轮对白。"),
                .assistant("“你何时拿到的船契？”"),
                .user("保持最近第二轮动作。"),
                .assistant("沈默将纸折起收回袖中。"),
                .user("保持最近第三轮追问。"),
                .assistant("烛火随窗缝风声晃了一下。"),
            ]

            let plan = ReFoldManager.apply(
                history: lossless,
                boundary: ReFoldBoundary(boundaryTurnIndex: 0, stride: 3),
                modelContextWindow: 32_000,
                effectiveInputBudget: 400
            )
            try expect(
                plan.deduplicatedToolCount == 1
                    && plan.updatedBoundary.boundaryTurnIndex >= 3
                    && plan.updatedBoundary.boundaryTurnIndex % 3 == 0
                    && plan.foldedTurnCount > 0,
                "ReFold 应去重重复工具返回，并按步长 3 推进折叠边界"
            )
            try expect(
                plan.messages[5].content.contains("重复工具结果"),
                "第二次出现的相同工具返回应替换为指向首次的存根"
            )

            let state = MaterializedNarrativeState(atNodeID: "root")
            let execResult = NarrativeReadTools.execute(
                call: LLMToolCall(
                    id: "call_restore",
                    functionName: NarrativeReadTools.restoreTurnName,
                    arguments: #"{"step_range":"0-1"}"#
                ),
                context: NarrativeToolContext(
                    pages: [],
                    causalLimit: nil,
                    materializedState: state,
                    losslessHistory: lossless
                )
            )
            try expect(
                execResult.output.contains("步骤 #0")
                    && execResult.output.contains("旧日恩怨")
                    && plan.messages[0].content.contains("已折叠步骤 #0"),
                "restore_turn 应从无损历史恢复原文，而不修改已折叠的前部前缀"
            )
            return "ReFold 去重/分块折叠 + restore_turn 无损复原 ok"
        }

        // 验证三项只读工具执行器与无工具渠道 BM25 降级预补检，以及 WriterPromptBuilder 入口路由。
        check("narrative.readOnlyToolsAndFallback") {
            let page0 = "第一章 雨港\n栈桥下栓着一艘黑漆铁锚，锚爪刻着三道云纹。\n沈默记下了暗纹位置。"
            let currentSeg = "\n第五章 夜谈\n林昭问起港口旧事。"
            let spoilerSeg = "\n第十章剧透\n那只黑漆铁锚其实是皇室沉银信物。"
            let fullBody = page0 + currentSeg + spoilerSeg
            let cutoff = (page0 + currentSeg as NSString).length

            let offStageEntity = EntityPage(
                id: "c_mentor",
                kind: .character,
                name: "顾山长",
                voiceProfile: "多用半文言反问",
                hardBoundaries: ["永不踏入皇城"]
            )
            let state = MaterializedNarrativeState(
                atNodeID: "root",
                pathNodeIDs: ["root"],
                entityPages: ["c_mentor": offStageEntity],
                activeFacts: [
                    "c_mentor\u{1F}location": WorldFactEvent(
                        id: "f_m",
                        entityID: "c_mentor",
                        attribute: WorldFactEvent.StandardAttribute.location,
                        value: "南山书院",
                        nodeID: "root"
                    )
                ]
            )
            let toolCtx = NarrativeToolContext(
                pages: [page0, currentSeg + spoilerSeg],
                causalLimit: cutoff,
                materializedState: state,
                losslessHistory: []
            )

            let grepOut = NarrativeReadTools.execute(
                call: LLMToolCall(
                    id: "g1",
                    functionName: NarrativeReadTools.grepManuscriptName,
                    arguments: #"{"pattern":"黑漆铁锚","context_lines":1}"#
                ),
                context: toolCtx
            )
            try expect(
                grepOut.output.contains("三道云纹") && !grepOut.output.contains("沉银信物"),
                "grep_manuscript 工具必须精准命中历史并严守因果截断"
            )

            let entityOut = NarrativeReadTools.execute(
                call: LLMToolCall(
                    id: "r1",
                    functionName: NarrativeReadTools.readEntityPageName,
                    arguments: #"{"entity_id":"顾山长","section":"行为底线"}"#
                ),
                context: toolCtx
            )
            try expect(
                entityOut.output.contains("永不踏入皇城") && entityOut.output.contains("顾山长"),
                "read_entity_page 工具应按别名或名称读取离场实体对应章节"
            )

            // 验证 WriterPromptBuilder 接入无工具渠道时的自动降级预检索。
            var delta = PlotNodeDelta(entityPageUpserts: [offStageEntity])
            delta.factEvents = Array(state.activeFacts.values)
            var workspace = NarrativeWorkspace(
                storyGraph: StoryGraph.makeInitial(rootID: "root", initialDelta: delta),
                anchorIndex: MechanicalAnchorExtractor.rebuildIndex(
                    fromPages: [page0],
                    knownEntities: [offStageEntity]
                )
            )
            try workspace.synchronizeMaterializedHead()

            var fallbackSettings = AppSettings()
            fallbackSettings.providers = [ProviderSetting(kind: .openCodeGo, model: "go-test")]
            fallbackSettings.activeProviderID = fallbackSettings.providers[0].id
            let preparedFallback = WriterPromptBuilder.prepare(
                WriterPromptSnapshot(
                    action: .send(instruction: "林昭回忆栈桥下黑漆铁锚的云纹"),
                    manuscript: fullBody,
                    messages: [],
                    world: WorldBook(),
                    assistantSupplement: "",
                    settings: fallbackSettings,
                    projectID: "p-fallback",
                    enabledUniverseEntryIDs: [],
                    bodyPromptSendWhole: false,
                    bodyPromptTailCodePoints: 40,
                    continuationAnchor: cutoff,
                    explicitBodyRange: .full,
                    inputBudget: 16_000,
                    narrativeWorkspace: workspace
                )
            )
            let mergedFallbackText = preparedFallback.messages.map(\.content).joined(separator: "\n")
            try expect(
                preparedFallback.tools.isEmpty
                    && preparedFallback.sourceIds.contains("narrative:fallback-bm25")
                    && mergedFallbackText.contains("三道云纹")
                    && !mergedFallbackText.contains("沉银信物"),
                "OpenCode 网关应自动关闭工具声明、启用本地 BM25 回填且严守因果截断"
            )
            return "三项只读工具 + 无工具网关自动退化本地 BM25 ok"
        }

        // 验证带工具轮次的 reasoning_content 与 tool_calls/tool_call_id 在 DeepSeek 协议下完整序列化。
        check("narrative.deepSeekToolReasoningPassthrough") {
            let toolCall = LLMToolCall(
                id: "call_ds_1",
                functionName: NarrativeReadTools.grepManuscriptName,
                arguments: #"{"pattern":"铁锚"}"#
            )
            let request = LLMRequest(
                model: "deepseek-reasoner",
                messages: [
                    .system("系统提示"),
                    .user("核查第一章铁锚刻纹"),
                    .assistantToolCalls([toolCall], content: "", reasoningContent: "先回查第一章铁锚细节再续写。"),
                    .toolResult(callID: "call_ds_1", content: "第 1 页：锚爪刻着三道云纹。"),
                ],
                tools: NarrativeReadTools.definitions
            )
            let bodyData = request.jsonBody(
                isDeepSeek: true,
                kind: .deepseek,
                providerLevel: .high
            )
            let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any]
            let msgs = (json?["messages"] as? [[String: Any]]) ?? []
            let assistantMsg = msgs.count > 2 ? msgs[2] : [:]
            let toolResultMsg = msgs.count > 3 ? msgs[3] : [:]
            let serializedTools = (json?["tools"] as? [[String: Any]]) ?? []
            try expect(
                (assistantMsg["reasoning_content"] as? String) == "先回查第一章铁锚细节再续写。"
                    && !((assistantMsg["tool_calls"] as? [[String: Any]]) ?? []).isEmpty
                    && (toolResultMsg["tool_call_id"] as? String) == "call_ds_1"
                    && serializedTools.count == 3,
                "DeepSeek 工具回合必须完整回传 reasoning_content、tool_calls、tool_call_id 与固定 3 工具 Schema"
            )
            return "DeepSeek 工具回合推理透传 ok"
        }

        // 验证未采纳草稿与候选变体隔离、采纳提交保留同页锚点与文风体检、撤销与重做同步回滚头节点。
        check("narrative.commitOnSelectAndBranchRollback") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-commit-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)

            let project = Project(id: "commit-book", title: "雾港铁锚")
            try files.saveProject(project)
            var settings = AppSettings()
            settings.sleepTimeStateSync = false
            try files.saveSettings(settings)

            let store = AppStore(fileStore: files)
            var world = WorldBook()
            world.characters = [
                CharacterCard(id: "c_lin", name: "林昭", identity: "守码头人"),
            ]
            let initialPage0 = "第一章 雨夜\n林昭提着灯走过石阶。\n\n"
            let assistantDraft =
                "林昭走上栈桥时，檐角冷雨顺着帽檐滴落。他仿佛某种宿命般不由得停住，"
                + "面前这个旧木箱不是铁锁，而是青铜暗扣——这一切令他迟疑。"
            var draftMsg = ChatMessage(id: "m_draft", role: .assistant, content: assistantDraft)
            draftMsg.variants.append("林昭跨过积水，一言未发。")
            let payload = ProjectPayload(
                manuscript: initialPage0,
                messages: [
                    ChatMessage(id: "m_user", role: .user, content: "续写走上栈桥"),
                    draftMsg,
                ],
                world: world
            )
            try files.savePayload(payload, projectID: project.id)
            try files.saveBody(initialPage0, chapters: [], projectID: project.id)

            let session = store.openSession(for: project)
            let baseline = session.ensureNarrativeWorkspace(
                settingsCorpusLibraries: store.settings.corpusLibraries
            )
            let baselineNodeCount = baseline.storyGraph.nodes.count
            let baselineHead = baseline.storyGraph.headNodeID

            try expect(
                session.narrativeWorkspace?.storyGraph.nodes.count == baselineNodeCount
                    && session.narrativeWorkspace?.storyGraph.headNodeID == baselineHead,
                "未采纳气泡与多变体绝不能提前修改剧情图"
            )

            let appendReceipt = session.appendToManuscript(assistantDraft)
            guard let commitReceipt = NarrativeCommitCoordinator.commitAcceptedProse(
                appendReceipt.text,
                sourceMessageID: "m_draft",
                insertionUTF16Offset: appendReceipt.location,
                session: session,
                store: store,
                persistSynchronously: true
            ) else {
                try expect(false, "采纳正文提交应返回有效回执")
                return ""
            }

            let committedWS = session.narrativeWorkspace
            let anchorEntities = committedWS?.anchorIndex.anchors.compactMap(\.canonicalEntityID) ?? []
            try expect(
                committedWS?.storyGraph.nodes.count == baselineNodeCount + 1
                    && committedWS?.storyGraph.headNodeID == commitReceipt.committedNodeID
                    && anchorEntities.count >= 2
                    && (committedWS?.latestStyleLint?.flaggedSpans.isEmpty == false),
                "采纳提交后应追加剧情节点、保留同页既有机械锚点并记录旁白文风体检结果"
            )

            if case .loaded(let reloaded) = files.narrative.loadWorkspaceState(projectID: project.id) {
                try expect(
                    reloaded.storyGraph.headNodeID == commitReceipt.committedNodeID
                        && reloaded.latestStyleLint != nil,
                    "采纳提交后应同步持久化叙事工作区"
                )
            } else {
                try expect(false, "采纳后磁盘应可读取最新叙事工作区")
            }

            _ = session.undoLastBodyAppend()
            NarrativeCommitCoordinator.undoCommit(commitReceipt, session: session)
            try expect(
                session.narrativeWorkspace?.storyGraph.headNodeID == baselineHead
                    && session.manuscript == initialPage0,
                "撤销采纳提交后必须无损回退剧情图头节点与正文"
            )

            let redoReceipt = session.insertIntoManuscript(appendReceipt.text, at: appendReceipt.location)
            NarrativeCommitCoordinator.redoCommit(commitReceipt, session: session)
            try expect(
                redoReceipt.location == appendReceipt.location
                    && session.narrativeWorkspace?.storyGraph.headNodeID == commitReceipt.committedNodeID,
                "重做提交后应恢复对应剧情图头节点"
            )
            return "采纳保护 + 同页锚点保留 + 撤销重做 ok"
        }

        // 验证离线记忆审计可检出矛盾认知、实体页膨胀、无凭据推断与超时伏笔，并在清理后稳定收敛。
        check("narrative.offlineDreamingAudit") {
            let t0 = Date(timeIntervalSince1970: 1_795_500_000)
            let longSummary = String(repeating: "旧档案条目；", count: 90)
            let bloatedEntity = EntityPage(
                id: "c_lin",
                kind: .character,
                name: "林昭",
                summary: longSummary,
                hardBoundaries: ["不伤无辜", "不伤无辜", "不留名号"],
                conflictWarnings: ["冲突告警一", "冲突告警二", "冲突告警三"]
            )
            let oldBelief = EpistemicBelief(
                id: "b_loc",
                characterID: "c_lin",
                topic: "location",
                believedTruth: "码头",
                knowsSecret: true,
                authority: .canonProseQuote,
                updatedAtNodeID: "root",
                quoteAnchor: TextSpanAnchor.make(utf16Start: 0, utf16Length: 6, quote: "林昭仍在码头"),
                updatedAt: t0
            )
            let inferredBelief = EpistemicBelief(
                id: "b_ungrounded",
                characterID: "c_lin",
                topic: "suspicion",
                believedTruth: "怀疑账房失窃",
                knowsSecret: false,
                authority: .inferredByAI,
                updatedAtNodeID: "root",
                quoteAnchor: nil,
                updatedAt: t0
            )
            let overdueThread = ProspectiveThread(
                id: "th_key",
                goal: "归还铜匙",
                activationCue: "入夜会面",
                intendedHorizonNodeOffset: 1,
                state: .pending,
                authority: .canonProseQuote,
                plantedAtNodeID: "root",
                updatedAtNodeID: "root",
                updatedAt: t0
            )
            let rootDelta = PlotNodeDelta(
                entityPageUpserts: [bloatedEntity],
                epistemicBeliefs: [oldBelief, inferredBelief],
                threadEvents: [
                    ProspectiveThreadEvent(
                        threadID: overdueThread.id,
                        kind: .plant,
                        goal: overdueThread.goal,
                        activationCue: overdueThread.activationCue,
                        intendedHorizonNodeOffset: 1,
                        nodeID: "root",
                        createdAt: t0
                    )
                ]
            )
            var graph = StoryGraph.makeInitial(
                rootID: "root",
                initialDelta: rootDelta,
                now: t0
            )

            let newerFact = WorldFactEvent(
                id: "f_loc_gate",
                entityID: "c_lin",
                attribute: "location",
                value: "北门",
                nodeID: "n1",
                authority: .canonProseQuote,
                quoteAnchor: TextSpanAnchor.make(utf16Start: 0, utf16Length: 6, quote: "林昭抵达北门"),
                createdAt: t0.addingTimeInterval(10)
            )
            try graph.appendNode(
                PlotNode(
                    id: "n1",
                    parentID: "root",
                    summary: "转场北门",
                    delta: PlotNodeDelta(factEvents: [newerFact]),
                    createdAt: t0.addingTimeInterval(10)
                )
            )
            try graph.appendNode(
                PlotNode(
                    id: "n2",
                    parentID: "n1",
                    summary: "城楼夜巡",
                    createdAt: t0.addingTimeInterval(20)
                )
            )

            var workspace = NarrativeWorkspace(storyGraph: graph)
            try workspace.synchronizeMaterializedHead()

            let report = try NarrativeDreamingAuditor.audit(
                workspace: workspace,
                manuscriptPages: ["第一页只写北门城楼雨夜，林昭抵达北门。"]
            )
            let kinds = Set(report.findings.map(\.kind))
            try expect(
                kinds.contains(.staleBelief)
                    && kinds.contains(.entityPageBloat)
                    && kinds.contains(.overdueThread)
                    && kinds.contains(.ungroundedFact),
                "离线记忆审计应同时检出认知冲突、实体页膨胀、超时伏笔与无凭据推断，实际：\(kinds)"
            )

            let cleanedCount = try NarrativeDreamingAuditor.applyCleanup(
                findings: report.findings,
                workspace: &workspace
            )
            try expect(cleanedCount >= 3, "清理执行应至少修复 3 项，实际：\(cleanedCount)")

            let cleanedState = try workspace.materializedState()
            let cleanEntity = cleanedState.entityPages["c_lin"]
            try expect(
                (cleanEntity?.summary.count ?? 999) <= 360
                    && (cleanEntity?.conflictWarnings.count ?? 9) <= 2
                    && (cleanEntity?.hardBoundaries.count ?? 9) == 2
                    && cleanedState.beliefs(for: "c_lin").first(where: { $0.topic == "location" })?.believedTruth == "北门"
                    && cleanedState.threads["th_key"]?.state == .ready,
                "清理节点重放后应精简膨胀实体、对齐过时认知并推进超期伏笔至就绪"
            )

            let secondReport = try NarrativeDreamingAuditor.audit(
                workspace: workspace,
                manuscriptPages: ["林昭抵达北门。"]
            )
            let remainingKinds = Set(secondReport.findings.map(\.kind))
            try expect(
                !remainingKinds.contains(.staleBelief) && !remainingKinds.contains(.entityPageBloat),
                "清理完成后再次审计不应再报过时认知与实体页膨胀"
            )
            return "离线审计 4 类检出 + 清理节点重放收敛 ok"
        }

        // 验证分支剧情推演提示词注入写作规则与就绪伏笔，并严格解析或拒绝推演 JSON 响应。
        check("narrative.storyChoicePlanning") {
            let t0 = Date(timeIntervalSince1970: 1_795_600_000)
            var ledger = AuthorDirectiveLedger()
            ledger.appendVerbatim("禁止主角在城楼对峙结束前撤退。", scope: .global, now: t0)
            let state = MaterializedNarrativeState(
                atNodeID: "n1",
                directiveLedger: ledger,
                entityPages: [
                    "c_lin": EntityPage(id: "c_lin", kind: .character, name: "林昭"),
                ],
                threads: [
                    "th_letter": ProspectiveThread(
                        id: "th_letter",
                        goal: "交出半封密信",
                        activationCue: "火把熄灭后",
                        state: .ready,
                        updatedAt: t0
                    )
                ],
                pyramid: NarrativePyramid(recentSceneCards: ["夜风吹熄城楼东角灯笼"])
            )

            let messages = StoryChoicePlanner.buildPlanningMessages(
                state: state,
                manuscriptTail: "城门绞盘吱呀作响，林昭按住剑柄。",
                desiredCount: 3
            )
            let promptText = messages.map(\.content).joined(separator: "\n")
            try expect(
                StoryChoicePlanner.recommendedTemperature == 0.75
                    && promptText.contains("禁止主角在城楼对峙结束前撤退")
                    && promptText.contains("交出半封密信"),
                "分支推演提示词必须完整携带写作规则与当前未回收伏笔"
            )

            let rawResponse = """
            ```json
            {"choices":[
              {"title":"截停城门守卒","direction":"林昭抢先踏前两步逼问来使身份","tension_hook":"可能提前惊动暗哨","involved_entity_ids":["c_lin"]},
              {"title":"交信换取筹码","direction":"亮出半封密信试探对方反应","tension_hook":"兑现伏笔但暴露行踪","involved_entity_ids":["c_lin"]}
            ]}
            ```
            """
            let choices = try StoryChoicePlanner.parseChoices(from: rawResponse, limit: 3)
            try expect(
                choices.count == 2
                    && choices[0].title == "截停城门守卒"
                    && choices[1].involvedEntityIDs == ["c_lin"],
                "合法分支 JSON 应准确解码所有核心字段"
            )

            var invalidRejected = false
            do {
                _ = try StoryChoicePlanner.parseChoices(from: #"{"choices":[]}"#)
            } catch StoryChoiceParseError.invalidStructure {
                invalidRejected = true
            }
            try expect(invalidRejected, "空分支数组必须抛出 invalidStructure 错误")
            return "分支推演提示词 + 解析/拒绝 ok"
        }

        // 验证增量脏写不会重写未修改的兄弟实体密文，以及轨道式情节图谱分叉与汇合拓扑。
        check("narrative.incrementalStoreAndRailLayout") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-inc-store-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)
            let pid = "inc-book"

            let entityA = EntityPage(id: "e_a", kind: .character, name: "林昭", summary: "初版")
            let entityB = EntityPage(id: "e_b", kind: .location, name: "旧书店", summary: "初版")
            let t0 = Date(timeIntervalSince1970: 1_795_700_000)

            var graph = StoryGraph.makeInitial(rootID: "root", branchLabel: "主线", summary: "开篇", now: t0)
            try graph.appendNode(
                PlotNode(
                    id: "main_1",
                    parentID: "root",
                    branchLabel: "主线",
                    summary: "采纳正文：雨夜推门",
                    manuscriptAnchor: TextSpanAnchor.make(utf16Start: 0, utf16Length: 10, quote: "雨夜推门"),
                    createdAt: t0.addingTimeInterval(10)
                )
            )
            try graph.appendNode(
                PlotNode(
                    id: "side_1",
                    parentID: "main_1",
                    branchLabel: "支线",
                    summary: "采纳正文：地窖试探",
                    manuscriptAnchor: TextSpanAnchor.make(utf16Start: 10, utf16Length: 10, quote: "地窖试探"),
                    createdAt: t0.addingTimeInterval(20)
                ),
                moveHead: false
            )
            try graph.appendNode(
                PlotNode(
                    id: "main_2",
                    parentID: "main_1",
                    branchLabel: "主线",
                    summary: "采纳正文：钟楼会面",
                    manuscriptAnchor: TextSpanAnchor.make(utf16Start: 12, utf16Length: 8, quote: "钟楼会面"),
                    createdAt: t0.addingTimeInterval(25)
                )
            )
            try graph.appendNode(
                PlotNode(
                    id: "merge_1",
                    parentID: "main_2",
                    secondaryCausalParentIDs: ["side_1"],
                    branchLabel: "主线",
                    summary: "两线汇合",
                    manuscriptAnchor: TextSpanAnchor.make(utf16Start: 20, utf16Length: 10, quote: "两线汇合"),
                    createdAt: t0.addingTimeInterval(30)
                )
            )

            let ws1 = NarrativeWorkspace(storyGraph: graph, entityPages: ["e_a": entityA, "e_b": entityB])
            try files.narrative.saveWorkspace(ws1, previous: nil, projectID: pid)

            let bURL = files.narrative.entityFileURL(entityID: "e_b", projectID: pid)
            let pastDate = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: bURL.path)

            var ws2 = ws1
            ws2.entityPages["e_a"]?.summary = "更新摘要"
            try files.narrative.saveWorkspace(ws2, previous: ws1, projectID: pid)

            let bAttrs = try FileManager.default.attributesOfItem(atPath: bURL.path)
            let bMTime = bAttrs[.modificationDate] as? Date
            try expect(
                bMTime == pastDate,
                "未变更的兄弟实体文件不应被增量写盘重新覆盖"
            )

            let railLayout = StoryGraphRailLayout.build(graph: graph)
            let visibleIDs = Set(railLayout.rows.map(\.id))
            let sideRow = railLayout.rows.first { $0.id == "side_1" }
            let mergeRow = railLayout.rows.first { $0.id == "merge_1" }
            try expect(
                visibleIDs.contains("main_1")
                    && visibleIDs.contains("main_2")
                    && visibleIDs.contains("side_1")
                    && visibleIDs.contains("merge_1")
                    && (sideRow?.lane ?? 0) > 0
                    && !(mergeRow?.mergeParentLanes.isEmpty ?? true),
                "轨道图谱应准确渲染主线节拍并分配支线与汇合轨道"
            )
            return "增量脏写保护 + 轨道图谱拓扑 ok"
        }

        // 验证分支作用域写作规则注入、回退历史后 ReFold 存根清理及叙事工作区超预算重试裁剪收敛。
        check("narrative.branchDirectiveAndBudgetTrimming") {
            let t0 = Date(timeIntervalSince1970: 1_795_800_000)
            var graph = StoryGraph.makeInitial(rootID: "root", branchLabel: "主线", summary: "开篇", now: t0)
            let branchRule = AuthorDirective(
                id: "d_side",
                verbatimRule: "支线必须保留雨声与铜铎风响。",
                scope: .branch(id: "夜探支线"),
                createdAt: t0
            )
            try graph.appendNode(
                PlotNode(
                    id: "side_branch",
                    parentID: "root",
                    branchLabel: "夜探支线",
                    summary: "开启夜探支线",
                    delta: PlotNodeDelta(directiveAdds: [branchRule]),
                    createdAt: t0.addingTimeInterval(10)
                )
            )
            var workspace = NarrativeWorkspace(storyGraph: graph)
            try workspace.synchronizeMaterializedHead()

            var settings = AppSettings()
            settings.providers = [ProviderSetting(kind: .deepseek, model: "deepseek-chat")]
            settings.activeProviderID = settings.providers[0].id

            let onBranch = NarrativeContextOrchestrator.compose(
                workspace: workspace,
                manuscript: "长街寂静。",
                history: [],
                userInstruction: "继续写",
                settings: settings,
                enabledUniverseEntryIDs: [],
                inputBudget: 16_000,
                enableTools: false
            )
            try expect(
                onBranch.messages.map(\.content).joined(separator: "\n").contains("支线必须保留雨声与铜铎风响"),
                "分支作用域写作规则应在处于对应分支时注入提示词"
            )

            try workspace.storyGraph.checkout(nodeID: "root")
            try workspace.synchronizeMaterializedHead()
            let onMain = NarrativeContextOrchestrator.compose(
                workspace: workspace,
                manuscript: "长街寂静。",
                history: [],
                userInstruction: "继续写",
                settings: settings,
                enabledUniverseEntryIDs: [],
                inputBudget: 16_000,
                enableTools: false
            )
            try expect(
                !onMain.messages.map(\.content).joined(separator: "\n").contains("支线必须保留雨声与铜铎风响"),
                "切回主线分支后不得继续注入其他分支局部写作规则"
            )

            // 验证对话缩短后 ReFold 清理过期存根键。
            let staleBoundary = ReFoldBoundary(
                boundaryTurnIndex: 6,
                stride: 3,
                foldedStepNotes: [0: "旧零", 5: "过期五"],
                deduplicatedStubs: [1: "step:0", 7: "step:2"]
            )
            let shrunk = ReFoldManager.apply(
                history: [.user("新首轮"), .assistant("新首答")],
                boundary: staleBoundary,
                modelContextWindow: 64_000,
                effectiveInputBudget: 16_000
            )
            try expect(
                shrunk.updatedBoundary.foldedStepNotes.isEmpty
                    && shrunk.updatedBoundary.deduplicatedStubs.isEmpty,
                "对话回退缩短后必须清理失效的 ReFold 存根记录"
            )

            // 验证开启叙事工作区且超预算时 retryAfterTrimming 可精确收敛并回传 ReFold 边界。
            let longBody = String(repeating: "城楼夜雪落满石阶与铁甲。", count: 500)
            let tightSnapshot = WriterPromptSnapshot(
                action: .send(instruction: "继续写城楼"),
                manuscript: longBody,
                messages: [],
                world: WorldBook(),
                assistantSupplement: "",
                settings: settings,
                projectID: "trim-book",
                enabledUniverseEntryIDs: [],
                bodyPromptSendWhole: true,
                bodyPromptTailCodePoints: 12_000,
                continuationAnchor: nil,
                explicitBodyRange: .full,
                inputBudget: 1_800,
                narrativeWorkspace: workspace,
                enableReadOnlyTools: false
            )
            let trimResult = try WriterPromptBuilder.retryAfterTrimming(tightSnapshot)
            var trimmedAccepted = false
            if case .prepared(let trimmedPrepared) = trimResult {
                trimmedAccepted = trimmedPrepared.estimatedInputTokens <= 1_800
                    && trimmedPrepared.updatedReFoldBoundary != nil
            }
            try expect(trimmedAccepted, "叙事工作区超预算时 retryAfterTrimming 应成功收敛至预算以内")
            return "分支规则 + 存根清理 + 超预算收敛 ok"
        }

        // 验证单源实时账本直写与 ledgers.json 持久化/缺失回填、纯剧情因果脉络检索、多厂商工具序列化与缓存 BM25 回退。
        check("narrative.liveLedgersToolsAndCausalGraph") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-live-ledger-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)
            let pid = "live-ledger-book"
            let t0 = Date(timeIntervalSince1970: 1_795_900_000)

            var graph = StoryGraph.makeInitial(rootID: "root", branchLabel: "主线", summary: "开篇", now: t0)
            try graph.appendNode(
                PlotNode(
                    id: "beat_a",
                    parentID: "root",
                    branchLabel: "主线",
                    summary: "码头接头",
                    manuscriptAnchor: TextSpanAnchor.make(utf16Start: 0, utf16Length: 8, quote: "老码头停着无灯乌篷"),
                    delta: PlotNodeDelta(
                        factEvents: [
                            WorldFactEvent(
                                entityID: "e_lin",
                                attribute: WorldFactEvent.StandardAttribute.possession,
                                value: "青铜短匙",
                                nodeID: "beat_a",
                                quoteAnchor: TextSpanAnchor.make(utf16Start: 0, utf16Length: 8, quote: "怀里揣着青铜短匙"),
                                createdAt: t0.addingTimeInterval(5)
                            )
                        ]
                    ),
                    createdAt: t0.addingTimeInterval(10)
                )
            )
            try graph.appendNode(
                PlotNode(
                    id: "beat_b",
                    parentID: "beat_a",
                    branchLabel: "支线",
                    summary: "密室破译",
                    manuscriptAnchor: TextSpanAnchor.make(utf16Start: 10, utf16Length: 8, quote: "暗格夹层铜钥匙"),
                    createdAt: t0.addingTimeInterval(20)
                ),
                moveHead: false
            )
            try graph.appendNode(
                PlotNode(
                    id: "beat_c",
                    parentID: "beat_a",
                    secondaryCausalParentIDs: ["beat_b"],
                    branchLabel: "主线",
                    summary: "雨夜对峙",
                    manuscriptAnchor: TextSpanAnchor.make(utf16Start: 20, utf16Length: 10, quote: "两人同时掏出铜钥匙"),
                    createdAt: t0.addingTimeInterval(30)
                )
            )

            let ancestors = graph.causalAncestorSummaries(of: "beat_c", limit: 8)
            let ancestorJoined = ancestors.joined(separator: "\n")
            let impactedIDs = Set(graph.downstreamImpactedNodes(of: "beat_b").map(\.id))
            try expect(
                ancestorJoined.contains("码头接头")
                    && ancestorJoined.contains("密室破译")
                    && impactedIDs.contains("beat_c"),
                "纯剧情因果图谱应跨越汇合边提取双亲祖先脉络并准确找出下游受影响节拍"
            )

            let linPage = EntityPage(id: "e_lin", kind: .character, name: "林昭", summary: "码头来客")
            var workspace = NarrativeWorkspace(storyGraph: graph, entityPages: ["e_lin": linPage])
            let nodeCountBefore = workspace.storyGraph.nodes.count

            let liveDelta = PlotNodeDelta(
                directiveAdds: [
                    AuthorDirective(
                        id: "d_live",
                        verbatimRule: "雨夜戏禁止使用现代时钟词汇。",
                        createdAt: t0.addingTimeInterval(40)
                    )
                ],
                factEvents: [
                    WorldFactEvent(
                        entityID: "e_lin",
                        attribute: WorldFactEvent.StandardAttribute.location,
                        value: "钟楼顶层",
                        nodeID: "direct",
                        quoteAnchor: TextSpanAnchor.make(utf16Start: 24, utf16Length: 6, quote: "登上钟楼顶层"),
                        createdAt: t0.addingTimeInterval(40)
                    )
                ],
                threadEvents: [
                    ProspectiveThreadEvent(
                        threadID: "th_bell",
                        kind: .plant,
                        goal: "铜钟裂痕",
                        activationCue: "敲响午夜钟声",
                        relatedEntityIDs: ["e_lin"],
                        intendedHorizonNodeOffset: 4,
                        evidenceAnchor: TextSpanAnchor.make(utf16Start: 28, utf16Length: 6, quote: "钟面生出细纹"),
                        nodeID: "direct",
                        createdAt: t0.addingTimeInterval(40)
                    )
                ]
            )
            let liveState = workspace.applyLedgerDelta(liveDelta)
            try expect(
                workspace.hasLiveLedgers
                    && workspace.storyGraph.nodes.count == nodeCountBefore
                    && liveState.directiveLedger.activeDirectives().count == 1
                    && liveState.activeFacts.values.contains { $0.value == "钟楼顶层" }
                    && liveState.threads["th_bell"]?.goal == "铜钟裂痕",
                "单源实时账本应支持 O(1) 原位更新且不向剧情图谱追加管理节点"
            )

            try files.narrative.saveWorkspace(workspace, previous: nil, projectID: pid)
            let ledgersURL = files.narrative.narrativeDirectory(pid).appendingPathComponent("ledgers.json")
            try expect(
                FileManager.default.fileExists(atPath: ledgersURL.path),
                "保存叙事工作区时必须写出加密的 ledgers.json 实时账本文件"
            )

            guard case .loaded(let reloaded) = files.narrative.loadWorkspaceState(projectID: pid) else {
                throw UnexpectedStoreStateError.notLoaded
            }
            try expect(
                reloaded.hasLiveLedgers
                    && reloaded.threads["th_bell"]?.goal == "铜钟裂痕"
                    && reloaded.activeFacts.values.contains { $0.value == "钟楼顶层" }
                    && reloaded.directives.activeDirectives().contains { $0.id == "d_live" },
                "从磁盘加载工作区应完整恢复实时账本与写作规则"
            )

            try FileManager.default.removeItem(at: ledgersURL)
            guard case .loaded(let backfilled) = files.narrative.loadWorkspaceState(projectID: pid) else {
                throw UnexpectedStoreStateError.notLoaded
            }
            try expect(
                backfilled.hasLiveLedgers
                    && backfilled.activeFacts.values.contains { $0.value == "青铜短匙" },
                "当 ledgers.json 缺失时加载路径应自动从图谱基线回填实时账本"
            )

            let toolCall = LLMToolCall(
                id: "tc_1",
                functionName: NarrativeReadTools.grepManuscriptName,
                arguments: #"{"pattern":"铜钟"}"#
            )
            let toolReq = LLMRequest(
                model: "claude-sonnet-4-5",
                messages: [
                    .system("系统提示"),
                    .user("检索铜钟线索"),
                    .assistantToolCalls([toolCall], content: ""),
                    .toolResult(callID: "tc_1", content: "第 2 页：铜钟裂痕贯顶。"),
                ],
                tools: NarrativeReadTools.definitions
            )

            let anthropicData = AnthropicClient.requestBody(for: toolReq, providerLevel: .high)
            let anthropicJSON = (try? JSONSerialization.jsonObject(with: anthropicData)) as? [String: Any]
            let anthropicMessages = (anthropicJSON?["messages"] as? [[String: Any]]) ?? []
            let anthropicTools = (anthropicJSON?["tools"] as? [[String: Any]]) ?? []
            let hasAnthropicToolUse = anthropicMessages.contains { msg in
                let blocks = (msg["content"] as? [[String: Any]]) ?? []
                return blocks.contains { ($0["type"] as? String) == "tool_use" && ($0["id"] as? String) == "tc_1" }
            }
            let hasAnthropicToolResult = anthropicMessages.contains { msg in
                let blocks = (msg["content"] as? [[String: Any]]) ?? []
                return blocks.contains {
                    ($0["type"] as? String) == "tool_result" && ($0["tool_use_id"] as? String) == "tc_1"
                }
            }
            try expect(
                hasAnthropicToolUse && hasAnthropicToolResult && !anthropicTools.isEmpty,
                "Anthropic 请求体必须准确序列化 tool_use 与 tool_result 轮次"
            )

            let geminiData = GeminiClient.requestBody(for: toolReq, providerLevel: .high)
            let geminiJSON = (try? JSONSerialization.jsonObject(with: geminiData)) as? [String: Any]
            let geminiContents = (geminiJSON?["contents"] as? [[String: Any]]) ?? []
            let geminiTools = (geminiJSON?["tools"] as? [[String: Any]]) ?? []
            let hasGeminiCall = geminiContents.contains { item in
                let parts = (item["parts"] as? [[String: Any]]) ?? []
                return parts.contains { part in
                    let call = part["functionCall"] as? [String: Any]
                    return (call?["name"] as? String) == NarrativeReadTools.grepManuscriptName
                }
            }
            let hasGeminiResponse = geminiContents.contains { item in
                let parts = (item["parts"] as? [[String: Any]]) ?? []
                return parts.contains { part in
                    let resp = part["functionResponse"] as? [String: Any]
                    return (resp?["name"] as? String) == NarrativeReadTools.grepManuscriptName
                }
            }
            try expect(
                hasGeminiCall && hasGeminiResponse && !geminiTools.isEmpty,
                "Gemini 请求体必须准确序列化 functionCall 与 functionResponse 轮次"
            )

            let page0 = "老码头青石阶下压着半截铜钥匙，林昭曾在此低声立誓。"
            let page1 = String(repeating: "风吹长街灯影微明。", count: 30) + "\n夜雨未歇，林昭独自望向街角。"
            let fullManuscript = page0 + "\n\n" + page1
            var bm25 = ManuscriptIndex.IncrementalBM25Index()
            _ = bm25.updatePage(index: 0, text: page0, utf16Start: 0)
            _ = bm25.updatePage(index: 1, text: page1, utf16Start: (page0 as NSString).length + 2)

            var settings = AppSettings()
            settings.providers = [ProviderSetting(kind: .deepseek, model: "deepseek-chat")]
            settings.activeProviderID = settings.providers[0].id

            let composed = NarrativeContextOrchestrator.compose(
                workspace: workspace,
                manuscript: fullManuscript,
                history: [],
                userInstruction: "查明铜钥匙下落",
                settings: settings,
                enabledUniverseEntryIDs: [],
                tailCodePointLimitOverride: 20,
                inputBudget: 16_000,
                enableTools: false,
                bm25Index: bm25
            )
            let mergedPrompt = composed.messages.map(\.content).joined(separator: "\n")
            try expect(
                composed.usedFallbackBM25
                    && mergedPrompt.contains("老码头青石阶下压着半截铜钥匙")
                    && mergedPrompt.contains("码头接头")
                    && mergedPrompt.contains("密室破译"),
                "关闭原生工具时编排器应使用缓存增量 BM25 召回早期正文，并将多亲本因果脉络注入工作区"
            )

            try expect(
                workspace.storyGraph.plannedBeatSummary() == nil,
                "已关联正文的节点不应误判为待写规划节拍"
            )
            try workspace.storyGraph.appendNode(
                PlotNode(
                    id: "plan_d",
                    parentID: "beat_c",
                    branchLabel: "主线",
                    summary: "码头当面拆穿假信",
                    createdAt: t0.addingTimeInterval(45)
                )
            )
            try expect(
                workspace.storyGraph.plannedBeatSummary() == "[主线] 码头当面拆穿假信",
                "未绑定正文的当前规划节拍应被准确提取"
            )
            let plannedPrompt = NarrativeContextOrchestrator.compose(
                workspace: workspace,
                manuscript: fullManuscript,
                history: [],
                userInstruction: "继续写",
                settings: settings,
                enabledUniverseEntryIDs: [],
                inputBudget: 16_000,
                enableTools: false,
                bm25Index: bm25
            )
            let plannedText = plannedPrompt.messages.map(\.content).joined(separator: "\n")
            try expect(
                plannedText.contains("【本幕待写目标】") && plannedText.contains("码头当面拆穿假信"),
                "当前待写规划节拍必须直接注入提示词工作区，不得被祖先过滤误伤"
            )

            let syncSession = ProjectSession(
                project: Project(id: "sync-book", title: "测试书"),
                payload: ProjectPayload(),
                source: "",
                translations: [],
                store: files,
                readOnly: true
            )
            _ = syncSession.ensureNarrativeWorkspace()
            syncSession.payload.world.styleTemplate = "短句白描，重动作少形容。"
            syncSession.payload.world.summaryEnabled = true
            syncSession.payload.world.longTermRules = "全书禁止出现现代热兵器。"
            syncSession.payload.world.characters = [
                CharacterCard(id: "c_shen", name: "沈夜", identity: "守夜人")
            ]
            syncSession.syncWorldChangesIntoNarrativeWorkspace()

            let syncedState = syncSession.ensureNarrativeWorkspace().currentState()
            try expect(
                syncSession.narrativeWorkspace?.preservedStyle.styleTemplate == "短句白描，重动作少形容。"
                    && syncedState.entityPages["c_shen"]?.identity == "守夜人"
                    && syncedState.directiveLedger.activeDirectives().contains {
                        $0.verbatimRule == "全书禁止出现现代热兵器。"
                    },
                "世界书流程写回的人物、仿写模板与长期规则应同步进叙事工作区"
            )

            syncSession.payload.world.longTermRules = "全书保持冷峻克制笔调。"
            syncSession.syncWorldChangesIntoNarrativeWorkspace()
            let updatedRules = syncSession.ensureNarrativeWorkspace()
                .currentState()
                .directiveLedger
                .activeDirectives()
                .map(\.verbatimRule)
            try expect(
                updatedRules.contains("全书保持冷峻克制笔调。")
                    && !updatedRules.contains("全书禁止出现现代热兵器。"),
                "更新长期规则后应替换旧导入规则，避免新旧条目并存冲突"
            )

            return "实时账本 + 纯因果图谱 + 多端工具请求 + BM25 回退 + 规划目标 + 同步联动 ok"
        }
    }

    private enum UnexpectedStoreStateError: Error {
        case notLoaded
    }
}
