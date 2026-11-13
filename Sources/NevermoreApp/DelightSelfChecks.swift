import AppKit
import NevermoreCore
import RavenProtocol

/// Hidden-window checks of the ravens on unread conversations and of
/// reactions handled as stickers. They use a disposable store and the
/// demo's local wire; nothing reaches a server. Automated runs cut every
/// animation, so these check state, not motion.
@MainActor enum DelightSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreDelightCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "delight-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        session.demoWire = DemoWire(session: session)
        func channel(_ id: String, _ extra: [String: JSONValue] = [:]) -> RavenChannel {
            RavenChannel(raw: .object(["name": .string(id), "channel_name": .string(id)].merging(extra) { _, new in new }))
        }
        let reading = channel("a-reading"), unread = channel("b-unread"), muted = channel("c-muted", ["muted": .bool(true)])
        let direct = channel("d-direct", ["is_direct_message": .bool(true), "peer_user_id": .string("other-fixture@example.invalid")])
        session.channels = [reading, unread, muted, direct]
        func message(_ id: String, in channelID: String, reactions: String? = nil) -> RavenMessage {
            var fields: [String: JSONValue] = ["name": .string(id), "channel_id": .string(channelID), "owner": .string("other-fixture@example.invalid"), "creation": .string("2026-11-08 12:00:00.000000"), "text": .string("<p>Fixture \(id)</p>"), "message_type": .string("Text")]
            if let reactions { fields["message_reactions"] = .string(reactions) }
            return RavenMessage(raw: .object(fields))
        }
        try await session.store.cacheMessages([
            message("delight-1", in: reading.id, reactions: #"{"👍": {"count": 1, "users": ["other-fixture@example.invalid"], "reaction": "👍"}}"#),
            message("delight-2", in: unread.id)
        ])
        func setUnread(_ counts: [(String, Double)]) {
            session.unread = .array(counts.map { .object(["name": .string($0.0), "unread_count": .number($0.1)]) })
            session.notify()
        }
        session.unread = .array([(unread.id, 2.0), (muted.id, 5.0), (direct.id, 1.0)].map { .object(["name": .string($0.0), "unread_count": .number($0.1)]) })

        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.select(reading)
        await controller.loadTask?.value; await controller.renderTask?.value
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        func cell(_ channel: RavenChannel) -> SidebarConversationCell? {
            guard let row = controller.sidebarItems.firstIndex(where: { $0.1?.id == channel.id }) else { return nil }
            let cell = controller.sidebar.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarConversationCell
            cell?.layoutSubtreeIfNeeded()
            return cell
        }

        // Ravens.
        check("an unread conversation has a raven on its row, a read one does not", cell(unread)?.perch.isHidden == false && cell(reading)?.perch.isHidden == true)
        check("a muted conversation keeps its count without a raven", cell(muted)?.perch.isHidden == true && controller.unreadCount(muted.id) == 5)
        check("a direct message's raven has a lit eye, a channel's does not", controller.unkindness.bird(for: direct)?.lit == true && controller.unkindness.bird(for: unread)?.lit == false)
        session.mentionedChannels.insert(unread.id)
        check("a mention lights the eye of a channel's raven", controller.unkindness.bird(for: unread)?.lit == true)
        session.mentionedChannels.remove(unread.id)
        check("the raven leaves the row's VoiceOver label as it was", cell(unread)?.accessibilityLabel() == "b-unread, 2 unread" && cell(unread)?.perch.isAccessibilityElement() == false)
        check("the raven stands beside the count without covering the title", { () -> Bool in
            guard let cell = cell(unread) else { return false }
            let perch = cell.perch.frame
            return perch.width == RavenFigure.size.width && perch.maxX <= cell.bounds.maxX && perch.minX > cell.bounds.midX
        }())

        // Space reads on.
        controller.readOn()
        await controller.loadTask?.value; await controller.renderTask?.value
        check("Space at the end of a conversation opens the next unread one", controller.channel?.id == unread.id)
        setUnread([(muted.id, 5)])
        controller.readOn()
        check("Space with nothing left to read stays where it is", controller.channel?.id == unread.id)

        // The footer.
        let footer = controller.connectionFooter
        let state = footer.label.stringValue
        setUnread([])
        check("reading the last unread conversation leaves the connection status visible", footer.label.stringValue == state && footer.accessibilityLabel()?.hasPrefix("Connection:") == true)
        check("the connection footer has no farewell bird", !footer.subviews.contains { $0 is RavenPerchView })
        check("unread birds have no flight overlay in the conversation pane", !controller.contentController.view.subviews.contains { $0 is AviaryView })
        setUnread([(direct.id, 1)])
        check("marking a conversation unread again restores its sidebar bird", cell(direct)?.perch.isHidden == false && cell(direct)?.perch.isAway == false)
        setUnread([])
        session.notify()
        check("repeated read updates leave the bird gone and the footer unchanged", cell(direct)?.perch.isHidden == true && footer.label.stringValue == state)

        // Stickers.
        controller.select(reading)
        await controller.loadTask?.value; await controller.renderTask?.value
        func mine() -> Set<String> {
            QuickReactions.reacted(by: account.user, in: controller.messages.first { $0.id == "delight-1" }?.raw["message_reactions"] ?? .null)
        }
        /// Waits for the toggle and for the transcript to show `expected`.
        func settle(_ expected: Set<String>) async throws {
            for task in controller.reactionSends.values { await task.value }
            for _ in 0..<300 where mine() != expected || !controller.reactionSends.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            await controller.renderTask?.value
        }
        let layout = controller.transcript.layoutManager as? TranscriptLayoutManager
        check("the transcript can veil glyphs without changing layout", { () -> Bool in
            guard let layout, let container = controller.transcript.textContainer, let storage = controller.transcript.textStorage, storage.length > 4 else { return false }
            let before = layout.usedRect(for: container)
            layout.veiled = [NSRange(location: 1, length: 3)]
            controller.transcript.display()
            let same = layout.usedRect(for: container) == before
            layout.veiled = []
            return same
        }())
        let chip = controller.stickers.chipFrames.first { $0.messageID == "delight-1" && $0.label == "👍" }
        check("a reaction chip is found where the transcript draws it", chip.map { $0.rect.width > 20 && $0.rect.height > 10 } == true)
        if let chip {
            let point = NSPoint(x: chip.rect.midX, y: chip.rect.midY)
            let added = controller.stickers.clickChip(at: point)
            try await settle(["👍"])
            check("clicking someone's reaction adds yours", added && mine() == ["👍"])
            check("an added reaction can be undone from the composer and the transcript", controller.composer.undoManager?.undoMenuItemTitle == "Undo Reaction" && controller.transcript.undoManager === controller.composer.undoManager)
            controller.composer.undoManager?.undo()
            try await settle([])
            check("Undo takes the reaction back", mine().isEmpty)
            check("a taken-back reaction leaves nothing to undo twice", controller.composer.undoManager?.canUndo == false)
            let again = controller.stickers.chipFrames.first { $0.messageID == "delight-1" && $0.label == "👍" }
            if let again {
                controller.stickers.clickChip(at: NSPoint(x: again.rect.midX, y: again.rect.midY)); try await settle(["👍"])
                let on = mine() == ["👍"]
                let yours = controller.stickers.chipFrames.first { $0.messageID == "delight-1" && $0.label == "👍" }
                if let yours { controller.stickers.clickChip(at: NSPoint(x: yours.rect.midX, y: yours.rect.midY)) }
                try await settle([])
                check("clicking your own reaction removes it", on && mine().isEmpty)
            } else { check("clicking your own reaction removes it", false) }
            check("a click beside the chips is left to the text", !controller.stickers.clickChip(at: NSPoint(x: chip.rect.maxX + 60, y: chip.rect.midY)))
        }
        if let target = controller.messages.first(where: { $0.id == "delight-1" }) {
            controller.stickers.toss("🎉", from: nil, to: target); try await settle(["🎉"])
            check("choosing an emoji in the quick row still reacts with one toggle", mine() == ["🎉"])
            let stored = controller.messages.first { $0.id == "delight-1" }?.raw["message_reactions"].nested["🎉"]
            check("the demo keeps reactions in Raven's shape", stored?["count"] == .number(1) && stored?["users"].array == [.string(account.user)] && stored?["reaction"] == .string("🎉"))
        }
        check("automated runs leave no sticker or bird in the air", controller.stickers.overlay.layer?.sublayers?.isEmpty != false && controller.unkindness.sidebarAir.layer?.sublayers?.isEmpty != false)
        return checks
    }
}
