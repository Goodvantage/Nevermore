import AppKit
import NevermoreCore
import RavenProtocol

/// The search results screen in a real window with a disposable demo
/// account: searching as you type, grouping, threads, the preview, and
/// the way to a result and back. The demo has no server, so these are
/// the matches saved on this Mac.
@MainActor enum SearchSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreSearchCheck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "self", siteName: "Fixture", clientID: "demo", displayName: "Fixture")
        let session = try AccountSession(account: account, directory: root, demo: true)
        defer { session.stop(); SavedSearchStore.clear(account.id) }

        let news = RavenChannel(raw: .object(["name": .string("news"), "channel_name": .string("news"), "workspace": .string("Fixture")]))
        let design = RavenChannel(raw: .object(["name": .string("design"), "channel_name": .string("design"), "workspace": .string("Fixture")]))
        session.channels = [news, design]
        session.userNames = ["peer": "Pat Peer", "self": "Fixture"]
        session.threadParents["thread-1"] = "news"
        let now = Date()
        func message(_ id: String, _ channel: String, _ text: String, ago: TimeInterval, owner: String = "peer") -> RavenMessage {
            RavenMessage(raw: .object(["name": .string(id), "channel_id": .string(channel), "owner": .string(owner), "creation": .string(session.serverTimestamp(now.addingTimeInterval(-ago))), "text": .string("<p>\(text)</p>"), "message_type": .string("Text")]))
        }
        try await session.store.cacheMessages([
            message("n1", "news", "The launch moves to Friday", ago: 600),
            message("n2", "news", "Launch notes are in the doc", ago: 1200),
            message("r1", "thread-1", "Launch reply inside the thread", ago: 900),
            message("d1", "design", "Launch banner draft", ago: 1800),
            message("old", "news", "Launch retrospective from last quarter", ago: 40 * 24 * 3600),
            message("s1", "news", "<span data-spoiler=\"\">launch secret</span>", ago: 300)
        ])

        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.window?.setContentSize(NSSize(width: 1300, height: 860))
        controller.select(news)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let view = controller.searchView
        var results: [(String, Bool)] = []

        func settle() async throws {
            for _ in 0..<150 {
                if !view.feed.isRunning, view.feed.results.messages.value != nil { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            // Name a timeout, so the checks after it are not blamed.
            if view.feed.isRunning || view.feed.results.messages.value == nil { results.append(("search results settle within three seconds", false)) }
            controller.window?.contentView?.layoutSubtreeIfNeeded()
        }
        func hits() -> [SearchHit] { view.items.compactMap { if case .hit(let hit) = $0 { return hit }; return nil } }
        func headings() -> [String] { view.items.compactMap { if case .conversation(let id, _) = $0 { return id }; return nil } }

        // One letter is not a search; two are, after a pause.
        controller.search.stringValue = "l"
        controller.searchFieldChanged()
        results.append(("one letter in the search field leaves the conversation open", !controller.isSearching && controller.channel?.id == "news"))

        // The toolbar's own glass scales the stock search item's contents
        // on every click, so the field brings a glass capsule of its own.
        let searchItem = controller.window?.toolbar?.items.first { $0.itemIdentifier == .nevermoreSearch }
        results.append(("the toolbar search field sits in its own glass, outside the toolbar's pressable one",
                        searchItem.map { !($0 is NSSearchToolbarItem) && !$0.isBordered && ($0.view as? NSGlassEffectView)?.contentView === controller.search } ?? false))
        controller.findMessages(nil)
        let fieldEditor = controller.search.currentEditor() as? NSTextView
        results.append(("⌥⌘F puts the cursor in the toolbar search field", fieldEditor != nil))
        if let fieldEditor { _ = controller.control(controller.search, textView: fieldEditor, doCommandBy: #selector(NSResponder.cancelOperation(_:))) }
        results.append(("Esc outside search clears the toolbar field and leaves it",
                        fieldEditor != nil && controller.search.stringValue.isEmpty && controller.search.currentEditor() == nil && !controller.isSearching && controller.channel?.id == "news"))
        controller.window?.toolbar?.isVisible = false
        controller.findMessages(nil)
        results.append(("⌥⌘F shows a hidden toolbar and puts the cursor in its search field",
                        controller.window?.toolbar?.isVisible == true && controller.search.currentEditor() != nil && !controller.isSearching))
        controller.window?.makeFirstResponder(nil)

        controller.search.stringValue = "launch"
        controller.searchFieldChanged()
        try await settle()
        results.append(("typing a query shows the results screen in place of the conversation",
                         controller.isSearching && !view.isHidden && controller.home.isHidden && controller.composerGlass.isHidden && controller.channel == nil && controller.window?.title == "Search"))
        controller.refreshSidebar()
        results.append(("no sidebar row is selected while search shows", controller.sidebar.selectedRow == -1))
        results.append(("a search begun in a conversation is scoped to it", view.criteria.scope == .conversation("news") && view.criteria.query == "launch"))
        results.append(("searching marks nothing read", session.lastSeen.isEmpty && session.interests[controller.windowID] == nil))
        // The transcript under the results set the I-beam on every move.
        results.append(("the results screen leaves no I-beam from the transcript beneath it",
                        controller.transcript.isHiddenOrHasHiddenAncestor && controller.transcriptScroll.documentCursor == nil))
        let first = hits()
        results.append(("results are grouped under their conversation", headings() == ["news"] && !first.isEmpty))
        results.append(("matched words are highlighted", first.allSatisfy { !$0.snippet.highlights.isEmpty || $0.snippet.text.contains("[Spoiler]") }))
        results.append(("thread replies in the conversation are included by default", first.contains { $0.id == "r1" && $0.isThreadReply && $0.conversationID == "news" }))
        results.append(("spoiler text stays hidden in results", !first.contains { $0.snippet.text.contains("secret") }))

        var criteria = view.criteria
        criteria.includeThreads = false
        controller.showSearch(criteria, immediately: true)
        try await settle()
        results.append(("Include Threads off leaves thread replies out", !hits().contains { $0.id == "r1" } && hits().contains { $0.id == "n1" }))

        criteria.scope = .account
        criteria.includeThreads = true
        controller.showSearch(criteria, immediately: true)
        try await settle()
        results.append(("Everywhere finds other conversations", Set(headings()) == ["news", "design"]))

        criteria.date = .today
        controller.showSearch(criteria, immediately: true)
        try await settle()
        results.append(("the date filter leaves out older messages", !hits().contains { $0.id == "old" } && hits().contains { $0.id == "n1" }))
        criteria.date = nil
        controller.showSearch(criteria, immediately: true)
        try await settle()
        results.append(("without a date the older message is found", hits().contains { $0.id == "old" }))

        // Return while the same search still loads must not strand it.
        var retyped = criteria
        retyped.query = "launch notes"
        controller.showSearch(retyped, immediately: true)
        view.searchNow("launch notes")
        try await settle()
        results.append(("Return while a search loads still shows its results", view.feed.results.messages.value?.contains { $0.id == "n2" } == true))
        controller.showSearch(criteria, immediately: true)
        try await settle()

        // The preview, and the way to a result and back.
        guard let row = view.items.firstIndex(where: { if case .hit(let hit) = $0 { return hit.id == "n1" }; return false }) else {
            results.append(("the fixture result is listed", false)); return results
        }
        view.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        for _ in 0..<50 where view.side.showsPreviewOf != "n1" { try await Task.sleep(for: .milliseconds(20)) }
        results.append(("selecting a result previews it beside the list", view.showsSideColumn && view.side.showsPreviewOf == "n1"))
        results.append(("previewing marks nothing read", session.lastSeen.isEmpty))
        let cell = view.tableView(view.table, viewFor: nil, row: row)
        results.append(("VoiceOver reads a result as one sentence with its matches", cell?.accessibilityLabel()?.contains("Pat Peer") == true && cell?.accessibilityLabel()?.contains("matches launch") == true))
        view.openSelected()
        results.append(("Return opens the result in its conversation and keeps the query", controller.channel?.id == "news" && !controller.isSearching && controller.search.stringValue == "launch" && view.isHidden))
        // Access that changes while the results are hidden applies when they return.
        session.revokedChannels.insert("design")
        session.deletedIDs.insert("thread-1")
        session.notify()
        try await Task.sleep(for: .milliseconds(50))
        controller.goBack()
        results.append(("Back returns to the same results", controller.isSearching && view.criteria == criteria && hits().contains { $0.id == "n1" } && controller.channel == nil))
        results.append(("results from a conversation revoked while search was hidden stay hidden", !hits().contains { $0.channelID == "design" }))
        results.append(("replies in a thread deleted while search was hidden stay hidden", !hits().contains { $0.id == "r1" }))
        session.revokedChannels.remove("design")
        session.deletedIDs.remove("thread-1")
        controller.goForward()
        results.append(("Forward goes to the result again", controller.channel?.id == "news" && !controller.isSearching))
        controller.goBack()

        // A selected result that goes away leaves nothing selected, not its neighbour.
        func isHit(_ row: Int) -> Bool { if view.items.indices.contains(row), case .hit = view.items[row] { return true }; return false }
        if let row = view.items.indices.first(where: { isHit($0) && isHit($0 + 1) }), case .hit(let gone) = view.items[row] {
            view.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            session.deletedIDs.insert(gone.id)
            session.notify()
            try await Task.sleep(for: .milliseconds(50))
            results.append(("a selected result that goes away leaves no other result selected", view.table.selectedRow == -1 && view.side.showsPreviewOf == nil))
            session.deletedIDs.remove(gone.id)
        } else {
            results.append(("a selected result that goes away leaves no other result selected", false))
        }

        // Saved searches live in the side column while nothing is selected.
        try SavedSearchStore.save([SavedSearch(title: "Launch", criteria: criteria)], account: account.id)
        view.table.deselectAll(nil)
        view.reloadSide()
        let savedRows = InteractionSelfChecks.descendants(view.side, of: HomeRow.self).compactMap { $0.accessibilityLabel() }
        results.append(("saved searches are listed while no result is selected", view.side.showsPreviewOf == nil && savedRows.contains("Saved search Launch")))

        // The Conversations and People tabs match names locally.
        controller.search.stringValue = "des"
        view.queryChanged("des", immediately: true)
        view.select(tab: .conversations)
        results.append(("the Conversations tab matches names", view.items.contains { if case .channel(let channel) = $0 { return channel.id == "design" }; return false }))
        session.revokedChannels.insert("design")
        view.reload()
        let conversationsTab = SearchTab.allCases.firstIndex(of: .conversations) ?? 0
        results.append(("the Conversations tab counts only the conversations it lists", view.items.isEmpty && view.tabs.label(forSegment: conversationsTab) == "Conversations 0"))
        session.revokedChannels.remove("design")
        view.select(tab: .messages)

        // A link whose message was deleted goes, as messages and files do.
        var linked = SearchFeed.Results()
        linked.links = .loaded([.object(["message_id": .string("gone-link"), "channel_id": .string("news"), "url": .string("https://example.invalid/")])])
        session.deletedIDs.insert("gone-link")
        results.append(("a link whose message was deleted leaves the results", SearchFeed.restricted(linked, session: session).links.value?.isEmpty == true))
        session.deletedIDs.remove("gone-link")

        // Esc leaves search for where it began.
        controller.leaveSearch()
        results.append(("Esc leaves search for the conversation it began in", !controller.isSearching && controller.channel?.id == "news" && controller.search.stringValue.isEmpty))
        controller.showSearch(SearchCriteria(query: "launch"), immediately: true)
        controller.showHome()
        results.append(("Go ▸ Home leaves search for Home", !controller.isSearching && !controller.home.isHidden && view.isHidden))

        // A refresh that keeps the selected file keeps its download going.
        try await session.store.cacheMessages([RavenMessage(raw: .object(["name": .string("f1"), "channel_id": .string("news"), "owner": .string("peer"), "creation": .string(session.serverTimestamp(now)), "text": .string("<p>Attached floorplan</p>"), "message_type": .string("File"), "file": .string("/private/files/floorplan.pdf")]))])
        controller.showSearch(SearchCriteria(query: "floorplan"), immediately: true)
        view.select(tab: .files)
        try await settle()
        guard let fileRow = view.items.firstIndex(where: { if case .hit(let hit) = $0 { return hit.id == "f1" }; return false }) else {
            results.append(("the fixture file is listed", false)); return results
        }
        view.table.selectRowIndexes(IndexSet(integer: fileRow), byExtendingSelection: false)
        view.attachments.transport = CollectionAttachmentActions.Transport(message: { _ in try await Task.sleep(for: .seconds(10)); throw CancellationError() },
                                                                           channelContext: { _ in throw CancellationError() }, download: { _ in throw CancellationError() })
        view.quickLookSelected()
        let reading = view.attachments.isReading
        view.reload()
        results.append(("a refresh that keeps the selected file keeps its download going", reading && view.attachments.isReading))
        view.attachments.cancel()
        return results
    }
}
