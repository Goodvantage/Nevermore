import AppKit
import NevermoreCore
import RavenProtocol

@MainActor enum LifecycleSelfChecks {
    static func run(app: AppDelegate, owner: ConversationWindow) async throws -> [(String, Bool)] {
        guard let session = owner.session, let channel = owner.channel else { return [("lifecycle fixture has an account", false)] }
        var result: [(String, Bool)] = []
        result.append(("server numeric summaries preserve fractions and avoid integer overflow", owner.summary(.number(12.5)) == "12.5" && !owner.summary(.number(Double.greatestFiniteMagnitude)).isEmpty))
        let related = app.windows.filter { $0.session === session && $0.channel?.id == channel.id }
        session.preparingChannels.insert(channel.id); session.notify()
        result.append(("shared draft editors pause together during local send acceptance", related.count >= 2 && related.allSatisfy { !$0.composer.isEditable && !$0.sendButton.isEnabled }))
        let frozen = owner.composer.attributedString().copy() as! NSAttributedString
        let reply = owner.replyTo
        owner.code(nil); owner.reply(nil); owner.cancelContext(); owner.clearAttachments()
        result.append(("draft actions cannot mutate a composer during local acceptance", owner.composer.attributedString().isEqual(to: frozen) && owner.replyTo == reply))
        session.preparingChannels.remove(channel.id); session.notify()
        result.append(("shared draft editors resume after local send acceptance", related.allSatisfy { $0.composer.isEditable }))
        let ticket = UUID(); session.pendingFileReceipts[ticket] = channel.id; session.notify()
        result.append(("a file import blocks Send across every shared-draft window", related.allSatisfy { $0.composer.isEditable && !$0.sendButton.isEnabled }))
        session.pendingFileReceipts.removeValue(forKey: ticket); session.notify()
        owner.composer.onImage?(Data([1, 2, 3]), "png")
        result.append(("pasted images register a shared import barrier before returning", session.pendingFileReceipts.values.contains(channel.id)))
        await owner.waitForPromisedFiles(); await owner.saveTask?.value
        owner.clearAttachments(); await owner.saveTask?.value
        session.draftRevisions["revision-fixture"] = 2
        session.unpersistedDraftRevisions["revision-fixture"] = 2
        try await session.save(Draft(channelID: "revision-fixture", html: "latest"), revision: 2)
        try await session.save(Draft(channelID: "revision-fixture", html: "stale"), revision: 1)
        let latest = try await session.store.draft(channelID: "revision-fixture")
        result.append(("late draft-save tasks cannot overwrite a newer input revision", latest?.html == "latest" && session.unpersistedDraftRevisions["revision-fixture"] == nil))
        let recoveryID = "draft-recovery-fixture"
        try await session.store.saveDraft(Draft(channelID: recoveryID, html: "<p>persisted older version</p>"))
        session.sharedTextStorage[recoveryID] = NSTextStorage(attributedString: NativeRichText.attributedString(document: try RichTextCodec.parse("<p>unsaved memory version</p>"), revealSpoilers: true))
        session.recoverableDrafts[recoveryID] = Draft(channelID: recoveryID, html: "<p>unsaved memory version</p>")
        session.draftPersistenceFailures[recoveryID] = "Synthetic write failure"
        app.open(session: session, channel: RavenChannel(raw: .object(["name": .string(recoveryID), "channel_name": .string("Recovery fixture")])))
        if let recovery = app.windows.last {
            await recovery.loadTask?.value; await Task.yield()
            result.append(("reopening a failed-save draft preserves newer in-memory text", recovery.composer.string.contains("unsaved memory version") && !recovery.composer.string.contains("persisted older")))
            recovery.close()
        }
        session.recoverableDrafts.removeValue(forKey: recoveryID); session.draftPersistenceFailures.removeValue(forKey: recoveryID); session.sharedTextStorage.removeValue(forKey: recoveryID)
        let closingChannel = RavenChannel(raw: .object(["name": .string("closed-send-fixture"), "channel_name": .string("Closed send fixture")]))
        app.open(session: session, channel: closingChannel)
        var closing = app.windows.last
        await closing?.loadTask?.value; await closing?.renderTask?.value
        closing?.composer.insertText("Captured draft survives its window", replacementRange: NSRange(location: 0, length: closing?.composer.string.utf16.count ?? 0))
        await closing?.saveTask?.value
        let previousState = session.state
        closing?.send(nil)
        let lockedBeforeClose = session.preparingChannels.contains(closingChannel.id)
        weak var released = closing
        closing?.close(); closing = nil
        for _ in 0..<100 { if !session.preparingChannels.contains(closingChannel.id) { break }; await Task.yield() }
        result.append(("closing a sending window releases its shared draft acceptance lock", lockedBeforeClose && !session.preparingChannels.contains(closingChannel.id) && released == nil))
        released = nil
        session.state = previousState
        let acceptedDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreAcceptedDraft-\(UUID())")
        let account = Account(id: UUID(), origin: URL(string: "https://acceptance-fixture.invalid")!, user: "fixture@example.com", siteName: "fixture", clientID: "fixture", displayName: "Local acceptance fixture")
        let acceptance = try AccountSession(account: account, directory: acceptedDirectory)
        defer { acceptance.stop(); try? FileManager.default.removeItem(at: acceptedDirectory) }
        let acceptedDraft = Draft(channelID: "accepted-draft", html: "<p>durably accepted</p>")
        try await acceptance.store.saveDraft(acceptedDraft)
        acceptance.recoverableDrafts[acceptedDraft.channelID] = acceptedDraft
        acceptance.unpersistedDraftRevisions[acceptedDraft.channelID] = 1
        acceptance.invalidDraftChannels.insert(acceptedDraft.channelID)
        acceptance.draftPersistenceFailures[acceptedDraft.channelID] = "Previous write failed"
        try await acceptance.send(acceptedDraft)
        // Stop before yielding: this fixture verifies local acceptance only.
        acceptance.stop()
        let acceptedOperations = try await acceptance.store.operations()
        let clearedDraft = try await acceptance.store.draft(channelID: acceptedDraft.channelID)
        result.append(("durable acceptance clears stale draft recovery state", acceptedOperations.count == 1 && acceptance.recoverableDrafts.isEmpty && acceptance.unpersistedDraftRevisions.isEmpty && acceptance.invalidDraftChannels.isEmpty && acceptance.draftPersistenceFailures.isEmpty && clearedDraft == nil))
        let oldTask = owner.saveTask
        var savedBeforeQuit = false
        owner.saveTask = Task {
            try? await Task.sleep(for: .milliseconds(30))
            try? await session.save(Draft(channelID: "quit-fixture", html: "durable before exit"))
            savedBeforeQuit = true
        }
        try await app.persistDraftsBeforeQuitting()
        let durable = try await session.store.draft(channelID: "quit-fixture")
        result.append(("quit waits for local draft persistence without waiting for the network", savedBeforeQuit && durable?.html == "durable before exit" && !session.stopped))
        owner.saveTask = oldTask
        session.draftPersistenceFailures["quit-fixture"] = "Synthetic persistence failure"
        do { try await app.persistDraftsBeforeQuitting(); result.append(("quit refuses to discard a failed draft save", false)) }
        catch { result.append(("quit refuses to discard a failed draft save", !session.stopped)) }
        session.draftPersistenceFailures.removeValue(forKey: "quit-fixture")
        let previous = owner.draftEncodingFailure; owner.draftEncodingFailure = RichTextError.unsafeEdit
        do { try await app.persistDraftsBeforeQuitting(); result.append(("quit retains unsaved unsupported composer content", false)) }
        catch { result.append(("quit retains unsaved unsupported composer content", true)) }
        owner.draftEncodingFailure = previous
        return result
    }
}
