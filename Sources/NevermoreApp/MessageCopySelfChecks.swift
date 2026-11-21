import AppKit
import NevermoreCore
import RavenProtocol

/// Hidden-window checks of Copy Message Text: the selected message reaches
/// a private pasteboard as plain text, with spoilers masked, without the
/// reader selecting its text. Uses a disposable store and the demo wire.
@MainActor enum MessageCopySelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreMessageCopyCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "copy-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        session.demoWire = DemoWire(session: session)
        let channel = RavenChannel(raw: .object(["name": .string("copying"), "channel_name": .string("copying")]))
        session.channels = [channel]
        func message(_ id: String, _ fields: [String: JSONValue]) -> RavenMessage {
            let base: [String: JSONValue] = ["name": .string(id), "channel_id": .string(channel.id), "owner": .string("other-fixture@example.invalid"), "creation": .string("2026-11-08 12:00:00.000000"), "message_type": .string("Text")]
            return RavenMessage(raw: .object(base.merging(fields) { _, new in new }))
        }
        try await session.store.cacheMessages([
            message("formatted", ["text": .string(#"<p>Ship <strong>today</strong>, the code is <span data-spoiler="true">hunter2</span>.</p>"#)]),
            message("file", ["text": .string(""), "message_type": .string("File"), "file": .string("/private/files/report%20final.pdf")])
        ])

        let controller = ConversationWindow(app: app, session: session)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NevermoreMessageCopyCheck-\(UUID())"))
        defer { pasteboard.releaseGlobally(); controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.select(channel)
        await controller.loadTask?.value; await controller.renderTask?.value
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        func select(_ id: String) { if let range = controller.messageRanges.first(where: { $0.1.id == id })?.0 { controller.transcript.setSelectedRange(NSRange(location: range.location, length: 0)) } }

        select("formatted")
        let item = NSMenuItem(title: "Copy Message Text", action: #selector(ConversationWindow.copyMessageText(_:)), keyEquivalent: "")
        check("Copy Message Text is available with only a caret in the message", controller.transcript.selectedRange().length == 0 && controller.validateMenuItem(item))
        controller.copyMessageText(to: pasteboard)
        check("Copy Message Text copies the message as plain text with its spoiler masked", pasteboard.string(forType: .string) == "Ship today, the code is [Spoiler].")
        select("file")
        controller.copyMessageText(to: pasteboard)
        check("Copy Message Text names a file message's attachment", pasteboard.string(forType: .string) == "[Attachment: report final.pdf]")
        check("the message's context menu offers Copy Text", controller.messageContextMenu()?.items.contains { $0.action == #selector(ConversationWindow.copyMessageText(_:)) && $0.title == "Copy Text" } == true)
        controller.transcript.setSelectedRange(NSRange(location: controller.transcript.string.utf16.count, length: 0))
        check("Copy Message Text is unavailable without a message under the caret", controller.selectedMessage == nil && !controller.validateMenuItem(item))
        select("file")
        let transcriptItem = NSMenuItem(title: "Copy Transcript", action: #selector(ConversationWindow.copyTranscript(_:)), keyEquivalent: "")
        func checkCopyBlocked(_ label: String) {
            pasteboard.clearContents()
            pasteboard.setString("unchanged", forType: .string)
            let revision = pasteboard.changeCount
            controller.copyMessageText(to: pasteboard)
            controller.copyFullTranscript(to: pasteboard)
            check(label, !controller.validateMenuItem(item) && !controller.validateMenuItem(transcriptItem) && pasteboard.changeCount == revision)
        }
        let parent = "parent"
        session.channels = [RavenChannel(raw: .object(["name": .string(channel.id), "channel_name": .string("copying"), "parent_channel_id": .string(parent)]))]
        controller.refreshSidebar()
        session.revokedChannels.insert(parent)
        checkCopyBlocked("copy commands respect parent access learned from the refreshed channel")
        session.revokedChannels.remove(parent)
        session.revokedChannels.insert(channel.id)
        check("a revoked message cannot be copied from the menu", !controller.validateMenuItem(item))
        let other = RavenChannel(raw: .object(["name": .string("other"), "channel_name": .string("other")]))
        controller.select(other)
        checkCopyBlocked("copy commands leave the pasteboard alone while the previous channel is still displayed")
        await controller.loadTask?.value; await controller.renderTask?.value
        return checks
    }
}
