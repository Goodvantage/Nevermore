import AppKit
import NevermoreCore

@MainActor extension ConversationWindow {
    func receivePromisedFiles(_ sources: [any PromisedFileSource]) {
        guard let session, let channel, !session.stopped, !isClosed, composer.isEditable else { return }
        guard editing == nil else { status.stringValue = "Finish editing the message before adding files."; return }
        let ticket = UUID(), originGeneration = navigationGeneration
        session.pendingFileReceipts[ticket] = channel.id
        promisedReceives[ticket] = Task { [weak self] in
            var batch: PromisedFileBatch?
            var staged: [StagedAttachment] = []
            var outcome: String?
            defer {
                batch?.cleanup()
                self?.promisedReceives.removeValue(forKey: ticket)
                session.pendingFileReceipts.removeValue(forKey: ticket); session.notify()
                if let self, self.isCurrent(session, channelID: channel.id) { self.updateContext(); if let outcome { self.status.stringValue = outcome } }
            }
            do {
                let received = try await PromisedFileReceiver.receive(sources: sources); batch = received
                try Task.checkCancellation()
                guard let self, self.isCurrent(session, channelID: channel.id), self.navigationGeneration == originGeneration, self.editing == nil else { throw CancellationError() }
                for file in received.files {
                    staged.append(try await session.store.stage(file: file.url))
                    try Task.checkCancellation()
                    guard self.isCurrent(session, channelID: channel.id), self.navigationGeneration == originGeneration, self.editing == nil else { throw CancellationError() }
                }
                self.attachments.append(contentsOf: staged)
                if received.timedOut || !received.failures.isEmpty || received.droppedFailures > 0 {
                    outcome = "\(staged.count) files attached. \(received.timedOut ? "The file provider did not finish in time." : "Some files could not be received.")"
                }
                self.updateContext()
                // Persist only private AccountStore copies, never provider/temp URLs.
                self.textDidChange(Notification(name: NSText.didChangeNotification, object: self.composer))
            } catch {
                await Task { try? await session.store.pruneStaging(discarding: Set(staged.map(\.id))) }.value
                if let self, self.isCurrent(session, channelID: channel.id), !(error is CancellationError) { outcome = "Files could not be attached: \(error.localizedDescription)" }
            }
        }
        session.notify(); updateContext()
    }
    @objc func cancelPromisedFiles(_ sender: Any? = nil) {
        for task in promisedReceives.values { task.cancel() }
        promisedReceives.removeAll(); updateContext()
    }
    func waitForPromisedFiles() async { for task in Array(promisedReceives.values) { await task.value } }
}
