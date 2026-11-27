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
            let messages = NarrativeDeltaExtractor.buildExtractionPayload(
                excerpt: excerpt,
                knownEntities: [lin],
                activeThreads: [thread]
            ).messages
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
                extracted.delta.factEvents.count == 1
                    && extracted.delta.factEvents.first?.authority == .canonProseQuote,
                "quote 命中正文应保留为 canonProseQuote，未命中非撤回事实应被门控拦截"
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
                    && !index.anchors.contains { $0.surfaceText.contains("两枚玄铁") },
                "首页应精准抽取人物、地点与章回标记，并过滤泛量词噪声"
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
                    && !index.anchors.contains { $0.surfaceText == "三更" },
                "追加页应识别别名并受因果偏移截断，同时避免非章回时间噪声"
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
                effectiveInputBudget: 950
            )
            try expect(
                plan.deduplicatedToolCount == 1
                    && plan.updatedBoundary.boundaryTurnIndex == 3
                    && plan.foldedTurnCount == 3,
                "ReFold 应去重重复工具返回，并按步长 3 非破坏性滑窗折叠"
            )
            try expect(
                plan.messages.contains { $0.content.contains("重复工具结果") },
                "保留区内的重复工具返回应替换为指向首次的存根"
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
                    && (plan.messages.first?.content.contains("已滑出窗口步骤 #0-2") ?? false),
                "restore_turn 应从无损历史恢复原文，同时前部滑窗只生成紧凑边界提示"
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
                    && session.narrativeWorkspace?.storyGraph.nodes.count == baselineNodeCount
                    && session.narrativeWorkspace?.storyGraph.nodes[commitReceipt.committedNodeID] == nil
                    && session.manuscript == initialPage0,
                "撤销采纳提交后必须从剧情线修剪对应节拍并无损回退进度与正文"
            )

            let redoReceipt = session.insertIntoManuscript(appendReceipt.text, at: appendReceipt.location)
            NarrativeCommitCoordinator.redoCommit(commitReceipt, session: session)
            try expect(
                redoReceipt.location == appendReceipt.location
                    && session.narrativeWorkspace?.storyGraph.headNodeID == commitReceipt.committedNodeID
                    && session.narrativeWorkspace?.storyGraph.nodes.count == baselineNodeCount + 1,
                "重做提交后应恢复对应剧情节拍与分支进度"
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

            let activeLayout = StoryActivePathLayout.build(graph: graph)
            let visibleIDs = Set(activeLayout.rows.map(\.id))
            let main1Row = activeLayout.rows.first { $0.id == "main_1" }
            let mergeRow = activeLayout.rows.first { $0.id == "merge_1" }
            try expect(
                visibleIDs.contains("main_1")
                    && visibleIDs.contains("main_2")
                    && visibleIDs.contains("merge_1")
                    && !visibleIDs.contains("side_1")
                    && activeLayout.totalNodeCount == 5
                    && (main1Row?.alternateBranches.contains { $0.tipNode.id == "side_1" && $0.branchLabel == "支线" } ?? false)
                    && activeLayout.otherBranchTips.contains { $0.tipNode.id == "side_1" }
                    && mergeRow?.isHead == true
                    && mergeRow?.node.secondaryCausalParentIDs == ["side_1"],
                "激活主路径布局应线性展开当前分支，并在分叉节点汇总可用支线入口与汇合关系"
            )
            return "增量脏写保护 + 激活主路径布局 ok"
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
                        entityPageUpserts: [
                            EntityPage(id: "e_lin", kind: .character, name: "林昭", summary: "码头来客")
                        ],
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
            syncSession.syncWorldChangesIntoNarrativeWorkspace(
                syncLegacyCharacters: true,
                syncLongTermRules: true
            )

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
            syncSession.syncWorldChangesIntoNarrativeWorkspace(
                syncLegacyCharacters: true,
                syncLongTermRules: true
            )
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

        // 验证撤回对话关联剧情节拍级联修剪/撤销恢复、四类设定抽取合并及级联删除。
        check("narrative.entityExtractionAndRollback") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-entity-rollback-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)
            let session = ProjectSession(
                project: Project(id: "rollback-book", title: "回退与设定测试"),
                payload: ProjectPayload(),
                source: "",
                translations: [],
                store: files,
                readOnly: true
            )
            var ws = session.ensureNarrativeWorkspace()
            let t0 = Date(timeIntervalSince1970: 1_796_000_000)

            try ws.storyGraph.appendNode(
                PlotNode(
                    id: "c1",
                    parentID: "root",
                    branchLabel: "主线",
                    summary: "第一幕",
                    manuscriptAnchor: TextSpanAnchor.make(utf16Start: 0, utf16Length: 4, quote: "雨落石阶"),
                    sourceMessageID: "msg_ai_1",
                    delta: PlotNodeDelta(
                        entityPageUpserts: [
                            EntityPage(id: "char_lin", kind: .character, name: "林昭")
                        ],
                        factEvents: [
                            WorldFactEvent(
                                entityID: "char_lin",
                                attribute: WorldFactEvent.StandardAttribute.location,
                                value: "青石巷",
                                nodeID: "c1"
                            )
                        ]
                    ),
                    createdAt: t0.addingTimeInterval(10)
                )
            )
            try ws.storyGraph.appendNode(
                PlotNode(
                    id: "c2",
                    parentID: "c1",
                    branchLabel: "主线",
                    summary: "第二幕",
                    manuscriptAnchor: TextSpanAnchor.make(utf16Start: 4, utf16Length: 4, quote: "推门入室"),
                    sourceMessageID: "msg_ai_2",
                    delta: PlotNodeDelta(
                        factEvents: [
                            WorldFactEvent(
                                entityID: "char_lin",
                                attribute: WorldFactEvent.StandardAttribute.location,
                                value: "暗室",
                                nodeID: "c2"
                            )
                        ],
                        epistemicBeliefs: [
                            EpistemicBelief(
                                characterID: "char_lin",
                                topic: "暗格",
                                believedTruth: "已打开",
                                knowsSecret: true,
                                updatedAtNodeID: "c2"
                            )
                        ]
                    ),
                    createdAt: t0.addingTimeInterval(20)
                )
            )
            try ws.synchronizeMaterializedHead()
            session.noteNarrativeWorkspaceUpdated(ws)

            guard let savedSnapshot = session.pruneStoryNodes(forMessageIDs: ["msg_ai_1"]) else {
                try expect(false, "撤回绑定节拍的消息时必须剪除对应节拍及其下游子节拍")
                return ""
            }
            try expect(
                session.narrativeWorkspace?.storyGraph.nodes["c1"] == nil
                    && session.narrativeWorkspace?.storyGraph.nodes["c2"] == nil
                    && session.narrativeWorkspace?.storyGraph.headNodeID == "root"
                    && session.narrativeWorkspace?.activeFacts.isEmpty == true
                    && session.narrativeWorkspace?.epistemicBeliefs.isEmpty == true,
                "撤回早期消息应级联修剪其引出的剧情子树并将头节点与支线账本同步退回根节拍"
            )

            session.restoreStoryRollback(savedSnapshot)
            let restoredState = session.narrativeWorkspace?.currentState()
            try expect(
                session.narrativeWorkspace?.storyGraph.nodes["c1"] != nil
                    && session.narrativeWorkspace?.storyGraph.nodes["c2"] != nil
                    && session.narrativeWorkspace?.storyGraph.headNodeID == "c2"
                    && restoredState?.facts(for: "char_lin").first?.value == "暗室"
                    && restoredState?.beliefs(for: "char_lin").first?.believedTruth == "已打开",
                "撤销撤回提示条后应完整恢复先前修剪的剧情线及对应的支线事实与认知"
            )

            try session.addPlotBeat(summary: "夜探：地窖试探")
            _ = session.pruneStoryNodes(
                forMessageIDs: ["msg_u_3"],
                removedUserContents: ["夜探：地窖试探（触发伏笔）"]
            )
            try expect(
                session.narrativeWorkspace?.storyGraph.headNodeID == "c2"
                    && !(session.narrativeWorkspace?.storyGraph.nodes.values.contains {
                        $0.summary == "夜探：地窖试探"
                    } ?? false),
                "撤回携带规划节拍指令的用户消息时应同步清理未动笔的同名规划节拍"
            )

            let existingChar = EntityPage(
                id: "char_lin",
                kind: .character,
                name: "林昭",
                aliases: ["阿昭"],
                summary: "初入码头",
                currentFactIDs: ["fact_1"],
                conflictWarnings: ["待核对旧伤"],
                enabled: true,
                updatedAt: t0
            )
            let extractRaw = """
            {"entities":[
              {"id":"char_lin","kind":"character","name":"林昭","aliases":["林捕快"],"identity":"巡夜捕快","summary":"发现暗格铜匙","voice_profile":"言简意赅","hard_boundaries":["绝不留活口"]},
              {"id":"","kind":"location","name":"旧书店","aliases":["沈记书铺"],"identity":"接头据点","summary":"地窖通往河道"},
              {"id":"","kind":"artifact","name":"青铜短匙","aliases":[],"identity":"库房钥匙","summary":"齿痕缺角"},
              {"id":"","kind":"lore","name":"宵禁律","aliases":[],"identity":"城防制度","summary":"亥时后禁行主街"}
            ]}
            """
            let parsed = try NarrativeEntityExtractor.parseEntities(
                from: extractRaw,
                existingPages: [existingChar],
                now: t0.addingTimeInterval(30)
            )
            let byKind = Dictionary(grouping: parsed.upserts, by: \.kind)
            let mergedLin = parsed.upserts.first { $0.id == "char_lin" }
            try expect(
                parsed.added == 3
                    && parsed.updated == 1
                    && byKind[.character]?.count == 1
                    && byKind[.location]?.count == 1
                    && byKind[.artifact]?.count == 1
                    && byKind[.lore]?.count == 1
                    && mergedLin?.summary.contains("初入码头") == true
                    && mergedLin?.summary.contains("发现暗格铜匙") == true
                    && mergedLin?.aliases.contains("阿昭") == true
                    && mergedLin?.aliases.contains("林捕快") == true
                    && mergedLin?.conflictWarnings == ["待核对旧伤"]
                    && mergedLin?.currentFactIDs == ["fact_1"],
                "设定提取器应覆盖四类设定并在更新已有设定时保留原告警、原别名与事实索引"
            )

            var delWorkspace = NarrativeWorkspace(storyGraph: StoryGraph.makeInitial(now: t0))
            delWorkspace.applyLedgerDelta(
                PlotNodeDelta(
                    entityPageUpserts: [existingChar],
                    factEvents: [
                        WorldFactEvent(entityID: "char_lin", attribute: "所在地", value: "旧书店", nodeID: "root")
                    ],
                    epistemicBeliefs: [
                        EpistemicBelief(characterID: "char_lin", topic: "密室", believedTruth: "未知", knowsSecret: false, updatedAtNodeID: "root")
                    ]
                )
            )
            let deleted = delWorkspace.deleteEntityPage(id: "char_lin")
            try expect(
                deleted
                    && delWorkspace.entityPages["char_lin"] == nil
                    && delWorkspace.activeFacts.isEmpty
                    && delWorkspace.epistemicBeliefs.isEmpty,
                "删除设定档案时应同步级联清除绑定到该设定的已知事实与角色认知"
            )

            return "撤回修剪恢复 + 四类设定提取合并 + 级联删除 ok"
        }

        // 验证五项记忆补强：分支账本隔离与全局保留、工具开启下轻量保底预检+金字塔/POV注入、
        // 新实体自动发现去重、分层金字塔滚动汇总，以及 pendingSync/activePOV 持久化往返。
        check("narrative.memorySystemUpgrades") {
            let t0 = Date(timeIntervalSince1970: 1_795_900_000)
            let lin = EntityPage(id: "c_lin", kind: .character, name: "林昭", aliases: ["阿昭"])
            let shen = EntityPage(id: "c_shen", kind: .character, name: "沈砚")
            let globalRule = AuthorDirective(
                id: "d_global",
                verbatimRule: "全文维持冷峻克制笔触。",
                scope: .global,
                createdAt: t0
            )
            let rootInit = PlotNode(
                id: "root",
                branchLabel: "主线",
                summary: "开篇",
                delta: PlotNodeDelta(
                    directiveAdds: [globalRule],
                    entityPageUpserts: [lin, shen]
                ),
                createdAt: t0
            )
            var graph = StoryGraph(rootNodeID: "root", headNodeID: "root", nodes: ["root": rootInit])
            try graph.appendNode(
                PlotNode(
                    id: "main_1",
                    parentID: "root",
                    branchLabel: "主线",
                    summary: "林昭独探码头",
                    delta: PlotNodeDelta(
                        factEvents: [
                            WorldFactEvent(entityID: "c_lin", attribute: "location", value: "老码头", nodeID: "main_1", authority: .canonProseQuote)
                        ],
                        epistemicBeliefs: [
                            EpistemicBelief(characterID: "c_lin", topic: "暗门", believedTruth: "通向江边", knowsSecret: true, authority: .canonProseQuote, updatedAtNodeID: "main_1"),
                            EpistemicBelief(characterID: "c_shen", topic: "内鬼", believedTruth: "赵二才是叛徒", knowsSecret: true, authority: .canonProseQuote, updatedAtNodeID: "main_1"),
                        ],
                        threadEvents: [
                            ProspectiveThreadEvent(threadID: "th_a", kind: .plant, goal: "归还铜匙", nodeID: "main_1")
                        ]
                    ),
                    createdAt: t0.addingTimeInterval(10)
                )
            )
            try graph.appendNode(
                PlotNode(
                    id: "branch_b",
                    parentID: "root",
                    branchLabel: "支线B",
                    summary: "改走北门客栈",
                    delta: PlotNodeDelta(
                        factEvents: [
                            WorldFactEvent(entityID: "c_lin", attribute: "location", value: "北门客栈", nodeID: "branch_b", authority: .canonProseQuote)
                        ]
                    ),
                    createdAt: t0.addingTimeInterval(20)
                ),
                moveHead: false
            )

            var ws = NarrativeWorkspace(storyGraph: graph)
            try ws.synchronizeMaterializedHead()
            let manualLore = EntityPage(id: "lore_manual", kind: .lore, name: "海禁密令", identity: "子时闭港")
            ws.applyLedgerDelta(PlotNodeDelta(entityPageUpserts: [manualLore]), sourceNodeID: "main_1")

            let branchBState = try ws.checkoutBranch(to: "branch_b", now: t0.addingTimeInterval(30))
            try expect(
                branchBState.threads["th_a"] == nil
                    && branchBState.epistemicBeliefs["c_lin\u{1F}暗门"] == nil
                    && branchBState.activeFacts["c_lin\u{1F}location"]?.value == "北门客栈"
                    && branchBState.directiveLedger.activeDirectives().contains { $0.id == "d_global" }
                    && branchBState.entityPages["lore_manual"] != nil,
                "切换支线后应隔离目标分支账本事件，同时保留全局规则与手动新增设定页"
            )

            let mainRestored = try ws.checkoutBranch(to: "main_1", now: t0.addingTimeInterval(40))
            try expect(
                mainRestored.threads["th_a"] != nil
                    && mainRestored.activeFacts["c_lin\u{1F}location"]?.value == "老码头"
                    && mainRestored.entityPages["lore_manual"] != nil,
                "回切旧分支时应完整恢复该支线的缓存账本快照而不丢失增量"
            )

            ws.pyramid = NarrativePyramid(
                volumeOneLiners: ["第一卷：雾港潮声下的暗线初现"],
                closedPlotlines: ["林昭在旧书店识破伪造信函"],
                recentSceneCards: ["雨夜潜行至老码头岸边"]
            )
            let p0 = "林昭记得老码头青石阶下压着半截铜钥匙，雨点打在石缝间发出闷响。"
            let p1 = String(repeating: "夜色沉沉，潮声漫过堤岸。", count: 12) + "林昭与沈砚在廊下对视。"
            let fullText = p0 + "\n\n" + p1
            var bm25 = ManuscriptIndex.IncrementalBM25Index()
            _ = bm25.updatePage(index: 0, text: p0, utf16Start: 0)
            _ = bm25.updatePage(index: 1, text: p1, utf16Start: (p0 as NSString).length + 2)

            var settings = AppSettings()
            settings.providers = [ProviderSetting(kind: .deepseek, model: "deepseek-chat")]
            settings.activeProviderID = settings.providers[0].id

            let composed = NarrativeContextOrchestrator.compose(
                workspace: ws,
                manuscript: fullText,
                history: [],
                userInstruction: "铜钥匙，老码头，留意沈砚神色",
                settings: settings,
                enabledUniverseEntryIDs: [],
                tailCodePointLimitOverride: 40,
                inputBudget: 16_000,
                enableTools: true,
                povCharacterID: "c_lin",
                bm25Index: bm25
            )
            let merged = composed.messages.map(\.content).joined(separator: "\n")
            let volumeCount = merged.components(separatedBy: "第一卷：雾港潮声下的暗线初现").count - 1
            try expect(
                !composed.usedFallbackBM25
                    && volumeCount == 1
                    && !composed.frozenSystemPrefix.contains("第一卷：雾港潮声下的暗线初现")
                    && !composed.frozenSystemPrefix.contains("bookIndexLines")
                    && merged.contains("第一卷：雾港潮声下的暗线初现")
                    && merged.contains("林昭在旧书店识破伪造信函")
                    && merged.contains("高关联早期细节预检")
                    && merged.contains("老码头青石阶下压着半截铜钥匙")
                    && !merged.contains("赵二才是叛徒"),
                "开启工具时应把易变卷纲置于动态槽位以维持冻结前缀稳定性，并保持 POV 私有认知隔离"
            )

            var oneHopWS = ws
            let zhaoOffStage = EntityPage(id: "c_zhao", kind: .character, name: "赵二", identity: "漕帮暗桩")
            oneHopWS.applyLedgerDelta(
                PlotNodeDelta(
                    entityPageUpserts: [zhaoOffStage],
                    factEvents: [
                        WorldFactEvent(
                            entityID: "c_lin",
                            attribute: WorldFactEvent.StandardAttribute.relation,
                            value: "暗中追查赵二行踪",
                            nodeID: "main_1",
                            authority: .canonProseQuote
                        )
                    ]
                ),
                sourceNodeID: "main_1"
            )
            let oneHopPrompt = NarrativeContextOrchestrator.compose(
                workspace: oneHopWS,
                manuscript: "林昭独自站在老码头石阶前。",
                history: [],
                userInstruction: "林昭查看码头潮水",
                settings: settings,
                enabledUniverseEntryIDs: [],
                tailCodePointLimitOverride: 40,
                inputBudget: 16_000,
                enableTools: false
            )
            let oneHopJoined = oneHopPrompt.messages.map(\.content).joined(separator: "\n")
            try expect(
                oneHopPrompt.onStageEntityIDs.contains("c_lin")
                    && !oneHopPrompt.onStageEntityIDs.contains("c_zhao")
                    && oneHopJoined.contains("【关联离场实体（一跳）】")
                    && oneHopJoined.contains("赵二")
                    && oneHopJoined.contains("漕帮暗桩"),
                "纯符号一跳关系扩展应将在场实体关系指向的离场启用实体轻量带入上下文"
            )

            var recencyBM25 = ManuscriptIndex.IncrementalBM25Index()
            let rP0 = "青铜短匙静静躺在潮湿石缝里。"
            let rP1 = String(repeating: "风吹过长廊暮色渐沉。", count: 3)
            let rP2 = "青铜短匙静静躺在潮湿石缝里。"
            _ = recencyBM25.updatePage(index: 0, text: rP0, utf16Start: 0)
            _ = recencyBM25.updatePage(index: 1, text: rP1, utf16Start: (rP0 as NSString).length + 2)
            _ = recencyBM25.updatePage(
                index: 2,
                text: rP2,
                utf16Start: (rP0 as NSString).length + (rP1 as NSString).length + 4
            )
            let recencyHits = recencyBM25.recall(
                queryTerms: ["青铜短匙"],
                instructionText: "石缝",
                excludeTrailingUTF16: 0,
                maxResults: 1,
                maxTokens: 500
            )
            try expect(
                recencyHits.first?.index == 2 && recencyHits.first?.text == rP2,
                "BM25 词法得分相近时应借助极轻加法近因决胜优先召回更近段落"
            )

            var deleteBranchWS = ws
            _ = deleteBranchWS.deleteEntityPage(id: "c_lin")
            let afterDeleteToB = try deleteBranchWS.checkoutBranch(to: "branch_b", now: t0.addingTimeInterval(50))
            let afterDeleteToMain = try deleteBranchWS.checkoutBranch(to: "main_1", now: t0.addingTimeInterval(60))
            try expect(
                afterDeleteToB.entityPages["c_lin"] == nil
                    && afterDeleteToB.facts(for: "c_lin").isEmpty
                    && afterDeleteToMain.entityPages["c_lin"] == nil
                    && afterDeleteToMain.facts(for: "c_lin").isEmpty,
                "全局删除实体档案后跨分支切换不得在快照重放中复活该实体及其残留事实"
            )

            let excerpt = "沈清秋推开松鹤楼的后门，低声提起那只南诏秘匣。"
            let discoveryJSON = """
            {"new_entities":[
              {"name":"林昭","kind":"character","identity":"重复实体"},
              {"name":"松鹤楼","kind":"location","identity":"南城茶楼","quote":"松鹤楼的后门"},
              {"name":"南诏秘匣","kind":"artifact","identity":"紫檀木盒","aliases":["秘匣"]},
              {"name":"莫须有刺客","kind":"character","identity":"原文不存在"}
            ],"facts":[]}
            """
            let discovered = try NarrativeDeltaExtractor.parseDelta(
                from: discoveryJSON,
                excerpt: excerpt,
                nodeID: "main_1",
                knownEntities: [lin]
            )
            try expect(
                discovered.delta.entityPageUpserts.count == 2
                    && Set(discovered.delta.entityPageUpserts.map(\.name)) == ["松鹤楼", "南诏秘匣"],
                "增量解析应自动发现原文中出现的新实体，过滤已知实体与无原文依据的幻觉实体"
            )

            var pyramid = NarrativePyramid(
                recentSceneCards: ["幕1", "幕2", "幕3", "幕4", "幕5", "幕6"]
            )
            try expect(NarrativePyramidConsolidator.needsSceneRollup(in: pyramid), "6 张场拍卡应触发阶段滚动汇总")
            let cards = NarrativePyramidConsolidator.pendingSceneCardsForRollup(in: pyramid)
            let sceneSummary = NarrativePyramidConsolidator.deterministicFallbackSummary(cards, maxChars: 120)
            NarrativePyramidConsolidator.applySceneRollup(summary: sceneSummary, consumedCount: cards.count, to: &pyramid)
            try expect(
                pyramid.recentSceneCards == ["幕5", "幕6"] && pyramid.closedPlotlines.count == 1,
                "阶段滚动汇总后应保留最近 2 张场拍卡并压入 closedPlotlines"
            )

            pyramid.closedPlotlines = (1...10).map { "阶段\($0)" }
            try expect(NarrativePyramidConsolidator.needsVolumeRollup(in: pyramid), "10 条阶段摘要应触发卷纲滚动汇总")
            let plots = NarrativePyramidConsolidator.pendingPlotlinesForRollup(in: pyramid)
            let volSummary = NarrativePyramidConsolidator.deterministicFallbackSummary(plots, maxChars: 150)
            NarrativePyramidConsolidator.applyVolumeRollup(summary: volSummary, consumedCount: plots.count, to: &pyramid)
            try expect(
                pyramid.closedPlotlines == ["阶段9", "阶段10"] && pyramid.volumeOneLiners.count == 1,
                "卷纲滚动汇总后应保留最近 2 条阶段摘要并压入 volumeOneLiners"
            )

            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-mem-upgrade-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            let files = FileStore(root: tempRoot)
            ws.pendingSyncNodeIDs = ["main_1", "main_2"]
            ws.activePOVCharacterID = "c_lin"
            try files.narrative.saveWorkspace(ws, projectID: "mem_p1")
            if case .loaded(let reloaded) = files.narrative.loadWorkspaceState(projectID: "mem_p1") {
                try expect(
                    reloaded.pendingSyncNodeIDs == ["main_1", "main_2"]
                        && reloaded.activePOVCharacterID == "c_lin",
                    "待补抽节点队列与激活 POV 视角必须经 manifest 加密往返持久化"
                )
            } else {
                throw UnexpectedStoreStateError.notLoaded
            }

            return "分支账本隔离 + 混合预检 + 新实体自动发现 + 金字塔滚动 + POV/脏队列持久化 ok"
        }

        // 验证剧情图加密 WAL 追加写、尾帧崩溃容错、自动压实、检查点独立落盘与子域修订号 O(1) 判脏。
        check("narrative.walAndCheckpointPersistence") {
            let rootDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-wal-check-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: rootDir) }
            let files = FileStore(root: rootDir)
            let projectID = "wal_p1"
            let t0 = Date(timeIntervalSince1970: 1_796_200_000)

            var graph1 = StoryGraph.makeInitial(rootID: "root", branchLabel: "主线", summary: "开篇", now: t0)
            try graph1.appendNode(
                PlotNode(id: "n1", parentID: "root", summary: "入城", createdAt: t0.addingTimeInterval(10))
            )
            try graph1.recordCheckpoint(at: "root", now: t0.addingTimeInterval(5))
            var ws1 = NarrativeWorkspace(storyGraph: graph1)
            try ws1.synchronizeMaterializedHead()
            ws1.entityPages["e_lin"] = EntityPage(id: "e_lin", kind: .character, name: "林昭", updatedAt: t0)
            try files.narrative.saveWorkspace(ws1, previous: nil, projectID: projectID)

            let storeDir = files.narrative.narrativeDirectory(projectID)
            let graphURL = storeDir.appendingPathComponent("story_graph.json")
            let manifestURL = storeDir.appendingPathComponent("manifest.json")
            let cpURL = files.narrative.checkpointFileURL(nodeID: "root", projectID: projectID)
            let walURL = files.narrative.storyGraphWALURL(projectID)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let plainGraphData = try PayloadCipher.open(try Data(contentsOf: graphURL))
            let decodedDiskGraph = try decoder.decode(StoryGraph.self, from: plainGraphData)
            try expect(
                decodedDiskGraph.checkpoints.isEmpty
                    && FileManager.default.fileExists(atPath: cpURL.path)
                    && PayloadCipher.isEncrypted(try Data(contentsOf: cpURL)),
                "检查点必须从 story_graph.json 剥离并以独立密文文件存于 checkpoints/"
            )

            let pastDate = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: graphURL.path)
            try FileManager.default.setAttributes([.modificationDate: pastDate], ofItemAtPath: manifestURL.path)

            var ws2 = ws1
            try ws2.storyGraph.appendNode(
                PlotNode(id: "n2", parentID: "n1", summary: "夜探码头", createdAt: t0.addingTimeInterval(20))
            )
            try expect(!ws2.hasSameRevision(as: ws1), "追加节拍后子域修订号必须判定为已变更")
            try files.narrative.saveWorkspace(ws2, previous: ws1, projectID: projectID)

            let graphMTime = (try FileManager.default.attributesOfItem(atPath: graphURL.path))[.modificationDate] as? Date
            let manifestMTime = (try FileManager.default.attributesOfItem(atPath: manifestURL.path))[.modificationDate] as? Date
            try expect(
                FileManager.default.fileExists(atPath: walURL.path)
                    && StoryGraphWAL.frameCount(at: walURL) == 2
                    && graphMTime == pastDate
                    && manifestMTime == pastDate,
                "纯追加节拍时应走加密 WAL 追加写，不得重写 story_graph.json 与 manifest.json"
            )

            guard case .loaded(let loaded2) = files.narrative.loadWorkspaceState(projectID: projectID) else {
                throw UnexpectedStoreStateError.notLoaded
            }
            try expect(
                loaded2 == ws2 && loaded2.storyGraph.headNodeID == "n2" && loaded2.storyGraph.nodes.count == 3,
                "重启重放 WAL 与检查点缓存后工作区应与内存语义完全一致"
            )

            // 模拟写半帧时崩溃，在 WAL 尾部写入截断尾帧，验证重放时就地截断残尾并支持继续追加。
            let handle = try FileHandle(forWritingTo: walURL)
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x46, 0x52, 0x57, 0x4C, 0x00, 0x00, 0x00, 0x20, 0xDE, 0xAD]))
            try handle.close()
            guard case .loaded(let recoveredCrash) = files.narrative.loadWorkspaceState(projectID: projectID) else {
                throw UnexpectedStoreStateError.notLoaded
            }
            try expect(
                recoveredCrash.storyGraph.headNodeID == "n2"
                    && recoveredCrash.storyGraph.nodes["n2"] != nil
                    && !StoryGraphWAL.inspect(at: walURL).hasTrailingGarbage,
                "WAL 尾部存在截断残留时应丢弃残帧并就地截断修复 WAL，完整恢复已提交节点"
            )

            var wsAfterCrash = recoveredCrash
            try wsAfterCrash.storyGraph.appendNode(
                PlotNode(id: "n3", parentID: "n2", summary: "残尾修复后续写", createdAt: t0.addingTimeInterval(25))
            )
            try files.narrative.saveWorkspace(wsAfterCrash, previous: recoveredCrash, projectID: projectID)
            guard case .loaded(let reloadedAfterCrash) = files.narrative.loadWorkspaceState(projectID: projectID) else {
                throw UnexpectedStoreStateError.notLoaded
            }
            try expect(
                reloadedAfterCrash == wsAfterCrash
                    && reloadedAfterCrash.storyGraph.headNodeID == "n3"
                    && reloadedAfterCrash.storyGraph.nodes["n3"] != nil,
                "崩溃残尾经截断修复后继续 WAL 追加写，重启重放仍必须无损恢复新节点"
            )

            // 剪枝删除节点触发基线重写并清理 WAL。
            var ws3 = wsAfterCrash
            _ = ws3.storyGraph.pruneSubtree { $0.id == "n2" }
            try files.narrative.saveWorkspace(ws3, previous: wsAfterCrash, projectID: projectID)
            try expect(!FileManager.default.fileExists(atPath: walURL.path), "节点被剪枝删除时应全量重写基线并清理 WAL")

            // 连续追加达到 compactionThreshold (20 次 * 2 帧 = 40 帧)，验证自动压实回收 WAL。
            var prevWS = ws3
            for i in 1...20 {
                var nextWS = prevWS
                let nodeID = "m_\(i)"
                let parent = i == 1 ? "n1" : "m_\(i - 1)"
                try nextWS.storyGraph.appendNode(
                    PlotNode(
                        id: nodeID,
                        parentID: parent,
                        summary: "续写第\(i)幕",
                        createdAt: t0.addingTimeInterval(Double(30 + i))
                    )
                )
                try files.narrative.saveWorkspace(nextWS, previous: prevWS, projectID: projectID)
                prevWS = nextWS
            }
            guard case .loaded(let compacted) = files.narrative.loadWorkspaceState(projectID: projectID) else {
                throw UnexpectedStoreStateError.notLoaded
            }
            try expect(
                !FileManager.default.fileExists(atPath: walURL.path) && compacted == prevWS,
                "WAL 帧数达到阈值后应自动压实回 story_graph.json 并清空 WAL，重载结果无损"
            )

            // 验证检查点数量上限裁剪，确保保留头节点与分支尖端。
            var cpGraph = StoryGraph.makeInitial(rootID: "root", branchLabel: "主线", summary: "开篇", now: t0)
            try cpGraph.appendNode(PlotNode(id: "p1", parentID: "root", summary: "1", createdAt: t0.addingTimeInterval(1)))
            try cpGraph.appendNode(PlotNode(id: "p2", parentID: "p1", summary: "2", createdAt: t0.addingTimeInterval(2)))
            try cpGraph.appendNode(PlotNode(id: "p3", parentID: "p2", summary: "3", createdAt: t0.addingTimeInterval(3)))
            try cpGraph.appendNode(
                PlotNode(id: "s1", parentID: "p1", branchLabel: "支线", summary: "S1", createdAt: t0.addingTimeInterval(4)),
                moveHead: false
            )
            for (idx, nid) in ["root", "p1", "p2", "p3", "s1"].enumerated() {
                cpGraph.checkpoints[nid] = ReplayCheckpoint(
                    nodeID: nid,
                    state: try cpGraph.replay(to: nid),
                    createdAt: t0.addingTimeInterval(Double(idx * 10))
                )
            }
            cpGraph.pruneCheckpoints(maxRetained: 3)
            try expect(
                cpGraph.checkpoints.count == 3
                    && cpGraph.checkpoints["p3"] != nil
                    && cpGraph.checkpoints["s1"] != nil,
                "检查点裁剪应严格遵守上限并优先保留头节点与支线尖端"
            )

            // 验证 O(1) 修订号判定对直接属性改写与检查点修改敏感。
            let baseWS = prevWS
            try expect(baseWS.hasSameRevision(as: baseWS), "同一修订号实例应满足 O(1) 快速判等")
            var editedEntityWS = baseWS
            editedEntityWS.entityPages["e_new"] = EntityPage(id: "e_new", kind: .lore, name: "海禁")
            try expect(!editedEntityWS.hasSameRevision(as: baseWS), "直接改写 entityPages 属性应递增修订号")
            var editedCPWS = baseWS
            editedCPWS.storyGraph.checkpoints["n1"] = ReplayCheckpoint(
                nodeID: "n1",
                state: try editedCPWS.storyGraph.replay(to: "n1"),
                createdAt: t0
            )
            try expect(!editedCPWS.hasSameRevision(as: baseWS), "单独修改检查点应递增 checkpointsRevision")

            // 验证整图替换即使前后图谱修订号同为 0，也因 StoryGraph.lineageID 不同而触发变更判定与落盘。
            var wsOrigZero = NarrativeWorkspace(
                storyGraph: StoryGraph.makeInitial(rootID: "r0", summary: "原开篇", now: t0)
            )
            try wsOrigZero.synchronizeMaterializedHead()
            try files.narrative.saveWorkspace(wsOrigZero, previous: nil, projectID: "wal_replace")
            var wsReplacedZero = wsOrigZero
            wsReplacedZero.storyGraph = StoryGraph.makeInitial(rootID: "r0", summary: "重置新开篇", now: t0)
            try expect(!wsReplacedZero.hasSameRevision(as: wsOrigZero), "整图替换新实例必须刷新 StoryGraph.lineageID 避免判等漏写")
            try files.narrative.saveWorkspace(wsReplacedZero, previous: wsOrigZero, projectID: "wal_replace")
            if case .loaded(let reloadedReplaced) = files.narrative.loadWorkspaceState(projectID: "wal_replace") {
                try expect(
                    reloadedReplaced.storyGraph.nodes["r0"]?.summary == "重置新开篇",
                    "整图替换同修订号 0 后必须真实覆盖落盘"
                )
            } else {
                throw UnexpectedStoreStateError.notLoaded
            }

            return "加密 WAL 追加 + 截断修复后可续写 + 达阈值压实 + 检查点裁剪 + 整图替换与 O(1) 修订号 ok"
        }

        // 验证四类实体分化（人物/地点/物件/世界观）、常驻世界观进 Tier 0、触发词唤醒及世界同步模型设置往返。
        check("narrative.entityOntologyAndWorldSyncSettings") {
            let legacyJSON = #"{"id":"legacy_lore","kind":"lore","name":"灵气潮汐","identity":"灵力体系","summary":"满月时灵气暴涨"}"#
            let legacyData = Data(legacyJSON.utf8)
            let decodedLegacy = try JSONDecoder().decode(EntityPage.self, from: legacyData)
            try expect(
                decodedLegacy.activationMode == .mentioned && decodedLegacy.triggerKeywords.isEmpty,
                "旧版 EntityPage JSON 缺失新字段时必须平滑解码为 mentioned 与空触发词"
            )

            let alwaysLore = EntityPage(
                id: "lore_always",
                kind: .lore,
                name: "灵力反噬铁律",
                activationMode: .always,
                summary: "越阶强行催动秘术必损经脉",
                identity: "修炼法则",
                hardBoundaries: ["筑基期不可承受元婴灵压"]
            )
            let triggeredLore = EntityPage(
                id: "lore_keyword",
                kind: .lore,
                name: "天机阁密律",
                triggerKeywords: ["星盘", "问卜"],
                activationMode: .mentioned,
                summary: "卜算天机须折寿三年",
                identity: "宗门制度",
                hardBoundaries: ["不得向外人泄露卦象代价"]
            )
            let hero = EntityPage(
                id: "c_hero",
                kind: .character,
                name: "林昭",
                summary: "性格谨慎",
                identity: "北境斥候",
                voiceProfile: "短句寡言",
                hardBoundaries: ["绝不背弃同袍"]
            )
            let inn = EntityPage(
                id: "l_inn",
                kind: .location,
                name: "松鹤楼",
                summary: "临街两层木楼，二楼雅间直通后巷屋檐",
                identity: "城南茶楼",
                voiceProfile: "不应出现在地点渲染中的残留声线",
                hardBoundaries: ["后门子时落锁"]
            )
            let relic = EntityPage(
                id: "a_relic",
                kind: .artifact,
                name: "玄铁星盘",
                triggerKeywords: ["推演"],
                summary: "掌心大小的乌铁圆盘，盘面刻二十八宿",
                identity: "林昭贴身持有",
                hardBoundaries: ["每日至多催动一次"]
            )

            var state = MaterializedNarrativeState(atNodeID: "root", pathNodeIDs: ["root"])
            for page in [alwaysLore, triggeredLore, hero, inn, relic] {
                state.entityPages[page.id] = page
            }
            state.epistemicBeliefs["b_inn_leak"] = EpistemicBelief(
                id: "b_inn_leak",
                characterID: "l_inn",
                topic: "误挂给地点的认知",
                believedTruth: "不应出现",
                knowsSecret: true,
                updatedAtNodeID: "root"
            )

            let frozen = NarrativeContextOrchestrator.buildFrozenSystemPrefix(
                globalPreset: "",
                aiFlavorRules: "",
                skills: [],
                universes: [],
                preservedStyle: PreservedStyleDistillation(),
                alwaysOnLorePages: [alwaysLore, hero]
            )
            try expect(
                frozen.contains("【常驻世界观】")
                    && frozen.contains("灵力反噬铁律")
                    && frozen.contains("筑基期不可承受元婴灵压")
                    && !frozen.contains("林昭"),
                "Tier 0 静态前缀应仅纳入启用的常驻世界观，不应混入人物"
            )

            let cone = NarrativeContextOrchestrator.buildQueryConeBlock(
                state: state,
                scanText: "林昭推开松鹤楼后窗，指尖在玄铁星盘边缘一按，借星盘推演今夜祸福。",
                povCharacterID: "c_hero"
            )
            try expect(
                cone.block.contains("【当前在场人物与认知边界】")
                    && cone.block.contains("【当前地点】")
                    && cone.block.contains("【当前物件】")
                    && cone.block.contains("【相关世界观】")
                    && cone.block.contains("天机阁密律")
                    && !cone.block.contains("灵力反噬铁律")
                    && !cone.block.contains("不应出现在地点渲染中的残留声线")
                    && !cone.block.contains("误挂给地点的认知"),
                "Tier 2 应按四类分块渲染、支持触发词带入词条、去重常驻世界观，并隔离非人物的声线与认知"
            )

            let extractorJSON = #"{"entities":[{"id":"","kind":"世界观","name":"血契反噬","trigger_keywords":["血誓","契印"],"activation_mode":"always","identity":"禁术体系","summary":"背誓者心脉俱断"}]}"#
            let parsedEntities = try NarrativeEntityExtractor.parseEntities(from: extractorJSON, existingPages: [])
            try expect(
                parsedEntities.upserts.first?.kind == .lore
                    && parsedEntities.upserts.first?.activationMode == .always
                    && parsedEntities.upserts.first?.triggerKeywords == ["血誓", "契印"],
                "实体解析器应正确识别世界观分类、激活方式与触发关键词"
            )

            var settings = AppSettings(narrativeSyncProviderID: "sync_flash_provider")
            let encodedSettings = try JSONEncoder().encode(settings)
            let decodedSettings = try JSONDecoder().decode(AppSettings.self, from: encodedSettings)
            let defaultSettings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
            try expect(
                decodedSettings.narrativeSyncProviderID == "sync_flash_provider"
                    && defaultSettings.narrativeSyncProviderID.isEmpty,
                "AppSettings.narrativeSyncProviderID 应支持 Codable 往返与旧设置空串默认"
            )

            settings.providers = [
                ProviderSetting(id: "p_writer", kind: .openAICompatible, model: "writer-pro"),
                ProviderSetting(id: "p_sync", kind: .openAICompatible, model: "sync-flash"),
            ]
            settings.activeProviderID = "p_writer"
            settings.narrativeSyncProviderID = "p_sync"
            let resolvedSyncID = settings.providers.first(where: { $0.id == settings.narrativeSyncProviderID })?.id
            try expect(resolvedSyncID == "p_sync", "独立世界更新服务商设置应准确解析到指定供应方")

            let mdSample = """
            # 标题
            ---
            > 第一行引用
            > 第二行引用
            - 无序条目
            1. 第一项
            2、第二项
            ```
            let x = 1
            ```
            普通正文段落。
            """
            let mdBlocks = MarkdownDocumentView.parseBlocks(from: mdSample)
            try expect(
                mdBlocks.count == 8
                    && mdBlocks[0] == .heading(id: 0, level: 1, text: "标题")
                    && mdBlocks[1] == .divider(id: 1)
                    && mdBlocks[2] == .quote(id: 2, lines: ["第一行引用", "第二行引用"])
                    && mdBlocks[3] == .bullet(id: 4, text: "无序条目")
                    && mdBlocks[4] == .numbered(id: 5, marker: "1.", text: "第一项")
                    && mdBlocks[5] == .numbered(id: 6, marker: "2、", text: "第二项")
                    && mdBlocks[6] == .codeBlock(id: 7, code: "let x = 1")
                    && mdBlocks[7] == .paragraph(id: 10, text: "普通正文段落。"),
                "MarkdownDocumentView.parseBlocks 应完整识别标题、分隔线、引用块、代码块、无序与有序列表及段落"
            )

            return "四类档案分化 + 常驻世界观 + 触发词带入 + 世界更新模型设置 ok"
        }

        // 验证关键事件层、旧档全字段导入、场景门控伏笔、多目标关系与泛化认知冲突核查。
        check("narrative.episodicEventsForeshadowingAndAntiDrift") {
            let t0 = Date(timeIntervalSince1970: 1_796_500_000)

            var world = WorldBook()
            world.characters = [
                CharacterCard(
                    id: "c_lin",
                    name: "林昭",
                    identity: "旧书店店主",
                    relationshipAttitudes: "沈清秋：表面恭敬，实则防备\n赵二: 暗中互通消息",
                    customEntries: [
                        CharacterCard.CustomEntry(id: "ce1", title: "随身武器", body: "断水匕首")
                    ],
                    memories: [
                        CharacterMemory(
                            id: "m1",
                            content: "十年前码头失火",
                            evidence: "左手掌心留有旧疤",
                            createdAt: 1_700_000_000_000
                        )
                    ]
                ),
                CharacterCard(id: "c_shen", name: "沈清秋", identity: "南城掌柜"),
                CharacterCard(id: "c_zhao", name: "赵二", identity: "漕帮暗桩"),
            ]
            world.events = [
                EventCard(
                    id: "ev_dock",
                    title: "雾港码头密会",
                    scene: "雾港老码头",
                    characters: ["林昭", "沈清秋"],
                    cause: "匿名信约见",
                    development: "双方交换半枚玄铁令",
                    consequence: "",
                    updatedAt: t0
                )
            ]
            let imported = LegacyArchiveImporter.importFromPayload(
                ProjectPayload(manuscript: "第一章\n林昭站在雾港老码头。", world: world),
                projectID: "episodic_import",
                projectTitle: "雾港夜行",
                now: t0
            )
            let importedState = try imported.workspace.materializedState()
            let importedFacts = importedState.facts(for: "c_lin")
            try expect(
                importedState.episodicEvents["legacy_evt_ev_dock"]?.status == .ongoing
                    && importedState.episodicEvents["legacy_evt_ev_dock"]?.participantEntityIDs == ["c_lin", "c_shen"]
                    && importedFacts.contains(where: { $0.attribute == "relation:沈清秋" })
                    && importedFacts.contains(where: { $0.attribute == "relation:赵二" })
                    && importedFacts.contains(where: { $0.attribute == "custom:随身武器" && $0.value == "断水匕首" })
                    && importedFacts.contains(where: { $0.attribute == "memory:1" && $0.value.contains("十年前码头失火") }),
                "旧档导入应完整迁移 EventCard、customEntries、memories 与多目标关系槽位"
            )

            let excerpt = "沈清秋在松鹤楼低声拆穿了假信，林昭这才明白旧案另有主谋。"
            let deltaJSON = """
            {
              "facts": [
                {"entity_id":"c_lin","attribute":"relation:沈清秋","value":"已识破沈清秋暗中查案","quote":"沈清秋在松鹤楼低声拆穿了假信"}
              ],
              "beliefs": [
                {"character_id":"c_lin","topic":"常规猜测","believed_truth":"猜测对方想喝茶","knows_secret":false,"quote":""},
                {"character_id":"c_lin","topic":"旧案主谋","believed_truth":"意识到另有主谋","knows_secret":true,"quote":"旧案另有主谋"}
              ],
              "events": [
                {"id":"","title":"松鹤楼拆信","arc":"南疆追查线","scene":"松鹤楼","participants":["林昭","沈清秋"],"cause":"假信引蛇出洞","development":"当面对质","outcome":"识破主谋线索","status":"resolved","quote":"沈清秋在松鹤楼低声拆穿了假信"}
              ],
              "threads": []
            }
            """
            let parsed = try NarrativeDeltaExtractor.parseDelta(
                from: deltaJSON,
                excerpt: excerpt,
                nodeID: "n1",
                knownEntities: Array(importedState.entityPages.values),
                now: t0.addingTimeInterval(20)
            )
            try expect(
                parsed.droppedSpeculativeCount >= 1
                    && parsed.delta.epistemicBeliefs.count == 1
                    && parsed.delta.epistemicBeliefs.first?.authority == .canonProseQuote
                    && parsed.delta.episodicEvents.count == 1
                    && parsed.delta.episodicEvents.first?.status == .resolved
                    && parsed.delta.factEvents.first?.attribute == "relation:沈清秋",
                "冷同步抽取应拦截无依据认知臆测、保留多目标关系与结构化事件"
            )

            // 验证事件与多目标关系在一跳召回、工具读取和分支切换中的隔离表现，以及伏笔场景相关性门控。
            var ws = imported.workspace
            ws.applyLedgerDelta(
                PlotNodeDelta(
                    factEvents: [
                        WorldFactEvent(
                            id: "f_zhao_only_attr",
                            entityID: "c_lin",
                            attribute: "relation:赵二",
                            value: "可随时联络的暗线",
                            nodeID: "root",
                            authority: .canonProseQuote,
                            createdAt: t0.addingTimeInterval(5)
                        )
                    ],
                    threadEvents: [
                        ProspectiveThreadEvent(
                            id: "p_rel_ready",
                            threadID: "th_dock_ready",
                            kind: .plant,
                            goal: "林昭交付老码头暗格钥匙",
                            activationCue: "老码头交接",
                            relatedEntityIDs: ["c_lin"],
                            nodeID: "root",
                            createdAt: t0
                        ),
                        ProspectiveThreadEvent(
                            id: "r_rel_ready",
                            threadID: "th_dock_ready",
                            kind: .promoteReady,
                            nodeID: "root",
                            createdAt: t0.addingTimeInterval(1)
                        ),
                        ProspectiveThreadEvent(
                            id: "p_unrel_1",
                            threadID: "th_unrel_1",
                            kind: .plant,
                            goal: "无关伏笔甲",
                            relatedEntityIDs: ["c_shen"],
                            nodeID: "root",
                            createdAt: t0
                        ),
                        ProspectiveThreadEvent(
                            id: "r_unrel_1",
                            threadID: "th_unrel_1",
                            kind: .promoteReady,
                            nodeID: "root",
                            createdAt: t0.addingTimeInterval(1)
                        ),
                        ProspectiveThreadEvent(
                            id: "p_unrel_2",
                            threadID: "th_unrel_2",
                            kind: .plant,
                            goal: "无关伏笔乙",
                            relatedEntityIDs: ["c_shen"],
                            nodeID: "root",
                            createdAt: t0
                        ),
                        ProspectiveThreadEvent(
                            id: "r_unrel_2",
                            threadID: "th_unrel_2",
                            kind: .promoteReady,
                            nodeID: "root",
                            createdAt: t0.addingTimeInterval(1)
                        ),
                        ProspectiveThreadEvent(
                            id: "p_pend_hit",
                            threadID: "th_pend_hit",
                            kind: .plant,
                            goal: "暗夜钟声响起后验证暗号",
                            activationCue: "暗夜钟声",
                            relatedEntityIDs: [],
                            evidenceAnchor: TextSpanAnchor.make(utf16Start: 0, utf16Length: 6, quote: "巷口铜钟三响"),
                            nodeID: "root",
                            createdAt: t0
                        ),
                        ProspectiveThreadEvent(
                            id: "p_pend_entity_only",
                            threadID: "th_pend_entity_only",
                            kind: .plant,
                            goal: "血月升起后揭开血契",
                            activationCue: "血月升起",
                            relatedEntityIDs: ["c_lin"],
                            nodeID: "root",
                            createdAt: t0
                        ),
                    ]
                ),
                sourceNodeID: "root"
            )
            let stateForCone = ws.currentState()
            let cone = NarrativeContextOrchestrator.buildQueryConeBlock(
                state: stateForCone,
                scanText: "林昭独自走在雨巷中，听见远处传来暗夜钟声。"
            )
            try expect(
                cone.block.contains("【相关关键事件】")
                    && cone.block.contains("雾港码头密会")
                    && cone.block.contains("【关联离场实体（一跳）】")
                    && cone.block.contains("赵二")
                    && cone.block.contains("林昭交付老码头暗格钥匙")
                    && !cone.block.contains("无关伏笔甲")
                    && cone.block.contains("【当前场景关联潜伏伏笔")
                    && cone.block.contains("暗夜钟声响起后验证暗号")
                    && cone.block.contains("巷口铜钟三响")
                    && !cone.block.contains("th_pend_entity_only")
                    && !cone.block.contains("参考"),
                "热路径应注入相关关键事件、通过 relation:赵二 触发一跳召回，并对伏笔做线索词门控与原文依据透出"
            )

            let extractionMessages = NarrativeDeltaExtractor.buildExtractionPayload(
                excerpt: "巷口铜钟再响，林昭轻声对出了暗号。",
                knownEntities: [],
                activeThreads: Array(stateForCone.threads.values),
                activeEvents: []
            ).messages
            let extractionText = extractionMessages.map(\.content).joined(separator: "\n")
            try expect(
                extractionText.contains("暗夜钟声")
                    && extractionText.contains("巷口铜钟三响")
                    && extractionText.contains("satisfied"),
                "冷同步伏笔提示词应包含激活线索、埋设原文依据与 once 兑现提示"
            )

            ws.anchorIndex = AnchorIndex(
                version: 1,
                anchors: [
                    MechanicalAnchor(
                        id: "anc_clock",
                        kind: .artifactOrCount,
                        surfaceText: "铜钟",
                        span: TextSpanAnchor.make(utf16Start: 0, utf16Length: 6, quote: "巷口铜钟三响")
                    )
                ],
                indexedUTF16Length: 120
            )
            var checkSettings = AppSettings()
            checkSettings.providers = [ProviderSetting(kind: .deepseek, model: "deepseek-chat")]
            checkSettings.activeProviderID = checkSettings.providers[0].id
            let composedWithPrefetch = NarrativeContextOrchestrator.compose(
                workspace: ws,
                manuscript: "第一章 雾港旧事：巷口铜钟三响。\n\n第五章 雨巷：林昭听见远处传来暗夜钟声。",
                history: [],
                userInstruction: "林昭留意铜钟动静",
                settings: checkSettings,
                enabledUniverseEntryIDs: [],
                tailCodePointLimitOverride: 30,
                inputBudget: 16_000,
                enableTools: false
            )
            let prefetchJoined = composedWithPrefetch.messages.map(\.content).joined(separator: "\n")
            try expect(
                prefetchJoined.contains("一律以当前最新状态为准"),
                "词法预检片段应附带状态时序优先级规则以防状态漂移"
            )

            // 验证跨分支切换与持久化往返对 EpisodicEvent 的隔离与兼容解码。
            let oldDeltaData = Data("{}".utf8)
            let decodedOldDelta = try JSONDecoder().decode(PlotNodeDelta.self, from: oldDeltaData)
            try expect(decodedOldDelta.episodicEvents.isEmpty && decodedOldDelta.removedEpisodicEventIDs.isEmpty, "旧版 PlotNodeDelta 缺省解码应为空")

            var branchGraph = StoryGraph.makeInitial(
                rootID: "root",
                initialDelta: PlotNodeDelta(
                    entityPageUpserts: [EntityPage(id: "c_lin", kind: .character, name: "林昭")],
                    epistemicBeliefs: [
                        EpistemicBelief(
                            id: "b_shen_stance",
                            characterID: "c_lin",
                            topic: "沈清秋立场",
                            believedTruth: "已知沈清秋在暗中调查",
                            knowsSecret: true,
                            authority: .canonProseQuote,
                            updatedAtNodeID: "root",
                            updatedAt: t0
                        ),
                        EpistemicBelief(
                            id: "b_shen_blindspot",
                            characterID: "c_lin",
                            topic: "沈清秋立场盲区",
                            believedTruth: "误以为沈清秋仍不知情",
                            knowsSecret: false,
                            authority: .canonProseQuote,
                            updatedAtNodeID: "root",
                            updatedAt: t0
                        ),
                    ]
                ),
                now: t0
            )
            try branchGraph.appendNode(
                PlotNode(
                    id: "n_branch_a",
                    parentID: "root",
                    branchLabel: "A线",
                    delta: PlotNodeDelta(
                        factEvents: [
                            WorldFactEvent(
                                id: "f_shen_revealed",
                                entityID: "c_lin",
                                attribute: "relation:沈清秋",
                                value: "沈清秋已识破伪装",
                                nodeID: "n_branch_a",
                                authority: .canonProseQuote,
                                quoteAnchor: TextSpanAnchor.make(utf16Start: 0, utf16Length: 8, quote: "沈清秋已识破伪装"),
                                createdAt: t0.addingTimeInterval(30)
                            )
                        ],
                        episodicEvents: [
                            EpisodicEvent(
                                id: "evt_branch_a",
                                title: "A线暗杀危机",
                                participantEntityIDs: ["c_lin"],
                                status: .ongoing,
                                nodeID: "n_branch_a",
                                updatedAt: t0.addingTimeInterval(30)
                            )
                        ]
                    ),
                    createdAt: t0.addingTimeInterval(30)
                )
            )
            try branchGraph.appendNode(
                PlotNode(
                    id: "n_branch_b",
                    parentID: "root",
                    branchLabel: "B线",
                    createdAt: t0.addingTimeInterval(40)
                ),
                moveHead: false
            )
            var auditWS = NarrativeWorkspace(storyGraph: branchGraph)
            try auditWS.synchronizeMaterializedHead()

            let auditReport = try NarrativeDreamingAuditor.audit(
                workspace: auditWS,
                manuscriptPages: ["沈清秋已识破伪装。"]
            )
            guard let staleFinding = auditReport.findings.first(where: { $0.kind == .staleBelief }) else {
                throw UnexpectedStoreStateError.notLoaded
            }
            try expect(
                NarrativeViewSupport.canSyncLatestFact(for: staleFinding, workspace: auditWS),
                "attribute 与 topic 非完全同名时也应检出 staleBelief 并支持同步最新事实"
            )
            let syncedCount = try NarrativeDreamingAuditor.applyCleanup(
                findings: [staleFinding],
                workspace: &auditWS
            )
            try expect(
                syncedCount == 1
                    && auditWS.currentState().beliefs(for: "c_lin").first(where: { $0.id == "b_shen_stance" })?.believedTruth == "沈清秋已识破伪装"
                    && auditWS.currentState().beliefs(for: "c_lin").first(where: { $0.id == "b_shen_blindspot" })?.believedTruth == "误以为沈清秋仍不知情",
                "同步清理应只更新已知情角色的过时认知，严禁抹平 knowsSecret=false 的角色信息差盲区"
            )

            let tempRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-episodic-check-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: tempRoot) }
            let files = FileStore(root: tempRoot)
            try files.narrative.saveWorkspace(auditWS, projectID: "ep_store")
            if case .loaded(let reloaded) = files.narrative.loadWorkspaceState(projectID: "ep_store") {
                try expect(reloaded.episodicEvents["evt_branch_a"]?.title == "A线暗杀危机", "关键事件必须经加密 ledgers.json 往返持久化")
            } else {
                throw UnexpectedStoreStateError.notLoaded
            }

            let switchedToB = try auditWS.checkoutBranch(to: "n_branch_b", now: t0.addingTimeInterval(50))
            try expect(switchedToB.episodicEvents["evt_branch_a"] == nil, "关键事件必须严格随剧情分支切换隔离")

            return "关键事件层 + 旧档补全 + 门控伏笔 + 多目标关系 + 认知冲突核查 ok"
        }

        // 验证旧档回流隔离、ReFold 无工具提示与撤回边界清理、语境改写与局部锚点调整。
        check("narrative.conflictFixesAndContextRewrite") {
            let t0 = Date(timeIntervalSince1970: 1_795_400_000)
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-conflict-fixes-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)

            var world = WorldBook()
            world.styleTemplate = "白描短句"
            world.characters = [CharacterCard(id: "c_ghost", name: "旧人物", identity: "旧档残余")]
            let payload = ProjectPayload(
                manuscript: "雾港夜雨中，林昭收起了铜钥匙。\n\n远处传来沈清秋的脚步声。",
                messages: [
                    ChatMessage(id: "m0", role: .user, content: String(repeating: "旧要求甲。", count: 50)),
                    ChatMessage(id: "m1", role: .assistant, content: String(repeating: "旧草稿甲。", count: 50)),
                    ChatMessage(id: "m2", role: .user, content: String(repeating: "旧要求乙。", count: 50)),
                    ChatMessage(id: "m3", role: .assistant, content: "短回复", createdAt: t0),
                    ChatMessage(id: "m4", role: .user, content: "继续", createdAt: t0),
                    ChatMessage(id: "m5", role: .assistant, content: "收到", createdAt: t0),
                ],
                world: world
            )
            let session = ProjectSession(
                project: Project(id: "conflict-book", title: "冲突修复验证"),
                payload: payload,
                source: "",
                translations: [],
                store: files,
                readOnly: true
            )

            // 1. 删除实体后默认 syncWorldChangesIntoNarrativeWorkspace 不得复活旧人物；清空仿写模板应同步清空工作区。
            var ws = session.ensureNarrativeWorkspace()
            ws.applyLedgerDelta(
                PlotNodeDelta(
                    directiveAdds: [AuthorDirective(id: "d_tone", verbatimRule: "保持克制冷峻", scope: .global)],
                    entityPageUpserts: [EntityPage(id: "c_lin", kind: .character, name: "林昭", identity: "新人物")]
                ),
                sourceNodeID: ws.storyGraph.headNodeID
            )
            ws.applyLedgerDelta(
                PlotNodeDelta(
                    entityPageUpserts: [
                        EntityPage(id: "c_ghost", kind: .character, name: "旧人物", identity: "旧档残余", enabled: false)
                    ]
                ),
                sourceNodeID: ws.storyGraph.headNodeID
            )
            _ = ws.deleteEntityPage(id: "c_ghost")
            ws.reFoldBoundary = ReFoldBoundary(
                boundaryTurnIndex: 3,
                stride: 3,
                foldedStepNotes: [0: "[已折叠步骤 #0]", 2: "[已折叠步骤 #2]"],
                deduplicatedStubs: [1: "step:0"]
            )
            session.noteNarrativeWorkspaceUpdated(ws)

            session.payload.world.styleTemplate = ""
            session.syncWorldChangesIntoNarrativeWorkspace()
            let afterDefaultSync = session.ensureNarrativeWorkspace()
            try expect(
                afterDefaultSync.currentState().entityPages["c_ghost"] == nil
                    && afterDefaultSync.preservedStyle.styleTemplate.isEmpty,
                "默认世界同步不得复活已删实体，且清空 styleTemplate 时应清空工作区保留模板"
            )

            // 2. 无工具模式下 ReFold 不得泄露 restore_turn，且撤回消息应清理受影响区间的折叠边界与存根。
            let noToolHistory: [LLMMessage] = [
                .user(String(repeating: "轮次零。", count: 55)),
                .assistant(String(repeating: "轮次一。", count: 55)),
                .user(String(repeating: "轮次二。", count: 55)),
                .assistant("短保留一"),
                .user("短保留二"),
                .assistant("短保留三"),
                .user("短保留四"),
                .assistant("短保留五"),
                .user("短保留六"),
            ]
            let noToolPlan = ReFoldManager.apply(
                history: noToolHistory,
                boundary: ReFoldBoundary(boundaryTurnIndex: 3, stride: 3),
                modelContextWindow: 32_000,
                effectiveInputBudget: 2_000,
                allowRestoreTool: false
            )
            let noToolJoined = noToolPlan.messages.map(\.content).joined(separator: "\n")
            try expect(
                !noToolJoined.contains("restore_turn") && noToolPlan.foldedTurnCount > 0,
                "禁用工具时 ReFold 存根不得出现 restore_turn 工具提示"
            )

            _ = session.withdraw(from: "m2")
            let invalidatedBoundary = session.ensureNarrativeWorkspace().reFoldBoundary
            try expect(
                invalidatedBoundary.boundaryTurnIndex == 0
                    && invalidatedBoundary.foldedStepNotes.isEmpty
                    && invalidatedBoundary.deduplicatedStubs.isEmpty,
                "撤回早期消息后必须清理从该位置起的 ReFoldBoundary 与旧存根"
            )

            // 3. 语境感知改写提示词应带上前/下文衔接、规则、在场角色与仿写模板。
            var rewriteWS = session.ensureNarrativeWorkspace()
            rewriteWS.preservedStyle = PreservedStyleDistillation(styleTemplate: "短句动作流")
            let fullManuscript = "雾港夜雨敲着码头石阶，林昭攥紧掌心半枚残令。\n\n他在街角停步回头。\n\n对面楼上沈清秋正冷眼看着。"
            let targetText = "他在街角停步回头。"
            let targetRange = (fullManuscript as NSString).range(of: targetText)
            let rewriteMessages = NarrativeContextOrchestrator.buildRewritePrompt(
                workspace: rewriteWS,
                manuscript: fullManuscript,
                range: targetRange,
                selection: targetText,
                instruction: "写得更有压迫感",
                settings: AppSettings()
            )
            let rewriteJoined = rewriteMessages.map(\.content).joined(separator: "\n")
            try expect(
                rewriteJoined.contains("短句动作流")
                    && rewriteJoined.contains("保持克制冷峻")
                    && rewriteJoined.contains("林昭")
                    && rewriteJoined.contains("【上文衔接")
                    && rewriteJoined.contains("【下文衔接")
                    && rewriteJoined.contains("【待改写片段】"),
                "语境改写提示词应注入仿写模板、写作规则、在场人物与前后文衔接片段"
            )

            // 4. 局部改写后 AnchorIndex 应删除改写区旧锚点并精确平移下游偏移。
            var anchorIndex = AnchorIndex(
                version: 1,
                anchors: [
                    MechanicalAnchor(
                        id: "anc_before",
                        kind: .artifactOrCount,
                        surfaceText: "铜钥匙",
                        span: TextSpanAnchor.make(utf16Start: 12, utf16Length: 3, quote: "铜钥匙")
                    ),
                    MechanicalAnchor(
                        id: "anc_inside",
                        kind: .timeMarker,
                        surfaceText: "三更",
                        span: TextSpanAnchor.make(utf16Start: 80, utf16Length: 2, quote: "三更")
                    ),
                    MechanicalAnchor(
                        id: "anc_after",
                        kind: .location,
                        surfaceText: "松鹤楼",
                        span: TextSpanAnchor.make(utf16Start: 200, utf16Length: 3, quote: "松鹤楼")
                    ),
                ],
                indexedUTF16Length: 240
            )
            let editRange = NSRange(location: 75, length: 10)
            let replacement = "次日破晓前林昭重新检查了门闩"
            let sampleUpdated = String(repeating: "甲", count: 75)
                + replacement
                + String(repeating: "乙", count: 240 - 85)
            anchorIndex.adjustForEdit(
                range: editRange,
                replacementUTF16Length: (replacement as NSString).length,
                updatedText: sampleUpdated,
                knownEntities: []
            )
            let delta = (replacement as NSString).length - editRange.length
            let shiftedAfter = anchorIndex.anchors.first { $0.id == "anc_after" }
            try expect(
                anchorIndex.anchors.contains { $0.id == "anc_before" && $0.span.utf16Start == 12 }
                    && !anchorIndex.anchors.contains { $0.id == "anc_inside" }
                    && shiftedAfter?.span.utf16Start == 200 + delta
                    && anchorIndex.indexedUTF16Length == (sampleUpdated as NSString).length,
                "局部改写应移除窗口内旧锚点、平移下游锚点并保持前缀锚点稳定"
            )

            return "旧档隔离 + ReFold无工具与撤回清理 + 语境改写 + 锚点局部调整 ok"
        }

        // 验证 corpusEnabled 开关控制语料范文、replaceManuscript 重置锚点与阅读器定位。
        check("narrative.phase2ReaderCorpusAndReset") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-phase2-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)

            let projectID = "phase2-reset-\(UUID().uuidString)"
            let posKey = ReaderStorageKey.position(projectID)
            let bkmKey = ReaderStorageKey.bookmark(projectID)
            UserDefaults.standard.set(128, forKey: posKey)
            UserDefaults.standard.set(64, forKey: bkmKey)
            defer {
                UserDefaults.standard.removeObject(forKey: posKey)
                UserDefaults.standard.removeObject(forKey: bkmKey)
            }

            let session = ProjectSession(
                project: Project(id: projectID, title: "二阶段校验"),
                payload: ProjectPayload(manuscript: "旧正文第一段。"),
                source: "",
                translations: [],
                store: files,
                readOnly: true
            )
            var ws = session.ensureNarrativeWorkspace()
            ws.anchorIndex = AnchorIndex(
                version: 3,
                anchors: [
                    MechanicalAnchor(
                        id: "anc_old",
                        kind: .location,
                        surfaceText: "旧码头",
                        span: TextSpanAnchor.make(utf16Start: 0, utf16Length: 3, quote: "旧码头")
                    )
                ],
                indexedUTF16Length: 10
            )
            let centroid = CorpusEntry(id: "c_cent", source: "样本", title: "冷峻质心", text: "风声掠过砖缝。")
            let sceneEx = CorpusEntry(id: "c_scene", source: "样本", title: "夜巷对峙", text: "雨打青石阶。")
            ws.preservedStyle = PreservedStyleDistillation(
                styleTemplate: "短句白描规则",
                centroidExemplar: centroid,
                exemplars: [centroid, sceneEx]
            )
            session.noteNarrativeWorkspaceUpdated(ws)

            var disabledSettings = AppSettings()
            disabledSettings.providers = [ProviderSetting(kind: .deepseek, model: "deepseek-chat")]
            disabledSettings.activeProviderID = disabledSettings.providers[0].id
            disabledSettings.corpusEnabled = false

            let withoutCorpus = NarrativeContextOrchestrator.compose(
                workspace: ws,
                manuscript: "林昭走进雨巷。",
                history: [],
                userInstruction: "夜巷对峙，继续写",
                settings: disabledSettings,
                enabledUniverseEntryIDs: [],
                inputBudget: 16_000,
                enableTools: false
            )
            let joinedNoCorpus = withoutCorpus.messages.map(\.content).joined(separator: "\n")
            try expect(
                joinedNoCorpus.contains("短句白描规则")
                    && !joinedNoCorpus.contains("风声掠过砖缝")
                    && !joinedNoCorpus.contains("雨打青石阶"),
                "关闭 corpusEnabled 时不得注入质心或场景示范语料，仅保留仿写模板"
            )

            var wsBeforeReplace = session.ensureNarrativeWorkspace()
            wsBeforeReplace.syncedManuscriptUTF16Offset = 128
            session.noteNarrativeWorkspaceUpdated(wsBeforeReplace)

            session.replaceManuscript("全新导入的正文。")
            let resetWS = session.ensureNarrativeWorkspace()
            try expect(
                resetWS.anchorIndex.anchors.isEmpty
                    && resetWS.syncedManuscriptUTF16Offset == 0
                    && UserDefaults.standard.object(forKey: posKey) == nil
                    && UserDefaults.standard.object(forKey: bkmKey) == nil,
                "replaceManuscript 应清零叙事锚点索引、同步进度并清除旧书阅读定位/书签"
            )

            return "语料开关隔离 + 导入正文重置锚点与阅读键 ok"
        }

        // 验证非 BMP 代理对真实页起点切片无偏移漂移，以及五维文风检查器对白豁免与跨语域阈值。
        check("narrative.phase3OffsetsAndStyleLint") {
            let pages = [
                "第零页甲乙丙丁戊己庚", // len 10
                "第一页子丑寅卯辰巳午未", // len 11 (不等长，模拟代理对缩页)
                "第二页终章落幕",
            ]
            let source = ReaderPageSource(
                pageCount: pages.count,
                pageSize: 12,
                pageStartOffsets: [0, 10, 21],
                loader: { idx in pages[idx] }
            )
            let crossSlice = source.text(in: NSRange(location: 8, length: 6))
            try expect(
                crossSlice == "己庚第一页子",
                "不等长分页应按 pageStartOffsets 精确定位跨页切片（实得：\(crossSlice)）"
            )

            let prose = "“他推门而出，他冷笑一声。”\n他站在廊下，他回头看了一眼。她按下灯扣，她没有出声。"
            let denseReport = ProseStyleLinter.lint(
                prose,
                thresholds: StyleLintThresholds(
                    hollowPronounsPer1K: 100,
                    demonstrativeClutterPer1K: 100,
                    contrastiveNegationPer1K: 100,
                    narrationEmDashPer1K: 100,
                    barePronounChainPer1K: 1.0,
                    minimumNarrationChars: 10
                )
            )
            try expect(
                (denseReport.metricsPer1KChars["bare_pronoun_chain"] ?? 0) > 1.0
                    && !denseReport.flaggedSpans.contains { $0.quote.contains("冷笑") }
                    && StyleLintProfile.webFiction.thresholds.demonstrativeClutterPer1K > StyleLintProfile.literary.thresholds.demonstrativeClutterPer1K,
                "文风检查应检出旁白连续裸代词、豁免对白并支持分语域阈值"
            )

            return "不等长页起点定位 + 五维文风检查器 ok"
        }

        // 验证分段同步切片（断点续切、按段落切分不丢字、到达末尾返回空）与同步位置持久化往返。
        check("narrative.watermarkChunkSync") {
            let paragraph1 = String(repeating: "雾港夜雨敲打着旧码头。", count: 8)
            let paragraph2 = String(repeating: "林昭翻检灯塔铜锁。", count: 8)
            let paragraph3 = String(repeating: "沈清秋推门走进茶室。", count: 8)
            let fullText = [paragraph1, paragraph2, paragraph3].joined(separator: "\n\n")
            let nsFull = fullText as NSString

            let allChunks = ManuscriptSyncEngine.splitIntoSyncChunks(
                fullText: fullText,
                startUTF16: 0,
                targetChunkUTF16: 120
            )
            let rejoined = allChunks.map(\.text).joined()
            try expect(
                allChunks.count >= 2 && rejoined == fullText,
                "分段切片应保留连续边界并完整拼回全文（chunks=\(allChunks.count)）"
            )

            let resumeStart = allChunks[0].utf16End
            let resumedChunks = ManuscriptSyncEngine.splitIntoSyncChunks(
                fullText: fullText,
                startUTF16: resumeStart,
                targetChunkUTF16: 120
            )
            try expect(
                resumedChunks.first?.utf16Start == resumeStart
                    && resumedChunks.map(\.text).joined() == nsFull.substring(from: resumeStart),
                "断点续切应精确衔接未同步尾部"
            )

            let emptyAtTail = ManuscriptSyncEngine.splitIntoSyncChunks(
                fullText: fullText,
                startUTF16: nsFull.length,
                targetChunkUTF16: 120
            )
            try expect(emptyAtTail.isEmpty, "同步位置到达末尾时不应再生成切片")

            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            var ws = NarrativeWorkspace()
            ws.syncedManuscriptUTF16Offset = resumeStart
            let encoded = try encoder.encode(ws)
            let decoded = try decoder.decode(NarrativeWorkspace.self, from: encoded)
            try expect(
                decoded.syncedManuscriptUTF16Offset == resumeStart,
                "NarrativeWorkspace 同步位置应正确往返序列化"
            )

            return "分段全书同步切片 + 同步位置序列化 ok"
        }

        // 验证上下文剪枝（消息排除/摘要替身 + 换场起点隔离前文 + 检索防回流）及旧消息兼容解码。
        check("narrative.contextPruningAndSceneBoundary") {
            let legacyJSON = """
            {"id":"m_legacy","role":"assistant","variants":["旧版正文"],"selectedVariant":0,"createdAt":1700000000}
            """.data(using: .utf8)!
            let decoder = JSONDecoder()
            let decodedLegacy = try decoder.decode(ChatMessage.self, from: legacyJSON)
            try expect(
                decodedLegacy.contextMode == .normal && decodedLegacy.prunedSummary.isEmpty,
                "旧版 ChatMessage 缺省解码应恢复为 normal 模式与空摘要"
            )

            let excludedMsg = ChatMessage(
                id: "m_ex",
                role: .assistant,
                content: "废弃支线里的铁锚与湿冷石阶",
                contextMode: .excluded
            )
            var prunedMsg = ChatMessage(
                id: "m_sum",
                role: .assistant,
                content: "大段繁复的前场感官与心理独白",
                contextMode: .summaryOnly,
                prunedSummary: "林昭深夜在旧码头修好油灯后离开。"
            )
            prunedMsg.setReasoning("长串前场推理过程", forVariant: 0)
            let normalMsg = ChatMessage(id: "m_ok", role: .user, content: "次日上午两人来到茶室会面")

            let converted = PromptComposer.llmMessages(
                from: [excludedMsg, prunedMsg, normalMsg],
                reasoningPolicy: .recentTwo
            )
            let convertedJoined = converted.map(\.content).joined(separator: "\n")
            try expect(
                converted.count == 2
                    && !convertedJoined.contains("湿冷石阶")
                    && !convertedJoined.contains("心理独白")
                    && convertedJoined.contains("[前情摘要：林昭深夜在旧码头修好油灯后离开。]")
                    && (converted.first?.reasoningContent == nil),
                "上下文剪枝应跳过 excluded、用摘要替代 summaryOnly 并剥离其原文与思维链"
            )

            let part1 = "前夜沈清秋在旧码头仓库里的漫长独白与感官细节描写。"
            let part2 = "清晨阳光照进茶室，沈清秋把账本推了过来。"
            let fullBody = part1 + "\n\n" + part2
            let boundaryOffset = (part1 + "\n\n" as NSString).length

            var scopedWorkspace = NarrativeWorkspace()
            scopedWorkspace.entityPages["c_shen"] = EntityPage(
                id: "c_shen",
                kind: .character,
                name: "沈清秋",
                enabled: true
            )
            scopedWorkspace.anchorIndex = AnchorIndex(
                anchors: [
                    MechanicalAnchor(
                        kind: .location,
                        surfaceText: "旧码头",
                        canonicalEntityID: "c_shen",
                        span: TextSpanAnchor(
                            pageIndex: 0,
                            utf16Start: 6,
                            utf16Length: 9,
                            quote: "旧码头仓库里的漫长独白",
                            paragraphHash: "p0"
                        )
                    )
                ],
                indexedUTF16Length: (fullBody as NSString).length
            )
            var boundaryBM25 = ManuscriptIndex.IncrementalBM25Index()
            _ = boundaryBM25.updatePage(index: 0, text: fullBody, utf16Start: 0)

            var settings = AppSettings()
            settings.providers = [ProviderSetting(kind: .deepseek, model: "deepseek-chat")]
            settings.activeProviderID = settings.providers[0].id

            let scoped = NarrativeContextOrchestrator.compose(
                workspace: scopedWorkspace,
                manuscript: fullBody,
                history: converted,
                userInstruction: "写两人在茶室里的对话交锋，不要提及旧码头",
                settings: settings,
                enabledUniverseEntryIDs: [],
                sceneBoundaryOffset: boundaryOffset,
                inputBudget: 16_000,
                enableTools: false,
                bm25Index: boundaryBM25
            )
            let scopedJoined = scoped.messages.map(\.content).joined(separator: "\n")
            try expect(
                !scopedJoined.contains("漫长独白与感官细节描写")
                    && !scopedJoined.contains("旧码头仓库里的漫长独白")
                    && scopedJoined.contains("沈清秋把账本推了过来"),
                "换场起点应隔离前场正文原文与前场锚点/检索，同时保留新场正文"
            )

            let atEndBoundary = (fullBody as NSString).length
            let atEndComposed = NarrativeContextOrchestrator.compose(
                workspace: scopedWorkspace,
                manuscript: fullBody,
                history: [],
                userInstruction: "旧码头与沈清秋接下来的安排",
                settings: settings,
                enabledUniverseEntryIDs: [],
                sceneBoundaryOffset: atEndBoundary,
                inputBudget: 16_000,
                enableTools: false,
                bm25Index: boundaryBM25
            )
            let atEndJoined = atEndComposed.messages.map(\.content).joined(separator: "\n")
            try expect(
                !atEndJoined.contains("漫长独白与感官细节描写")
                    && !atEndJoined.contains("旧码头仓库里的漫长独白"),
                "新场正文尚为空时，BM25 与机械锚点检索不得把边界前的前场原文回流进提示词"
            )

            let fallbackComposed = NarrativeContextOrchestrator.compose(
                workspace: scopedWorkspace,
                manuscript: fullBody,
                history: [],
                userInstruction: "旧码头",
                settings: settings,
                enabledUniverseEntryIDs: [],
                sceneBoundaryOffset: boundaryOffset,
                tailCodePointLimitOverride: 8,
                inputBudget: 16_000,
                enableTools: false,
                bm25Index: nil
            )
            let fallbackJoined = fallbackComposed.messages.map(\.content).joined(separator: "\n")
            try expect(
                !fallbackJoined.contains("漫长独白与感官细节描写"),
                "无增量 BM25 缓存时，兜底历史摘录也必须受换场起点限制"
            )

            let emptySceneTail = NarrativeContextOrchestrator.effectiveTailText(
                manuscript: fullBody,
                continuationAnchor: nil,
                sceneBoundaryOffset: atEndBoundary,
                tailTier: .standard
            )
            try expect(
                emptySceneTail.tailText.isEmpty,
                "刚将正文末尾设为新场起点时，活跃正文窗口应为空而不回流旧场景原文"
            )

            return "上下文剪枝 + 换场起点隔离 + 检索防回流 ok"
        }

        // 验证自动换场信号解析（主观插曲不落入客观事实）、消息自动收起与 ReFoldBoundary 同步清理、以及 Few-Shot 对白防滚雪球。
        check("narrative.autoScenePruningAndDialogueBalance") {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("frthink-auto-prune-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = FileStore(root: root)

            let subjectiveJSON = """
            {"new_entities":[],"facts":[{"entity_id":"c_lin","attribute":"location","value":"异界高塔","quote":"仿佛置身异界高塔"}],"beliefs":[],"threads":[],"events":[],"scene_card":"心理插曲","scene_transition":{"shifted":true,"previous_layer":"subjective_insert","time_anchor":"抵达港口未满半日","neutral_bridge":"林昭因疲惫产生短暂恍惚，很快回到旅馆休息。"}}
            """
            let parsed = try NarrativeDeltaExtractor.parseDelta(
                from: subjectiveJSON,
                excerpt: "他恍惚间仿佛置身异界高塔。",
                nodeID: "n_sub",
                knownEntities: [EntityPage(id: "c_lin", kind: .character, name: "林昭")]
            )
            try expect(
                parsed.sceneTransition?.shouldAutoPrune == true
                    && parsed.sceneTransition?.previousLayer == .subjectiveInsert
                    && parsed.delta.factEvents.isEmpty
                    && (parsed.sceneTransition?.formattedBridge.contains("抵达港口未满半日") == true),
                "主观插曲不应写入客观 factEvents，且应保留时间锚点与桥接摘要"
            )

            try expect(
                NarrativeCommitCoordinator.hasExplicitSceneBreakPrefix("第十二章 雾散之后\n正文内容")
                    && NarrativeCommitCoordinator.hasExplicitSceneBreakPrefix("***\n新的一天")
                    && !NarrativeCommitCoordinator.hasExplicitSceneBreakPrefix("他推开窗看了一眼外面的雨。"),
                "显式分章/分隔符识别应准确区分换场与普通句段"
            )

            let manualMsg = ChatMessage(
                id: "m_manual",
                role: .assistant,
                content: "手工气泡",
                contextMode: .summaryOnly,
                prunedSummary: "保留作者手写摘要"
            )
            let oldMsg1 = ChatMessage(id: "m_old1", role: .user, content: "旧场指令一")
            let oldMsg2 = ChatMessage(id: "m_old2", role: .assistant, content: "旧场回复二")
            let newMsg = ChatMessage(id: "m_new", role: .assistant, content: "新场回复三")
            let payload = ProjectPayload(
                manuscript: "前情。新场正文。",
                messages: [manualMsg, oldMsg1, oldMsg2, newMsg]
            )
            let session = ProjectSession(
                project: Project(id: "auto-prune-book", title: "自动剪枝验证"),
                payload: payload,
                source: "",
                translations: [],
                store: files,
                readOnly: true
            )
            var ws = session.ensureNarrativeWorkspace()
            ws.reFoldBoundary = ReFoldBoundary(
                boundaryTurnIndex: 3,
                stride: 3,
                foldedStepNotes: [1: "[已折叠步骤 #1]"]
            )
            session.noteNarrativeWorkspaceUpdated(ws)

            let prunedCount = session.autoPruneMessagesBefore(
                messageID: "m_new",
                bridgeSummary: "[次日清晨] 旧场冲突已收尾。"
            )
            try expect(
                prunedCount == 2
                    && session.payload.messages[0].prunedSummary == "保留作者手写摘要"
                    && session.payload.messages[1].contextMode == .excluded
                    && session.payload.messages[2].contextMode == .summaryOnly
                    && session.payload.messages[2].prunedSummary == "[次日清晨] 旧场冲突已收尾。"
                    && session.payload.messages[3].contextMode == .normal
                    && (session.narrativeWorkspace?.reFoldBoundary.boundaryTurnIndex ?? -1) <= 1,
                "自动收起前场气泡应保留手工摘要与新场消息，并同步收敛 ReFoldBoundary"
            )

            let heavyDialogue = PromptAssembly.Corpus(
                libraryID: "lib",
                libraryName: "样章",
                entryID: "e_dlg",
                entryName: "雨夜茶室交谈",
                category: "仿写样本",
                text: "“你来了。”“我一直都在。”“茶凉了。”“再续一壶就是。”“外头还在下雨吗？”“下了整夜。”"
            )
            let proseSample = PromptAssembly.Corpus(
                libraryID: "lib",
                libraryName: "样章",
                entryID: "e_prose",
                entryName: "旧巷石阶白描",
                category: "仿写样本",
                text: "石阶被夜露浸得发暗，檐角的铁风铃动了一下，远处传来收摊车轮碾过青石板的声音。他收紧袖口，沿着墙根往前走。"
            )
            let suppressedRef = StyleDistiller.styleReferenceBlock(
                from: [heavyDialogue, proseSample],
                maxSamples: 1,
                instructionText: "减少对话，重点写他穿过长巷赶路。",
                queryText: "“走吧。”他关上门，沿着潮湿长巷往北走去。"
            )
            try expect(
                suppressedRef.injectedEntryIDs == ["e_prose"],
                "Few-Shot 样本筛选应抑制高对白正反馈并响应减少对话要求"
            )

            return "自动换场剪枝 + 主观隔离 + Few-Shot 对白均衡 ok"
        }

        // 验证实体短编号映射、反向别名回填、泛称/歧义保护、跨类不覆盖、孤儿防线、因果追加与候选去重解析。
        check("narrative.entityResolutionAndEventIntegrity") {
            let t0 = Date(timeIntervalSince1970: 1_796_200_000)
            let lin = EntityPage(
                id: "char_lin_real",
                kind: .character,
                name: "林昭",
                aliases: ["阿昭"],
                identity: "雾港旧书店掌柜",
                updatedAt: t0
            )
            let chenOld = EntityPage(
                id: "char_chen_real",
                kind: .character,
                name: "老陈",
                identity: "码头船夫",
                updatedAt: t0.addingTimeInterval(-10)
            )
            let loreSect = EntityPage(
                id: "lore_qingyun",
                kind: .lore,
                name: "青云宗",
                summary: "以剑入道",
                identity: "修真宗门",
                updatedAt: t0
            )
            let ongoingEvent = EpisodicEvent(
                id: "evt_dock_meeting",
                title: "雾港夜谈",
                arcTitle: "南疆线",
                scene: "老码头",
                participantEntityIDs: [lin.id],
                cause: "接到密信赶赴码头。",
                development: "两人在雨棚下碰头。",
                status: .ongoing,
                nodeID: "root",
                updatedAt: t0
            )

            // 1. Short-ID + NEW: 同响应不分裂 + 反向别名回填 + 泛称过滤 + 标点容错锚点
            let excerpt1 = "雨棚下，林昭把铜牌递给沈清秋，陈远山（老陈）在旁望风；旁边一个黑衣人冷眼看着。"
            let payload = NarrativeDeltaExtractor.buildExtractionPayload(
                excerpt: excerpt1,
                leadingContext: "夜色沉沉，码头钟声刚歇。",
                knownEntities: [lin, chenOld, loreSect],
                activeThreads: [],
                activeEvents: [ongoingEvent]
            )
            let linShort = payload.mapping.entityRealToShort[lin.id] ?? ""
            let evtShort = payload.mapping.eventRealToShort[ongoingEvent.id] ?? ""
            try expect(!linShort.isEmpty && !evtShort.isEmpty, "抽取载荷应为已知实体与事件生成短编号")

            let rawDelta1 = """
            {
              "new_entities": [
                {"name": "沈清秋", "kind": "character", "identity": "南疆暗探", "aliases": ["沈姑娘", "黑衣人"], "quote": "沈清秋"},
                {"name": "陈远山", "kind": "character", "identity": "老舵手", "aliases": ["老陈"], "quote": "陈远山"},
                {"name": "黑衣人", "kind": "character", "identity": "不明刺客", "quote": "黑衣人"}
              ],
              "facts": [
                {"entity_id": "\(linShort)", "attribute": "possession", "value": "已转交铜牌", "quote": "「林昭把铜牌递给沈清秋」"},
                {"entity_id": "NEW:沈清秋", "attribute": "possession", "value": "取得铜牌", "quote": "林昭把铜牌递给沈清秋"},
                {"entity_id": "ghost_unknown_id", "attribute": "location", "value": "虚空"}
              ],
              "beliefs": [
                {"character_id": "NEW:沈清秋", "topic": "铜牌交接", "believed_truth": "确认林昭可信", "knows_secret": true, "quote": "林昭把铜牌递给沈清秋"}
              ],
              "events": [
                {"id": "\(evtShort)", "title": "雾港夜谈", "participants": ["\(linShort)", "NEW:沈清秋"], "development": "林昭当面交出铜牌。", "outcome": "双方达成临时同盟。", "status": "resolved", "quote": "林昭把铜牌递给沈清秋"}
              ],
              "threads": []
            }
            """
            let parsed1 = try NarrativeDeltaExtractor.parseDelta(
                from: rawDelta1,
                excerpt: excerpt1,
                nodeID: "n_sync_1",
                knownEntities: [lin, chenOld, loreSect],
                activeEvents: [ongoingEvent],
                idMapping: payload.mapping,
                now: t0.addingTimeInterval(30)
            )
            let shenCreated = parsed1.delta.entityPageUpserts.first { $0.name == "沈清秋" }
            let chenMerged = parsed1.delta.entityPageUpserts.first { $0.id == chenOld.id }
            try expect(
                shenCreated != nil
                    && !(shenCreated?.aliases.contains("黑衣人") ?? true)
                    && chenMerged != nil
                    && (chenMerged?.aliases.contains("陈远山") ?? false)
                    && parsed1.delta.entityPageUpserts.count == 2
                    && !parsed1.delta.entityPageUpserts.contains(where: { $0.name == "黑衣人" })
                    && parsed1.delta.factEvents.count == 2
                    && parsed1.delta.factEvents.contains(where: { $0.entityID == lin.id && $0.value == "已转交铜牌" })
                    && parsed1.delta.factEvents.contains(where: { $0.entityID == shenCreated?.id && $0.value == "取得铜牌" })
                    && parsed1.delta.epistemicBeliefs.first?.characterID == shenCreated?.id
                    && parsed1.delta.episodicEvents.first?.id == ongoingEvent.id
                    && parsed1.delta.episodicEvents.first?.participantEntityIDs == [lin.id, shenCreated?.id ?? ""],
                "短编号与 NEW: 应正确映射且不产生幽灵卡，反向别名应回填原卡，泛称不得建卡或入别名，带引号引用应放行"
            )

            // 2. 归约器孤儿防线 + 事件因果追加不覆盖
            var state = MaterializedNarrativeState(
                atNodeID: "root",
                pathNodeIDs: ["root"],
                entityPages: [lin.id: lin, chenOld.id: chenOld, loreSect.id: loreSect],
                episodicEvents: [ongoingEvent.id: ongoingEvent]
            )
            NarrativeStateReducer.apply(delta: parsed1.delta, nodeID: "n_sync_1", to: &state)
            NarrativeStateReducer.apply(
                delta: PlotNodeDelta(
                    factEvents: [
                        WorldFactEvent(
                            entityID: "missing_entity_should_drop",
                            attribute: "location",
                            value: "幽灵客栈",
                            nodeID: "n_sync_1"
                        )
                    ],
                    epistemicBeliefs: [
                        EpistemicBelief(
                            characterID: "missing_char_should_drop",
                            topic: "秘密",
                            believedTruth: "不应入库",
                            knowsSecret: true,
                            updatedAtNodeID: "n_sync_1"
                        )
                    ]
                ),
                nodeID: "n_sync_2",
                to: &state
            )
            let updatedEvent = state.episodicEvents[ongoingEvent.id]
            try expect(
                state.entityPages["missing_entity_should_drop"] == nil
                    && state.entityPages["missing_char_should_drop"] == nil
                    && (updatedEvent?.cause.contains("接到密信赶赴码头") ?? false)
                    && (updatedEvent?.development.contains("两人在雨棚下碰头") ?? false)
                    && (updatedEvent?.development.contains("林昭当面交出铜牌") ?? false)
                    && updatedEvent?.outcome == "双方达成临时同盟。",
                "归约器必须拦截孤儿事实/认知防止新建幽灵卡，且事件进展应句级追加不覆盖旧因果"
            )

            // 3. 跨分类同名不覆盖 + 同分类共享别名歧义不盲选
            let entityPayload = NarrativeEntityExtractor.buildExtractionPayload(
                manuscriptTail: "一行人走进青云宗山门。",
                existingPages: [loreSect]
            )
            let entityExtractRaw = """
            {"entities":[
              {"id":"","kind":"location","name":"青云宗","identity":"东域高山道观群","summary":"石阶九百级"}
            ]}
            """
            let parsedEntities = try NarrativeEntityExtractor.parseEntities(
                from: entityExtractRaw,
                existingPages: [loreSect],
                idMapping: entityPayload.mapping
            )
            try expect(
                parsedEntities.added == 1
                    && parsedEntities.updated == 0
                    && parsedEntities.upserts.first?.kind == .location
                    && parsedEntities.upserts.first?.id != loreSect.id,
                "跨分类同名实体不得互相覆盖，应各自独立建档"
            )

            let ambA = EntityPage(id: "c_a", kind: .character, name: "张三", aliases: ["铁剑"])
            let ambB = EntityPage(id: "c_b", kind: .character, name: "李四", aliases: ["铁剑"])
            let lookup = NarrativeEntityResolver.EntityLookupIndex(pages: [ambA, ambB])
            if case .ambiguous(let hits) = lookup.resolve(name: "铁剑", expectedKind: .character) {
                try expect(hits.count == 2, "多候选共享别名应返回 ambiguous 而不是盲选第一个")
            } else {
                try expect(false, "多候选共享别名必须触发歧义保护")
            }

            // 4. 同步切片前情重叠区 + 候选去重响应解析校验
            let seg1 = String(repeating: "第一段雨夜码头对峙。", count: 10)
            let seg2 = String(repeating: "第二段茶室密谈细节。", count: 10)
            let joinedBook = seg1 + "\n\n" + seg2
            let overlapChunks = ManuscriptSyncEngine.splitIntoSyncChunks(
                fullText: joinedBook,
                startUTF16: 0,
                targetChunkUTF16: 120,
                contextOverlapUTF16: 30
            )
            try expect(
                overlapChunks.count >= 2
                    && overlapChunks.map(\.text).joined() == joinedBook
                    && overlapChunks[0].leadingContext.isEmpty
                    && !overlapChunks[1].leadingContext.isEmpty
                    && seg1.contains(overlapChunks[1].leadingContext),
                "同步切片应保持 text 无缝拼接且续段携带来自上段末尾的只读前情"
            )

            let dedupeRaw = """
            {"resolutions":[
              {"id":0,"duplicate_candidate_id":0,"merge_with_new_id":-1,"canonical_name":"","aliases":["小张"]},
              {"id":1,"duplicate_candidate_id":-1,"merge_with_new_id":-1,"canonical_name":"","aliases":[]}
            ]}
            """
            let dedupeSuggestions = NarrativeEntityResolver.parseDedupeResponse(
                from: dedupeRaw,
                candidateIDs: ["new_0", "new_1"],
                existingIDs: ["exist_0"]
            )
            let invalidDedupe = NarrativeEntityResolver.parseDedupeResponse(
                from: #"{"resolutions":[{"id":0,"duplicate_candidate_id":99,"merge_with_new_id":-1}]}"#,
                candidateIDs: ["new_0"],
                existingIDs: ["exist_0"]
            )
            try expect(
                dedupeSuggestions?.count == 1
                    && dedupeSuggestions?.first?.sourceID == "new_0"
                    && dedupeSuggestions?.first?.targetID == "exist_0"
                    && invalidDedupe == nil,
                "候选去重解析应校验索引边界并正确映射合法合并建议"
            )

            return "短号防分裂 + 反向别名 + 泛称/歧义/跨类隔离 + 因果追加 + 切片前情 ok"
        }

        // 验证两阶段全书同步抽取（阶段 1 档案+精确事实，阶段 2 剧情+认知+伏笔）及写作上下文人物摘要与顺时序事件视野。
        check("narrative.twoStageSyncAndCharacterSummaryInjection") {
            let t0 = Date(timeIntervalSince1970: 1_796_300_000)
            let lin = EntityPage(
                id: "char_lin",
                kind: .character,
                name: "林昭",
                summary: "外冷内热，行事慎密",
                identity: "雾港旧书店掌柜",
                voiceProfile: "言简意赅，少用虚词",
                hardBoundaries: ["绝不在外人面前暴露左手旧伤"],
                updatedAt: t0
            )
            let excerpt = "茶室内，林昭把青铜钥匙拍在桌上，沉声道：“沈清秋，账本就在码头地窖。”沈清秋脸色微变，这才知道地窖早在半月前就已易主。"

            // 1. 阶段 1：档案 + 精确动态事实专精提取
            let stage1Payload = NarrativeEntityExtractor.buildExtractionPayload(
                manuscriptTail: excerpt,
                leadingContext: "夜雨未歇，两人刚从巷口闪进茶室。",
                existingPages: [lin],
                includeFacts: true
            )
            let linShort1 = stage1Payload.mapping.entityRealToShort[lin.id] ?? ""
            let stage1PromptText = stage1Payload.messages.map(\.content).joined(separator: "\n")
            try expect(
                !linShort1.isEmpty
                    && stage1PromptText.contains("【前情参考")
                    && stage1PromptText.contains("\"facts\""),
                "阶段 1 应携带前情隔离区与档案+精确事实双层契约"
            )

            let stage1Raw = """
            {
              "entities": [
                {"id": "\(linShort1)", "kind": "character", "name": "林昭", "summary": "当面摊牌试探沈清秋", "voice_profile": "语调沉冷"},
                {"id": "", "kind": "character", "name": "沈清秋", "aliases": ["沈姑娘"], "identity": "南疆暗探", "summary": "城府深沉，此时略显动容", "voice_profile": "字句试探", "hard_boundaries": ["不轻信口头承诺"]}
              ],
              "facts": [
                {"entity_id": "\(linShort1)", "attribute": "location", "value": "茶室", "quote": "茶室内，林昭把青铜钥匙拍在桌上"},
                {"entity_id": "NEW:沈清秋", "attribute": "relation:林昭", "value": "心生忌惮", "quote": "沈清秋脸色微变"},
                {"entity_id": "unknown_orphan_id", "attribute": "location", "value": "幽灵巷", "quote": "茶室内"}
              ]
            }
            """
            let stage1Parsed = try NarrativeEntityExtractor.parseEntitiesAndFacts(
                from: stage1Raw,
                excerpt: excerpt,
                nodeID: "sync_stage1",
                existingPages: [lin],
                idMapping: stage1Payload.mapping,
                now: t0.addingTimeInterval(10)
            )
            let shenPage = stage1Parsed.upserts.first { $0.name == "沈清秋" }
            let linUpdated = stage1Parsed.upserts.first { $0.id == lin.id }
            try expect(
                stage1Parsed.added == 1
                    && stage1Parsed.updated == 1
                    && shenPage != nil
                    && shenPage?.voiceProfile == "字句试探"
                    && shenPage?.hardBoundaries == ["不轻信口头承诺"]
                    && (linUpdated?.summary.contains("外冷内热") ?? false)
                    && (linUpdated?.summary.contains("当面摊牌试探沈清秋") ?? false)
                    && stage1Parsed.factEvents.count == 2
                    && stage1Parsed.ungroundedFactCount == 1
                    && stage1Parsed.factEvents.contains(where: { $0.entityID == lin.id && $0.value == "茶室" })
                    && stage1Parsed.factEvents.contains(where: { $0.entityID == shenPage?.id && $0.attribute == "relation:林昭" }),
                "阶段 1 应完整抽齐人物档案与精确事实，并拦截孤儿实体事实"
            )

            // 2. 阶段 2：基于已定型实体专精提取事件、伏笔与认知盲区
            let allEntities = [linUpdated ?? lin, shenPage].compactMap { $0 }
            let priorEvent = EpisodicEvent(
                id: "evt_teahouse",
                title: "茶室摊牌",
                arcTitle: "南疆追查线",
                scene: "茶室",
                participantEntityIDs: [lin.id],
                cause: "林昭携青铜钥匙赴约。",
                development: "双方刚落座试探。",
                status: .ongoing,
                nodeID: "root",
                updatedAt: t0
            )
            let thread = ProspectiveThread(
                id: "th_cellar",
                goal: "查明码头地窖真主",
                activationCue: "码头地窖",
                state: .pending,
                plantedAtNodeID: "root",
                updatedAtNodeID: "root"
            )
            let stage2Payload = NarrativeDeltaExtractor.buildPlotExtractionPayload(
                excerpt: excerpt,
                knownEntities: allEntities,
                activeThreads: [thread],
                activeEvents: [priorEvent]
            )
            let stage2Prompt = stage2Payload.messages.map(\.content).joined(separator: "\n")
            let linShort2 = stage2Payload.mapping.entityRealToShort[lin.id] ?? ""
            let shenShort2 = stage2Payload.mapping.entityRealToShort[shenPage?.id ?? ""] ?? ""
            let evShort2 = stage2Payload.mapping.eventRealToShort[priorEvent.id] ?? ""
            let thShort2 = stage2Payload.mapping.threadRealToShort[thread.id] ?? ""
            try expect(
                stage2Prompt.contains("双方刚落座试探")
                    && !linShort2.isEmpty
                    && !shenShort2.isEmpty
                    && !evShort2.isEmpty
                    && !thShort2.isEmpty,
                "阶段 2 应向模型提供进行中事件既有进展与全量短编号"
            )

            let stage2Raw = """
            {
              "events": [
                {"id": "\(evShort2)", "title": "茶室摊牌", "participants": ["\(linShort2)", "\(shenShort2)"], "development": "林昭亮出青铜钥匙并点破地窖地址。", "outcome": "沈清秋惊觉地窖早已易主。", "status": "resolved", "quote": "账本就在码头地窖"}
              ],
              "beliefs": [
                {"character_id": "\(shenShort2)", "topic": "码头地窖归属", "believed_truth": "地窖早在半月前就已易主", "knows_secret": true, "quote": "地窖早在半月前就已易主"}
              ],
              "threads": [
                {"thread_id": "\(thShort2)", "action": "ready", "related_entity_ids": ["\(shenShort2)"], "quote": "账本就在码头地窖"}
              ],
              "scene_card": "茶室亮出铜匙并揭晓地窖易主"
            }
            """
            let stage2Parsed = try NarrativeDeltaExtractor.parsePlotDelta(
                from: stage2Raw,
                excerpt: excerpt,
                nodeID: "sync_stage2",
                knownEntities: allEntities,
                activeEvents: [priorEvent],
                idMapping: stage2Payload.mapping,
                now: t0.addingTimeInterval(20)
            )
            try expect(
                stage2Parsed.delta.entityPageUpserts.isEmpty
                    && stage2Parsed.delta.factEvents.isEmpty
                    && stage2Parsed.delta.episodicEvents.first?.id == priorEvent.id
                    && stage2Parsed.delta.episodicEvents.first?.participantEntityIDs == [lin.id, shenPage?.id ?? ""]
                    && stage2Parsed.delta.epistemicBeliefs.first?.characterID == shenPage?.id
                    && stage2Parsed.delta.threadEvents.first?.threadID == thread.id
                    && stage2Parsed.delta.pyramidPatch?.addedRecentSceneCards == ["茶室亮出铜匙并揭晓地窖易主"],
                "阶段 2 应只产出事件/认知/伏笔/场拍卡并精确绑定实体，不得再创建实体或零散事实"
            )

            // 3. 写作上下文应注入人物性格与处境，且关键事件按顺时序展示最多 6 条
            var eventsMap: [String: EpisodicEvent] = [:]
            for idx in 1...6 {
                let evtID = "evt_seq_\(idx)"
                eventsMap[evtID] = EpisodicEvent(
                    id: evtID,
                    title: "事件\(idx)",
                    participantEntityIDs: [lin.id],
                    status: .ongoing,
                    nodeID: "root",
                    updatedAt: t0.addingTimeInterval(TimeInterval(idx * 10))
                )
            }
            let checkState = MaterializedNarrativeState(
                atNodeID: "root",
                pathNodeIDs: ["root"],
                entityPages: Dictionary(uniqueKeysWithValues: allEntities.map { ($0.id, $0) }),
                episodicEvents: eventsMap
            )
            let cone = NarrativeContextOrchestrator.buildQueryConeBlock(
                state: checkState,
                scanText: "林昭走进茶室。"
            )
            let idx1 = cone.block.range(of: "事件1")?.lowerBound
            let idx6 = cone.block.range(of: "事件6")?.lowerBound
            try expect(
                cone.block.contains("性格与处境：")
                    && cone.block.contains("外冷内热，行事慎密")
                    && cone.block.contains("事件6")
                    && idx1 != nil
                    && idx6 != nil
                    && idx1! < idx6!,
                "写作上下文必须注入人物性格与处境摘要，并按时间升序保留最多 6 条相关关键事件"
            )

            return "两阶段全书同步 + 人物摘要注入 + 顺时序事件视野 ok"
        }

        // 验证消费端提示词注意力排布、去重、无工具噪声裁剪与超长档案预算限制。
        check("narrative.orchestratorAttentionLayoutAndDedupe") {
            let t0 = Date(timeIntervalSince1970: 1_795_960_000)
            let longSummary = "核心性格冷静克制，极擅察言观色。" + String(repeating: "曾在江南旧案中孤身潜伏数月不露破绽。", count: 14) + "此刻正屏息躲在茶楼暗格后。"
            let lin = EntityPage(
                id: "auto_character_deadbeef",
                kind: .character,
                name: "林昭",
                summary: longSummary,
                identity: "旧书店掌柜",
                voiceProfile: "短句寡言",
                updatedAt: t0
            )
            let shen = EntityPage(
                id: "auto_character_cafe0001",
                kind: .character,
                name: "沈清秋",
                summary: "城府极深，擅借刀杀人",
                identity: "南疆密使",
                updatedAt: t0
            )
            let p0 = "第一章：老码头青石阶下压着半截铜钥匙。\n"
            let p1 = String(repeating: "雨夜街巷冷清无人。\n", count: 8)
                + "茶室内灯影摇曳，林昭盯着沈清秋手中的密信，指尖缓缓按住桌沿。"
            let fullManuscript = p0 + "\n\n" + p1

            var ws = NarrativeWorkspace(
                preservedStyle: PreservedStyleDistillation(
                    exemplars: [
                        CorpusEntry(
                            id: "ex_teahouse",
                            source: "样本",
                            title: "[场景:动作｜节奏:快｜对白:低] 茶室对峙拆穿假印鉴动作示范",
                            text: "灯花啪地一爆，茶盏盖子刮过瓷沿，发出极轻的一声脆响。"
                        )
                    ]
                )
            )
            ws.storyGraph = StoryGraph.makeInitial(
                rootID: "root",
                summary: "开篇码头伏笔",
                now: t0
            )
            try ws.storyGraph.appendNode(
                PlotNode(
                    id: "sync_1",
                    parentID: "root",
                    branchLabel: "主线",
                    summary: "林昭茶楼试探沈清秋",
                    manuscriptAnchor: TextSpanAnchor.make(utf16Start: 0, utf16Length: 10, quote: "第一章"),
                    createdAt: t0.addingTimeInterval(10)
                )
            )
            try ws.storyGraph.appendNode(
                PlotNode(
                    id: "plan_next",
                    parentID: "sync_1",
                    branchLabel: "主线",
                    summary: "当场拆穿密信上的假印鉴",
                    createdAt: t0.addingTimeInterval(20)
                )
            )
            ws.applyLedgerDelta(
                PlotNodeDelta(
                    directiveAdds: [
                        AuthorDirective(
                            id: "dir_no_modern",
                            verbatimRule: "严禁出现现代科技词汇与枪械描写。",
                            scope: .global,
                            sourceNodeID: "root",
                            createdAt: t0
                        )
                    ],
                    entityPageUpserts: [lin, shen],
                    factEvents: [
                        WorldFactEvent(
                            entityID: lin.id,
                            attribute: "location",
                            value: "茶室",
                            nodeID: "sync_1",
                            authority: .canonProseQuote,
                            createdAt: t0
                        ),
                        WorldFactEvent(
                            entityID: lin.id,
                            attribute: "relation:沈清秋",
                            value: "高度警惕",
                            nodeID: "sync_1",
                            authority: .canonProseQuote,
                            createdAt: t0
                        ),
                    ],
                    pyramidPatch: NarrativePyramidPatch(addedRecentSceneCards: ["林昭茶楼试探沈清秋"])
                ),
                sourceNodeID: "sync_1"
            )

            var bm25 = ManuscriptIndex.IncrementalBM25Index()
            _ = bm25.updatePage(index: 0, text: p0, utf16Start: 0)
            _ = bm25.updatePage(index: 1, text: p1, utf16Start: (p0 as NSString).length + 2)

            var settings = AppSettings()
            settings.providers = [ProviderSetting(kind: .deepseek, model: "deepseek-chat")]
            settings.activeProviderID = settings.providers[0].id
            settings.corpusEnabled = true

            let instruction = "请紧接写林昭拆穿密信假印鉴的动作"
            let noToolsPrompt = NarrativeContextOrchestrator.compose(
                workspace: ws,
                manuscript: fullManuscript,
                history: [],
                userInstruction: instruction,
                settings: settings,
                enabledUniverseEntryIDs: [],
                tailCodePointLimitOverride: 80,
                inputBudget: 16_000,
                enableTools: false,
                bm25Index: bm25
            )
            let noToolsMerged = noToolsPrompt.messages.map(\.content).joined(separator: "\n")
            let idxPrefetch = noToolsMerged.range(of: "老码头青石阶下压着半截铜钥匙")?.lowerBound
            let idxStyle = noToolsMerged.range(of: "灯花啪地一爆")?.lowerBound
            let idxBody = noToolsMerged.range(of: "【当前场次正文】")?.lowerBound
            let idxRule = noToolsMerged.range(of: "严禁出现现代科技词汇与枪械描写")?.lowerBound
            let idxBeat = noToolsMerged.range(of: "【本幕待写目标】")?.lowerBound
            let idxInstr = noToolsMerged.range(of: instruction)?.lowerBound
            let sceneCardCount = noToolsMerged.components(separatedBy: "林昭茶楼试探沈清秋").count - 1

            try expect(
                !noToolsMerged.contains("【全书实体与伏笔索引目录")
                    && !noToolsMerged.contains(lin.id)
                    && !noToolsMerged.contains("location=")
                    && noToolsMerged.contains("位置：茶室")
                    && noToolsMerged.contains("与沈清秋关系：高度警惕")
                    && sceneCardCount == 1
                    && !noToolsMerged.contains("性格与处境：\(longSummary)")
                    && noToolsMerged.contains("核心性格冷静克制")
                    && noToolsMerged.contains("屏息躲在茶楼暗格后")
                    && idxPrefetch != nil && idxStyle != nil && idxBody != nil && idxRule != nil && idxBeat != nil && idxInstr != nil
                    && idxPrefetch! < idxStyle!
                    && idxStyle! < idxBody!
                    && idxBody! < idxRule!
                    && idxRule! < idxBeat!
                    && idxBeat! < idxInstr!,
                "无工具模式应移除工具目录与机器 ID、汉化事实键、去重场景卡，并将参考资料前置、硬规则与目标置后紧贴指令"
            )

            let withToolsPrompt = NarrativeContextOrchestrator.compose(
                workspace: ws,
                manuscript: fullManuscript,
                history: [],
                userInstruction: instruction,
                settings: settings,
                enabledUniverseEntryIDs: [],
                tailCodePointLimitOverride: 80,
                inputBudget: 16_000,
                enableTools: true,
                bm25Index: bm25
            )
            let withToolsMerged = withToolsPrompt.messages.map(\.content).joined(separator: "\n")
            try expect(
                withToolsMerged.contains("【全书实体与伏笔索引目录")
                    && withToolsMerged.contains(lin.id),
                "开启工具模式应保留精简索引目录与实体 ID 供按需查询"
            )

            return "消费端注意力排布 + 语义去噪 + 重复抑制 + 摘要预算 ok"
        }

        // 验证抽取端 20 实体上限、原文 grounding 门控、事件相关性排序与只读工具降级检出。
        check("narrative.extractionBoundsAndToolHardening") {
            let t0 = Date(timeIntervalSince1970: 1_795_970_000)
            var pages: [EntityPage] = []
            for idx in 1...30 {
                pages.append(
                    EntityPage(
                        id: "e_\(idx)",
                        kind: .character,
                        name: "角色\(idx)",
                        identity: "路人甲\(idx)",
                        updatedAt: t0.addingTimeInterval(TimeInterval(idx * 10))
                    )
                )
            }
            let lin = EntityPage(id: "e_lin", kind: .character, name: "林昭", identity: "书店主", updatedAt: t0)
            pages.insert(lin, at: 0)

            let leading = "【前情】幽灵前情角色顾寒舟昨日离开了京城。"
            let excerpt = "今日茶室内，林昭打开青铜匣，取出半张旧契。"
            let stage1Payload = NarrativeEntityExtractor.buildExtractionPayload(
                manuscriptTail: excerpt,
                leadingContext: leading,
                existingPages: pages,
                includeFacts: true
            )
            try expect(
                stage1Payload.mapping.entityShortToReal.count == 20
                    && stage1Payload.mapping.entityRealToShort[lin.id] != nil,
                "Stage 1 现有实体候选清单应严格收敛至 20 条以内并优先保留本段出场实体"
            )

            let stage1Raw = """
            {
              "entities": [
                {"id": "", "kind": "character", "name": "顾寒舟", "identity": "京城旧客"},
                {"id": "", "kind": "artifact", "name": "青铜匣", "identity": "盛放旧契的匣子"}
              ],
              "facts": []
            }
            """
            let stage1Parsed = try NarrativeEntityExtractor.parseEntitiesAndFacts(
                from: stage1Raw,
                excerpt: excerpt,
                nodeID: "sync_ground",
                existingPages: pages,
                idMapping: stage1Payload.mapping,
                now: t0
            )
            try expect(
                stage1Parsed.upserts.count == 1 && stage1Parsed.upserts.first?.name == "青铜匣",
                "Stage 1 必须拦截未出现在本段待提取正文（仅出现在前情参考或脑补）的新实体建档"
            )

            var events: [EpisodicEvent] = [
                EpisodicEvent(
                    id: "evt_old_lin",
                    title: "旧契失窃案",
                    scene: "茶室",
                    participantEntityIDs: [lin.id],
                    status: .ongoing,
                    nodeID: "root",
                    updatedAt: t0
                )
            ]
            for idx in 1...14 {
                events.append(
                    EpisodicEvent(
                        id: "evt_recent_\(idx)",
                        title: "无关支线\(idx)",
                        participantEntityIDs: ["e_\(idx)"],
                        status: .ongoing,
                        nodeID: "root",
                        updatedAt: t0.addingTimeInterval(TimeInterval(idx * 100))
                    )
                )
            }
            let stage2Payload = NarrativeDeltaExtractor.buildPlotExtractionPayload(
                excerpt: excerpt,
                knownEntities: pages,
                activeThreads: [],
                activeEvents: events
            )
            try expect(
                stage2Payload.mapping.entityShortToReal.count == 20
                    && stage2Payload.mapping.eventShortToReal.count == 12
                    && stage2Payload.mapping.eventRealToShort["evt_old_lin"] != nil,
                "Stage 2 应控制实体上限为 20 且把命中本段实体与场景的早期进行中事件优先排入前 12"
            )

            // 验证只读工具：高频分布采样、多词空格降级 BM25、模糊/异类实体与事件兜底。
            var repeatedLines = ["第1页开端：林昭初入茶馆。"]
            for idx in 2...12 {
                repeatedLines.append("第\(idx)段：林昭翻看泛黄卷宗第\(idx)页。")
            }
            repeatedLines.append("尾声：林昭终于找到半截青铜令牌。")
            let pageOne = repeatedLines.joined(separator: "\n")
            let futurePage = "未来章节：林昭飞升仙界。"
            let fullBody = pageOne + "\n" + futurePage
            let sameLoc = EntityPage(id: "loc_tea", kind: .location, name: "听雨阁（南区）", identity: "隐秘茶肆", updatedAt: t0)
            let sameLore = EntityPage(id: "lore_tea", kind: .lore, name: "听雨阁", aliases: ["茶肆旧盟"], identity: "江湖情报组织", updatedAt: t0.addingTimeInterval(10))
            let toolState = MaterializedNarrativeState(
                atNodeID: "root",
                pathNodeIDs: ["root"],
                entityPages: [lin.id: lin, sameLoc.id: sameLoc, sameLore.id: sameLore],
                threads: [
                    "th_tok": ProspectiveThread(
                        id: "th_tok",
                        goal: "查清青铜令牌出处",
                        activationCue: "青铜令牌",
                        state: .pending,
                        plantedAtNodeID: "root",
                        updatedAtNodeID: "root"
                    )
                ],
                episodicEvents: ["evt_old_lin": events[0]]
            )
            let toolCtx = NarrativeToolContext(
                pages: [pageOne, futurePage],
                causalLimit: (pageOne as NSString).length,
                materializedState: toolState
            )

            let freqGrep = NarrativeReadTools.execute(
                call: LLMToolCall(id: "tc1", functionName: NarrativeReadTools.grepManuscriptName, arguments: #"{"pattern":"林昭"}"#),
                context: toolCtx
            )
            let invalidRegexGrep = NarrativeReadTools.execute(
                call: LLMToolCall(id: "tc1b", functionName: NarrativeReadTools.grepManuscriptName, arguments: #"{"pattern":"[unclosed","regex":true}"#),
                context: toolCtx
            )
            let multiTermGrep = NarrativeReadTools.execute(
                call: LLMToolCall(id: "tc2", functionName: NarrativeReadTools.grepManuscriptName, arguments: #"{"query":"林昭 青铜令牌"}"#),
                context: toolCtx
            )
            let fuzzyEntityRead = NarrativeReadTools.execute(
                call: LLMToolCall(id: "tc3", functionName: NarrativeReadTools.readEntityPageName, arguments: #"{"name":"听雨阁"}"#),
                context: toolCtx
            )
            let eventFallbackRead = NarrativeReadTools.execute(
                call: LLMToolCall(id: "tc4", functionName: NarrativeReadTools.readEntityPageName, arguments: #"{"entity_id":"旧契失窃案"}"#),
                context: toolCtx
            )
            try expect(
                freqGrep.output.contains("共命中 13 处")
                    && freqGrep.output.contains("第1页开端")
                    && freqGrep.output.contains("青铜令牌")
                    && !freqGrep.output.contains("仙界")
                    && invalidRegexGrep.output.contains("语法无效")
                    && multiTermGrep.output.contains("BM25相关段落")
                    && multiTermGrep.output.contains("青铜令牌")
                    && fuzzyEntityRead.output.contains("江湖情报组织")
                    && fuzzyEntityRead.output.contains("隐秘茶肆")
                    && eventFallbackRead.output.contains("旧契失窃案"),
                "只读工具应汇报命中总数并支持早晚分布采样、显式正则错误、多词降级 BM25、模糊/同名异类档案合并及事件伏笔兜底"
            )

            let segmentedWords = ManuscriptIndex.tokenize("林昭在城隍庙找到青铜令牌")
            let segmentedSentences = NarrativeEntityResolver.splitSentences("核心性格冷静。他低声道：“你敢么？”说罢起身离开。")
            let denseIndexState = MaterializedNarrativeState(
                atNodeID: "root",
                pathNodeIDs: ["root"],
                entityPages: Dictionary(uniqueKeysWithValues: (1...90).map { idx in
                    let longBio = String(repeating: "旧案追踪线索详情第\(idx)段。", count: 8)
                    return ("idx_\(idx)", EntityPage(id: "idx_\(idx)", kind: .character, name: "甲\(idx)", summary: longBio, updatedAt: t0.addingTimeInterval(TimeInterval(idx))))
                }),
                threads: [
                    "th_keep": ProspectiveThread(
                        id: "th_keep",
                        goal: "城隍庙地下暗门尚未开启",
                        state: .ready,
                        plantedAtNodeID: "root",
                        updatedAtNodeID: "root",
                        updatedAt: t0
                    )
                ]
            )
            let boundedIndex = denseIndexState.bookIndexLines(maxLines: 80)
            let chineseQueryRecall = ManuscriptIndex.recallHistoricalExcerpts(
                fullManuscript: "第一章：老城隍庙的青铜香炉底座刻着一道暗门机关。\n\n第五章：街上行人匆匆走过。",
                activeWindowText: "街上行人匆匆走过。",
                queryTerms: [],
                instructionText: "请紧接写他去城隍庙找暗门机关",
                maxResults: 2,
                maxTokens: 300
            )
            try expect(
                segmentedWords.contains("城隍庙")
                    && !segmentedWords.contains("庙找")
                    && segmentedSentences.count >= 2
                    && boundedIndex.count == 80
                    && boundedIndex.contains(where: { $0.contains("城隍庙地下暗门尚未开启") })
                    && boundedIndex.allSatisfy { $0.count <= 95 }
                    && chineseQueryRecall.contains(where: { $0.text.contains("青铜香炉") }),
                "中文分词/查询词应走系统 NLTokenizer、断句应正确切分整句，目录索引应截断单行简介并为未决伏笔预留名额"
            )

            return "抽取端 20 实体上限 + grounding + 事件相关性排序 + 工具加固 ok"
        }
    }

    private enum UnexpectedStoreStateError: Error {
        case notLoaded
    }
}
