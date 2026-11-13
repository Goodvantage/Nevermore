import AppKit
import NevermoreCore
import RavenProtocol

/// Hidden native fixtures use an injected canonical read. No download, sheet,
/// account mutation or network request is performed by these checks.
@MainActor enum CollectionAttachmentSelfChecks {
    private final class Probe {
        var reads = 0
        var downloads = 0
        var pending: CheckedContinuation<JSONValue, Never>?
    }
    static func run(owner: ConversationWindow) async throws -> [(String, Bool)] {
        guard let session = owner.session, session.demo else { throw AppError.message("Search attachment checks require demo mode.") }
        let parent = ConversationWindow(app: owner.app, session: session)
        defer { parent.close() }
        let probe = Probe()
        let rows: [JSONValue] = ["one", "two"].map { .object(["name": .string($0), "channel_id": .string("attachment-search-fixture"), "message_type": .string("File")]) }
        let transport = CollectionAttachmentActions.Transport(message: { _ in
            probe.reads += 1
            return await withCheckedContinuation { probe.pending = $0 }
        }, channelContext: { _ in throw RavenError.invalidResponse }, download: { _ in probe.downloads += 1; throw RavenError.invalidResponse })
        let collection = CollectionWindow(owner: parent, title: "Search attachment checks", records: rows, kind: .search, source: CollectionSource(method: "raven.api.search.sqlite_search"), attachmentTransport: transport)
        defer { collection.close() }
        collection.table.reloadData(); collection.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        collection.updateChrome()
        var results: [(String, Bool)] = []
        results.append(("file-search results expose labeled Quick Look and Save Attachment controls", collection.previewAttachmentButton.isEnabled && collection.saveAttachmentButton.isEnabled && !collection.previewAttachmentButton.isHidden && collection.previewAttachmentButton.accessibilityLabel()?.isEmpty == false))
        var previews = 0, saves = 0
        let preview = collection.table.onPreviewAttachment, save = collection.table.onSaveAttachment
        collection.table.onPreviewAttachment = { previews += 1 }; collection.table.onSaveAttachment = { saves += 1 }
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: collection.window!.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) { collection.table.keyDown(with: event) }
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: collection.window!.windowNumber, context: nil, characters: "S", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1) { collection.table.keyDown(with: event) }
        results.append(("file-search keyboard commands dispatch preview and Save As", previews == 1 && saves == 1))
        collection.table.onPreviewAttachment = preview; collection.table.onSaveAttachment = save
        func begin() async -> Task<Void, Never>? {
            collection.previewSearchAttachment()
            let task = collection.attachmentTask
            for _ in 0..<100 { if probe.pending != nil { break }; await Task.yield() }
            return task
        }
        func finish(_ task: Task<Void, Never>?) async {
            let pending = probe.pending; probe.pending = nil
            pending?.resume(returning: .object(["name": .string("one"), "channel_id": .string("attachment-search-fixture"), "message_type": .string("File"), "file": .string("/private/files/fixture.pdf")]))
            await task?.value
        }
        let changedSelection = await begin()
        collection.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        await finish(changedSelection)
        results.append(("changed file-search selection cancels suspended canonical reads before download", probe.reads == 1 && probe.downloads == 0 && collection.attachmentTask == nil))
        collection.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let revoked = await begin()
        session.revokedChannels.insert("attachment-search-fixture"); collection.restrictRevoked()
        await finish(revoked)
        results.append(("revoked file-search projections cannot finish a private attachment download", probe.reads == 2 && probe.downloads == 0 && !collection.canReadSearchAttachment))
        session.revokedChannels.remove("attachment-search-fixture")
        collection.pager.records = rows; collection.applyFilter(); collection.table.reloadData(); collection.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let switched = await begin()
        parent.session = nil; collection.validateSearchAttachment()
        await finish(switched)
        results.append(("account switches invalidate suspended file-search reads", probe.reads == 3 && probe.downloads == 0 && collection.attachmentTask == nil))
        parent.session = session
        let closed = await begin()
        collection.close(); await finish(closed)
        results.append(("closing file search cancels attachment work before download", probe.reads == 4 && probe.downloads == 0 && collection.attachmentTask == nil && collection.searchAttachmentWindows.isEmpty))
        return results
    }
}
