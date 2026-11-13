import Foundation
import NevermoreCore
import RavenProtocol

@MainActor enum OutboxArchiveSelfChecks {
    static func run() async throws -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        for isThread in [false, true] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreOutboxArchive-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            let account = Account(origin: URL(string: "https://fixture.invalid")!, user: "fixture@example.invalid", siteName: "fixture", clientID: "fixture")
            let session = try AccountSession(account: account, directory: directory)
            defer { session.stop() }
            // An invalidated client guarantees this fixture cannot reach a
            // network, even when the outbox gate is regressed.
            await session.client.invalidate()
            session.channels = [RavenChannel(raw: .object(["name": .string("parent"), "is_archived": .bool(true)]))]
            session.threadParents["thread"] = "parent"
            let draft = Draft(channelID: isThread ? "thread" : "parent", html: "<p>Recoverable fixture</p>")
            try await session.store.saveDraft(draft)
            let operation = try await session.store.acceptDraft(channelID: draft.channelID, expected: draft)
            await session.flush()
            let saved = try await session.store.operations().first { $0.id == operation.id }
            results.append((isThread ? "queued thread replies pause when the parent is archived" : "queued sends pause when their conversation is archived", saved?.state == .needsReview && saved?.attempts == 0 && saved?.html == draft.html))
        }
        return results
    }
}
