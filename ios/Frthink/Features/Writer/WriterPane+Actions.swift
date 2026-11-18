// 码字机消息菜单、正文插入撤销、回退分支、多选删除与正文导入导出动作。

import SwiftUI
import UIKit

extension WriterPane {

    // MARK: - 上下文菜单

    func contextMenuSections(for message: ChatMessage) -> [[UIMenuElement]] {
        message.role == .user
            ? userMenuSections(for: message)
            : assistantMenuSections(for: message)
    }

    private func userMenuSections(for message: ChatMessage) -> [[UIMenuElement]] {
        let copyAction = UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { _ in
            copyToClipboard(message.content)
        }
        let withdrawAction = UIAction(
            title: "撤回",
            image: UIImage(systemName: "arrow.uturn.backward"),
            attributes: .destructive
        ) { _ in
            withdrawUserMessage(message)
        }
        let deleteAction = UIAction(
            title: "删除消息",
            image: UIImage(systemName: "trash"),
            attributes: controller.isBusy ? [.destructive, .disabled] : .destructive
        ) { _ in
            messageAction = .deleteMessage(message)
        }
        return [[copyAction], [withdrawAction, deleteAction]]
    }

    private func assistantMenuSections(for message: ChatMessage) -> [[UIMenuElement]] {
        let isBusy = controller.isBusy
        var primary: [UIMenuElement] = [
            UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { _ in
                copyToClipboard(message.content)
            },
            UIAction(title: "插入到光标处", image: UIImage(systemName: "text.insert")) { _ in
                insertIntoManuscript(message.content)
            },
            UIAction(title: "追加到正文末尾", image: UIImage(systemName: "text.append")) { _ in
                messageAction = .append(message)
            },
        ]
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            primary.append(
                UIAction(
                    title: "提取为人物卡",
                    image: UIImage(systemName: "person.crop.rectangle.badge.plus"),
                    attributes: isBusy ? .disabled : []
                ) { _ in
                    ingestCharacter(from: message.content)
                }
            )
        }

        var secondary: [UIMenuElement] = [
            UIAction(
                title: "重新生成",
                image: UIImage(systemName: "arrow.clockwise"),
                attributes: isBusy ? .disabled : []
            ) { _ in
                controller.regenerate(messageID: message.id, session: session, store: store)
            },
            UIAction(
                title: "回退到此",
                image: UIImage(systemName: "arrow.uturn.backward"),
                attributes: isBusy ? .disabled : []
            ) { _ in
                messageAction = .rollback(message)
            },
        ]
        if message.variants.count > 1 {
            secondary.append(
                UIAction(title: "清理历史版本", image: UIImage(systemName: "archivebox")) { _ in
                    messageAction = .cleanup(message)
                }
            )
        }

        let deleteAction = UIAction(
            title: message.variants.count > 1 ? "删除当前版本" : "删除气泡",
            image: UIImage(systemName: "trash"),
            attributes: isBusy ? [.destructive, .disabled] : .destructive
        ) { _ in
            messageAction = .delete(message)
        }
        return [primary, secondary, [deleteAction]]
    }

    private func withdrawUserMessage(_ message: ChatMessage) {
        if controller.isBusy { controller.stop() }
        let previousDraft = composer.text
        let withdrawnText = message.content
        composer.text = withdrawnText
        session.payload.composerDraft = withdrawnText
        let index = session.payload.messages.firstIndex { $0.id == message.id }
        let removed = session.withdraw(from: message.id)
        presentUndoPrompt("已撤销指令") {
            session.restore(removed, at: index)
            guard composer.text == withdrawnText else { return }
            composer.text = previousDraft
            session.payload.composerDraft = previousDraft
        }
    }

    private func ingestCharacter(from text: String) {
        Task { @MainActor in
            do {
                let result = try await WorldWorkflow.ingestCharacterFromBubble(
                    text,
                    session: session,
                    store: store
                )
                store.toast = result.isNew
                    ? "已新建人物卡：\(result.cardName)"
                    : "已更新人物卡：\(result.cardName)"
            } catch {
                guard !error.isLLMCancellation else { return }
                store.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 正文插入与撤销

    func startContinuation() {
        dismissKeyboard()
        controller.continueWriting(session: session, store: store)
    }

    func copyToClipboard(_ text: String) {
        guard !text.isEmpty else { return }
        WriterClipboard.copy(text)
        store.toast = "已复制"
    }

    func insertIntoManuscript(_ text: String) {
        guard !text.isEmpty else { return }
        dismissKeyboard()
        let length = session.manuscriptLength
        let base = cursorPlaced ? min(max(cursorOffset, 0), length) : length
        let block = paragraphSeparated(text, at: base)
        guard !block.isEmpty else { return }
        let receipt = session.insertIntoManuscript(block, at: base)
        cursorOffset = base + (block as NSString).length
        cursorPlaced = true
        StateSyncWorkflow.scheduleSleepTimeSync(
            excerpt: block,
            session: session,
            store: store
        )
        let action = registerBodyUndo(receipt, actionName: "插入正文")
        presentUndoPrompt("已插入正文") {
            StateSyncWorkflow.cancelSleepTimeSync(projectID: session.project.id)
            action.undoViaButton()
        }
    }

    /// 应用级动作登记进窗口的 UndoManager（§5.8）。
    func registerBodyUndo(
        _ receipt: BodyAppendReceipt,
        actionName: String
    ) -> WriterBodyUndoAction {
        let action = WriterBodyUndoAction(
            receipt: receipt,
            actionName: actionName,
            undoManager: undoManager,
            session: session,
            store: store
        )
        undoActions.append(action)
        action.registerInitialUndo()
        undoState.refresh()
        return action
    }

    /// 页面离开时注销所有撤销动作，避免跨项目误触发与悬挂引用。
    func discardUndoActions() {
        for action in undoActions {
            undoManager.removeAllActions(withTarget: action)
        }
        undoActions.removeAll()
    }

    /// 为插入文本补充段落分隔换行符。
    func paragraphSeparated(_ text: String, at offset: Int) -> String {
        let ns = session.manuscript as NSString
        var block = text.trimmingCharacters(in: .newlines)
        if offset > 0 {
            let start = max(0, offset - 2)
            let before = ns.substring(with: NSRange(location: start, length: offset - start))
            if !before.hasSuffix("\n\n") {
                block = (before.hasSuffix("\n") ? "\n" : "\n\n") + block
            }
        }
        let afterLength = min(2, ns.length - offset)
        if afterLength > 0 {
            let after = ns.substring(with: NSRange(location: offset, length: afterLength))
            if !after.hasPrefix("\n\n") {
                block += after.hasPrefix("\n") ? "\n" : "\n\n"
            }
        }
        return block
    }

    func dismissKeyboard() {
        composer.dismissRequest += 1
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }

    // MARK: - 消息动作与多选

    /// 回退操作：回滚当前助手回复及其前置用户指令，并将指令文本恢复至输入框。
    func performRollback(to target: ChatMessage) {
        let messages = session.payload.messages
        guard let index = messages.firstIndex(where: { $0.id == target.id }) else { return }

        var cutIndex = index
        var restoredInstruction = false
        if let userIndex = messages[..<index].lastIndex(where: { $0.role == .user }) {
            let instruction = messages[userIndex].content
            composer.text = instruction
            session.payload.composerDraft = instruction
            cutIndex = userIndex
            restoredInstruction = true
        }
        session.rollbackToMessage(messages[cutIndex].id)
        store.toast = restoredInstruction
            ? "已回退指令，指令已放回输入框"
            : "已删除此气泡及后续对话"
    }

    func beginSelection(_ messageID: String) {
        guard !controller.isBusy else { return }
        dismissKeyboard()
        selectionMode = true
        selectedMessageIDs.insert(messageID)
    }

    func toggleSelection(_ messageID: String) {
        selectedMessageIDs.formSymmetricDifference([messageID])
    }

    func exitSelection() {
        selectionMode = false
        selectedMessageIDs.removeAll()
    }

    func performMessageAction(_ action: MessageAction) {
        messageAction = nil
        switch action {
        case .append(let message):
            dismissKeyboard()
            let receipt = session.appendToManuscript(message.content)
            cursorOffset = session.manuscriptLength
            cursorPlaced = true
            StateSyncWorkflow.scheduleSleepTimeSync(
                excerpt: message.content,
                session: session,
                store: store
            )
            let undoAction = registerBodyUndo(receipt, actionName: "追加到正文")
            presentUndoPrompt("已追加到正文") {
                StateSyncWorkflow.cancelSleepTimeSync(projectID: session.project.id)
                undoAction.undoViaButton()
            }
        case .rollback(let message):
            performRollback(to: message)
        case .cleanup(let message):
            session.keepOnlySelectedVariant(for: message.id)
            store.toast = "已清理历史版本"
        case .delete(let message):
            forceScrollToBottom = message.variants.count <= 1
            withAnimation(Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)) {
                session.deleteSelectedVariant(for: message.id)
            }
            store.toast = "已删除当前版本"
        case .deleteMessage(let message):
            forceScrollToBottom = true
            withAnimation(Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)) {
                session.deleteMessage(message.id)
            }
            store.toast = "已删除消息"
        case .deleteSelected:
            let ids = selectedMessageIDs
            guard !ids.isEmpty else { return }
            forceScrollToBottom = true
            exitSelection()
            withAnimation(Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)) {
                session.deleteMessages(ids)
            }
            store.toast = "已删除 \(ids.count) 条消息"
        case .clearAll:
            forceScrollToBottom = true
            withAnimation(Theme.motion(Theme.motionLayout, reduceMotion: reduceMotion)) {
                session.clearConversation()
            }
            store.toast = "已清空聊天记录"
        }
    }

    // MARK: - 导入导出正文

    func handleBodyImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            guard !settingsIsUserCancelled(error) else { return }
            store.errorMessage = "读取正文失败：\(error.localizedDescription)"
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { @MainActor in
                do {
                    let text = try await readBodyFile(from: url)
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        store.errorMessage = "这个文件没有正文内容。"
                        return
                    }
                    pendingBodyImport = PendingBodyImport(
                        filename: url.lastPathComponent,
                        text: text
                    )
                } catch {
                    store.errorMessage = "读取正文失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func readBodyFile(from url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            try TextFileCodec.validateExtension(url)
            let data = try SecurityScopedFileReader.read(
                url,
                maxBytes: TextFileCodec.maxImportBytes
            ) { _ in
                NSError(
                    domain: "Frthink.BodyImport",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "正文文件过大（超过 12 MB），无法导入。"]
                )
            }
            return try TextFileCodec.decode(data)
        }.value
    }

    func performBodyImport(_ pending: PendingBodyImport) {
        dismissKeyboard()
        session.replaceManuscript(pending.text)
        cursorOffset = 0
        cursorPlaced = false
        store.toast = "已导入正文，共 \(pending.text.count.formatted()) 字"
    }

    @MainActor
    func prepareBodyExport() {
        let title = session.project.title
        let files = store.fileStore
        Task { @MainActor in
            let plain = await TextFileCodec.loadPlainExport(session: session, files: files)
            guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                store.errorMessage = "当前作品暂无可导出的正文。"
                return
            }
            bodyExportDocument = PlainTextFileDocument(text: plain)
            bodyExportFilename = TextFileCodec.exportFilename(title: title)
            isExportingBody = true
        }
    }
}
