import AppKit
import NevermoreCore

@MainActor extension AppDelegate {
    /// Wait only for local persistence, not server delivery or socket shutdown.
    func persistDraftsBeforeQuitting() async throws {
        let live = Array(windows)
        guard !live.contains(where: { $0.draftEncodingFailure != nil }) && !sessions.contains(where: { !$0.stopped && !$0.invalidDraftChannels.isEmpty }) else { throw AppError.message("Some composer content could not be saved. Copy or correct that text before quitting; Nevermore will stay open.") }
        for controller in live {
            if controller.activeComposer.hasMarkedText() {
                controller.activeComposer.unmarkText()
                controller.persistActiveDraft()
            }
            controller.cancelPromisedFiles()
        }
        for controller in live { await controller.saveTask?.value }
        let deadline = Date().addingTimeInterval(30)
        while sessions.contains(where: { !$0.stopped && (!$0.preparingChannels.isEmpty || !$0.acceptingChannels.isEmpty || !$0.unpersistedDraftRevisions.isEmpty) }) {
            guard !live.contains(where: { $0.draftEncodingFailure != nil }) && !sessions.contains(where: { !$0.stopped && !$0.invalidDraftChannels.isEmpty }) else { throw AppError.message("Some composer content could not be saved. Nevermore will stay open so you can recover it.") }
            if sessions.contains(where: { !$0.stopped && !$0.draftPersistenceFailures.isEmpty }) { throw AppError.message("A draft could not be saved. Nevermore will stay open so you can recover your text.") }
            guard Date() < deadline else { throw AppError.message("A message is still being saved to the local outbox. Keep Nevermore open and try quitting again after it finishes.") }
            try await Task.sleep(for: .milliseconds(5))
        }
        // Local send acceptance/IME commitment can enqueue a final draft update.
        for controller in live { await controller.saveTask?.value }
        guard !live.contains(where: { $0.draftEncodingFailure != nil }) && !sessions.contains(where: { !$0.stopped && !$0.invalidDraftChannels.isEmpty }) else { throw AppError.message("Some composer content could not be saved. Nevermore will stay open so you can recover it.") }
        if sessions.contains(where: { !$0.stopped && !$0.draftPersistenceFailures.isEmpty }) {
            throw AppError.message("A draft could not be saved. Nevermore will stay open so you can recover or retry your text.")
        }
    }
    @objc func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationTask != nil { return .terminateLater }
        if ComposerEditorLifetime.activeCount > 0 {
            let alert = NSAlert(); alert.messageText = "Finish editing before quitting"
            alert.informativeText = "Use or cancel the open text or table editor first. Your original draft has not been replaced."
            alert.addButton(withTitle: "Continue Editing"); alert.runModal()
            return .terminateCancel
        }
        let edited = windows.contains { controller in
            guard let message = controller.editing else { return false }
            guard let draft = try? controller.currentDraft() else { return true }
            let original = (try? RichTextCodec.html(RichTextCodec.parse(message.html))) ?? message.html
            return original != draft.html
        }
        if edited {
            let alert = NSAlert(); alert.messageText = "An edited message has not been saved"
            alert.informativeText = "Continue editing to save or copy your changes before quitting."
            alert.addButton(withTitle: "Continue Editing"); alert.addButton(withTitle: "Discard Edits and Quit")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        isPreparingToQuit = true
        for window in windows { window.updateComposerAvailability() }
        terminationTask = Task {
            do {
                try await persistDraftsBeforeQuitting()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                isPreparingToQuit = false; terminationTask = nil
                for window in windows { window.updateContext() }
                showError(error); sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
