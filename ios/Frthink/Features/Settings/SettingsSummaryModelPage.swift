import SwiftUI

/// 摘要任务单独指定模型；留空时跟随当前AI服务商。
///
/// 自动摘要和长期规则更新优先使用该模型，不影响写作/翻译的主模型。
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
            }

            Section {
                Button("跟随当前模型") {
                    model = ""
                    commit()
                }
                .disabled(store.settings.summaryModel.isEmpty)
            }
        }
        .settingsFormColumn()
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
