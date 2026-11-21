import AppKit
import NevermoreCore
import RavenProtocol

/// Hidden-window checks of the Pinned and Saved marks after a message's
/// text and of the message commands that toggle them. They use a disposable
/// store and the demo's local wire; nothing reaches a server.
@MainActor enum MessageMarkSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreMessageMarkCheck-\(UUID())")
        let user = "marks-fixture@example.invalid"
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: user, siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        session.demoWire = DemoWire(session: session)
        let channel = RavenChannel(raw: .object(["name": .string("marks"), "channel_name": .string("marks"), "pinned_messages_string": .string("pinned-1\nboth-1")]))
        session.channels = [channel]
        func message(_ id: String, savedBy: [String] = []) -> RavenMessage {
            var fields: [String: JSONValue] = ["name": .string(id), "channel_id": .string(channel.id), "owner": .string("other-fixture@example.invalid"), "creation": .string("2026-11-08 12:00:00.000000"), "text": .string("<p>Body of \(id)</p>"), "message_type": .string("Text")]
            if !savedBy.isEmpty, let data = try? JSONEncoder().encode(savedBy), let text = String(data: data, encoding: .utf8) { fields["_liked_by"] = .string(text) }
            return RavenMessage(raw: .object(fields))
        }
        try await session.store.cacheMessages([
            message("plain-1"),
            message("saved-1", savedBy: [user]),
            message("pinned-1"),
            message("both-1", savedBy: ["someone@example.invalid", user]),
            message("other-saved-1", savedBy: ["someone@example.invalid"])
        ])

        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.select(channel)
        await controller.loadTask?.value; await controller.renderTask?.value
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        let text = controller.transcript.string as NSString
        func shown(_ id: String) -> String {
            guard let range = controller.messageRanges.first(where: { $0.1.id == id })?.0 else { return "" }
            return text.substring(with: range)
        }

        check("a message saved by the reader says Saved after its text", shown("saved-1").contains("Body of saved-1  \u{FFFC} Saved") && !shown("saved-1").contains("Pinned"))
        check("a pinned message says Pinned after its text", shown("pinned-1").contains("Body of pinned-1  \u{FFFC} Pinned") && !shown("pinned-1").contains("Saved"))
        check("a message both pinned and saved says both", shown("both-1").contains("Pinned") && shown("both-1").contains("Saved"))
        check("a message saved only by someone else and a plain one carry no mark", !shown("other-saved-1").contains("Saved") && !shown("plain-1").contains("Saved") && !shown("plain-1").contains("Pinned"))
        check("each mark has a symbol in front of its word", shown("both-1").filter { $0 == "\u{FFFC}" }.count == 2)

        // Copies keep the message, not the marks.
        if let range = controller.messageRanges.first(where: { $0.1.id == "both-1" })?.0 {
            let exported = NSMutableAttributedString(attributedString: controller.transcript.attributedString().attributedSubstring(from: range))
            TranscriptView.prepareForExport(exported)
            check("copying a marked message leaves the marks out", exported.string.contains("Body of both-1") && !exported.string.contains("Pinned") && !exported.string.contains("Saved") && !exported.string.contains("\u{FFFC}"))
        } else { check("copying a marked message leaves the marks out", false) }

        // Commands follow the selected message's state.
        func select(_ id: String) { if let range = controller.messageRanges.first(where: { $0.1.id == id })?.0 { controller.transcript.setSelectedRange(NSRange(location: range.location, length: 0)) } }
        func title(_ action: Selector) -> String {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            _ = controller.validateMenuItem(item)
            return item.title
        }
        select("saved-1")
        check("the Message menu offers Remove from Saved for a saved message", title(#selector(ConversationWindow.saveForLater(_:))) == "Remove from Saved")
        check("the Message menu offers Pin Message for an unpinned message", title(#selector(ConversationWindow.pin(_:))) == "Pin Message")
        select("pinned-1")
        check("the Message menu offers Save for Later for an unsaved message", title(#selector(ConversationWindow.saveForLater(_:))) == "Save for Later")
        check("the Message menu offers Unpin Message for a pinned message", title(#selector(ConversationWindow.pin(_:))) == "Unpin Message")
        let context = controller.messageContextMenu()?.items.map(\.title) ?? []
        check("the message's context menu names the same commands", context.contains("Save for Later") && context.contains("Unpin Message"))
        session.channels = []
        check("the current conversation keeps the same pin source after the list empties", title(#selector(ConversationWindow.pin(_:))) == "Unpin Message")
        let thread = RavenMessage(raw: .object(["name": .string("thread-reply"), "channel_id": .string("unlisted-thread")]))
        check("a message outside the channel list keeps the neutral pin title", ConversationWindow.pinTitle(pinned: controller.isPinned(thread)) == "Pin / Unpin Message")
        return checks
    }
}
