import SwiftUI
import UIKit

/// 正文导入的确认页：先给文件名和字数，再让用户决定是否覆盖。
struct BodyImportConfirmPage: View {
    let pending: WriterPane.PendingBodyImport
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                AppValueRow(title: "文件", value: pending.filename)
                AppValueRow(title: "字数", value: "\(pending.text.count.formatted()) 字")
            } header: {
                AppSectionHeader(title: "导入正文")
            }

            Section {
                Text("导入会覆盖当前正文，且不能撤销。")
                    .font(Font.footnote)
                    .foregroundStyle(.secondary)
                Button("覆盖并导入", role: .destructive) {
                    onConfirm()
                    dismiss()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .groupedPageBackground()
        .navigationTitle("确认导入")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 桥接 `UIContextMenuInteraction` 弹出原生快捷菜单，屏蔽默认预览视图。
struct NoPreviewContextMenu<Content: View>: UIViewRepresentable {
    let sections: [[UIMenuElement]]
    let content: Content

    init(sections: [[UIMenuElement]], @ViewBuilder content: () -> Content) {
        self.sections = sections
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content, sections: sections)
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        let hostView = context.coordinator.hostingController.view!
        hostView.backgroundColor = .clear
        hostView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostView)

        let anchor = context.coordinator.anchorView
        anchor.backgroundColor = .clear
        anchor.isUserInteractionEnabled = false
        container.addSubview(anchor)

        NSLayoutConstraint.activate([
            hostView.topAnchor.constraint(equalTo: container.topAnchor),
            hostView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            hostView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        container.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.hostingController.rootView = content
        context.coordinator.sections = sections
        let measured = context.coordinator.hostingController.sizeThatFits(
            in: CGSize(
                width: uiView.bounds.width > 0 ? uiView.bounds.width : UIView.layoutFittingCompressedSize.width,
                height: UIView.layoutFittingCompressedSize.height
            )
        )
        if abs(measured.height - context.coordinator.lastMeasuredHeight) > 0.5 {
            context.coordinator.lastMeasuredHeight = measured.height
            uiView.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        let targetWidth = proposal.width ?? UIView.layoutFittingCompressedSize.width
        let measured = context.coordinator.hostingController.sizeThatFits(
            in: CGSize(width: targetWidth, height: UIView.layoutFittingCompressedSize.height)
        )
        context.coordinator.lastMeasuredHeight = measured.height
        return CGSize(width: proposal.width ?? measured.width, height: measured.height)
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        let hostingController: UIHostingController<Content>
        let anchorView = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        var sections: [[UIMenuElement]]
        var lastMeasuredHeight: CGFloat = 0

        init(content: Content, sections: [[UIMenuElement]]) {
            let controller = UIHostingController(rootView: content)
            controller.sizingOptions = [.intrinsicContentSize]
            self.hostingController = controller
            self.sections = sections
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            anchorView.center = location
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return UIMenu(children: []) }
                if self.sections.count <= 1 {
                    return UIMenu(title: "", children: self.sections.first ?? [])
                }
                let groups = self.sections.map {
                    UIMenu(title: "", options: .displayInline, children: $0)
                }
                return UIMenu(title: "", children: groups)
            }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            emptyPreview(in: interaction.view)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            emptyPreview(in: interaction.view)
        }

        private func emptyPreview(in container: UIView?) -> UITargetedPreview? {
            guard let container else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath()
            let target = UIPreviewTarget(container: container, center: anchorView.center)
            return UITargetedPreview(view: anchorView, parameters: parameters, target: target)
        }
    }
}
