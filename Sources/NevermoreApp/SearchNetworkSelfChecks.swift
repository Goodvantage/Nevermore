import AppKit
import NevermoreCore
import RavenProtocol

/// Exercises scoped search against the credential-free loopback fixture:
/// cached hits show while the thread-list RPC is held, and cached replies
/// join when the held list names their thread. The fixture holds
/// `get_all_threads`/`get_other_threads` for two seconds, so the cached
/// elapsed time separates showing this Mac's matches from waiting for the
/// thread list.
@MainActor enum SearchNetworkSelfChecks {
    private static let settleBudget: TimeInterval = 5.0
    private static let samples = 3

    static func run(app: AppDelegate, origin input: String) async throws -> [(String, Bool)] {
        let origin = try SiteOrigin.normalize(input, allowLocalHTTP: true)
        guard origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil else { throw AppError.message("Search checks require the local fixture runner.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreSearchNetworkCheck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(origin: origin, user: "search-fixture-user", siteName: "Local fixture", clientID: "local-fixture")
        let session = try AccountSession(account: account, directory: root)
        let channel = RavenChannel(raw: .object(["name": .string("search-fixture-channel"), "channel_name": .string("Search fixture"), "workspace": .string("Fixture"), "is_archived": .bool(false), "is_thread": .bool(false)]))
        session.channels = [channel]
        session.userNames = ["peer@example.invalid": "Pat Peer", "search-fixture-user": "Search Fixture"]
        session.revokedChannels = ["search-fixture-revoked"]
        session.deletedIDs = ["search-fixture-deleted"]
        let now = Date()
        func message(_ id: String, _ channelID: String, _ text: String, type: String = "Text", file: String? = nil) -> RavenMessage {
            var fields: [String: JSONValue] = [
                "name": .string(id), "channel_id": .string(channelID), "owner": .string("peer@example.invalid"),
                "creation": .string(session.serverTimestamp(now.addingTimeInterval(-600))), "text": .string(text), "message_type": .string(type)]
            if let file { fields["file"] = .string(file) }
            return RavenMessage(raw: .object(fields))
        }
        try await session.store.cacheMessages([
            message("search-fixture-cached", channel.id, "<p>Launch cached row</p>"),
            message("search-fixture-known-reply", "search-fixture-known-thread", "<p>Launch known thread reply</p>"),
            message("search-fixture-other-reply", "search-fixture-other-thread", "<p>Launch reply the thread list names</p>"),
            message("search-fixture-file", channel.id, "<p>Launch file row</p>", type: "File", file: "/private/files/launch.pdf"),
            message("search-fixture-revoked", "search-fixture-revoked", "<p>Launch revoked row</p>"),
            message("search-fixture-deleted", channel.id, "<p>Launch deleted row</p>"),
            message("search-fixture-orphan", "search-fixture-orphan", "<p>Launch orphan row</p>"),
        ])
        let controller = ConversationWindow(app: app, session: session)
        app.windows.append(controller)
        controller.showWindow(nil)
        controller.window?.setContentSize(NSSize(width: 1300, height: 860))
        let view = controller.searchView
        defer { controller.close(); session.stop() }

        var results: [(String, Bool)] = []
        var cachedElapsed: [TimeInterval] = []
        var releaseElapsed: [TimeInterval] = []
        var unknownAbsentAtFirstCache = true
        var heldAtFirstCache = true
        var reevaluated = true
        var selectionStable = true
        var selectionKeyBefore: String?
        var filtersKept = true
        var deduped = true

        func waitUntil(_ budget: TimeInterval, _ condition: () -> Bool) async -> Bool {
            let deadline = Date().addingTimeInterval(budget)
            while Date() < deadline {
                if condition() { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }
        func messageHits() -> [SearchHit] { view.feed.results.messages.value ?? [] }
        func hasHit(_ id: String) -> Bool { messageHits().contains { $0.id == id } }
        func fixtureStats() async throws -> JSONValue { try await session.client.rpc("nevermore_fixture.search_stats") }
        func requestCount(_ stats: JSONValue, _ key: String) -> Int {
            if case .number(let number) = stats[key] { return Int(number) }
            return 0
        }
        func selectedKey() -> String? {
            view.table.selectedRow >= 0 && view.items.indices.contains(view.table.selectedRow) ? view.items[view.table.selectedRow].key : nil
        }

        for sample in 1...Self.samples {
            // A fresh feed has a cold thread cache, and the known mapping is
            // the only one the first cached pass may use.
            session.threadParents = ["search-fixture-known-thread": channel.id,
                                     "search-fixture-other-thread": "previous-parent"]
            view.reset(session: session)
            let before = try await fixtureStats()
            _ = try await session.client.rpc("nevermore_fixture.hold_threads")
            let criteria = SearchCriteria(query: "launch", scope: .conversation(channel.id))
            let start = Date()
            view.begin(criteria, origin: nil, immediately: true)
            let appeared = await waitUntil(Self.settleBudget) { hasHit("search-fixture-cached") }
            let elapsed = Date().timeIntervalSince(start)
            cachedElapsed.append(elapsed)
            if appeared, hasHit("search-fixture-other-reply") { unknownAbsentAtFirstCache = false }
            if sample == 1, appeared, let row = view.items.firstIndex(where: { if case .hit = $0 { return true }; return false }) {
                view.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                selectionKeyBefore = selectedKey()
            }
            let holdDeadline = Date().addingTimeInterval(Self.settleBudget)
            var held = try await fixtureStats()
            while requestCount(held, "held_threads") - requestCount(before, "held_threads") < 2 && Date() < holdDeadline {
                try await Task.sleep(for: .milliseconds(10))
                held = try await fixtureStats()
            }
            heldAtFirstCache = heldAtFirstCache && appeared && requestCount(held, "held_threads") >= requestCount(before, "held_threads") + 2
                && requestCount(held, "hold_timeouts") == requestCount(before, "hold_timeouts")
            let released = Date()
            _ = try await session.client.rpc("nevermore_fixture.release_threads")
            let arrived = await waitUntil(Self.settleBudget) { hasHit("search-fixture-other-reply") }
            releaseElapsed.append(Date().timeIntervalSince(released))
            reevaluated = reevaluated && arrived
            let serverArrived = await waitUntil(Self.settleBudget) { hasHit("search-fixture-server") }
            let selected = selectedKey()
            if sample == 1 { selectionStable = selectionKeyBefore != nil && selected == selectionKeyBefore }
            let ids = messageHits().map(\.id)
            deduped = deduped && serverArrived && ids.filter { $0 == "search-fixture-cached" }.count == 1 && ids.contains("search-fixture-server") && ids.contains("search-fixture-known-reply")
            filtersKept = filtersKept && !ids.contains("search-fixture-revoked") && !ids.contains("search-fixture-deleted") && !ids.contains("search-fixture-orphan")
            let after = try await fixtureStats()
            print("SEARCH-FIXTURE sample \(sample) ids: \(ids); server error: \(view.feed.results.indexErrors[.messages] ?? "none"); requests thread +\(requestCount(after, "thread_requests") - requestCount(before, "thread_requests")) index +\(requestCount(after, "index_requests") - requestCount(before, "index_requests"))")
        }
        let stats = try await session.client.rpc("nevermore_fixture.search_stats")
        let sampleText = cachedElapsed.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        let releaseText = releaseElapsed.map { String(format: "%.3f", $0) }.joined(separator: ", ")
        func intText(_ value: JSONValue) -> String? { if case .number(let number) = value { return String(Int(number)) }; return nil }
        let requests = intText(stats["thread_requests"]) ?? "?"
        let indexRequests = intText(stats["index_requests"]) ?? "?"
        print("SEARCH-FIXTURE methodology: fixture holds get_all_threads/get_other_threads 2.0s; \(Self.samples) fresh SearchFeed samples; cached elapsed measured from view.begin to the first known cached hit; release elapsed measured from release_threads to the newly mapped thread reply; revoked, deleted and unknown rows filtered; server and cached matches merged by id.")
        print("SEARCH-FIXTURE cached elapsed seconds: \(sampleText); release-to-reply seconds: \(releaseText); thread requests: \(requests); index requests: \(indexRequests)")
        results.append(("cached hits appear while both thread-list requests are held (samples \(sampleText)s)", heldAtFirstCache))
        results.append(("the held list's new thread parent joins cached replies after release (release samples \(releaseText)s)", reevaluated && unknownAbsentAtFirstCache))
        results.append(("a selected cached hit stays selected when the thread reply arrives", selectionStable))
        results.append(("revoked, deleted and unknown cached rows stay out", filtersKept))
        results.append(("server and cached matches merge without duplicates", deduped))
        func visibleLabel(containing text: String) -> Bool {
            InteractionSelfChecks.descendants(view, of: NSTextField.self)
                .contains { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue.contains(text) }
        }
        view.reset(session: session)
        let baseline = try await fixtureStats()
        _ = try await session.client.rpc("nevermore_fixture.hold_threads")
        controller.showSearch(SearchCriteria(query: "emptyfixture", scope: .conversation(channel.id)), immediately: true)
        let deadline = Date().addingTimeInterval(Self.settleBudget)
        while Date() < deadline {
            let current = try await fixtureStats()
            if requestCount(current, "held_threads") >= requestCount(baseline, "held_threads") + 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let searching = visibleLabel(containing: "Searching…")
            && !visibleLabel(containing: "No messages match") && view.items.isEmpty
        _ = try await session.client.rpc("nevermore_fixture.release_threads")
        let empty = await waitUntil(Self.settleBudget) { !view.feed.isRunning && visibleLabel(containing: "No messages match") }
        results.append(("an empty local search stays in progress until an empty server answer arrives", searching && empty))

        view.reset(session: session)
        controller.showSearch(SearchCriteria(query: "delivery", scope: .conversation(channel.id), kind: .text), immediately: true)
        let settled = await waitUntil(Self.settleBudget) { !view.feed.isRunning }
        let messagesSucceeded = hasHit("search-fixture-server") && !visibleLabel(containing: "The server search failed")
        view.select(tab: .files)
        let filesFailed = await waitUntil(Self.settleBudget) { !view.feed.isRunning && visibleLabel(containing: "Search is not available") }
        let messagesIntact = hasHit("search-fixture-server") && view.feed.results.indexErrors[.messages] == nil
        view.select(tab: .messages)
        // Returning from Files changes the kind to All and starts a new search.
        let messagesVisible = await waitUntil(Self.settleBudget) {
            !view.feed.isRunning && hasHit("search-fixture-server") && !visibleLabel(containing: "The server search failed")
        }
        results.append(("a Files search failure stays on Files and leaves successful Messages alone", settled && messagesSucceeded && filesFailed && messagesIntact && messagesVisible))
        return results
    }
}
