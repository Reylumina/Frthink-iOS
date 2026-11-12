import SwiftUI
import UIKit

@main
struct FrthinkApp: App {
    @State private var store = AppStore()

    init() {
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
    }

    var body: some Scene {
        WindowGroup {
            if SelfCheck.isRequested {
                // CI 用 `-runSelfCheck` 拉起来跑一遍纯逻辑，输出进日志后退出。
                Color.clear
                    .onAppear {
                        let code = SelfCheck.run()
                        exit(code)
                    }
            } else {
                RootView()
                    .environment(store)
                    .tint(Theme.accent)
                    .scrollIndicators(.hidden)
            }
        }
    }
}

