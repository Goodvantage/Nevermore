import AppKit
import RavenProtocol

/// Exercises real AppKit controls and Raven transport against a credential-free
/// loopback fixture. This session never starts realtime or enters the account list.
@MainActor enum PollNetworkSelfChecks {
    static func run(app: AppDelegate, origin input: String) async throws -> [(String, Bool)] {
        let origin = try SiteOrigin.normalize(input, allowLocalHTTP: true)
        guard origin.scheme == "http", origin.host == "127.0.0.1", origin.port != nil else { throw AppError.message("Poll checks require the local fixture runner.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermorePollNetworkCheck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(origin: origin, user: "poll-fixture-user", siteName: "Local fixture", clientID: "local-fixture")
        let session = try AccountSession(account: account, directory: root)
        let channel = RavenChannel(raw: .object(["name": .string("poll-fixture-channel"), "channel_name": .string("Local fixture"), "is_archived": .bool(false), "is_thread": .bool(false)]))
        session.channels = [channel]
        let owner = ConversationWindow(app: app, session: session)
        owner.channel = channel
        app.windows.append(owner)
        owner.showWindow(nil)
        let message = RavenMessage(raw: .object(["name": .string("poll-message-fixture"), "channel_id": .string(channel.id), "message_type": .string("Poll"), "poll_id": .string("poll-fixture")]))
        let poll = owner.showPoll(message)
        defer { poll.close(); owner.close(); session.stop() }
        var results: [(String, Bool)] = []
        func hasQuestion() -> Bool {
            poll.window?.contentView.map { InteractionSelfChecks.descendants($0, of: NSTextField.self).contains { $0.stringValue == "Loopback poll fixture" } } == true
        }
        func buttons() -> [NSButton] { poll.window?.contentView.map { InteractionSelfChecks.descendants($0, of: NSButton.self) } ?? [] }
        func wait(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<200 {
                if condition() { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }
        let loaded = try await wait(hasQuestion)
        results.append(("poll RPC fixture loads through the real native window", loaded))
        guard loaded, let option = buttons().first(where: { $0.identifier?.rawValue == "option-1" }), let submit = buttons().first(where: { $0.title == "Submit Vote" }) else {
            await session.client.invalidate()
            return results
        }
        option.performClick(nil)
        submit.performClick(nil)
        let locked = !submit.isEnabled && !option.isEnabled
        submit.performClick(nil)
        try await Task.sleep(for: .milliseconds(20))
        submit.performClick(nil)
        results.append(("poll mutation disables controls across suspended requests", locked && !submit.isEnabled))
        let acknowledged = try await wait { buttons().contains { $0.title == "Retract Vote" && $0.isEnabled } }
        let stats = try await session.client.rpc("nevermore_fixture.poll_stats")
        results.append(("repeated native vote clicks send one POST and await canonical state", acknowledged && stats["vote_requests"] == .number(1) && !submit.isEnabled))
        _ = try await session.client.rpc("nevermore_fixture.fail_next_poll")
        poll.refresh()
        let invalidated = try await wait { !hasQuestion() }
        session.notify()
        let recovered = try await wait(hasQuestion)
        results.append(("poll refresh recovers automatically after a failed read", invalidated && recovered))
        await session.client.invalidate()
        return results
    }
}
