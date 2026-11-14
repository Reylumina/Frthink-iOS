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
                // CI 通过 `-runSelfCheck` 参数启动执行纯逻辑自检，将结果输出至日志后退出。
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

