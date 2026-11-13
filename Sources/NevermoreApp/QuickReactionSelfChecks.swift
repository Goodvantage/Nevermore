import AppKit
import NevermoreCore
import RavenProtocol

/// Checks the message hover bar and the one-click reaction row. `run` uses
/// the isolated demo window and never sends a reaction; `runNetwork` sends
/// real reaction toggles to a credential-free loopback fixture.
@MainActor enum QuickReactionSelfChecks {
    private static func wait(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<300 { if condition() { return true }; try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// Shows the hover bar over the last visible message and returns it.
    private static func hover(_ owner: ConversationWindow, messageID: String? = nil) -> (NSRange, RavenMessage)? {
        let readable = owner.readableTranscriptRect
        guard let entry = owner.messageRanges.last(where: { entry in
            (messageID == nil || entry.1.id == messageID) && readable.intersects(owner.highlightRect(for: entry.0))
        }) else { return nil }
        let rect = owner.highlightRect(for: entry.0)
        owner.updateHover(at: NSPoint(x: rect.midX, y: min(max(rect.midY, readable.minY + 4), readable.maxY - 4)))
        return owner.hoveredMessageID == entry.1.id ? entry : nil
    }

    static func run(owner: ConversationWindow) async throws -> [(String, Bool)] {
        guard let session = owner.session, session.demo, let window = owner.window else { throw AppError.message("Quick reaction checks require the isolated demo account.") }
        var results: [(String, Bool)] = []
        await owner.renderTask?.value
        window.contentView?.layoutSubtreeIfNeeded()
        owner.hideHoverBar()
        guard let entry = hover(owner), let react = owner.hoverBar.reactButton as? HoverHighlightButton, !owner.hoverBar.isHidden else {
            return [("hover bar appears over the message under the pointer", false)]
        }
        defer { owner.hideHoverBar() }

        NSCursor.iBeam.set()
        let center = react.convert(NSPoint(x: react.bounds.midX, y: react.bounds.midY), to: nil)
        guard let move = NSEvent.mouseEvent(with: .mouseMoved, location: center, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
            return [("synthetic pointer event", false)]
        }
        owner.transcript.mouseMoved(with: move)
        results.append(("the pointer over hover actions is the arrow, not the text I-beam", NSCursor.current == NSCursor.arrow))
        results.append(("reaching for a hover action keeps the bar on its message", owner.hoveredMessageID == entry.1.id && !owner.hoverBar.isHidden))
        react.mouseEntered(with: move)
        let highlighted = react.isHovered && react.contentTintColor == .labelColor
        react.mouseExited(with: move)
        results.append(("hover actions highlight under the pointer", highlighted && !react.isHovered && react.contentTintColor == .secondaryLabelColor))

        let popover = owner.quickReactions
        react.performClick(nil)
        results.append(("the React button opens the one-click row instead of the full picker", popover.isShown && popover.messageID == entry.1.id && popover.emoji == QuickReactions.defaults && window.attachedSheet == nil))
        results.append(("a pointer-opened row starts without keyboard focus", popover.buttons.count == QuickReactions.slotCount && popover.buttons.allSatisfy { !$0.isKeyboardFocused && !$0.isChosen }))
        if let other = owner.messageRanges.first(where: { $0.1.id != entry.1.id }) {
            let rect = owner.highlightRect(for: other.0)
            owner.updateHover(at: NSPoint(x: rect.midX, y: rect.midY))
        }
        owner.render(); await owner.renderTask?.value
        results.append(("an open row stays on its message across pointer moves and re-renders", popover.isShown && popover.messageID == entry.1.id && owner.hoveredMessageID == entry.1.id && !owner.hoverBar.isHidden))

        popover.moreButton.performClick(nil)
        let sheetOpened = try await wait { window.attachedSheet != nil }
        results.append(("More Emoji… closes the row and opens the full picker", sheetOpened && !popover.isShown))
        window.attachedSheet?.contentView.flatMap { InteractionSelfChecks.descendants($0, of: NSButton.self).first { $0.title == "Cancel" } }?.performClick(nil)
        _ = try await wait { window.attachedSheet == nil }
        await owner.emojiSelectionTask?.value

        // Keyboard checks record choices instead of sending demo reactions.
        let sendChoice = popover.onChoose, sendMore = popover.onMore
        var chosen: [String] = [], more: [String] = []
        popover.onChoose = { emoji, id in chosen.append("\(emoji) \(id)") }
        popover.onMore = { id in more.append(id) }
        defer { popover.onChoose = sendChoice; popover.onMore = sendMore }
        // Keys go through the popover window's own dispatch, so they reach
        // the row only while it is that window's first responder.
        func press(_ code: UInt16, _ characters: String) {
            guard let rowWindow = popover.popover.contentViewController?.view.window, let event = InteractionSelfChecks.key(code, window: rowWindow, characters: characters) else { return }
            rowWindow.sendEvent(event)
        }
        owner.react(nil)
        let rowView = popover.popover.contentViewController?.view
        let focused = popover.isShown && popover.buttons.first?.isKeyboardFocused == true && rowView?.window?.firstResponder === rowView && (!NSApp.isActive || rowView?.window?.isKeyWindow == true)
        press(124, "\u{F703}"); press(36, "\r")
        results.append(("React… from the menu focuses the row; arrows and Return choose", focused && chosen == ["✅ \(entry.1.id)"] && !popover.isShown))
        owner.react(nil); press(20, "3")
        results.append(("number keys choose a reaction directly", chosen.last == "👀 \(entry.1.id)" && !popover.isShown))
        owner.react(nil); press(53, "\u{1b}")
        results.append(("Escape closes the row without reacting", chosen.count == 2 && !popover.isShown))
        owner.react(nil)
        for _ in 0...QuickReactions.slotCount { press(124, "\u{F703}") }
        press(36, "\r")
        results.append(("the keyboard reaches More Emoji…", more == [entry.1.id] && chosen.count == 2 && !popover.isShown))
        owner.react(nil)
        if let first = popover.buttons.first, let event = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            press(124, "\u{F703}")
            popover.buttons[2].mouseEntered(with: event); first.mouseEntered(with: event)
            press(36, "\r")
        }
        results.append(("pointer hover and the keyboard share one highlight, as in menus", chosen.last == "👍 \(entry.1.id)" && !popover.isShown))
        owner.react(nil); owner.cancelEmojiPicker()
        results.append(("closing or switching the conversation closes the row", !popover.isShown))

        // Losing access clears the transcript; the row and the hover bar
        // must not outlive the messages they point at.
        owner.react(nil)
        let openBeforeRevoke = popover.isShown
        session.revokedChannels.insert(entry.1.channelID); owner.render()
        let cleared = !popover.isShown && owner.hoverBar.isHidden
        session.revokedChannels.remove(entry.1.channelID); owner.render(); await owner.renderTask?.value
        results.append(("losing access to the conversation closes the row and hides the hover bar", openBeforeRevoke && cleared))
        return results
    }

    /// Exercises real reaction toggles against the loopback fixture started
    /// by `scripts/check-native-attachments.py --reactions`.
    static func runNetwork(app: AppDelegate, origin input: String) async throws -> [(String, Bool)] {
        let origin = try SiteOrigin.normalize(input, allowLocalHTTP: true)
        guard origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil else { throw AppError.message("Reaction checks require the local fixture runner.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreReactionNetworkCheck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(origin: origin, user: "reaction-fixture-user", siteName: "Local fixture", clientID: "local-fixture")
        let session = try AccountSession(account: account, directory: root)
        let channel = RavenChannel(raw: .object(["name": .string("reaction-fixture-channel"), "channel_name": .string("Reaction fixture"), "is_archived": .bool(false), "is_thread": .bool(false)]))
        let elsewhere = RavenChannel(raw: .object(["name": .string("reaction-fixture-elsewhere"), "channel_name": .string("Elsewhere"), "is_archived": .bool(false), "is_thread": .bool(false)]))
        session.channels = [channel, elsewhere]
        let owner = ConversationWindow(app: app, session: session)
        app.windows.append(owner)
        owner.showWindow(nil)
        defer { owner.close(); session.stop() }
        var results: [(String, Bool)] = []
        let messageID = "reaction-message-fixture"
        owner.select(channel)
        await owner.loadTask?.value
        let loaded = try await wait { owner.messageRanges.contains { $0.1.id == messageID } }
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        func reacted() -> Set<String> {
            owner.messageRanges.first { $0.1.id == messageID }.map { QuickReactions.reacted(by: account.user, in: $0.1.raw["message_reactions"]) } ?? ["missing"]
        }
        func stats() async throws -> JSONValue { try await session.client.rpc("nevermore_fixture.reaction_stats") }
        let popover = owner.quickReactions
        func openRow() -> Bool {
            owner.hideHoverBar()
            guard hover(owner, messageID: messageID) != nil else { return false }
            owner.hoverBar.reactButton?.performClick(nil)
            return popover.isShown && popover.messageID == messageID
        }

        _ = hover(owner, messageID: messageID)
        let usage = try await wait { session.quickReactionUsage.mostUsed == ["🚀", "👍"] }
        results.append(("most-used reactions load through the real transport", loaded && usage))
        guard openRow() else { results.append(("the fixture message opens a reaction row", false)); await session.client.invalidate(); return results }
        results.append(("the row puts the account's most-used reactions first", popover.emoji == ["🚀", "👍", "✅", "👀", "🎉", "🔥", "🤔", "❤️"] && !popover.buttons.contains { $0.isChosen }))

        popover.buttons[1].performClick(nil)
        await owner.reactionSends[messageID]?.value
        let added = try await wait { reacted() == ["👍"] }
        let first = try await stats()
        results.append(("one click sends one reaction toggle and shows the refreshed result", added && !popover.isShown && first["react_requests"] == .number(1) && first["last_reaction"] == .string("👍") && first["last_is_custom"] == .bool(false) && owner.transcript.string.contains("👍 1")))

        let reopened = openRow()
        let marked = reopened && popover.buttons[1].isChosen && popover.buttons[1].accessibilityLabel() == "Remove your 👍 reaction"
        if reopened { popover.buttons[1].performClick(nil) }
        await owner.reactionSends[messageID]?.value
        let removed = try await wait { reacted().isEmpty }
        let second = try await stats()
        results.append(("your reaction is marked in the row and a second click removes it", marked && removed && second["react_requests"] == .number(2)))

        owner.toggleQuickReaction("🎉", messageID: messageID)
        owner.toggleQuickReaction("🎉", messageID: messageID)
        await owner.reactionSends[messageID]?.value
        let single = try await wait { reacted() == ["🎉"] }
        let third = try await stats()
        results.append(("a toggle in flight blocks a second one", single && third["react_requests"] == .number(3)))

        // Choosing is the commitment: switching conversations right after
        // the click must not drop the reaction.
        owner.toggleQuickReaction("🔥", messageID: messageID)
        owner.select(elsewhere)
        await owner.reactionSends[messageID]?.value
        let fourth = try await stats()
        owner.select(channel)
        await owner.loadTask?.value
        let kept = try await wait { reacted() == ["🎉", "🔥"] }
        results.append(("a reaction chosen just before switching conversations is still sent", fourth["react_requests"] == .number(4) && fourth["last_reaction"] == .string("🔥") && kept))

        /// Reacts in a second window and closes it in the same turn, so
        /// that nothing but the send can keep that window alive.
        func reactAndClose(_ emoji: String) async throws -> Bool {
            let other = ConversationWindow(app: app, session: session)
            app.windows.append(other)
            other.showWindow(nil)
            other.select(channel)
            await other.loadTask?.value
            let ready = try await wait { other.messageRanges.contains { $0.1.id == messageID } }
            if ready { other.toggleQuickReaction(emoji, messageID: messageID) }
            other.close()
            return ready
        }
        let closed = try await reactAndClose("👀")
        var fifth = try await stats()
        for _ in 0..<300 where fifth["react_requests"] != .number(5) { try await Task.sleep(for: .milliseconds(10)); fifth = try await stats() }
        results.append(("a reaction chosen just before closing the window is still sent", closed && fifth["react_requests"] == .number(5) && fifth["last_reaction"] == .string("👀")))

        // Reactions to two messages each refresh the conversation. The
        // fixture holds the first refresh's answer, which predates the
        // second reaction, until the second one's own refresh has landed.
        let pair = RavenChannel(raw: .object(["name": .string("reaction-fixture-pair"), "channel_name": .string("Reaction pair"), "is_archived": .bool(false), "is_thread": .bool(false)]))
        let pairIDs = ["reaction-pair-first", "reaction-pair-second"]
        session.channels.append(pair)
        owner.select(pair)
        await owner.loadTask?.value
        let pairLoaded = try await wait { pairIDs.allSatisfy { id in owner.messageRanges.contains { $0.1.id == id } } }
        /// What the session holds, which is what the transcript draws next.
        func stored(_ id: String) -> Set<String> {
            session.memoryMessages[pair.id]?.first { $0.id == id }.map { QuickReactions.reacted(by: account.user, in: $0.raw["message_reactions"]) } ?? ["missing"]
        }
        _ = try await session.client.rpc("nevermore_fixture.hold_messages")
        owner.toggleQuickReaction("👍", messageID: pairIDs[0])
        var holding = try await stats()
        for _ in 0..<300 where holding["held_messages"] != .number(1) { try await Task.sleep(for: .milliseconds(10)); holding = try await stats() }
        owner.toggleQuickReaction("🎉", messageID: pairIDs[1])
        await owner.reactionSends[pairIDs[1]]?.value
        let overtaken = holding["held_messages"] == .number(1) && stored(pairIDs[1]) == ["🎉"]
        _ = try await session.client.rpc("nevermore_fixture.release_messages")
        await owner.reactionSends[pairIDs[0]]?.value
        results.append(("a slow refresh after one reaction does not hide a later reaction to another message", pairLoaded && overtaken && stored(pairIDs[0]) == ["👍"] && stored(pairIDs[1]) == ["🎉"]))

        // Each window can send a reaction, but both display the same session
        // snapshot. A stale answer from one must cover the other's toggle.
        let other = ConversationWindow(app: app, session: session)
        app.windows.append(other)
        other.showWindow(nil)
        defer { other.close() }
        other.select(pair)
        await other.loadTask?.value
        let otherLoaded = try await wait { pairIDs.allSatisfy { id in other.messageRanges.contains { $0.1.id == id } } }
        _ = try await session.client.rpc("nevermore_fixture.hold_messages")
        owner.toggleQuickReaction("🔥", messageID: pairIDs[0])
        holding = try await stats()
        for _ in 0..<300 where holding["held_messages"] != .number(2) { try await Task.sleep(for: .milliseconds(10)); holding = try await stats() }
        other.toggleQuickReaction("✅", messageID: pairIDs[1])
        await other.reactionSends[pairIDs[1]]?.value
        let crossWindowOvertaken = holding["held_messages"] == .number(2) && stored(pairIDs[1]) == ["🎉", "✅"]
        _ = try await session.client.rpc("nevermore_fixture.release_messages")
        await owner.reactionSends[pairIDs[0]]?.value
        let bothStored = stored(pairIDs[0]) == ["👍", "🔥"] && stored(pairIDs[1]) == ["🎉", "✅"]
        let bothRendered = try await wait {
            [owner, other].allSatisfy { window in
                pairIDs.allSatisfy { id in
                    guard let message = window.messageRanges.first(where: { $0.1.id == id })?.1 else { return false }
                    return QuickReactions.reacted(by: account.user, in: message.raw["message_reactions"]) == (id == pairIDs[0] ? ["👍", "🔥"] : ["🎉", "✅"])
                }
            }
        }
        results.append(("a slow reaction refresh in one window preserves a later reaction from another", otherLoaded && crossWindowOvertaken && bothStored && bothRendered))
        await session.client.invalidate()
        return results
    }
}
