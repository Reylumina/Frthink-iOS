// 设定档案新建与编辑浮层：支持全部四类设定（人物、地点、物件、设定）的创建与全字段修改。

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
            .navigationTitle(existingPage == nil ? "新建设定" : "编辑设定")
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

            TextField("别名（用顿号或逗号分隔）", text: $aliasesText)
                .font(Theme.labelSmall)

            Toggle("参与生成上下文", isOn: $enabled)
        } header: {
            AppSectionHeader(title: "基本信息")
        }
    }

    private var detailSection: some View {
        Section {
            TextField("身份定位（如：主人公、城南酒馆、传家玉佩）", text: $identity, axis: .vertical)
                .font(Theme.label)
                .lineLimit(1...4)

            TextField("设定摘要（核心特征与现状）", text: $summary, axis: .vertical)
                .font(Theme.labelSmall)
                .lineLimit(2...6)

            if kind == .character {
                TextField("说话风格（口吻、措辞偏好）", text: $voiceProfile, axis: .vertical)
                    .font(Theme.labelSmall)
                    .lineLimit(1...4)
            }
        } header: {
            AppSectionHeader(title: "详细设定")
        }
    }

    private var boundariesSection: some View {
        Section {
            TextField("每行一条不可违背的底线或规则…", text: $hardBoundariesText, axis: .vertical)
                .font(Theme.labelSmall)
                .lineLimit(2...6)
        } header: {
            AppSectionHeader(title: "行为底线 / 约束（可选）")
        }
    }

    private func save() {
        let cleanName = trimmedName
        guard !cleanName.isEmpty else { return }

        let aliases = NarrativeEntityExtractor.parseStringArray(aliasesText)

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
        store.toast = existingPage == nil ? "已添加设定" : "已保存修改"
        dismiss()
    }
}
