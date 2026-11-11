import SwiftUI

/// 摘要任务单独指定模型；留空时跟随当前AI服务商。
///
/// 原版设置里有 `summaryModel`，自动摘要和长期规则更新走这个模型，
/// 不改写作/翻译用的主模型。
struct SettingsSummaryModelPage: View {
    let store: AppStore
    @State private var model = ""

    var body: some View {
        Form {
            Section {
                TextField("模型名", text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                AppSectionHeader(title: "摘要模型")
            } footer: {
                Text("留空跟随当前AI服务商模型；只影响自动对话摘要和长期规则更新。")
            }

            Section {
                Button("跟随当前模型") {
                    model = ""
                    commit()
                }
                .disabled(store.settings.summaryModel.isEmpty)
            }
        }
        .navigationTitle("摘要模型")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model = store.settings.summaryModel }
        .onDisappear { commit() }
    }

    private func commit() {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != store.settings.summaryModel else { return }
        store.settings.summaryModel = trimmed
        store.saveSettings()
    }
}
