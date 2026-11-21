import AppKit
import NevermoreCore
import RavenProtocol

/// Checks that the binary-searched visible messages are exactly the ones a
/// full scan finds, across a long mixed transcript. Hidden window,
/// disposable store, demo wire.
@MainActor enum VisibleMessageSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreVisibleMessageCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "visible-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        session.demoWire = DemoWire(session: session)
        let channel = RavenChannel(raw: .object(["name": .string("visible"), "channel_name": .string("visible")]))
        session.channels = [channel]
        let bodies = ["<p>Short.</p>", "<p>A longer message that wraps onto a second line in a normal window, so rows differ in height.</p>", "<pre><code>let a = 1\nlet b = 2\nlet c = 3</code></pre>", "<ul><li>one</li><li>two</li></ul>", "<blockquote><p>Quoted</p></blockquote><p>Reply</p>"]
        var rows: [RavenMessage] = []
        for index in 0..<160 {
            rows.append(RavenMessage(raw: .object(["name": .string("v\(index)"), "channel_id": .string(channel.id), "owner": .string(index % 3 == 0 ? "a@example.invalid" : "b@example.invalid"),
                "creation": .string(String(format: "2026-11-%02d %02d:%02d:00.000000", 3 + index / 40, 8 + (index % 40) / 4, (index % 4) * 15)), "text": .string(bodies[index % bodies.count]), "message_type": .string("Text")])))
        }
        try await session.store.cacheMessages(rows)
        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.select(channel)
        await controller.loadTask?.value; await controller.renderTask?.value
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        let height = controller.transcript.bounds.height
        let width = controller.transcript.bounds.width
        var agree = controller.messageRanges.count == rows.count
        var bands = 0
        var y: CGFloat = -50
        while y < height + 50 {
            let band = NSRect(x: 0, y: y, width: width, height: 37 + abs(y.truncatingRemainder(dividingBy: 300)))
            let searched = controller.messageEntries(intersecting: band).map(\.1.id)
            let scanned = controller.messageRanges.filter { band.intersects(controller.rect(for: $0.0)) }.map(\.1.id)
            if searched != scanned { agree = false; print("DIAGNOSTIC visible search y=\(y) searched=\(searched) scanned=\(scanned)") }
            bands += 1; y += 61
        }
        check("the searched visible messages match a full scan in every band of a long transcript", agree && bands > 20)
        check("a band below the text has no visible messages", controller.messageEntries(intersecting: NSRect(x: 0, y: height + 100, width: width, height: 200)).isEmpty)
        check("the read receipt still names the bottom visible message", { () -> Bool in
            let readable = controller.readableTranscriptRect
            let searched = controller.messageEntries(intersecting: readable).last?.1.id
            return searched != nil && searched == controller.messageRanges.last { readable.intersects(controller.rect(for: $0.0)) }?.1.id
        }())
        return checks
    }
}
