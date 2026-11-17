import AppKit
import NevermoreCore
import RavenProtocol

/// Quick Look and Save As for file results, with an injected canonical
/// read. No download, sheet, account change or network request happens.
@MainActor enum SearchAttachmentSelfChecks {
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
        let hits = ["one", "two"].compactMap { SearchHit(row: .object(["name": .string($0), "channel_id": .string("attachment-search-fixture"), "message_type": .string("File"), "title": .string("fixture.pdf")]), currentUser: session.account.user) }
        let reader = SearchAttachmentReader()
        reader.transport = CollectionAttachmentActions.Transport(message: { _ in
            probe.reads += 1
            return await withCheckedContinuation { probe.pending = $0 }
        }, channelContext: { _ in throw RavenError.invalidResponse }, download: { _ in probe.downloads += 1; throw RavenError.invalidResponse })
        var results: [(String, Bool)] = []

        // The keys reach the search screen's actions.
        let table = SearchResultsTable()
        var previews = 0, saves = 0
        table.onQuickLook = { previews += 1 }; table.onSave = { saves += 1 }
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) { table.keyDown(with: event) }
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: 0, context: nil, characters: "S", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1) { table.keyDown(with: event) }
        results.append(("file results take Space for Quick Look and Shift-Command-S for Save As", previews == 1 && saves == 1))

        var selected = "one"
        func begin(_ hit: SearchHit) async -> Task<Void, Never>? {
            selected = hit.id
            reader.read(hit, session: session, owner: parent, save: false) { selected == hit.id }
            for _ in 0..<100 { if probe.pending != nil { break }; await Task.yield() }
            return nil
        }
        func finish() async {
            let pending = probe.pending; probe.pending = nil
            pending?.resume(returning: .object(["name": .string(selected), "channel_id": .string("attachment-search-fixture"), "message_type": .string("File"), "file": .string("/private/files/fixture.pdf")]))
            for _ in 0..<100 where reader.isReading { await Task.yield() }
        }
        guard hits.count == 2 else { return [("file result fixtures parse", false)] }

        _ = await begin(hits[0])
        selected = "two"
        await finish()
        results.append(("a changed selection stops a suspended canonical read before the download", probe.reads == 1 && probe.downloads == 0 && reader.windows.isEmpty))

        _ = await begin(hits[0])
        session.revokedChannels.insert("attachment-search-fixture")
        await finish()
        results.append(("a revoked conversation cannot finish a private file download", probe.reads == 2 && probe.downloads == 0))
        session.revokedChannels.remove("attachment-search-fixture")

        _ = await begin(hits[0])
        parent.session = nil
        await finish()
        results.append(("an account switch stops a suspended file read", probe.reads == 3 && probe.downloads == 0))
        parent.session = session

        _ = await begin(hits[0])
        reader.cancel()
        await finish()
        results.append(("leaving search cancels file work before the download", probe.reads == 4 && probe.downloads == 0 && !reader.isReading && reader.windows.isEmpty))
        return results
    }
}
