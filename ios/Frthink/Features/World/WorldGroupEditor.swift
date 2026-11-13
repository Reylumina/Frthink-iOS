// 人物分组管理：新增/改名/启停/删除；删组时把卡片退回未分组。

import SwiftUI

struct WorldGroupEditor: View {
    @Bindable var session: ProjectSession
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDeleteOffsets: IndexSet?

    var body: some View {
        Form {
            Section {
                groupRows
            } header: {
                AppSectionHeader(title: "分组")
            }

            Section {
                Button {
                    addGroup()
                } label: {
                    Label("新建分组", systemImage: "plus")
                        .font(Font.body)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle("人物分组")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    session.scheduleSave()
                    dismiss()
                }
            }
        }
        .deleteConfirmationDialog(deleteTitle, isPresented: deleteAlertBinding) {
            confirmDeleteGroups()
        }
        .onChange(of: session.payload.world.characterGroups) { _, _ in
            session.scheduleSave()
        }
        .onDisappear {
            session.scheduleSave()
        }
    }

    @ViewBuilder
    private var groupRows: some View {
        if session.payload.world.characterGroups.isEmpty {
            Text("还没有分组")
                .font(Font.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach($session.payload.world.characterGroups) { $group in
                HStack(spacing: Theme.Spacing.s) {
                    TextField("分组名", text: $group.name)
                        .font(Font.body)
                    Toggle("", isOn: $group.enabled)
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityLabel("启用分组")
                }
            }
            .onDelete { offsets in
                pendingDeleteOffsets = offsets
            }
        }
    }

    private func addGroup() {
        session.payload.world.characterGroups.append(
            CharacterGroup(name: "新分组")
        )
    }

    private var deleteTitle: String {
        let count = pendingDeleteOffsets?.count ?? 0
        return count == 1 ? "删除这个分组？" : "删除 \(count) 个分组？"
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingDeleteOffsets != nil },
            set: { if !$0 { pendingDeleteOffsets = nil } }
        )
    }

    private func confirmDeleteGroups() {
        guard let offsets = pendingDeleteOffsets else { return }
        pendingDeleteOffsets = nil

        let groups = session.payload.world.characterGroups
        let ids = Set(offsets.compactMap { groups.indices.contains($0) ? groups[$0].id : nil })
        guard !ids.isEmpty else { return }

        session.payload.world.characterGroups.removeAll { ids.contains($0.id) }
        for index in session.payload.world.characters.indices {
            if let groupID = session.payload.world.characters[index].groupId,
               ids.contains(groupID) {
                session.payload.world.characters[index].groupId = nil
            }
        }
        session.scheduleSave()
    }
}
