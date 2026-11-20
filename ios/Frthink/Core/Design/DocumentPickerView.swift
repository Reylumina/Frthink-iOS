// 共享文件导入选择器：借助 UIKit `asCopy: true` 让系统直接拷贝至沙盒临时目录，
// 规避 SwiftUI `.fileImporter` 的安全作用域权限过期与多修饰符呈现冲突。

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DocumentPickerView: UIViewControllerRepresentable {
    let allowedContentTypes: [UTType]
    let onComplete: (Result<URL, Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: allowedContentTypes,
            asCopy: true
        )
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: (Result<URL, Error>) -> Void

        init(onComplete: @escaping (Result<URL, Error>) -> Void) {
            self.onComplete = onComplete
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let sourceURL = urls.first else {
                onComplete(.failure(CocoaError(.userCancelled)))
                return
            }
            do {
                let stagedURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("frthink-import-\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
                if FileManager.default.fileExists(atPath: stagedURL.path) {
                    try FileManager.default.removeItem(at: stagedURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
                onComplete(.success(stagedURL))
            } catch {
                onComplete(.failure(error))
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onComplete(.failure(CocoaError(.userCancelled)))
        }
    }
}
