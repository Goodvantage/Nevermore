import AppKit
import NevermoreCore
import RavenProtocol

/// Hidden-window checks that a transcript shows what the window decided to
/// show: the newest messages after a send, and a requested message as soon
/// as the cache has it. Disposable demo store; nothing reaches a server.
@MainActor enum TranscriptPlacementSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermorePlacementCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "placement-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        let channel = RavenChannel(raw: .object(["name": .string("placement-fixture"), "channel_name": .string("Placement fixture")]))
        let other = RavenChannel(raw: .object(["name": .string("placement-other"), "channel_name": .string("Placement other")]))
        session.channels = [channel, other]
        // More than one window of 500 messages, so a view can end before
        // the newest message.
        let count = 700, otherCount = 300
        func row(_ index: Int, channelID: String, prefix: String) -> RavenMessage {
            RavenMessage(raw: .object(["name": .string("\(prefix)-\(index)"), "channel_id": .string(channelID), "owner": .string("other-fixture@example.invalid"), "creation": .string(String(format: "2026-11-08 12:%02d:%02d.000000", index / 60, index % 60)), "text": .string("<p>Fixture message \(index) of the placement checks.</p>"), "message_type": .string("Text")]))
        }
        try await session.store.cacheMessages((0..<count).map { row($0, channelID: channel.id, prefix: "placement") })
        try await session.store.cacheMessages((0..<otherCount).map { row($0, channelID: other.id, prefix: "placement-other") })
        for fixture in [channel, other] { session.recordTranscriptVisit(.timestamp("2026-11-08 13:00:00"), channelID: fixture.id) }
        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        guard let window = controller.window else { return [("placement fixture has a window", false)] }
        func settle() { window.contentView?.layoutSubtreeIfNeeded() }
        func rendered() async { await controller.loadTask?.value; await controller.renderTask?.value; settle() }
        window.setFrame(NSRect(x: 0, y: 0, width: 1080, height: 760), display: false); settle()
        controller.select(channel)
        await rendered()

        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        let clip = controller.transcriptScroll.contentView
        let newest = "placement-\(count - 1)"
        func scroll(to y: CGFloat) {
            clip.scroll(to: NSPoint(x: 0, y: y)); controller.transcriptScroll.reflectScrolledClipView(clip)
            controller.seenVisible()
        }
        /// The conversation's newest message ends inside the band above the composer.
        func showsNewest() -> Bool {
            guard let last = controller.messageRanges.last, last.1.id == newest else { return false }
            return controller.rect(for: last.0).maxY <= controller.readableTranscriptRect.maxY + 1 && controller.isFollowing && controller.jumpLatestButton.isHidden
        }
        func isInView(_ id: String) -> Bool {
            guard let range = controller.messageRanges.first(where: { $0.1.id == id })?.0 else { return false }
            let rect = controller.rect(for: range), readable = controller.readableTranscriptRect
            return rect.minY >= readable.minY - 1 && rect.maxY <= readable.maxY + 1
        }
        check("the placement fixture opens on the newest of more messages than one view holds", controller.messages.count == 500 && showsNewest())

        // A demo session does not send, so these start where a send was
        // accepted: the window is told so and the session announces a change.
        controller.isFollowing = false; controller.historyUpperID = "placement-300"
        controller.render(); await rendered()
        let readsHistory = controller.messages.last?.id == "placement-300" && !controller.isFollowing
        controller.sendWasAccepted(); session.notify()
        await rendered()
        check("a message sent from a page of history shows the newest messages", readsHistory && controller.historyUpperID == nil && showsNewest())

        controller.select(channel, anchor: "placement-100")
        await rendered()
        let readsContext = controller.requestedAnchor == "placement-100" && controller.messages.contains { $0.id == "placement-100" } && controller.messages.last?.id != newest
        controller.sendWasAccepted(); session.notify()
        await rendered()
        check("a message sent from the context of an opened message shows the newest messages", readsContext && controller.requestedAnchor == nil && showsNewest())

        // The answer to an opened message arrives after the send: the
        // window has moved on and does not go back to that message.
        controller.select(channel, anchor: "placement-400")
        controller.sendWasAccepted(); session.notify()
        await rendered()
        check("a message opened just before a send does not take the pane back from the sent message", controller.requestedAnchor == nil && showsNewest())
        // Go ▸ Back restores a message at its pixel offset once the
        // conversation has loaded, in a task of its own: let that run.
        controller.restoreLocation(ConversationLocation(channelID: channel.id, anchorMessageID: "placement-400", pixelOffset: 10))
        controller.sendWasAccepted(); session.notify()
        await rendered()
        await controller.restoreLocationTask?.value
        settle()
        check("a location restored just before a send does not take the pane back from the sent message", controller.requestedAnchor == nil && showsNewest())

        scroll(to: controller.minimumTranscriptOrigin + 60)
        let readsEarlier = !controller.isFollowing
        controller.sendWasAccepted()
        scroll(to: clip.bounds.minY + 40)
        session.notify()
        await rendered()
        check("a scroll between an accepted send and its render does not hide the sent message", readsEarlier && showsNewest())

        // Opening a message from search or the inbox: the cache has it, so
        // it is shown at once. The server's answer is cancelled here to see
        // the pane as it is while that answer is on its way.
        scroll(to: controller.minimumTranscriptOrigin + 60)
        let target = "placement-other-250"
        controller.select(other, anchor: target)
        controller.loadTask?.cancel()
        await rendered()
        check("a cached message opened from another conversation is in view before the server answers", controller.channel?.id == other.id && isInView(target) && !controller.isFollowing)
        controller.select(channel, anchor: "placement-400")
        await rendered()
        let selected = controller.messageRanges.first { $0.1.id == "placement-400" }?.0
        check("a message opened from another conversation is in view and selected once the server answered", isInView("placement-400") && selected != nil && controller.transcript.selectedRange() == selected && !controller.isFollowing)
        // The same in the conversation already on screen, where the rows
        // in view could be held on to instead.
        controller.select(channel, anchor: "placement-250")
        controller.loadTask?.cancel()
        await rendered()
        check("a cached message opened in the conversation on screen is in view before the server answers", controller.requestedAnchor == "placement-250" && isInView("placement-250") && !controller.isFollowing)

        // Go ▸ Back puts a message back at the offset it had below the top
        // of the pane. From the cache at once: the server's answer and the
        // task that waits for it are both cancelled here.
        func isAtOffset(_ id: String, _ offset: CGFloat) -> Bool {
            guard let range = controller.messageRanges.first(where: { $0.1.id == id })?.0 else { return false }
            return abs(clip.bounds.minY - max(controller.minimumTranscriptOrigin, controller.rect(for: range).minY - offset)) < 1
        }
        controller.restoreLocation(ConversationLocation(channelID: other.id, anchorMessageID: "placement-other-100", pixelOffset: 10))
        controller.loadTask?.cancel(); controller.restoreLocationTask?.cancel()
        await rendered()
        check("a restored location shows a cached message at its remembered offset before the server answers", controller.channel?.id == other.id && isAtOffset("placement-other-100", 10) && !controller.isFollowing)
        controller.restoreLocation(ConversationLocation(channelID: channel.id, anchorMessageID: "placement-400", pixelOffset: 10))
        await rendered()
        await controller.restoreLocationTask?.value
        settle()
        check("a restored location is at its remembered offset once the server answered", controller.requestedAnchor == "placement-400" && isAtOffset("placement-400", 10) && !controller.isFollowing)
        return checks
    }
}
