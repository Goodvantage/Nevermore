import AppKit
import UserNotifications
import RavenProtocol
import NevermoreCore

/// Keyboard/accessibility checks for collection windows. Uses only the demo
/// session and static fixture rows; windows are created but never shown, and
/// callbacks are injected where a real open would create a conversation window
/// or a refresh would touch the network.
@MainActor enum CollectionInteractionSelfChecks {
    static func run(owner: ConversationWindow) async throws -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func check(_ label: String, _ body: () throws -> Bool) {
            do { results.append((label, try body())) }
            catch { results.append(("\(label) [\(error.localizedDescription)]", false)) }
        }
        func key(_ code: UInt16, window: NSWindow?, modifiers: NSEvent.ModifierFlags = [], characters: String = "\r") -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                             windowNumber: window?.windowNumber ?? 0, context: nil,
                             characters: characters, charactersIgnoringModifiers: characters,
                             isARepeat: false, keyCode: code)
        }
        func hasLabel(_ view: NSView) -> Bool { !(view.accessibilityLabel() ?? "").isEmpty }
        guard let session = owner.session else { throw AppError.message("Collection self-check needs a demo session") }
        let rows: [JSONValue] = [
            .object(["channel_id": .string("collection-alpha"), "content": .string("First static result")]),
            .object(["channel_id": .string("collection-beta"), "content": .string("Second static result")]),
        ]

        // MARK: Keyboard dispatch (injected callbacks avoid real windows/network)
        let staticCollection = CollectionWindow(owner: owner, title: "Static self-check", records: rows, kind: .messages, source: nil)
        check("collection tables reject stale row callbacks after data changes") { staticCollection.tableView(staticCollection.table, viewFor: nil, row: rows.count) == nil }
        staticCollection.findPrevious(nil)
        check("Find Previous starts from the last collection result") { staticCollection.table.selectedRow == rows.count - 1 }
        staticCollection.findNext(nil)
        check("Find Next wraps without discarding the collection query") { staticCollection.table.selectedRow == 0 }
        staticCollection.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        var opened = 0
        staticCollection.table.onOpen = { opened += 1 }
        if let event = key(36, window: staticCollection.window) { staticCollection.table.keyDown(with: event) }
        check("Return dispatches open through the collection table") { opened == 1 }

        var openedModified = 0
        staticCollection.table.onOpen = { openedModified += 1 }
        if let event = key(36, window: staticCollection.window, modifiers: .shift) { staticCollection.table.keyDown(with: event) }
        check("Shift-Return keeps native table behavior instead of opening") { openedModified == 0 }

        var closed = 0
        staticCollection.table.onClose = { closed += 1 }
        if let event = key(53, window: staticCollection.window, characters: "\u{1b}") { staticCollection.table.keyDown(with: event) }
        check("Escape dispatches close through the collection table") { closed == 1 }

        var refreshed = 0
        staticCollection.table.onRefresh = { refreshed += 1 }
        if let event = key(15, window: staticCollection.window, modifiers: .command, characters: "r") { staticCollection.table.keyDown(with: event) }
        check("Command-R does not refresh a static collection without a source") { refreshed == 0 && staticCollection.table.canRefresh == false }

        let beforeNoSource = staticCollection.status.stringValue
        if let event = key(15, window: staticCollection.window, modifiers: .command, characters: "r") { staticCollection.table.keyDown(with: event) }
        check("Command-R without a source performs no refresh") { staticCollection.status.stringValue == beforeNoSource && !staticCollection.isLoading }

        // A filter that holds text clears on the first Escape; only an
        // empty field dismisses the window.
        let filterCollection = CollectionWindow(owner: owner, title: "Filter escape self-check", records: rows, kind: .messages, source: nil)
        filterCollection.search.stringValue = "Second"
        filterCollection.applySearch()
        check("a collection filter narrows its rows") { filterCollection.records.count == 1 }
        // Seed the editor's buffer too: ending editing commits it back into
        // the field, so both must be cleared for the result to survive.
        let fieldEditor = NSTextView()
        fieldEditor.string = "Second"
        let cleared = filterCollection.control(filterCollection.search, textView: fieldEditor, doCommandBy: NSSelectorFromString("cancelOperation:"))
        check("Escape clears a collection filter instead of closing the window") {
            cleared && filterCollection.search.stringValue.isEmpty && fieldEditor.string.isEmpty && filterCollection.records.count == rows.count && !filterCollection.isClosed
        }
        // Focus moved to the results, so the real second Escape reaches the
        // table rather than the search field again.
        var closedAgain = false
        if let event = key(53, window: filterCollection.window, characters: "\u{1b}") {
            filterCollection.table.keyDown(with: event)
            closedAgain = filterCollection.isClosed
        }
        check("a second Escape through the results closes an empty-filter collection") { closedAgain }

        // Text held only in the field editor still counts as populated.
        let editorOnly = CollectionWindow(owner: owner, title: "Editor-only escape self-check", records: rows, kind: .messages, source: nil)
        let uncommitted = NSTextView()
        uncommitted.string = "Second"
        let clearedByEditor = editorOnly.control(editorOnly.search, textView: uncommitted, doCommandBy: NSSelectorFromString("cancelOperation:"))
        check("Escape clears from the field editor's buffer alone") {
            clearedByEditor && editorOnly.search.stringValue.isEmpty && uncommitted.string.isEmpty && !editorOnly.isClosed
        }

        // With the results focused and a populated filter, the first Escape
        // clears instead of closing; only an empty filter dismisses.
        let tableFocused = CollectionWindow(owner: owner, title: "Results-focused escape self-check", records: rows, kind: .messages, source: nil)
        tableFocused.search.stringValue = "Second"
        tableFocused.applySearch()
        check("a populated filter narrows the results") { tableFocused.records.count == 1 }
        if let event = key(53, window: tableFocused.window, characters: "\u{1b}") { tableFocused.table.keyDown(with: event) }
        check("Escape with results focus clears a populated filter instead of closing") {
            !tableFocused.isClosed && tableFocused.search.stringValue.isEmpty && tableFocused.records.count == rows.count
        }
        if let event = key(53, window: tableFocused.window, characters: "\u{1b}") { tableFocused.table.keyDown(with: event) }
        check("a second Escape with results focus closes an empty-filter collection") { tableFocused.isClosed }

        // A real close must clear private rows and reject delayed results.
        let escapeCollection = CollectionWindow(owner: owner, title: "Escape self-check", records: rows, kind: .messages, source: nil)
        if let event = key(53, window: escapeCollection.window, characters: "\u{1b}") { escapeCollection.table.keyDown(with: event) }
        check("Escape closes the collection window and clears its rows") { escapeCollection.isClosed && escapeCollection.records.isEmpty && escapeCollection.selected == nil }

        // Escape backs out of a filter before it closes anything.
        let named: [JSONValue] = [
            .object(["name": .string("row-alpha"), "channel_id": .string("collection-alpha"), "content": .string("First static result")]),
            .object(["name": .string("row-beta"), "channel_id": .string("collection-beta"), "content": .string("Second static result")]),
        ]
        let filtered = CollectionWindow(owner: owner, title: "Filter Escape self-check", records: named, kind: .messages, source: nil)
        filtered.search.stringValue = "second"; filtered.applySearch()
        filtered.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let fieldHandled = filtered.control(filtered.search, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        check("Escape in a collection's filter field clears the filter instead of closing") { fieldHandled && !filtered.isClosed && filtered.search.stringValue.isEmpty && filtered.records.count == named.count }
        check("clearing the filter keeps the selected item selected") { filtered.selected?["name"].string == "row-beta" }
        filtered.search.stringValue = "first"; filtered.applySearch()
        if let event = key(53, window: filtered.window, characters: "\u{1b}") { filtered.table.keyDown(with: event) }
        check("Escape in a filtered collection's table clears the filter first") { !filtered.isClosed && filtered.search.stringValue.isEmpty && filtered.records.count == named.count }
        _ = filtered.control(filtered.search, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        check("Escape with an empty filter closes the collection") { filtered.isClosed }

        // An Inbox permits several rows at once. Clearing a filter must
        // reselect every chosen row by its ID rather than by the index it
        // held while filtered, so the selection survives rows reordering.
        let multi: [JSONValue] = [
            .object(["name": .string("inbox-alpha"), "channel_id": .string("collection-alpha"), "content": .string("First static result")]),
            .object(["name": .string("inbox-beta"), "channel_id": .string("collection-beta"), "content": .string("Second dynamic result")]),
            .object(["name": .string("inbox-gamma"), "channel_id": .string("collection-alpha"), "content": .string("Third static result")]),
        ]
        let inbox = CollectionWindow(owner: owner, title: "Multiple selection escape self-check", records: multi, kind: .inbox, source: nil)
        inbox.search.stringValue = "static"; inbox.applySearch()
        check("the Inbox filter hides a non-matching row") { inbox.records.count == 2 }
        // The remaining rows sit at 0 and 1 while filtered, but gamma moves
        // back to 2 once the filter clears.
        inbox.table.selectRowIndexes(IndexSet(integersIn: 0...1), byExtendingSelection: false)
        if let event = key(53, window: inbox.window, characters: "\u{1b}") { inbox.table.keyDown(with: event) }
        check("clearing an Inbox filter restores every selected row by ID") {
            !inbox.isClosed && inbox.search.stringValue.isEmpty && inbox.records.count == multi.count
                && Array(inbox.table.selectedRowIndexes) == [0, 2]
        }
        check("the restored Inbox selection keeps every chosen row selected") {
            inbox.selectedBatchRows.compactMap { $0["name"].string } == ["inbox-alpha", "inbox-gamma"]
        }
        // The window-level Escape route shares the same policy: with the
        // filter already empty it closes.
        if let event = key(53, window: inbox.window, characters: "\u{1b}") { inbox.keyDown(with: event) }
        check("a second Escape through the window route closes the empty-filter Inbox") { inbox.isClosed }

        // MARK: Selection-aware and source-aware control states
        staticCollection.table.deselectAll(nil)
        check("static collection disables refresh and paging controls") {
            !staticCollection.refreshButton.isEnabled && staticCollection.refreshButton.isHidden &&
            !staticCollection.moreButton.isEnabled && staticCollection.moreButton.isHidden &&
            !staticCollection.openButton.isEnabled && !staticCollection.manageButton.isEnabled
        }
        staticCollection.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        check("selecting a result enables Open and Actions") { staticCollection.openButton.isEnabled && staticCollection.manageButton.isEnabled }
        staticCollection.table.selectRowIndexes(IndexSet(), byExtendingSelection: false)
        check("clearing the selection disables Open and Actions") { !staticCollection.openButton.isEnabled && !staticCollection.manageButton.isEnabled }

        staticCollection.isLoading = true
        staticCollection.updateChrome()
        check("loading disables refresh and paging controls") { !staticCollection.refreshButton.isEnabled && !staticCollection.moreButton.isEnabled }
        staticCollection.isLoading = false
        staticCollection.updateChrome()

        check("collection controls expose accessibility labels") {
            hasLabel(staticCollection.table) && hasLabel(staticCollection.search) && hasLabel(staticCollection.status) &&
            hasLabel(staticCollection.refreshButton) && hasLabel(staticCollection.moreButton) &&
            hasLabel(staticCollection.openButton) && hasLabel(staticCollection.manageButton)
        }

        // MARK: Source support (no network: sources are never shown/refreshed)
        let sourced = CollectionWindow(owner: owner, title: "Sourced self-check", records: [], kind: .reminders,
                                       source: CollectionSource(method: "raven.api.reminders.get_reminders", strategy: .none))
        check("sourced collection enables refresh but never paging") {
            sourced.refreshButton.isEnabled && !sourced.refreshButton.isHidden &&
            !sourced.moreButton.isEnabled && sourced.moreButton.isHidden
        }
        var sourcedRefreshed = 0
        sourced.table.onRefresh = { sourcedRefreshed += 1 }
        if let event = key(15, window: sourced.window, modifiers: .command, characters: "r") { sourced.table.keyDown(with: event) }
        check("Command-R refreshes when the collection has a verified source") { sourcedRefreshed == 1 && sourced.table.canRefresh == true }

        var sourcedModifiedRefresh = 0
        sourced.table.onRefresh = { sourcedModifiedRefresh += 1 }
        if let event = key(15, window: sourced.window, modifiers: [.command, .shift], characters: "R") { sourced.table.keyDown(with: event) }
        check("modified Command-R does not refresh") { sourcedModifiedRefresh == 0 }

        let paged = CollectionWindow(owner: owner, title: "Paged self-check", records: rows, kind: .saved,
                                     source: CollectionSource(method: "raven.api.raven_message.get_saved_messages", strategy: .offset(parameter: "start")))
        check("Load More is enabled only for a paging source") {
            paged.moreButton.isEnabled && !paged.moreButton.isHidden && !staticCollection.moreButton.isEnabled
        }
        paged.pager.hasMore = false
        paged.updateChrome()
        check("Load More disables when no further pages are available") { !paged.moreButton.isEnabled }
        paged.pager.hasMore = true
        paged.updateChrome()

        // MARK: Privacy, closed-view and account guards
        session.revokedChannels.insert("collection-beta")
        staticCollection.restrictRevoked()
        check("collections remove revoked conversation content") {
            staticCollection.records.count == 1 && staticCollection.records.first?["channel_id"].string == "collection-alpha"
        }
        let appliedRevoked = staticCollection.apply(rows: [.object(["channel_id": .string("collection-beta"), "content": .string("Revoked")])],
                                                    generation: staticCollection.pager.generation, refresh: true)
        check("apply filters revoked channels before displaying results") {
            appliedRevoked && staticCollection.records.allSatisfy { $0["channel_id"].string != "collection-beta" }
        }
        session.revokedChannels.remove("collection-beta")

        let windowsBeforeRevoked = owner.app.windows.count
        let revokedCollection = CollectionWindow(owner: owner, title: "Revoked self-check", records: rows, kind: .messages, source: nil)
        session.revokedChannels.insert("collection-beta")
        revokedCollection.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        if let event = key(36, window: revokedCollection.window) { revokedCollection.table.keyDown(with: event) }
        session.revokedChannels.remove("collection-beta")
        check("Return cannot reopen a revoked conversation") { owner.app.windows.count == windowsBeforeRevoked }

        let windowsBeforeClosed = owner.app.windows.count
        staticCollection.close()
        check("closing a collection clears rows and selection") {
            staticCollection.isClosed && staticCollection.records.isEmpty && staticCollection.selected == nil
        }
        let staleApplied = staticCollection.apply(rows: rows, generation: staticCollection.pager.generation, refresh: true)
        check("delayed results cannot repopulate a closed collection") { !staleApplied && staticCollection.records.isEmpty }
        staticCollection.records.append(.object(["channel_id": .string("collection-alpha"), "content": .string("Stale")]))
        staticCollection.table.reloadData()
        staticCollection.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        staticCollection.open()
        check("a stale row cannot reopen a closed collection") { owner.app.windows.count == windowsBeforeClosed }

        if let parent = owner.channel {
            let threadCollection = CollectionWindow(owner: owner, title: "Thread route check", records: [.object(["name": .string("collection-thread-fixture"), "channel_id": .string(parent.id)])], kind: .threads)
            threadCollection.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let windowsBeforeThread = owner.app.windows.count
            threadCollection.open()
            await owner.loadTask?.value
            await owner.renderTask?.value
            check("collection items open in their own conversation window, not a new one") { owner.app.windows.count == windowsBeforeThread && owner.channel?.id == "collection-thread-fixture" }
            check("thread collections retain the server-provided parent route") { owner.channel?.raw["is_thread"].bool == true && owner.channel?.raw["parent_channel_id"].string == parent.id }
            owner.select(parent)
            await owner.loadTask?.value
            await owner.renderTask?.value
            let beforeRevokedParent = owner.app.windows.count
            session.revokedChannels.insert(parent.id); threadCollection.open(); session.revokedChannels.remove(parent.id)
            check("thread collections cannot reopen a revoked parent channel") { owner.app.windows.count == beforeRevokedParent && owner.channel?.id == parent.id }
            threadCollection.close()

            do {
                let previousRead = session.readRPC
                defer { session.readRPC = previousRead }
                let incomingID = "notification-burst-incoming"
                func row(_ id: String, channelID: String, user: String) -> JSONValue {
                    .object(["name": .string(id), "channel_id": .string(channelID), "owner": .string(user),
                             "creation": .string("2026-11-23 10:00:00.000000"), "message_type": .string("Text")])
                }
                var rows = (0..<48).map { row("notification-burst-\($0)", channelID: parent.id, user: session.account.user) }
                rows.append(row("notification-wrong-conversation", channelID: "unrelated", user: "peer@example.invalid"))
                rows.append(row(incomingID, channelID: parent.id, user: "peer@example.invalid"))
                session.readRPC = { method, arguments in
                    guard method == "raven.api.chat_stream.get_messages", arguments["channel_id"]?.string == parent.id,
                          arguments["update_last_visit"] == .bool(false) else {
                        throw AppError.message("Unexpected notification fixture read.")
                    }
                    return .object(["messages": .array(Array(rows.prefix(Int(arguments["limit"]?.nonnegativeCount ?? 0))))])
                }
                let page = try await session.notificationPage(channelID: parent.id)
                let candidate = NotificationPolicy.nextNotification(in: page, user: session.account.user, seen: nil, notified: { _ in false })
                check("a notification finds an incoming row behind a burst of the reader's own messages") {
                    candidate?.id == incomingID && page.allSatisfy { $0.channelID == parent.id }
                }
            }

            // Notifications route through the same reuse: the conversation a
            // window shows comes forward, another one is shown in place.
            let windowsBeforeReveal = owner.app.windows.count
            owner.app.reveal(session: session, channel: parent, preferring: owner)
            check("revealing the conversation a window shows opens no new window") { owner.app.windows.count == windowsBeforeReveal && owner.channel?.id == parent.id }
            // The self-check account lists one channel; any other route will do.
            let other = RavenChannel(raw: .object(["name": .string("collection-reveal-fixture"), "channel_name": .string("Reveal fixture")]))
            session.revokedChannels.insert(other.id)
            owner.app.reveal(session: session, channel: other, anchor: "stale-notification", preferring: owner)
            check("a stale notification cannot navigate to a revoked conversation") {
                owner.app.windows.count == windowsBeforeReveal && owner.channel?.id == parent.id
            }
            session.revokedChannels.remove(other.id)
            owner.app.reveal(session: session, channel: other, preferring: owner)
            await owner.loadTask?.value
            await owner.renderTask?.value
            check("revealing another conversation shows it in place") { owner.app.windows.count == windowsBeforeReveal && owner.channel?.id == other.id }
            NSApp.activate(ignoringOtherApps: true)
            owner.window?.makeKeyAndOrderFront(nil)
            for _ in 0..<100 where NSApp.keyWindow !== owner.window { try await Task.sleep(for: .milliseconds(10)) }

            do {
                let defaults = UserDefaults.standard
                let saved = defaults.object(forKey: "notifications")
                let savedQuietHours = NotificationPreferenceStore.quietHours(accountID: session.account.id)
                session.channels.append(other)
                defer {
                    session.channels.removeAll { $0.id == other.id }
                    defaults.set(saved, forKey: "notifications")
                    NotificationPreferenceStore.setQuietHours(savedQuietHours, accountID: session.account.id)
                }
                defaults.set(true, forKey: "notifications")
                NotificationPreferenceStore.setQuietHours(nil, accountID: session.account.id)
                let accountID = session.account.id.uuidString
                let selector = NSSelectorFromString("userNotificationCenter:willPresentNotification:withCompletionHandler:")
                let app = owner.app
                check("foreground presentation requests a banner and list entry for another conversation") {
                    app.responds(to: selector) && NSApp.isActive && NSApp.keyWindow === owner.window &&
                        app.foregroundChatPresentation(accountID: accountID, channelID: parent.id) == [.banner, .list]
                }
                check("foreground presentation stays silent in the conversation being read") {
                    app.foregroundChatPresentation(accountID: accountID, channelID: other.id).isEmpty
                }
                defaults.set(false, forKey: "notifications")
                check("foreground presentation respects disabled chat notifications") {
                    app.foregroundChatPresentation(accountID: accountID, channelID: parent.id).isEmpty
                }
            }

            // A notification response can arrive before Session.start has read
            // the channel list. It must be retained, then replayed once the
            // channel appears, instead of being dropped at the cold-launch gap.
            let windowsBeforeColdRoute = owner.app.windows.count
            let coldChannel = RavenChannel(raw: .object(["name": .string("cold-notification-fixture"), "channel_name": .string("Cold notification")]))
            owner.app.handleNotificationRoute(accountID: session.account.id.uuidString, channelID: coldChannel.id, anchor: "cold-route-anchor")
            check("a notification for an unloaded conversation is retained without opening anything") {
                owner.app.pendingNotificationRoute?.channelID == coldChannel.id && owner.app.pendingNotificationRoute?.anchor == "cold-route-anchor"
                    && owner.app.windows.count == windowsBeforeColdRoute && owner.channel?.id != coldChannel.id
            }
            session.channels.append(coldChannel)
            owner.window?.makeKeyAndOrderFront(nil)
            session.notify()
            // The replay runs on the main queue after the post.
            var replayAttempts = 0
            while owner.app.pendingNotificationRoute != nil || owner.channel?.id != coldChannel.id {
                try await Task.sleep(for: .milliseconds(10))
                replayAttempts += 1
                if replayAttempts >= 200 { break }
            }
            await owner.loadTask?.value
            await owner.renderTask?.value
            let replayTimedOut = replayAttempts >= 200
            check("the retained notification opens once its conversation loads (attempts: \(replayAttempts)\(replayTimedOut ? ", timed out" : ""))") {
                owner.app.pendingNotificationRoute == nil && owner.channel?.id == coldChannel.id
            }
            // Restore the conversation the surrounding checks expect.
            owner.select(other)
            await owner.loadTask?.value
            await owner.renderTask?.value
            session.channels.removeAll { $0.id == coldChannel.id }
            session.notify()
            // A route retained while the channel was absent must still honor
            // revocation once the channel appears.
            let revokedChannel = RavenChannel(raw: .object(["name": .string("cold-revoked-fixture"), "channel_name": .string("Cold revoked")]))
            owner.app.handleNotificationRoute(accountID: session.account.id.uuidString, channelID: revokedChannel.id, anchor: nil)
            session.channels.append(revokedChannel)
            session.revokedChannels.insert(revokedChannel.id)
            session.notify()
            var revokedAttempts = 0
            while owner.app.pendingNotificationRoute != nil, revokedAttempts < 100 {
                try await Task.sleep(for: .milliseconds(10))
                revokedAttempts += 1
            }
            check("a retained notification for a revoked conversation is dropped without opening it (attempts: \(revokedAttempts))") {
                owner.app.pendingNotificationRoute == nil && owner.channel?.id != revokedChannel.id
            }
            session.revokedChannels.remove(revokedChannel.id)
            session.channels.removeAll { $0.id == revokedChannel.id }
            session.notify()
            let threadParent = RavenChannel(raw: .object(["name": .string("notification-thread-parent"), "channel_name": .string("Thread notification parent")]))
            let rootID = "notification-thread-root"
            let replyID = "notification-thread-reply"
            func threadRow(_ id: String, channelID: String) -> RavenMessage {
                RavenMessage(raw: .object([
                    "name": .string(id), "channel_id": .string(channelID), "owner": .string("peer@example.invalid"),
                    "creation": .string("2026-11-23 08:01:00.000000"), "text": .string("<p>Thread fixture</p>"),
                    "message_type": .string("Text"),
                ]))
            }
            try await session.store.cacheMessages([
                threadRow(rootID, channelID: threadParent.id), threadRow(replyID, channelID: rootID),
            ])
            session.channels.append(threadParent)
            session.threadParents[rootID] = threadParent.id

            owner.window?.makeKeyAndOrderFront(nil)
            owner.app.handleNotificationRoute(accountID: session.account.id.uuidString, channelID: rootID, anchor: replyID)
            await owner.app.notificationRouteTask?.value
            check("a thread reply notification opens the reply's own conversation and anchor") {
                owner.channel?.id == rootID && owner.requestedAnchor == replyID
            }
            owner.app.handleNotificationRoute(accountID: session.account.id.uuidString, channelID: rootID, anchor: rootID)
            await owner.app.notificationRouteTask?.value
            check("a thread root notification opens its parent at the root") {
                owner.channel?.id == threadParent.id && owner.requestedAnchor == rootID
            }
            check("only a notification's default action opens a conversation") {
                AppDelegate.notificationResponseOpens(UNNotificationDefaultActionIdentifier) &&
                    !AppDelegate.notificationResponseOpens(UNNotificationDismissActionIdentifier)
            }

            owner.app.handleNotificationRoute(accountID: session.account.id.uuidString, channelID: rootID, anchor: replyID)
            let superseded = owner.app.notificationRouteTask
            owner.app.handleNotificationRoute(accountID: session.account.id.uuidString, channelID: threadParent.id, anchor: nil)
            await superseded?.value
            check("a newer notification click cancels an unresolved thread route") {
                superseded?.isCancelled == true && owner.channel?.id == threadParent.id
            }

            owner.app.handleNotificationRoute(accountID: session.account.id.uuidString, channelID: rootID, anchor: replyID)
            let abandoned = owner.app.notificationRouteTask
            owner.select(other)
            await abandoned?.value
            check("navigation cancels an unresolved notification route") {
                abandoned?.isCancelled == true && owner.channel?.id == other.id
            }
            // This click arrives before any conversation window exists.
            // Bringing up a window and selecting a conversation must win.
            let previousKey = NSApp.keyWindow
            let visible = NSApp.orderedWindows.filter(\.isVisible)
            for window in visible { window.orderOut(nil) }
            let coldApp = AppDelegate()
            coldApp.sessions = [session]
            let noOrigin = coldApp.activeConversationWindow == nil
            coldApp.handleNotificationRoute(accountID: session.account.id.uuidString, channelID: rootID, anchor: replyID)
            let coldRoute = coldApp.notificationRouteTask
            let firstWindow = ConversationWindow(app: coldApp, session: session, lastFrameAutosaveName: nil)
            coldApp.windows.append(firstWindow)
            firstWindow.showWindow(nil)
            firstWindow.window?.makeKeyAndOrderFront(nil)
            firstWindow.select(other)
            await coldRoute?.value
            check("navigation in the first window cancels an unresolved cold-launch notification") {
                noOrigin && coldRoute?.isCancelled == true && coldApp.pendingNotificationRoute == nil &&
                    firstWindow.channel?.id == other.id
            }
            firstWindow.close()
            for window in visible.reversed() { window.orderFront(nil) }
            previousKey?.makeKeyAndOrderFront(nil)

            session.channels.removeAll { $0.id == threadParent.id }
            session.threadParents.removeValue(forKey: rootID)
            session.notify()

            // A window busy with an edit is passed over for another window
            // of the account before a new one opens. Every window but a
            // spare is made busy, so the spare is the one that can take it.
            let spare = ConversationWindow(app: owner.app, session: session)
            owner.app.windows.append(spare)
            let windowsWithSpare = owner.app.windows.count
            let busy = owner.app.windows.filter { $0 !== spare && $0.session === session }
            let edits = busy.map(\.editing)
            for window in busy { window.editing = RavenMessage(raw: .object(["name": .string("reveal-edit-fixture"), "channel_id": .string(other.id)])) }
            let unseen = RavenChannel(raw: .object(["name": .string("collection-reveal-busy-fixture"), "channel_name": .string("Busy reveal fixture")]))
            owner.app.reveal(session: session, channel: unseen, preferring: owner)
            await spare.loadTask?.value
            await spare.renderTask?.value
            check("revealing passes over a window busy with an edit") { owner.app.windows.count == windowsWithSpare && spare.channel?.id == unseen.id && owner.channel?.id == other.id }
            // The busy owner already shows the destination. An anchored
            // request must route the message to the available spare.
            let anchor = "anchored-collection-message"
            owner.app.reveal(session: session, channel: other, anchor: anchor, preferring: owner)
            check("an anchored reveal preserves the edit and reaches the message in a free window") {
                owner.editing != nil && spare.channel?.id == other.id && spare.requestedAnchor == anchor
                    && owner.app.windows.count == windowsWithSpare
            }
            for (window, edit) in zip(busy, edits) { window.editing = edit }
            if let host = owner.window {
                let sheet = NSWindow()
                host.beginSheet(sheet, completionHandler: nil)
                owner.app.reveal(session: session, channel: other, anchor: "sheet-anchor", preferring: owner)
                check("a matching window with a sheet keeps the sheet and another match takes the anchor") {
                    host.attachedSheet === sheet && spare.requestedAnchor == "sheet-anchor"
                }
                host.endSheet(sheet)
                sheet.orderOut(nil)
            }
            spare.close()
            owner.app.windows.removeAll { $0 === spare }
            owner.select(parent)
            await owner.loadTask?.value
            await owner.renderTask?.value
        }

        results.append(contentsOf: try await CollectionBatchSelfChecks.run(owner: owner))

        let originalOwnerClosed = owner.isClosed
        owner.isClosed = true
        defer { owner.isClosed = originalOwnerClosed }
        let ownerClosed = CollectionWindow(owner: owner, title: "Owner closed self-check", records: rows, kind: .messages, source: nil)
        let appliedOwnerClosed = ownerClosed.apply(rows: rows, generation: ownerClosed.pager.generation, refresh: true)
        check("a closed conversation owner rejects collection results") { !appliedOwnerClosed }

        return results
    }
}
