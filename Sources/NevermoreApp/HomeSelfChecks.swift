import AppKit
import NevermoreCore
import RavenProtocol

/// Home in a real window with a disposable demo account: what it shows,
/// what it leaves alone, and the way back and forth to a conversation.
@MainActor enum HomeSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreHomeCheck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "self", siteName: "Fixture", clientID: "demo", displayName: "Fixture")
        let session = try AccountSession(account: account, directory: root, demo: true)
        defer { session.stop() }
        // Home's layout is an app-wide default; put the reader's back after.
        let savedLayout = UserDefaults.standard.data(forKey: HomeLayout.defaultsKey)
        defer {
            if let savedLayout { UserDefaults.standard.set(savedLayout, forKey: HomeLayout.defaultsKey) } else { UserDefaults.standard.removeObject(forKey: HomeLayout.defaultsKey) }
            NotificationCenter.default.post(name: .homeLayoutChanged, object: nil)
        }
        HomePreferences.layout = .standard

        func details(_ owner: String, _ content: String) -> JSONValue {
            .string(#"{"message_id": "m-\#(owner)", "owner": "\#(owner)", "content": "\#(content)", "message_type": "Text"}"#)
        }
        let news = RavenChannel(raw: .object(["name": .string("news"), "channel_name": .string("news"), "workspace": .string("Fixture"),
                                              "last_message_details": details("peer", "Fresh from the channel list"), "last_message_timestamp": .string("2026-11-15 10:00:00")]))
        let quiet = RavenChannel(raw: .object(["name": .string("quiet"), "channel_name": .string("quiet"), "workspace": .string("Fixture"), "muted": .bool(true),
                                               "last_message_details": details("peer", "Muted chatter"), "last_message_timestamp": .string("2026-11-15 11:00:00")]))
        let shelved = RavenChannel(raw: .object(["name": .string("shelved"), "channel_name": .string("shelved"), "workspace": .string("Fixture"), "is_archived": .bool(true)]))
        let direct = RavenChannel(raw: .object(["name": .string("dm-peer"), "channel_name": .string("Peer"), "is_direct_message": .bool(true), "peer_user_id": .string("peer"),
                                                "last_message_timestamp": .string("2026-11-15 09:00:00")]))
        session.channels = [news, quiet, shelved, direct]
        session.userNames = ["peer": "Pat Peer", "self": "Fixture"]
        session.unread = .array([
            .object(["name": .string("news"), "unread_count": .number(4)]),
            .object(["name": .string("quiet"), "unread_count": .number(12)]),
            .object(["name": .string("shelved"), "unread_count": .number(2)])
        ])
        let now = Date()
        try await session.store.cacheMessages([
            RavenMessage(raw: .object(["name": .string("own-1"), "channel_id": .string("dm-peer"), "owner": .string("self"), "creation": .string(session.serverTimestamp(now.addingTimeInterval(-3600))), "text": .string("<p>Mine</p>"), "message_type": .string("Text")])),
            RavenMessage(raw: .object(["name": .string("own-2"), "channel_id": .string("dm-peer"), "owner": .string("self"), "creation": .string(session.serverTimestamp(now.addingTimeInterval(-7200))), "text": .string("<p>Also mine</p>"), "message_type": .string("Text")])),
            RavenMessage(raw: .object(["name": .string("theirs"), "channel_id": .string("dm-peer"), "owner": .string("peer"), "creation": .string(session.serverTimestamp(now.addingTimeInterval(-1800))), "text": .string("<p>Not mine</p>"), "message_type": .string("Text")]))
        ])

        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.window?.setContentSize(NSSize(width: 1300, height: 860))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.home.reloadNow()
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        var results: [(String, Bool)] = []
        func cards() -> [HomeCard] { InteractionSelfChecks.descendants(controller.home, of: HomeCard.self) }
        func card(_ module: HomeModule) -> HomeCard? { cards().first { $0.accessibilityLabel() == module.title } }
        func rows(_ module: HomeModule) -> [String] { card(module).map { InteractionSelfChecks.descendants($0, of: HomeRow.self).compactMap { $0.accessibilityLabel() } } ?? [] }
        func labels(_ view: NSView?) -> [String] { view.map { InteractionSelfChecks.descendants($0, of: NSTextField.self).map(\.stringValue) } ?? [] }

        results.append(("a window without a conversation shows Home, not the empty state or the composer",
                         !controller.home.isHidden && controller.emptyConversation.isHidden && controller.composerGlass.isHidden && controller.window?.title == "Home"))
        results.append(("Home leads the sidebar and is selected while it shows",
                         controller.sidebarItems.first?.isHome == true && controller.sidebar.selectedRow == 0))
        results.append(("Home builds every module by default", HomeModule.allCases.allSatisfy { card($0) != nil }))
        let unread = rows(.unread)
        results.append(("Unread previews the newest message from the channel list",
                         unread.count == 1 && unread[0].contains("news") && unread[0].contains("4 unread") && unread[0].contains("Fresh from the channel list")))
        results.append(("muted conversations are one quiet line and archived ones are left out",
                         labels(card(.unread)).contains { $0.contains("12 new in 1 muted conversation") } && !unread.contains { $0.contains("shelved") || $0.contains("quiet") }))
        results.append(("showing Home marks nothing read", session.lastSeen.isEmpty && session.interests[controller.windowID] == nil))
        // The transcript under Home set the I-beam over its buttons, and
        // selectable notes showed it over the cards.
        results.append(("Home leaves no I-beam from the transcript beneath it",
                        controller.transcript.isHiddenOrHasHiddenAncestor && controller.transcriptScroll.documentCursor == nil))
        results.append(("Home's text is not selectable", !InteractionSelfChecks.descendants(controller.home, of: NSTextField.self).contains(where: \.isSelectable)))

        // The column fills the pane up to its maximum width without taking
        // part in sizing the pane. As a wish on the pane's width it held the
        // sidebar at its maximum and made showing the sidebar jump.
        let split = controller.splitController.splitView
        func layOut(width: CGFloat) { controller.window?.setContentSize(NSSize(width: width, height: 860)); controller.window?.contentView?.layoutSubtreeIfNeeded() }
        func divider() -> CGFloat { split.arrangedSubviews.first?.frame.maxX ?? .nan }
        func column() -> (document: CGFloat, column: CGFloat) {
            let scroll = InteractionSelfChecks.descendants(controller.home, of: NSScrollView.self).first
            return (scroll?.documentView?.frame.width ?? .nan, scroll?.documentView?.subviews.first?.frame.width ?? .nan)
        }
        let sidebarWidth = divider()
        layOut(width: 2000)
        let wide = (divider: divider(), column: column())
        layOut(width: 1000)
        let narrow = column()
        layOut(width: 1300)
        let fills = abs(wide.divider - sidebarWidth) <= 1 && abs(wide.column.column - HomeView.maximumContentWidth) <= 1 && abs(narrow.column - (narrow.document - 48)) <= 1
        if !fills { print("DIAGNOSTIC Home column: sidebar \(sidebarWidth) -> \(wide.divider) in a wide window; column \(wide.column), narrow \(narrow)") }
        results.append(("Home's column fills the pane up to its maximum width and leaves the sidebar where it was", fills))
        controller.splitController.toggleSidebar(nil)
        for _ in 0..<150 where split.arrangedSubviews.first?.isHidden == false { try await Task.sleep(for: .milliseconds(10)) }
        controller.splitController.toggleSidebar(nil)
        // AppKit lays out the start of the slide before animating: the
        // sidebar at no width. A competing wish put it at its full width.
        let start = split.arrangedSubviews.first?.frame.width ?? .nan
        for _ in 0..<150 where abs(divider() - sidebarWidth) > 1 { try await Task.sleep(for: .milliseconds(10)) }
        if !(start < 1) { print("DIAGNOSTIC sidebar slide: starts at \(start) pt, ends at \(divider()) of \(sidebarWidth)") }
        results.append(("showing the sidebar over Home slides it in from the edge", start < 1 && abs(divider() - sidebarWidth) <= 1))

        // The demo feed counts the reader's own cached messages, never others'.
        session.home.refresh(force: true)
        for _ in 0..<250 where session.home.snapshot.sent.value == nil { try await Task.sleep(for: .milliseconds(20)) }
        controller.home.reloadNow()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let week = labels(card(.week))
        results.append(("Your Week counts only the reader's messages and says who can see it",
                         session.home.snapshot.sent.value?.count == 2 && week.contains("2") && week.contains("Only you see this")))
        let bars = InteractionSelfChecks.descendants(card(.week) ?? NSView(), of: HomeBars.self).first
        let tips = bars.map { bars in bars.toolTipTexts.keys.sorted().map { bars.view(bars, stringForToolTip: $0, point: .zero, userData: nil) } } ?? []
        results.append(("each day in Your Week has a tooltip with its count", tips.count == 7 && tips.allSatisfy { $0.contains("message") }))
        results.append(("an empty Later card never says nothing is saved when a part failed or still loads",
                        HomeView.emptyLaterNote(reminders: .loaded([]), saved: .failed("offline")) == nil
                            && HomeView.emptyLaterNote(reminders: .failed("offline"), saved: .loaded([])) == nil
                            && HomeView.emptyLaterNote(reminders: .loaded([]), saved: .loading) == "Loading…"
                            && HomeView.emptyLaterNote(reminders: .loaded([]), saved: .loaded([]))?.hasPrefix("Nothing saved") == true))
        results.append(("You Talk with Most finds the person the reader writes to",
                         InteractionSelfChecks.descendants(card(.people) ?? NSView(), of: HomePerson.self).first?.accessibilityLabel()?.hasPrefix("Pat Peer") == true))

        // Into a conversation and back.
        controller.select(news)
        results.append(("opening a conversation hides Home", controller.home.isHidden && !controller.composerGlass.isHidden && controller.channel?.id == "news"))
        results.append(("a conversation shows its transcript with the I-beam", !controller.transcript.isHidden && controller.transcriptScroll.documentCursor === NSCursor.iBeam))
        controller.showHome()
        let storage = session.sharedTextStorage["news"]
        results.append(("Go ▸ Home leaves the conversation and detaches its draft",
                         controller.channel == nil && !controller.home.isHidden && controller.sidebar.selectedRow == 0
                            && session.interests[controller.windowID] == nil && storage != nil && controller.composer.textStorage !== storage))
        controller.goBack()
        results.append(("Back from Home returns to the conversation", controller.channel?.id == "news"))
        controller.showHome()

        // A hidden module is not built; the order follows the preference.
        var layout = HomeLayout.standard
        layout.setVisible(.week, false)
        layout.move(.files, to: 0)
        HomePreferences.layout = layout
        controller.home.reloadNow()
        let titles = cards().compactMap { $0.accessibilityLabel() }
        results.append(("Customize Home hides and reorders modules", card(.week) == nil && titles.first == HomeModule.files.title))
        return results
    }
}
