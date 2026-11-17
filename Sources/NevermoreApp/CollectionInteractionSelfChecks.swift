import AppKit
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

        // A real close must clear private rows and reject delayed results.
        let escapeCollection = CollectionWindow(owner: owner, title: "Escape self-check", records: rows, kind: .messages, source: nil)
        if let event = key(53, window: escapeCollection.window, characters: "\u{1b}") { escapeCollection.table.keyDown(with: event) }
        check("Escape closes the collection window and clears its rows") { escapeCollection.isClosed && escapeCollection.records.isEmpty && escapeCollection.selected == nil }

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
            threadCollection.open()
            if let threadWindow = owner.app.windows.last, threadWindow !== owner {
                await threadWindow.loadTask?.value
                check("thread collections retain the server-provided parent route") { threadWindow.channel?.raw["is_thread"].bool == true && threadWindow.channel?.raw["parent_channel_id"].string == parent.id }
                threadWindow.close()
            } else { results.append(("thread collections retain the server-provided parent route", false)) }
            let beforeRevokedParent = owner.app.windows.count
            session.revokedChannels.insert(parent.id); threadCollection.open(); session.revokedChannels.remove(parent.id)
            check("thread collections cannot reopen a revoked parent channel") { owner.app.windows.count == beforeRevokedParent }
            threadCollection.close()
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
