import Foundation

/// 语料收集与翻译。
extension PromptComposer {

    // MARK: - §9 语料收集

    /// 语料收集：system 为 P56，user 为 P58 的 JSON 请求体。
    static func corpusMessages(
        rules: String,
        fragments: [String],
        categories: [String] = []
    ) -> [LLMMessage] {
        [
            .system(PromptLibrary.corpusSystem),
            .user(PromptLibrary.corpusRequestBody(
                rules: rules.isEmpty ? nil : rules,
                categories: categories,
                fragments: fragments
            )),
        ]
    }

    // MARK: - §10 翻译

    /// 翻译单段：system 为 P59，user 为原文文本。
    static func translationMessages(_ segment: String) -> [LLMMessage] {
        [.system(PromptLibrary.translationSystem), .user(segment)]
    }

}
