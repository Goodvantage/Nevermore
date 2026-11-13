import AppKit
import NevermoreCore
import RavenProtocol

/// The same site can be open under two accounts, so message identifiers
/// alone cannot identify the account whose reaction Undo should remove.
@MainActor enum ReactionUndoSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreReactionUndoCheck-\(UUID())")
        let origin = URL(string: "https://demo.invalid")!
        let account = Account(origin: origin, user: "reaction-a@example.invalid", siteName: "Fixture", clientID: "demo")
        let otherAccount = Account(origin: origin, user: "reaction-b@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        let other = try AccountSession(account: otherAccount, directory: directory.appendingPathComponent("other"), demo: true)
        session.demoWire = DemoWire(session: session); other.demoWire = DemoWire(session: other)
        let channel = RavenChannel(raw: .object(["name": .string("same-channel"), "channel_name": .string("Shared Channel")]))
        func message(user: String) -> RavenMessage {
            RavenMessage(raw: .object([
                "name": .string("same-message"), "channel_id": .string(channel.id),
                "owner": .string("author@example.invalid"), "creation": .string("2026-11-08 12:00:00.000000"),
                "text": .string("<p>Shared message.</p>"), "message_type": .string("Text"),
                "message_reactions": .object(["👍": .object(["count": .number(1), "users": .array([.string(user)]), "reaction": .string("👍")])])
            ]))
        }
        let original = message(user: account.user)
        session.channels = [channel]; other.channels = [channel]
        try await session.store.cacheMessages([original])
        try await other.store.cacheMessages([message(user: otherAccount.user)])
        let source = ConversationWindow(app: app, session: session)
        let peer = ConversationWindow(app: app, session: session)
        app.windows.append(contentsOf: [source, peer])
        defer { source.close(); peer.close(); session.stop(); other.stop(); try? FileManager.default.removeItem(at: directory) }
        source.select(channel); peer.select(channel)
        await source.loadTask?.value; await source.renderTask?.value
        await peer.loadTask?.value; await peer.renderTask?.value
        guard let undo = session.draftUndoManagers[channel.id] else { throw AppError.message("Missing reaction undo manager.") }
        undo.removeAllActions(); undo.beginUndoGrouping(); source.stickers.registerUndo("👍", on: original); undo.endUndoGrouping()
        source.session = other
        source.select(channel)
        await source.loadTask?.value; await source.renderTask?.value
        undo.undo()
        func reacted(in session: AccountSession) async throws -> Bool {
            let rows = try await session.cachedMessages(channelID: channel.id)
            return QuickReactions.reacted(by: session.account.user, in: rows.first { $0.id == original.id }?.raw["message_reactions"] ?? .null).contains("👍")
        }
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(10))
            let originalHasReaction = try await reacted(in: session)
            let otherHasReaction = try await reacted(in: other)
            if !originalHasReaction || !otherHasReaction { break }
        }
        let originalStillReacted = try await reacted(in: session)
        let otherStillReacted = try await reacted(in: other)
        return [("Undo Reaction from a shared conversation acts on its original account after the registering window switches accounts", !originalStillReacted && otherStillReacted)]
    }
}
