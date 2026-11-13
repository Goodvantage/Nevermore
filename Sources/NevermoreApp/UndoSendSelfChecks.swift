import AppKit
import NevermoreCore
import RavenProtocol

/// Undo Send belongs to the accepted account and conversation, even after
/// its window navigates elsewhere. These fixtures never contact Raven.
@MainActor enum UndoSendSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreUndoSendCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "undo-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        let foreignAccount = Account(origin: URL(string: "https://other-demo.invalid")!, user: "other-undo-fixture@example.invalid", siteName: "Other Fixture", clientID: "demo")
        let foreign = try AccountSession(account: foreignAccount, directory: directory.appendingPathComponent("other-account"), demo: true)
        func channel(_ id: String) -> RavenChannel {
            RavenChannel(raw: .object(["name": .string(id), "channel_name": .string(id)]))
        }
        let original = channel("undo-original"), other = channel("undo-other")
        session.channels = [original, other]
        try await session.store.cacheChannels(session.channels)
        let source = ConversationWindow(app: app, session: session)
        let peer = ConversationWindow(app: app, session: session)
        defer { source.close(); peer.close(); session.stop(); foreign.stop(); try? FileManager.default.removeItem(at: directory) }
        source.select(original); peer.select(original)
        await source.loadTask?.value; await source.renderTask?.value
        await peer.loadTask?.value; await peer.renderTask?.value

        try await session.store.saveDraft(Draft(channelID: original.id, html: "<p>Original queued send</p>"))
        let operation = try await session.store.acceptDraft(channelID: original.id)
        guard let undo = session.draftUndoManagers[original.id] else { throw AppError.message("Missing shared draft undo manager.") }
        undo.removeAllActions()
        undo.beginUndoGrouping()
        source.ink.accepted(operation)
        undo.endUndoGrouping()

        // Undo is invoked from the second window, but its target is the
        // first window's controller, which is now showing another draft.
        source.select(other)
        await source.loadTask?.value; await source.renderTask?.value
        let isolatedNavigation = peer.composer.textStorage === session.sharedTextStorage[original.id] && source.composer.textStorage === session.sharedTextStorage[other.id] && peer.composer.textStorage !== source.composer.textStorage
        let file = directory.appendingPathComponent("newer.txt")
        try Data("newer draft attachment".utf8).write(to: file)
        let attachment = try await session.store.stage(file: file)
        try await session.save(Draft(channelID: original.id, attachments: [attachment]))
        peer.restoreDraft()
        for _ in 0..<100 where peer.attachments.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        guard peer.attachments.count == 1, undo.canUndo, source.channel?.id == other.id else {
            throw AppError.message("Undo Send fixture did not settle.")
        }
        undo.undo()
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            if try await session.store.draft(channelID: original.id)?.html == operation.html { break }
        }
        let draft = try await session.store.draft(channelID: original.id)
        let operations = try await session.store.operations()
        var checks = [
            ("navigating one shared composer leaves the other window attached to its original draft", isolatedNavigation),
            ("Undo Send from another window preserves a newer staged draft after the original window navigates away", draft?.attachments.map(\.id) == [attachment.id] && operations.contains { $0.id == operation.id })
        ]

        // An empty A can receive its send even when the original window's
        // B now has both a different queued send and a newer draft.
        try await session.save(Draft(channelID: original.id))
        source.select(original)
        await source.loadTask?.value; await source.renderTask?.value
        undo.removeAllActions(); undo.beginUndoGrouping(); source.ink.accepted(operation); undo.endUndoGrouping()
        source.select(other)
        await source.loadTask?.value; await source.renderTask?.value
        try await session.store.saveDraft(Draft(channelID: other.id, html: "<p>Queued in B.</p>"))
        let otherSend = try await session.store.acceptDraft(channelID: other.id)
        guard let otherUndo = session.draftUndoManagers[other.id] else { throw AppError.message("Missing other draft undo manager.") }
        otherUndo.beginUndoGrouping(); source.ink.accepted(otherSend); otherUndo.endUndoGrouping()
        let otherDraft = Draft(channelID: other.id, html: "<p>Newer work in B.</p>")
        try await session.save(otherDraft)
        for _ in 0..<100 where !source.composer.string.contains("Newer work in B.") { try await Task.sleep(for: .milliseconds(10)) }
        guard otherUndo.canUndo, source.composer.string.contains("Newer work in B.") else {
            throw AppError.message("Other conversation's draft and undo fixture did not settle.")
        }
        undo.undo()
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            if peer.composer.string.contains("Original queued send") { break }
        }
        let returned = try await session.store.draft(channelID: original.id)
        let untouched = try await session.store.draft(channelID: other.id)
        let pending = try await session.store.operations()
        checks.append(("Undo Send restores its original conversation while its registering window has another draft", returned?.html == operation.html && pending.map(\.id) == [otherSend.id] && peer.composer.string.contains("Original queued send")))
        checks.append(("Undo Send leaves another conversation's newer draft unchanged", untouched == otherDraft && source.composer.string.contains("Newer work in B.")))
        checks.append(("Undo Send leaves another conversation's send undo actions intact", otherUndo.canUndo))

        // Conversation IDs can be identical on different accounts. Switching
        // the registering window must not redirect the old undo callback.
        let originalAgain = try await session.store.acceptDraft(channelID: original.id)
        source.select(original)
        await source.loadTask?.value; await source.renderTask?.value
        undo.removeAllActions(); undo.beginUndoGrouping(); source.ink.accepted(originalAgain); undo.endUndoGrouping()
        foreign.channels = [original, other]
        let foreignDraft = Draft(channelID: original.id, html: "<p>Other account work.</p>")
        try await foreign.store.saveDraft(foreignDraft)
        source.session = foreign
        source.select(original)
        await source.loadTask?.value; await source.renderTask?.value
        undo.undo()
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            if try await session.store.draft(channelID: original.id)?.html == originalAgain.html { break }
        }
        let restoredAccountDraft = try await session.store.draft(channelID: original.id)
        let foreignAfter = try await foreign.store.draft(channelID: original.id)
        let originalPending = try await session.store.operations()
        checks.append(("Undo Send remains bound to the original account after its registering window switches accounts", restoredAccountDraft?.html == originalAgain.html && foreignAfter == foreignDraft && !originalPending.contains { $0.id == originalAgain.id } && source.composer.string.contains("Other account work.")))

        let waiting = try await session.store.acceptDraft(channelID: original.id)
        let unsaved = Draft(channelID: original.id, html: "<p>Unsaved newer work.</p>")
        session.draftRevisions[original.id, default: 0] += 1
        session.recoverableDrafts[original.id] = unsaved
        session.unpersistedDraftRevisions[original.id] = session.draftRevisions[original.id]
        var refusedUnsaved = false
        do { _ = try await session.takeBack(id: waiting.id, channelID: original.id) }
        catch { refusedUnsaved = true }
        let stillWaiting = try await session.store.operations()
        checks.append(("Undo Send preserves a newer draft whose save is still pending", refusedUnsaved && session.recoverableDrafts[original.id] == unsaved && stillWaiting.contains { $0.id == waiting.id }))
        session.recoverableDrafts.removeValue(forKey: original.id)
        session.unpersistedDraftRevisions.removeValue(forKey: original.id)
        let receipt = UUID()
        session.pendingFileReceipts[receipt] = original.id
        var refusedReceipt = false
        do { _ = try await session.takeBack(id: waiting.id, channelID: original.id) }
        catch { refusedReceipt = true }
        let afterReceipt = try await session.store.operations()
        checks.append(("Undo Send waits for an in-flight file receipt before restoring its shared draft", refusedReceipt && afterReceipt.contains { $0.id == waiting.id } && !session.acceptingChannels.contains(original.id)))
        session.pendingFileReceipts.removeValue(forKey: receipt)
        return checks
    }
}
