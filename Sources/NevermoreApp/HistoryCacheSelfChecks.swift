import AppKit
import SQLite3
import RavenProtocol
import NevermoreCore

/// Suspends history reads until the check releases them, so overlapping
/// loads can be completed in either order.
@MainActor private final class PendingHistoryReads {
    private var continuations: [CheckedContinuation<JSONValue, Error>] = []
    private var finished = false

    func suspend() async throws -> JSONValue {
        guard !finished else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func releaseFirst(_ result: Result<JSONValue, Error>) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(with: result)
    }

    func releaseLast(_ result: Result<JSONValue, Error>) {
        continuations.popLast()?.resume(with: result)
    }

    func count() -> Int { continuations.count }

    func finish() {
        finished = true
        while !continuations.isEmpty { releaseFirst(.failure(CancellationError())) }
    }
}

/// Answers the read RPCs a membership refresh and history load need. History
/// pages stay pending until the check releases them.
@MainActor
private final class HistoryCacheRPC {
    private let pending = PendingHistoryReads()
    var allowedChannels: Set<String> = []

    func rpc(_ method: String, _ arguments: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "raven.api.native.boot":
            return .object(["read_only": .bool(false), "user": .object(["roles": .array([])])])
        case "raven.api.raven_users.get_current_raven_user":
            return .object([:])
        case "raven.api.raven_users.get_list", "raven.api.user_availability.get_active_users":
            return .array([])
        case "raven.api.raven_channel.get_all_channels":
            let items = allowedChannels.sorted().map { id in
                JSONValue.object(["name": .string(id), "channel_name": .string("History fixture"), "is_thread": .bool(false), "is_archived": .bool(false)])
            }
            return .object(["channels": .array(items), "dm_channels": .array([])])
        case "raven.api.raven_message.get_unread_count_for_channels":
            return .object([:])
        case "raven.api.notifications.get_unread_notification_message_ids":
            return .array([])
        case "raven.api.chat_stream.get_messages", "raven.api.chat_stream.get_older_messages":
            return try await pending.suspend()
        default:
            throw AppError.message("The history fixture received an unexpected read: \(method)")
        }
    }

    func releaseFirst(_ result: Result<JSONValue, Error>) { pending.releaseFirst(result) }
    func releaseLast(_ result: Result<JSONValue, Error>) { pending.releaseLast(result) }
    func pendingCount() -> Int { pending.count() }
    func drain() {
        pending.finish()
    }
}

/// Deterministic cache-consistency fixture: overlapping loads, membership
/// revocation and restoration, a thread under a revoked parent, and the
/// survival of drafts and queued sends. No server or external target.
@MainActor enum HistoryCacheSelfChecks {
    private static let channelID = "history-fixture-channel"
    private static let threadID = "history-fixture-thread"

    private static func message(_ id: String, _ channelID: String, _ label: String) -> RavenMessage {
        RavenMessage(raw: .object([
            "name": .string(id), "channel_id": .string(channelID), "owner": .string("alex@example.com"),
            "creation": .string("2026-11-07 12:00:00.000000"), "text": .string("<p>\(label) \(id)</p>"),
            "message_type": .string("Text")
        ]))
    }

    private static func page(_ rows: [RavenMessage]) -> JSONValue {
        .object(["messages": .array(rows.map(\.raw)), "last_visit": .null])
    }

    static func run() async -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreHistoryCache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let account = Account(origin: URL(string: "https://history-cache.invalid")!, user: "history-fixture", siteName: "fixture", clientID: "fixture")
        guard let session = try? AccountSession(account: account, directory: directory) else {
            return [("history cache fixture opens an account session", false)]
        }
        defer { session.stop() }
        let rpc = HistoryCacheRPC()
        session.readRPC = { method, arguments in try await rpc.rpc(method, arguments) }

        let channel = RavenChannel(raw: .object(["name": .string(channelID), "channel_name": .string("History fixture"), "is_thread": .bool(false)]))
        let thread = RavenChannel(raw: .object(["name": .string(threadID), "channel_name": .string("History thread"), "is_thread": .bool(true), "parent_channel_id": .string(channelID)]))
        let channelRows = (0..<3).map { message("history-channel-\($0)", channelID, "History fixture") }
        let nestedID = "history-fixture-nested-thread"
        let nested = message("nested-only", nestedID, "Nestedchild")
        let threadRows = (0..<2).map { message("history-thread-\($0)", threadID, "Thread fixture") }
        let channelRowIDs = Set(channelRows.map(\.id))
        session.channels = [channel]
        session.threadParents[threadID] = channelID
        session.attach(window: UUID(), channelID: threadID)

        func waitUntilSuspended(_ count: Int) async -> Bool {
            for _ in 0..<200 {
                if rpc.pendingCount() == count { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return rpc.pendingCount() == count
        }
        func storeIDs(_ id: String) async -> Set<String> {
            do { return Set(try await session.store.messages(channelID: id, limit: 5000).map(\.id)) }
            catch { results.append(("the history fixture could read durable rows: \(error.localizedDescription)", false)); return [] }
        }
        func searchHits(_ query: String) async -> [RavenMessage] {
            do { return try await session.store.search(query) }
            catch { results.append(("the history fixture could query the index: \(error.localizedDescription)", false)); return [] }
        }
        func startLoad(_ id: String) -> Task<Void, Never> {
            Task { try? await session.load(channelID: id) }
        }

        do {
            try await session.store.cacheChannels([channel, thread])
            try await session.store.cacheMessages(channelRows + threadRows)
            rpc.allowedChannels = [channelID]
            try await session.refresh()
            results.append(("history cache fixture refreshes membership offline",
                           session.channels.contains(where: { $0.id == channelID }) && !session.revokedChannels.contains(channelID)))
        } catch {
            rpc.drain()
            return results + [("history cache fixture refreshes membership offline: \(error.localizedDescription)", false)]
        }

        // A denial that completes before an older authorized page must keep
        // that page out of memory, durable history and search.
        let older = startLoad(channelID)
        guard await waitUntilSuspended(1) else { rpc.drain(); await older.value; return results + [("history cache fixture suspends overlapping loads", false)] }
        let denial = startLoad(channelID)
        guard await waitUntilSuspended(2) else {
            rpc.drain(); await older.value; await denial.value
            return results + [("history cache fixture suspends overlapping loads", false)]
        }
        rpc.releaseLast(.failure(RavenError.http(403, nil)))
        await denial.value
        rpc.releaseFirst(.success(page(channelRows)))
        await older.value
        let olderMemory = Set((session.memoryMessages[channelID] ?? []).map(\.id))
        let olderStored = await storeIDs(channelID)
        let olderHits = await searchHits("History fixture")
        results.append(("a denial that completes first keeps an older authorized page out of memory, history and search",
                       olderMemory.isEmpty && olderStored.isEmpty && olderHits.isEmpty))

        // Reverse order: an authorized page commits, then a later denial
        // purges it.
        rpc.allowedChannels = [channelID]
        try? await session.refresh()
        try? await session.store.cacheMessages(channelRows)
        let success = startLoad(channelID)
        guard await waitUntilSuspended(1) else { rpc.drain(); await success.value; return results + [("history cache fixture suspends a single load", false)] }
        rpc.releaseFirst(.success(page(channelRows)))
        await success.value
        let committed = await storeIDs(channelID) == channelRowIDs
            && Set((session.memoryMessages[channelID] ?? []).map(\.id)) == channelRowIDs
        let laterDenial = startLoad(channelID)
        guard await waitUntilSuspended(1) else { rpc.drain(); await laterDenial.value; return results + [("history cache fixture suspends a later load", false)] }
        rpc.releaseFirst(.failure(RavenError.http(403, nil)))
        await laterDenial.value
        let purged = await storeIDs(channelID)
        let purgedMemory = Set((session.memoryMessages[channelID] ?? []).map(\.id))
        let purgedHits = await searchHits("History fixture")
        results.append(("an authorized page commits, and a later denial purges memory, history and search",
                       committed && purged.isEmpty && purgedMemory.isEmpty && purgedHits.isEmpty))

        // A denial delivered after access was restored is stale: it must not
        // purge a channel that is authorized again.
        rpc.allowedChannels = [channelID]
        try? await session.refresh()
        try? await session.store.cacheMessages(channelRows)
        session.memoryMessages[channelID] = channelRows
        let stale = startLoad(channelID)
        guard await waitUntilSuspended(1) else { rpc.drain(); await stale.value; return results + [("history cache fixture suspends a stale load", false)] }
        rpc.allowedChannels = []
        try? await session.refresh()
        rpc.allowedChannels = [channelID]
        try? await session.refresh()
        try? await session.store.cacheMessages(channelRows)
        session.memoryMessages[channelID] = channelRows
        rpc.releaseFirst(.failure(RavenError.http(403, nil)))
        await stale.value
        let stillAuthorized = !session.revokedChannels.contains(channelID)
        let stillStored = await storeIDs(channelID) == channelRowIDs
        let stillInMemory = Set((session.memoryMessages[channelID] ?? []).map(\.id)) == channelRowIDs
        results.append(("a denial delivered after access was restored does not purge the channel",
                       stillAuthorized && stillStored && stillInMemory))

        // Load and find the nested reply before withdrawing the parent. A
        // missing seed would otherwise also produce an empty post-purge read.
        rpc.allowedChannels = [channelID]
        do {
            try await session.refresh()
            try await session.store.cacheMessages(threadRows)
        } catch { return results + [("the parent and thread history fixture could be seeded: \(error.localizedDescription)", false)] }
        session.memoryMessages[threadID] = threadRows
        session.threadParents[nestedID] = threadID
        let nestedLoad = startLoad(nestedID)
        guard await waitUntilSuspended(1) else { rpc.drain(); await nestedLoad.value; return results + [("history cache fixture suspends a nested load", false)] }
        rpc.releaseFirst(.success(page([nested])))
        await nestedLoad.value
        do {
            let memory = session.memoryMessages[nestedID]?.map(\.id)
            let stored = try await session.store.messages(channelID: nestedID).map(\.id)
            let indexed = try await session.store.search("Nestedchild").map(\.id)
            results.append(("the nested reply is present in memory, disk and search before revocation",
                            memory == [nested.id] && stored == [nested.id] && indexed == [nested.id]))
        } catch { return results + [("reading the nested history fixture: \(error.localizedDescription)", false)] }

        let threadLoad = startLoad(threadID)
        guard await waitUntilSuspended(1) else { rpc.drain(); await threadLoad.value; return results + [("history cache fixture suspends a thread load", false)] }
        rpc.allowedChannels = []
        do { try await session.refresh() }
        catch { rpc.drain(); await threadLoad.value; return results + [("withdrawing the thread fixture: \(error.localizedDescription)", false)] }
        rpc.releaseFirst(.success(page(threadRows)))
        await threadLoad.value
        let threadMemory = Set((session.memoryMessages[threadID] ?? []).map(\.id))
        let threadStored = await storeIDs(threadID)
        let threadHits = await searchHits("Thread fixture")
        let threadDocumentBlocked = session.messageDocument(for: threadRows[0]) == .failed
        results.append(("revoking a parent purges its thread and drops an outstanding thread load",
                       threadMemory.isEmpty && threadStored.isEmpty && threadHits.isEmpty && threadDocumentBlocked))

        do {
            let stored = try await session.store.messages(channelID: nestedID)
            let hits = try await session.store.search("Nestedchild")
            results.append(("withdrawn descendant history without a channel-list row is absent from memory, disk and search",
                            session.memoryMessages[nestedID] == nil && stored.isEmpty && hits.isEmpty))
        } catch { results.append(("reading withdrawn descendant history: \(error.localizedDescription)", false)) }

        // A denial purge withdraws messages only; the draft and the queued
        // send stay recoverable.
        rpc.allowedChannels = [channelID]
        try? await session.refresh()
        try? await session.store.saveDraft(Draft(channelID: channelID, html: "<p>Queued</p>"))
        _ = try? await session.store.acceptDraft(channelID: channelID)
        try? await session.store.saveDraft(Draft(channelID: channelID, html: "<p>Recoverable</p>"))
        let preserving = startLoad(channelID)
        guard await waitUntilSuspended(1) else { rpc.drain(); await preserving.value; return results + [("history cache fixture suspends a preservation load", false)] }
        rpc.releaseFirst(.failure(RavenError.http(403, nil)))
        await preserving.value
        let draftKept = (try? await session.store.draft(channelID: channelID))?.html == "<p>Recoverable</p>"
        let outboxKept = (try? await session.store.operations().contains { $0.channelID == channelID }) == true
        results.append(("a denial purge keeps the channel's draft and queued send", draftKept && outboxKept))

        // A first purge can fail independently of the server denial. Repeat
        // the denial in the same epoch after the store becomes writable.
        rpc.allowedChannels = [channelID]
        do {
            try await session.refresh()
            try await session.store.cacheMessages(channelRows)
            var db: OpaquePointer?
            let opened = sqlite3_open(directory.appendingPathComponent(AccountStore.databaseFileName).path, &db)
            defer { sqlite3_close(db) }
            guard opened == SQLITE_OK,
                  sqlite3_exec(db, "CREATE TRIGGER deny_purge BEFORE DELETE ON messages BEGIN SELECT RAISE(ABORT, 'Held purge'); END", nil, nil, nil) == SQLITE_OK else {
                throw AppError.message("Could not hold the history purge.")
            }
            let failed = startLoad(channelID)
            guard await waitUntilSuspended(1) else { rpc.drain(); await failed.value; return results + [("the purge retry fixture suspended", false)] }
            rpc.releaseFirst(.failure(RavenError.http(403, nil)))
            await failed.value
            let held = try await session.store.messages(channelID: channelID)
            guard sqlite3_exec(db, "DROP TRIGGER deny_purge", nil, nil, nil) == SQLITE_OK else { throw AppError.message("Could not release the purge.") }
            let retry = startLoad(channelID)
            guard await waitUntilSuspended(1) else { rpc.drain(); await retry.value; return results + [("the purge retry fixture resumed", false)] }
            rpc.releaseFirst(.failure(RavenError.http(403, nil)))
            await retry.value
            let finalRows = try await session.store.messages(channelID: channelID)
            let finalHits = try await session.store.search("History fixture")
            results.append(("a repeated current denial retries a previously failed durable purge",
                            !held.isEmpty && finalRows.isEmpty && finalHits.isEmpty))
        } catch { results.append(("the purge retry fixture completed: \(error.localizedDescription)", false)) }

        rpc.drain()
        // Exercise refresh through the same reader as history and membership.
        let counts = JSONValue.array([.object(["name": .string(channelID), "unread_count": .number(2)])])
        session.unread = counts
        session.unreadNotificationIDs = ["known"]
        rpc.allowedChannels = []
        var answer: JSONValue?
        var legacyAnswer: JSONValue?
        session.readRPC = { method, arguments in
            switch method {
            case "raven.api.raven_message.get_unread_count_for_channels",
                 "raven.api.notifications.get_unread_notification_message_ids":
                guard let answer else { throw RavenError.transport }
                return answer
            case "raven.api.notifications.get_notifications":
                guard let legacyAnswer else { throw RavenError.transport }
                return legacyAnswer
            default: return try await rpc.rpc(method, arguments)
            }
        }
        do {
            try await session.refresh()
            results.append(("unread failures preserve the snapshot while membership is withdrawn",
                            session.channels.isEmpty && session.unread == counts && session.unreadNotificationIDs == ["known"]))
            legacyAnswer = .array([.object(["message_id": .string("legacy")])])
            answer = .object([:])
            try await session.refresh()
            results.append(("malformed unread replies preserve the snapshot",
                            session.unread == counts && session.unreadNotificationIDs == ["known"]))
            answer = .array([.null])
            try await session.refresh()
            results.append(("invalid unread rows preserve counts and attention IDs",
                            session.unread == counts && session.unreadNotificationIDs == ["known"]))
            answer = nil
            try await session.refresh()
            results.append(("unavailable notification IDs use the legacy inbox", session.unreadNotificationIDs == ["legacy"]))
            answer = .array([])
            try await session.refresh()
            results.append(("authoritative empty unread replies replace the snapshot",
                            session.unread == .array([]) && session.unreadNotificationIDs.isEmpty))
        } catch { results.append(("unread refresh fixture completed", false)) }
        return results
    }
}
