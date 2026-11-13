import AppKit
import NevermoreCore
import RavenProtocol

@MainActor extension AccountSession {
    func customEmojiPage(query: String, offset: Int) async throws -> RavenCustomEmojiPage {
        guard !stopped else { throw AppError.message("This account is unavailable.") }
        guard !demo else {
            let fixtures: [JSONValue] = ["party", "raven", "wave"].map { .object(["name": .string("fixture-\($0)"), "emoji_name": .string($0), "image": .string("/files/\($0).png"), "keywords": .string("Demo emoji")]) }
            let matching = fixtures.filter { query.isEmpty || ($0["emoji_name"].string ?? "").localizedCaseInsensitiveContains(query) }
            return try RavenCustomEmojiPage(raw: .array(Array(matching.dropFirst(max(0, offset)))), origin: account.origin, offset: offset)
        }
        return try await client.customEmojiPage(query: query, offset: offset)
    }
}

/// The account's most-used reactions for the quick reaction row. Raven counts
/// them server-side across the user's devices; they load once per session and
/// again after the user reacts. A server without `most_used_reactions` (older
/// Raven) or a failed read keeps Raven's default row and retries after a
/// pause. The row is a convenience, so a failure never raises an alert.
/// One instance lives on each AccountSession, so history never crosses accounts.
@MainActor final class QuickReactionUsage {
    private(set) var mostUsed: [String] = []
    private var loaded = false
    private var task: Task<Void, Never>?
    private var retryAfter = Date.distantPast

    func prefetch(for session: AccountSession) {
        guard !loaded, task == nil, Date() >= retryAfter, !session.stopped else { return }
        // The demo has no reaction history and never contacts a server.
        guard !session.demo else { loaded = true; return }
        let client = session.client
        task = Task { [weak self, weak session] in
            let response = try? await client.rpc("raven.api.reactions.most_used_reactions", arguments: ["limit": .number(Double(QuickReactions.usageLimit))])
            guard let self, !Task.isCancelled else { return }
            self.task = nil
            guard let session, !session.stopped else { return }
            if let response { self.mostUsed = QuickReactions.mostUsed(from: response); self.loaded = true }
            else { self.retryAfter = Date().addingTimeInterval(600) }
        }
    }

    /// After a reaction the counts change; the next prefetch reads them again.
    func invalidate() {
        task?.cancel(); task = nil
        // Keep `retryAfter` so a failing endpoint is not re-poked on every
        // reaction; a successful read leaves it in the past, so it refetches.
        loaded = false
    }
}
