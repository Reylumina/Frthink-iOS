// 共享文件导入选择器：直接由当前顶层 UIViewController 弹出原生 UIDocumentPickerViewController(asCopy: true)，
// 避免 SwiftUI .sheet 双层包裹远程视图控制器造成白屏，并在选中后立即拷贝至沙盒临时目录。

import ObjectiveC
import UIKit
import UniformTypeIdentifiers

@MainActor
enum DocumentPickerPresenter {
    private static var activeDelegateKey: UInt8 = 0

    static func present(
        allowedContentTypes: [UTType],
        onComplete: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        guard let presenter = topViewController() else {
            onComplete(.failure(NSError(
                domain: "Frthink.DocumentPicker",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法获取当前界面控制器，请重试。"]
            )))
            return
        }

        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedContentTypes,
            asCopy: true
        )
        let coordinator = Coordinator { result in
            objc_setAssociatedObject(picker, &activeDelegateKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            Task { @MainActor in
                // 等待 UIKit 文档选择器完成收起转场，再触发后续导航或弹窗。
                try? await Task.sleep(for: .milliseconds(150))
                onComplete(result)
            }
        }
        objc_setAssociatedObject(picker, &activeDelegateKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        picker.delegate = coordinator
        picker.allowsMultipleSelection = false
        presenter.present(picker, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let window = scenes
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first(where: \.isKeyWindow)
            ?? scenes.flatMap(\.windows).first
        var current = window?.rootViewController
        while let presented = current?.presentedViewController {
            current = presented
        }
        return current
    }

    private final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finish: (Result<URL, Error>) -> Void

        init(finish: @escaping (Result<URL, Error>) -> Void) {
            self.finish = finish
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let sourceURL = urls.first else {
                finish(.failure(CocoaError(.userCancelled)))
                return
            }
            do {
                let stagedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("frthink-import-\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
                if FileManager.default.fileExists(atPath: stagedURL.path) {
                    try FileManager.default.removeItem(at: stagedURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
                finish(.success(stagedURL))
            } catch {
                finish(.failure(error))
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish(.failure(CocoaError(.userCancelled)))
        }
    }
}
