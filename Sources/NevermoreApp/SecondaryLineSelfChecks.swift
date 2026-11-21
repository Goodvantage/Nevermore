import AppKit
import NevermoreCore
import RavenProtocol

/// Hidden-window checks that the lines annotating a message (linked
/// document, code block header) and the unread divider use the reading
/// font and follow the reading size. Uses a disposable store, the demo
/// wire, and restores the reading size it changes.
@MainActor enum SecondaryLineSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreSecondaryLineCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "lines-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        session.demoWire = DemoWire(session: session)
        let channel = RavenChannel(raw: .object(["name": .string("lines"), "channel_name": .string("lines")]))
        session.channels = [channel]
        func message(_ id: String, _ fields: [String: JSONValue]) -> RavenMessage {
            let base: [String: JSONValue] = ["name": .string(id), "channel_id": .string(channel.id), "owner": .string("other-fixture@example.invalid"), "creation": .string("2026-11-08 12:00:00.000000"), "message_type": .string("Text")]
            return RavenMessage(raw: .object(base.merging(fields) { _, new in new }))
        }
        try await session.store.cacheMessages([
            message("linked", ["text": .string("<p>See the order</p>"), "link_doctype": .string("Sales Order"), "link_document": .string("SO-0001")]),
            message("code", ["text": .string("<pre><code>let one = 1</code></pre>")])
        ])
        let defaults = UserDefaults.standard
        let storedSize = defaults.object(forKey: "fontSize")
        let controller = ConversationWindow(app: app, session: session)
        defer {
            if let storedSize { defaults.set(storedSize, forKey: "fontSize") } else { defaults.removeObject(forKey: "fontSize") }
            controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory)
        }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        func font(of text: String) -> NSFont? {
            let storage = controller.transcript.attributedString()
            let range = (storage.string as NSString).range(of: text)
            guard range.location != NSNotFound else { return nil }
            return storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        }
        for size: CGFloat in [13, 24] {
            defaults.set(Double(size), forKey: "fontSize")
            controller.select(channel)
            await controller.loadTask?.value; await controller.renderTask?.value
            controller.render(); await controller.renderTask?.value
            let expected = max(11, size - 2)
            let linked = font(of: "Linked document: Sales Order")
            check("the linked document line uses the system font at \(Int(expected)) pt for \(Int(size)) pt text", linked?.familyName == NSFont.systemFont(ofSize: expected).familyName && linked?.pointSize == expected)
            check("a one-line code block says 1 line at \(Int(size)) pt", controller.transcript.string.contains("Code · 1 line · ") && !controller.transcript.string.contains("1 lines"))
            let divider = TranscriptStyle.unreadDivider(metrics: TranscriptMetrics(size: size, compact: false))
            let dividerFont = divider.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            check("the unread divider follows the reading size at \(Int(size)) pt", dividerFont?.pointSize == expected)
        }
        return checks
    }
}
