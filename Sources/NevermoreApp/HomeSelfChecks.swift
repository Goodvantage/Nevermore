import AppKit
import SQLite3
import NevermoreCore
import RavenProtocol

/// Home in a real window with a disposable demo account: what it shows,
/// what it leaves alone, and the way back and forth to a conversation.
@MainActor enum HomeSelfChecks {
    @MainActor private static func draftRow(in controller: ConversationWindow) -> HomeRow? {
        let later = InteractionSelfChecks.descendants(controller.home, of: HomeCard.self).first { $0.accessibilityLabel() == HomeModule.later.title }
        return InteractionSelfChecks.descendants(later ?? NSView(), of: HomeRow.self).first { ($0.accessibilityLabel() ?? "").contains("draft") }
    }

    @MainActor private static func pressDraftRow(in controller: ConversationWindow) {
        _ = draftRow(in: controller)?.accessibilityPerformPress()
    }

    @MainActor private static func sheetButtons(_ sheet: NSWindow?) -> [NSButton] {
        sheet?.contentView.map { InteractionSelfChecks.descendants($0, of: NSButton.self) } ?? []
    }

    @MainActor private static func waitForSheet(_ window: NSWindow?) async -> NSWindow? {
        for _ in 0..<100 {
            if let sheet = window?.attachedSheet { return sheet }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    @MainActor private static func waitForSheetToClose(_ window: NSWindow?) async {
        for _ in 0..<100 where window?.attachedSheet != nil { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Stores the two synthetic drafts and shows Home with the Later row
    /// built from them. The ghost draft belongs to no channel and must stay
    /// out of the destinations.
    @MainActor private static func seedDrafts(_ session: AccountSession, attachment: StagedAttachment, controller: ConversationWindow) async throws {
        try await session.store.saveDraft(Draft(channelID: "news", html: "<p>First draft body</p>"))
        try await session.store.saveDraft(Draft(channelID: "quiet", html: "<p>Second draft body</p>", attachments: [attachment]))
        for _ in 0..<250 {
            session.home.refreshLocal()
            if session.home.snapshot.drafts.contains(where: { $0.channelID == "news" }),
               session.home.snapshot.drafts.contains(where: { $0.channelID == "quiet" }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.showHome()
        for _ in 0..<100 where controller.home.isHidden { try? await Task.sleep(for: .milliseconds(10)) }
        controller.home.reloadNow()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private static func markAllRead(app: AppDelegate) async throws -> [(String, Bool)] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreHomeRead-\(UUID())")
        let origin = URL(string: "http://127.0.0.1:12345")!
        let account = Account(origin: origin, user: "performance-fixture@example.invalid", siteName: "Fixture", clientID: "performance-loopback")
        let session = try AccountSession(account: account, directory: root, authentication: .loopbackFixture)
        let owner = ConversationWindow(app: app, session: session)
        defer { owner.close(); session.stop(); try? FileManager.default.removeItem(at: root) }
        await session.client.invalidate()
        owner.showWindow(nil)
        owner.showHome()

        let cutoff = "2026-11-15 10:00:00"
        func conversation(_ name: String) -> RavenChannel {
            RavenChannel(raw: .object([
                "name": .string(name), "channel_name": .string(name), "last_message_timestamp": .string(cutoff),
                "last_message_details": .object(["owner": .string("peer"), "content": .string("Unread")]),
            ]))
        }
        session.channels = ["normal", "revoked-before", "revoked-during", "write-failed"].map(conversation)
        session.unread = .array(session.channels.map {
            .object(["name": .string($0.id), "unread_count": .number(1)])
        })
        let digest = HomeUnreadDigest.make(channels: session.channels, unread: session.unread, mentioned: [])
        session.revokedChannels.insert("revoked-before")

        var db: OpaquePointer?
        let opened = sqlite3_open(root.appendingPathComponent(AccountStore.databaseFileName).path, &db)
        defer { sqlite3_close(db) }
        let trigger = "CREATE TRIGGER fail_home_visit BEFORE INSERT ON visits WHEN NEW.channelID = 'write-failed' BEGIN SELECT RAISE(ABORT, 'fixture'); END"
        guard opened == SQLITE_OK, sqlite3_exec(db, trigger, nil, nil, nil) == SQLITE_OK else {
            throw AppError.message("Could not configure Home read fixture.")
        }
        owner.markAllRead(digest)
        let sheet = await waitForSheet(owner.window)
        let labels = sheet?.contentView.map { InteractionSelfChecks.descendants($0, of: NSTextField.self).map(\.stringValue) } ?? []
        let accept = sheetButtons(sheet).first { $0.title == "Mark as Read" }
        session.revokedChannels.insert("revoked-during")
        var updated = session.channels[0].raw.object
        updated["last_message_timestamp"] = .string("2026-11-15 10:01:00")
        session.channels[0] = RavenChannel(raw: .object(updated))
        accept?.performClick(nil)
        if accept == nil, let sheet { owner.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
        for _ in 0..<150 where !owner.status.stringValue.contains("Could not save") {
            try await Task.sleep(for: .milliseconds(10))
        }
        let visits = try await session.store.visits()
        return [
            ("Home excludes access already lost from the Mark All Read confirmation",
             labels.contains("Mark 3 conversations as read?")),
            ("Home saves the confirmed cutoff and skips conversations revoked before and during the sheet",
             visits == ["normal": cutoff]),
            ("Home reports local read progress without counting a failed write or claiming server acceptance",
             owner.status.stringValue.contains("Read progress saved for 1 of 4 conversations") &&
             owner.status.stringValue.contains("Could not save 1")),
        ]
    }

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

        var results = HomeOrderSelfChecks.run()
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
        var later = HomeFeed.Snapshot()
        later.saved = .loaded([]); later.reminders = .loaded([])
        results.append(("an empty Later card waits for local sources", HomeView.emptyLaterNote(later) == "Loading…"))
        later.draftRead = .loaded([]); later.outboxRead = .loaded([])
        results.append(("a fully loaded empty Later card explains how to save", HomeView.emptyLaterNote(later)?.hasPrefix("Nothing saved") == true))
        later.saved = .failed("offline")
        results.append(("a failed saved-message read cannot produce an empty Later message", HomeView.emptyLaterNote(later) == nil))
        later.saved = .loaded([]); later.reminders = .failed("offline")
        results.append(("a failed reminder read cannot produce an empty Later message", HomeView.emptyLaterNote(later) == nil))

        results += try await markAllRead(app: app)

        // Later's draft destinations: one opens directly, several offer a
        // native chooser, and a choice rechecks the session, Home and access.
        let fixtureFile = root.appendingPathComponent("draft-fixture.txt")
        try Data("Second draft staged attachment".utf8).write(to: fixtureFile)
        let staged = try await session.store.stage(file: fixtureFile)
        try await session.store.saveDraft(Draft(channelID: "ghost", html: "<p>Ghost draft</p>"))
        try await seedDrafts(session, attachment: staged, controller: controller)
        let listed = draftRow(in: controller)?.accessibilityLabel() ?? ""
        results.append(("Later lists every eligible draft destination once",
                        listed.contains("2 drafts") && listed.contains("# news") && listed.contains("# quiet") && !listed.contains("ghost")))

        pressDraftRow(in: controller)
        let choices = await waitForSheet(controller.window)
        let choiceButtons = sheetButtons(choices)
        results.append(("multiple drafts open a native chooser with every eligible destination",
                        choices != nil && choiceButtons.contains { $0.title == "# news" } && choiceButtons.contains { $0.title == "# quiet" }
                            && !choiceButtons.contains { $0.title == "ghost" }))
        let cancel = choiceButtons.first { $0.title == "Cancel" }
        cancel?.performClick(nil)
        await waitForSheetToClose(controller.window)
        results.append(("cancelling the draft chooser leaves Home as it was",
                        cancel != nil && controller.window?.attachedSheet == nil && controller.channel == nil && !controller.home.isHidden))

        pressDraftRow(in: controller)
        let secondChoice = await waitForSheet(controller.window)
        let secondButtons = sheetButtons(secondChoice)
        let secondDraftKept: Bool
        if let quietButton = secondButtons.first(where: { $0.title == "# quiet" }), let choose = secondButtons.first(where: { $0.title == "Choose" }) {
            quietButton.performClick(nil)
            choose.performClick(nil)
            for _ in 0..<250 where controller.channel?.id != "quiet" { try? await Task.sleep(for: .milliseconds(20)) }
            for _ in 0..<250 where controller.composer.string != "Second draft body" || controller.attachments != [staged] { try? await Task.sleep(for: .milliseconds(20)) }
            secondDraftKept = controller.channel?.id == "quiet" && controller.composer.string == "Second draft body" && controller.attachments == [staged]
        } else { secondDraftKept = false }
        results.append(("choosing the second draft opens it with its text and staged attachment", secondDraftKept))

        // The chip must not collapse into one accessibility element, or
        // VoiceOver cannot reach Remove.
        let chips = InteractionSelfChecks.descendants(controller.attachmentsRow, of: AttachmentChip.self)
        @MainActor func exposesRemove(_ view: NSView) -> Bool {
            if let button = view as? NSButton {
                return !button.isHiddenOrHasHiddenAncestor && button.isEnabled
                    && button.accessibilityLabel() == "Remove \(staged.filename)"
                    && button.action == #selector(ConversationWindow.removeAttachment(_:))
                    && button.target === controller
            }
            return (view.accessibilityChildren() ?? []).compactMap { $0 as? NSView }.contains { exposesRemove($0) }
        }
        let removeExposed = !chips.isEmpty && chips.allSatisfy { chip in
            NSAccessibility.unignoredChildren(from: [chip]).compactMap { $0 as? NSView }.contains { exposesRemove($0) }
        }
        results.append(("the attachment chip exposes its Remove control to VoiceOver", removeExposed))
        // AppKit controls report isAccessibilityElement() == false even when
        // they are exposed, so assert the readable filename itself.
        let nameExposed = !chips.isEmpty && chips.allSatisfy { chip in
            InteractionSelfChecks.descendants(chip, of: NSTextField.self).contains { field in
                field.stringValue == staged.filename
            }
        }
        results.append(("the attachment chip exposes its file name to VoiceOver", nameExposed))

        // One draft opens directly, with no chooser.
        try await session.store.saveDraft(Draft(channelID: "quiet"))
        for _ in 0..<250 {
            session.home.refreshLocal()
            if !session.home.snapshot.drafts.contains(where: { $0.channelID == "quiet" }) { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        controller.showHome()
        for _ in 0..<100 where controller.home.isHidden { try? await Task.sleep(for: .milliseconds(10)) }
        controller.home.reloadNow()
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let singleLabel = draftRow(in: controller)?.accessibilityLabel() ?? ""
        pressDraftRow(in: controller)
        let singleSheet = await waitForSheet(controller.window)
        for _ in 0..<250 where controller.channel?.id != "news" { try? await Task.sleep(for: .milliseconds(20)) }
        for _ in 0..<250 where controller.composer.string != "First draft body" { try? await Task.sleep(for: .milliseconds(20)) }
        results.append(("one draft opens directly without a chooser",
                        singleLabel.contains("1 draft") && singleSheet == nil && controller.channel?.id == "news" && controller.composer.string == "First draft body"))

        // Eligibility is rechecked when the choice is made.
        try await seedDrafts(session, attachment: staged, controller: controller)
        pressDraftRow(in: controller)
        let eligibilityChoice = await waitForSheet(controller.window)
        let eligibilityButtons = sheetButtons(eligibilityChoice)
        let eligibilityKept: Bool
        if let quietButton = eligibilityButtons.first(where: { $0.title == "# quiet" }), let choose = eligibilityButtons.first(where: { $0.title == "Choose" }) {
            session.revokedChannels.insert("quiet")
            quietButton.performClick(nil)
            choose.performClick(nil)
            await waitForSheetToClose(controller.window)
            eligibilityKept = controller.channel == nil && !controller.home.isHidden
            session.revokedChannels.remove("quiet")
        } else { eligibilityKept = false }
        results.append(("a destination that loses eligibility while choosing is not opened", eligibilityKept))

        // Home's state is rechecked when the choice is made.
        try await seedDrafts(session, attachment: staged, controller: controller)
        pressDraftRow(in: controller)
        let stateChoice = await waitForSheet(controller.window)
        let stateButtons = sheetButtons(stateChoice)
        let homeStateKept: Bool
        if let quietButton = stateButtons.first(where: { $0.title == "# quiet" }), let choose = stateButtons.first(where: { $0.title == "Choose" }) {
            controller.select(news)
            quietButton.performClick(nil)
            choose.performClick(nil)
            await waitForSheetToClose(controller.window)
            homeStateKept = controller.channel?.id == "news" && controller.home.isHidden
        } else { homeStateKept = false }
        results.append(("choosing while Home is no longer shown does not navigate", homeStateKept))
        controller.showHome()

        // The original session is rechecked when the choice is made.
        let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreHomeOther-\(UUID())")
        let other = try AccountSession(account: Account(origin: URL(string: "https://other.invalid")!, user: "other", siteName: "Other", clientID: "other", displayName: "Other"), directory: otherRoot, demo: true)
        defer { other.stop(); try? FileManager.default.removeItem(at: otherRoot) }
        try await seedDrafts(session, attachment: staged, controller: controller)
        pressDraftRow(in: controller)
        let identityChoice = await waitForSheet(controller.window)
        let identityButtons = sheetButtons(identityChoice)
        let identityKept: Bool
        if let quietButton = identityButtons.first(where: { $0.title == "# quiet" }), let choose = identityButtons.first(where: { $0.title == "Choose" }) {
            controller.use(other)
            quietButton.performClick(nil)
            choose.performClick(nil)
            await waitForSheetToClose(controller.window)
            identityKept = controller.session === other && controller.channel == nil
            controller.use(session)
        } else { identityKept = false }
        results.append(("choosing for a session the window no longer shows does not navigate", identityKept))

        // Switching accounts must rebuild Home from the new session without the
        // check forcing a reload; the window has to do it itself.
        controller.showHome()
        controller.home.reloadNow()
        let oldDraftShown = draftRow(in: controller) != nil
        controller.use(other)
        for _ in 0..<80 where draftRow(in: controller) != nil { try? await Task.sleep(for: .milliseconds(20)) }
        let otherHomeClean = oldDraftShown && draftRow(in: controller) == nil
        controller.use(session)
        for _ in 0..<80 where draftRow(in: controller) == nil { try? await Task.sleep(for: .milliseconds(20)) }
        results.append(("switching accounts rebuilds Home for the new account", otherHomeClean && draftRow(in: controller) != nil))

        results.append(("People You Talk With Most finds the person the reader writes to",
                         InteractionSelfChecks.descendants(card(.people) ?? NSView(), of: HomePerson.self).first?.accessibilityLabel()?.hasPrefix("Pat Peer") == true))

        // The retry check expects an empty Later after its outbox is cleared.
        // Remove the chooser's remaining draft destinations from this fixture.
        try await session.store.saveDraft(Draft(channelID: quiet.id))
        try await session.store.saveDraft(Draft(channelID: "ghost"))

        // Change only the disposable fixture database. A missing table forces
        // a real read failure while the other three Later sources stay usable.
        var fixture: OpaquePointer?
        guard sqlite3_open_v2(root.appendingPathComponent(AccountStore.databaseFileName).path, &fixture,
                              SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(fixture)
            throw AppError.message("Could not open the Home fixture database.")
        }
        defer { sqlite3_close(fixture) }
        func renameFixtureTable(_ sql: String) throws {
            guard sqlite3_exec(fixture, sql, nil, nil, nil) == SQLITE_OK else {
                throw AppError.message("Could not change the disposable Home fixture table.")
            }
        }
        func waitForLater(_ matches: () -> Bool) async throws -> Bool {
            for _ in 0..<80 {
                controller.home.reloadNow()
                if matches() { return true }
                try await Task.sleep(for: .milliseconds(15))
            }
            return false
        }
        try await session.store.saveDraft(Draft(channelID: news.id, html: "<p>Queue fixture</p>"))
        var unsent = try await session.store.acceptDraft(channelID: news.id)
        unsent.state = .retryable
        try await session.store.updateOperation(unsent)
        try renameFixtureTable("ALTER TABLE drafts RENAME TO unavailable_drafts")
        session.home.refreshLocal()
        let partial = try await waitForLater {
            labels(card(.later)).contains("Drafts could not be loaded.")
                && rows(.later).contains { $0.contains("1 message not sent") }
        }
        results.append(("Later reports draft read failures and keeps the working outbox visible", partial))
        try renameFixtureTable("ALTER TABLE unavailable_drafts RENAME TO drafts")
        unsent.state = .cancelled
        try await session.store.updateOperation(unsent)
        try renameFixtureTable("ALTER TABLE operations RENAME TO unavailable_operations")
        session.home.refreshLocal()
        let unavailable = try await waitForLater {
            let text = labels(card(.later))
            return text.contains("The outbox could not be loaded.")
                && !text.contains { $0.hasPrefix("Nothing saved") }
        }
        results.append(("an unavailable outbox cannot produce an empty Later message", unavailable))
        try renameFixtureTable("ALTER TABLE unavailable_operations RENAME TO operations")
        session.home.refreshLocal()
        let recovered = try await waitForLater { labels(card(.later)).contains { $0.hasPrefix("Nothing saved") } }
        results.append(("Later returns to its empty state after a successful retry", recovered))
        try await session.store.saveDraft(Draft(channelID: quiet.id, html: "<p>Recovered draft</p>"))
        session.home.refreshLocal()
        let draftRestored = try await waitForLater { rows(.later).contains { $0.contains("1 draft") && $0.contains("quiet") } }
        results.append(("a new draft appears after a failed local read recovers", draftRestored))


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
