import AppKit
import NevermoreCore
import RavenProtocol

/// Plain GIF sends have no client idempotency key. These fixtures drive the
/// real outbox against a credential-free loopback RPC server and pin the
/// recovery contract: a preflight failure stays retryable, an uncertain POST
/// waits for an explicit review choice, a matching row already in history is
/// not proof, a reply answer must carry the reply, and the same GIF can be
/// sent twice on purpose.
@MainActor enum GIFRecoverySelfChecks {
    private static let channelID = "gif-fixture-channel"
    private static let user = "performance-fixture@example.invalid"

    static func run(app: AppDelegate, origin input: String) async throws -> [(String, Bool)] {
        let origin = try PerformanceMetrics.loopbackOrigin(input)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreGIFRecoveryCheck-\(UUID())")
        var results: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { results.append((label, value)) }
        let channel = RavenChannel(raw: .object(["name": .string(channelID), "channel_name": .string("GIF fixture"), "is_archived": .bool(false), "is_thread": .bool(false)]))
        let item = GIFItem(id: "recovery-gif", title: "Party",
                           preview: GIFRendition(url: URL(string: "https://static.klipy.com/fixture/recovery-sm.gif")!, width: 80, height: 60),
                           message: GIFRendition(url: URL(string: "https://static.klipy.com/fixture/recovery.gif")!, width: 80, height: 60))
        let html = GIFMessage.html(for: item)
        var counter = 0
        func makeSession() throws -> AccountSession {
            counter += 1
            let account = Account(origin: origin, user: user, siteName: "GIF fixture", clientID: "performance-loopback")
            let session = try AccountSession(account: account, directory: root.appendingPathComponent("store-\(counter)-and-\(UUID().uuidString)"), authentication: .loopbackFixture)
            session.channels = [channel]
            return session
        }
        func control(_ session: AccountSession, _ arguments: [String: JSONValue]) async throws -> JSONValue {
            try await session.client.rpc("nevermore_fixture.gif_control", arguments: arguments)
        }
        func reset(_ session: AccountSession) async throws { _ = try await control(session, ["reset": .bool(true)]) }
        func posts(_ session: AccountSession) async throws -> Int {
            let stats = try await session.client.rpc("nevermore_fixture.gif_stats")
            guard case .number(let count) = stats["posts"] else { return -1 }
            return Int(count)
        }
        func stored(_ session: AccountSession, _ id: UUID) async throws -> SendOperation? {
            try await session.store.operations().first { $0.id == id }
        }
        func cachedIDs(_ session: AccountSession) async throws -> Set<String> {
            Set(try await session.store.messages(channelID: channelID, limit: 20).map(\.id))
        }
        func explicitRetry(_ session: AccountSession, _ id: UUID) async throws {
            guard var operation = try await stored(session, id) else { return }
            operation.state = .queued
            operation.error = nil
            session.approvedOldSends.insert(operation.id)
            guard try await session.store.updateOperation(operation) else { return }
            await session.flush()
        }
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let session = try makeSession(); defer { session.stop() }
            try await reset(session)
            let operation = try await session.store.acceptGIF(channelID: channelID, html: html, replyTo: "root")
            await session.flush()
            let stats = try await session.client.rpc("nevermore_fixture.gif_stats")
            let answer = stats["posted"].array.first?["linked_message"].string
            let saved = try await stored(session, operation.id)
            let cached = try await cachedIDs(session)
            let postCount = try await posts(session)
            check("a confirmed GIF send acknowledges the server's message and reply target",
                  saved == nil && cached == Set(["gif-posted-0"]) && answer == "root" && postCount == 1)
        }

        do {
            let session = try makeSession(); defer { session.stop() }
            try await reset(session)
            _ = try await control(session, ["mode": .string("wrong_reply")])
            let operation = try await session.store.acceptGIF(channelID: channelID, html: html, replyTo: "root")
            await session.flush()
            let first = try await stored(session, operation.id)
            await session.flush()
            let second = try await stored(session, operation.id)
            let postCount = try await posts(session)
            check("a GIF answer carrying another reply target is not acknowledged and is not replayed",
                  first?.state == .needsReview && second?.state == .needsReview && postCount == 1)
        }

        do {
            let session = try makeSession(); defer { session.stop() }
            try await reset(session)
            _ = try await control(session, ["mode": .string("ambiguous")])
            let operation = try await session.store.acceptGIF(channelID: channelID, html: html)
            await session.flush()
            let first = try await stored(session, operation.id)
            let firstPosts = try await posts(session)
            await session.flush()
            let second = try await stored(session, operation.id)
            let secondPosts = try await posts(session)
            check("an ambiguous GIF POST waits for review instead of replaying itself",
                  first?.state == .needsReview && firstPosts == 1 && second?.state == .needsReview && secondPosts == 1)
            _ = try await control(session, ["mode": .string("ok")])
            try await explicitRetry(session, operation.id)
            let retried = try await stored(session, operation.id)
            let retriedPosts = try await posts(session)
            check("an explicit GIF retry resends and acknowledges", retried == nil && retriedPosts == 2)
        }

        do {
            let session = try makeSession(); defer { session.stop() }
            try await reset(session)
            _ = try await control(session, ["mode": .string("oversized_ack")])
            let operation = try await session.store.acceptGIF(channelID: channelID, html: html)
            await session.flush()
            let state = try await stored(session, operation.id)?.state
            await session.flush()
            let count = try await posts(session)
            check("an accepted GIF with an oversized acknowledgement stays in review without another POST",
                  state == .needsReview && count == 1)
        }

        do {
            let session = try makeSession(); defer { session.stop() }
            try await reset(session)
            _ = try await control(session, ["preflight_failures": .number(1)])
            let operation = try await session.store.acceptGIF(channelID: channelID, html: html)
            await session.flush()
            let first = try await stored(session, operation.id)
            let firstPosts = try await posts(session)
            await session.flush()
            let second = try await stored(session, operation.id)
            let laterPosts = try await posts(session)
            check("a failed GIF preflight stays retryable and a later attempt sends once",
                  first?.state == .retryable && firstPosts == 0 && second == nil && laterPosts == 1)
        }

        do {
            let session = try makeSession(); defer { session.stop() }
            try await reset(session)
            let operation = try await session.store.acceptGIF(channelID: channelID, html: html)
            var interrupted = operation
            interrupted.state = .sending
            interrupted.attempts = 1
            guard try await session.store.updateOperation(interrupted) else { throw AppError.message("The interrupted GIF could not be stored.") }
            try await session.store.recoverInterruptedOperations()
            let recovered = try await stored(session, operation.id)
            await session.flush()
            let after = try await stored(session, operation.id)
            let postCount = try await posts(session)
            check("a GIF interrupted after its POST began waits for review instead of replaying",
                  recovered?.state == .needsReview && after?.state == .needsReview && postCount == 0)
        }

        do {
            let session = try makeSession(); defer { session.stop() }
            try await reset(session)
            let operation = try await session.store.acceptGIF(channelID: channelID, html: html)
            var interrupted = operation
            interrupted.state = .uploading
            interrupted.attempts = 1
            guard try await session.store.updateOperation(interrupted) else { throw AppError.message("The interrupted GIF could not be stored.") }
            try await session.store.recoverInterruptedOperations()
            let recovered = try await stored(session, operation.id)
            await session.flush()
            let after = try await stored(session, operation.id)
            let postCount = try await posts(session)
            check("a GIF interrupted before its POST stays retryable and sends once",
                  recovered?.state == .retryable && after == nil && postCount == 1)
        }

        do {
            let session = try makeSession(); defer { session.stop() }
            try await reset(session)
            let first = try await session.store.acceptGIF(channelID: channelID, html: html)
            let second = try await session.store.acceptGIF(channelID: channelID, html: html)
            await session.flush()
            let firstSaved = try await stored(session, first.id)
            let secondSaved = try await stored(session, second.id)
            let cached = try await cachedIDs(session)
            let postCount = try await posts(session)
            check("sending the same GIF twice posts and acknowledges both",
                  firstSaved == nil && secondSaved == nil && cached.count == 2 && postCount == 2)
        }

        do {
            let session = try makeSession(); defer { session.stop() }
            try await reset(session)
            _ = try await control(session, ["mode": .string("ambiguous"), "inject_history": .bool(true), "text": .string(html)])
            let operation = try await session.store.acceptGIF(channelID: channelID, html: html)
            await session.flush()
            let first = try await stored(session, operation.id)
            await session.flush()
            let second = try await stored(session, operation.id)
            let postCount = try await posts(session)
            check("a matching GIF already in history does not confirm an uncertain send",
                  first?.state == .needsReview && second?.state == .needsReview && postCount == 1)
        }

        return results
    }
}
