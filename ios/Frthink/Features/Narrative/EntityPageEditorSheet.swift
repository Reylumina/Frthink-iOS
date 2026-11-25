// 档案新建与编辑浮层：支持人物、地点、物件、世界观四类档案的创建与全字段修改。

import Foundation
import SwiftUI

struct EntityPageEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let session: ProjectSession
    let existingPage: EntityPage?
    let initialKind: EntityKind

    @State private var kind: EntityKind
    @State private var name: String
    @State private var aliasesText: String
    @State private var triggerKeywordsText: String
    @State private var activationMode: EntityActivationMode
    @State private var identity: String
    @State private var summary: String
    @State private var voiceProfile: String
    @State private var hardBoundariesText: String
    @State private var enabled: Bool

    private let allKinds: [EntityKind] = [.character, .location, .artifact, .lore]

    init(
        session: ProjectSession,
        existingPage: EntityPage? = nil,
        initialKind: EntityKind = .character
    ) {
        self.session = session
        self.existingPage = existingPage
        self.initialKind = initialKind
        _kind = State(initialValue: existingPage?.kind ?? initialKind)
        _name = State(initialValue: existingPage?.name ?? "")
        _aliasesText = State(initialValue: existingPage?.aliases.joined(separator: "、") ?? "")
        _triggerKeywordsText = State(initialValue: existingPage?.triggerKeywords.joined(separator: "、") ?? "")
        _activationMode = State(initialValue: existingPage?.activationMode ?? .mentioned)
        _identity = State(initialValue: existingPage?.identity ?? "")
        _summary = State(initialValue: existingPage?.summary ?? "")
        _voiceProfile = State(initialValue: existingPage?.voiceProfile ?? "")
        _hardBoundariesText = State(initialValue: existingPage?.hardBoundaries.joined(separator: "\n") ?? "")
        _enabled = State(initialValue: existingPage?.enabled ?? true)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                basicSection
                detailSection
                boundariesSection
            }
            .scrollContentBackground(.hidden)
            .groupedPageBackground()
            .navigationTitle(existingPage == nil ? "新建档案" : "编辑档案")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton(title: "取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton(title: "保存", isEnabled: !trimmedName.isEmpty) {
                        save()
                    }
                }
            }
        }
    }

    private var basicSection: some View {
        Section {
            Picker("分类", selection: $kind) {
                ForEach(allKinds, id: \.rawValue) { item in
                    Text(NarrativeViewSupport.entityKindLabel(item)).tag(item)
                }
            }

            TextField("名称（必填）", text: $name)
                .font(Theme.label)

            TextField(aliasesPlaceholder, text: $aliasesText)
                .font(Theme.labelSmall)

            if kind == .lore {
                Picker("生效方式", selection: $activationMode) {
                    Text(EntityActivationMode.mentioned.displayName).tag(EntityActivationMode.mentioned)
                    Text(EntityActivationMode.always.displayName).tag(EntityActivationMode.always)
                }
            }

            if kind != .lore || activationMode == .mentioned {
                TextField("触发词（正文中出现即带入，用顿号或逗号分隔）", text: $triggerKeywordsText, axis: .vertical)
                    .font(Theme.labelSmall)
                    .lineLimit(1...3)
            }

            Toggle("参与生成上下文", isOn: $enabled)
        } header: {
            AppSectionHeader(title: "基本信息")
        }
    }

    private var detailSection: some View {
        Section {
            TextField(identityPlaceholder, text: $identity, axis: .vertical)
                .font(Theme.label)
                .lineLimit(1...4)

            TextField(summaryPlaceholder, text: $summary, axis: .vertical)
                .font(Theme.labelSmall)
                .lineLimit(2...6)

            if kind == .character {
                TextField("说话风格（口吻、措辞偏好）", text: $voiceProfile, axis: .vertical)
                    .font(Theme.labelSmall)
                    .lineLimit(1...4)
            }
        } header: {
            AppSectionHeader(title: detailSectionTitle)
        }
    }

    private var boundariesSection: some View {
        Section {
            TextField(boundariesPlaceholder, text: $hardBoundariesText, axis: .vertical)
                .font(Theme.labelSmall)
                .lineLimit(2...6)
        } header: {
            AppSectionHeader(title: boundariesSectionTitle)
        }
    }

    private var aliasesPlaceholder: String {
        kind == .lore ? "同义词或别称（用顿号或逗号分隔）" : "别名（用顿号或逗号分隔）"
    }

    private var identityPlaceholder: String {
        switch kind {
        case .character: return "身份（如：主角、北境校尉）"
        case .location: return "位置与类型（如：城南酒馆、地宫二层）"
        case .artifact: return "归属与类型（如：林昭佩剑、南诏秘匣）"
        case .lore: return "所属类别（如：修炼体系、宗门制度、货币）"
        }
    }

    private var summaryPlaceholder: String {
        switch kind {
        case .character: return "性格与近期处境"
        case .location: return "空间布局、环境氛围与出入口"
        case .artifact: return "外观、用途与当前状态"
        case .lore: return "词条内容与具体机制"
        }
    }

    private var detailSectionTitle: String {
        switch kind {
        case .character: return "人物设定"
        case .location: return "空间与环境"
        case .artifact: return "器物与用途"
        case .lore: return "世界观内容"
        }
    }

    private var boundariesSectionTitle: String {
        "\(kind.boundariesLabel)（选填）"
    }

    private var boundariesPlaceholder: String {
        switch kind {
        case .character: return "每行一条，写角色绝不会违背的底线"
        case .location: return "每行一条，写地形、出入口或准入限制"
        case .artifact: return "每行一条，写触发条件、代价或损耗限制"
        case .lore: return "每行一条，写世界内不可违背的铁律或例外"
        }
    }

    private func save() {
        let cleanName = trimmedName
        guard !cleanName.isEmpty else { return }

        let aliases = NarrativeEntityExtractor.parseStringArray(aliasesText)
        let triggerKeywords = NarrativeEntityExtractor.parseStringArray(triggerKeywordsText)

        let boundaries = hardBoundariesText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let pageID = existingPage?.id
            ?? "\(kind.rawValue)_\(UUID().uuidString.prefix(8).lowercased())"

        let page = EntityPage(
            id: pageID,
            kind: kind,
            name: cleanName,
            aliases: aliases,
            triggerKeywords: triggerKeywords,
            activationMode: kind == .lore ? activationMode : .mentioned,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            identity: identity.trimmingCharacters(in: .whitespacesAndNewlines),
            voiceProfile: kind == .character ? voiceProfile.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            hardBoundaries: boundaries,
            currentFactIDs: existingPage?.currentFactIDs ?? [],
            conflictWarnings: existingPage?.conflictWarnings ?? [],
            enabled: enabled,
            updatedAt: Date()
        )
        session.saveEntityPage(
            page,
            isReplacement: true,
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        store.toast = existingPage == nil ? "已添加档案" : "已保存修改"
        dismiss()
    }
}
