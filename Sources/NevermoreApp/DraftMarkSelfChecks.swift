import AppKit
import NevermoreCore
import RavenProtocol

/// Hidden-window checks of the sidebar's draft pencil: it marks other
/// conversations whose saved draft holds something, follows saves and
/// clears, and stays off the conversation on screen. Disposable store,
/// demo wire.
@MainActor enum DraftMarkSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreDraftMarkCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "draft-mark-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        session.demoWire = DemoWire(session: session)
        func channel(_ id: String) -> RavenChannel { RavenChannel(raw: .object(["name": .string(id), "channel_name": .string(id)])) }
        let reading = channel("a-reading"), other = channel("b-other")
        session.channels = [reading, other]
        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.select(reading)
        await controller.loadTask?.value; await controller.renderTask?.value
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        func cell(_ channel: RavenChannel) -> SidebarConversationCell? {
            guard let row = controller.sidebarItems.firstIndex(where: { $0.channel?.id == channel.id }) else { return nil }
            return controller.sidebar.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarConversationCell
        }
        func pencil(_ channel: RavenChannel) -> Bool { cell(channel).map { $0.showsDraftMark && $0.accessibilityLabel()?.contains(", draft") == true } ?? false }
        func settle(_ condition: () -> Bool) async { for _ in 0..<40 where !condition() { try? await Task.sleep(for: .milliseconds(25)) } }

        check("no conversation has a pencil before anything is written", !pencil(reading) && !pencil(other))
        try await session.save(Draft(channelID: other.id, html: "<p>Later, about the release</p>"))
        await settle { session.draftChannelIDs.contains(other.id) && pencil(other) }
        check("saving a draft in another conversation marks its row with a pencil", session.draftChannelIDs.contains(other.id) && pencil(other))
        try await session.save(Draft(channelID: reading.id, html: "<p>Typing here</p>"))
        await settle { session.draftChannelIDs.contains(reading.id) }
        check("the conversation on screen shows no pencil for its own draft", session.draftChannelIDs.contains(reading.id) && !pencil(reading))
        controller.select(other)
        await controller.loadTask?.value; await controller.renderTask?.value
        check("leaving a conversation with a draft marks its row", pencil(reading) && !pencil(other))
        try await session.save(Draft(channelID: reading.id, html: "<p> </p>"))
        await settle { !session.draftChannelIDs.contains(reading.id) && !pencil(reading) }
        check("emptying a draft removes its pencil", !session.draftChannelIDs.contains(reading.id) && !pencil(reading))
        await session.loadDraftMarks()
        check("draft marks load from the store", session.draftChannelIDs == [other.id])
        check("only drafts with content count", !AccountSession.holdsContent(Draft(channelID: "x", html: "<p>  </p>")) && AccountSession.holdsContent(Draft(channelID: "x", html: "<p>x</p>")))
        return checks
    }
}
