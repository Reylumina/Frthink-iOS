// 叙事管理页面共用状态读取、领域映射与统一错误弹窗修饰器。

import Foundation
import SwiftUI

@MainActor
enum NarrativeViewSupport {

    static func loadState(
        session: ProjectSession,
        store: AppStore
    ) throws -> MaterializedNarrativeState {
        let workspace = session.ensureNarrativeWorkspace(
            settingsCorpusLibraries: store.settings.corpusLibraries
        )
        return workspace.currentState()
    }

    static func authorityLabel(_ authority: AuthorityRank) -> String {
        switch authority {
        case .authorDirective: return "手动设定"
        case .canonProseQuote: return "正文记录"
        case .inferredByAI: return "自动提取"
        }
    }

    static func authorityTone(_ authority: AuthorityRank) -> AppTone {
        switch authority {
        case .authorDirective: return .accent
        case .canonProseQuote: return .success
        case .inferredByAI: return .warning
        }
    }

    static func entityKindLabel(_ kind: EntityKind) -> String {
        switch kind {
        case .character: return "人物"
        case .location: return "地点"
        case .artifact: return "物件"
        case .lore: return "设定"
        }
    }
}

extension Binding where Value == Bool {
    static func isPresent<T>(_ optional: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { optional.wrappedValue != nil },
            set: { if !$0 { optional.wrappedValue = nil } }
        )
    }
}

private struct NarrativeErrorAlertModifier: ViewModifier {
    let title: String
    @Binding var errorMessage: String?

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding.isPresent($errorMessage)) {
            Button("好", role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}

extension View {
    func narrativeErrorAlert(
        _ errorMessage: Binding<String?>,
        title: String = "操作失败"
    ) -> some View {
        modifier(NarrativeErrorAlertModifier(title: title, errorMessage: errorMessage))
    }
}
