import AppKit
import NevermoreCore
import RavenProtocol

extension Notification.Name {
    /// Posted with the `AccountSession` whose Home data changed.
    static let homeFeedChanged = Notification.Name("NevermoreHomeFeedChanged")
}

/// The server data Home shows beyond what the session already keeps:
/// reminders, saved messages, followed threads, recent files and the
/// reader's own sending. One feed per account, shared by its windows.
///
/// Every read is a plain GET that changes nothing on the server; in
/// particular nothing here marks a conversation or thread read. Each
/// module loads and fails on its own, so one missing endpoint (an older
/// Raven) leaves the rest of Home working.
@MainActor final class HomeFeed {
    enum Part<Value: Sendable>: Sendable {
        case loading
        case loaded(Value)
        case failed(String)

        var isLoading: Bool { if case .loading = self { return true }; return false }
        var value: Value? { if case .loaded(let value) = self { return value }; return nil }
    }

    struct Snapshot {
        var reminders: Part<[JSONValue]> = .loading
        var saved: Part<[JSONValue]> = .loading
        var threads: Part<[JSONValue]> = .loading
        /// Unread replies per thread ID, from `get_unread_threads`.
        var unreadThreads: [String: Int] = [:]
        var files: Part<[JSONValue]> = .loading
        /// The reader's own messages of the last 30 days.
        var sent: Part<[HomePeople.Sent]> = .loading
        /// True when the server returned the whole page, so older days may
        /// be missing from the counts.
        var sentTruncated = false
        var draftRead: Part<[Draft]> = .loading
        var outboxRead: Part<[SendOperation]> = .loading
        var drafts: [Draft] { draftRead.value ?? [] }
        var unsent: [SendOperation] { outboxRead.value ?? [] }
        /// The newest cached message of unread conversations the channel
        /// list sent without `last_message_details`, keyed by channel.
        var cachedLatest: [String: HomeLatestMessage] = [:]
    }

    private(set) var snapshot = Snapshot()
    private(set) var loadedAt: Date?
    private weak var session: AccountSession?
    private var task: Task<Void, Never>?
    /// Identifies the refresh that owns `task`. A refresh that is cancelled or
    /// superseded bumps this, so a late-finishing task cannot clear the slot
    /// of a newer one.
    private var refreshGeneration = 0
    /// When the last refresh produced no module at all. A total failure keeps
    /// the feed stale so the next display retries, but without a short backoff
    /// every display would refire all six requests.
    private var lastEmptyRefreshAt: Date?
    private static let emptyRefreshBackoff: TimeInterval = 15
    private var localTask: Task<Void, Never>?
    private var localRefreshPending = false
    /// A forced refresh asked for while one was in flight runs when it ends,
    /// instead of being dropped by the `task == nil` guard.
    private var pendingForceRefresh = false

    /// Home reloads server modules at most this often while it is shown.
    static let freshness: TimeInterval = 120
    static let sentPageLimit = 5000
    static let threadLimit = 4
    static let fileLimit = 5
    static let savedLimit = 3

    init(session: AccountSession) { self.session = session }

    var isStale: Bool { loadedAt.map { Date().timeIntervalSince($0) >= Self.freshness } ?? true }

    /// Loads the server modules when they are older than `freshness`, or
    /// now when `force` is set. Local drafts and the outbox always reload.
    func refresh(force: Bool = false) {
        refreshLocal()
        let inFailureBackoff = lastEmptyRefreshAt.map { Date().timeIntervalSince($0) < Self.emptyRefreshBackoff } ?? false
        guard let session, !session.stopped, force || (isStale && !inFailureBackoff) else { return }
        if task != nil {
            if force { pendingForceRefresh = true }
            return
        }
        // Stamp only when the refresh finishes. Stamping here would make a
        // cancelled or superseded task look fresh for the whole window and
        // suppress the retry the reader expects.
        refreshGeneration += 1
        let generation = refreshGeneration
        session.quickReactionUsage.prefetch(for: session)
        if session.demo {
            snapshot.reminders = .loaded([]); snapshot.saved = .loaded([]); snapshot.threads = .loaded([]); snapshot.files = .loaded([])
            task = Task { [weak self] in
                await self?.loadDemoSent()
                guard let self, generation == self.refreshGeneration else { return }
                self.task = nil
                guard !Task.isCancelled else { return }
                self.loadedAt = Date(); self.lastEmptyRefreshAt = nil
                self.runPendingForceRefresh()
            }
            return
        }
        let client = session.client
        let since = session.serverTimestamp(Date().addingTimeInterval(-HomePeople.window))
        task = Task { [weak self] in
            async let reminders = Self.part { try await client.rpc("raven.api.reminders.get_reminders").array }
            async let saved = Self.part { try await client.rpc("raven.api.raven_message.get_saved_messages", arguments: ["limit": .number(Double(Self.savedLimit)), "start": .number(0)]) }
            async let threads = Self.part { try await client.rpc("raven.api.threads.get_all_threads", arguments: ["limit": .number(Double(Self.threadLimit)), "fetch_members": .bool(false)]).array }
            async let unreadThreads = Self.part { try await client.rpc("raven.api.threads.get_unread_threads").array }
            async let files = Self.part { try await Self.recentFiles(client) }
            async let sent = Self.part { try await Self.sentMessages(client, since: since) }
            let results = await (reminders, saved, threads, unreadThreads, files, sent)
            guard let self, generation == self.refreshGeneration else { return }
            self.task = nil
            guard !Task.isCancelled, let session = self.session, !session.stopped else { return }
            self.snapshot.reminders = results.0
            self.snapshot.saved = results.1.map { $0.array.isEmpty ? $0["messages"].array : $0.array }
            self.snapshot.threads = results.2
            self.snapshot.unreadThreads = Dictionary((results.3.value ?? []).compactMap { row -> (String, Int)? in
                guard let id = row["name"].string, case .number(let count) = row["unread_count"], count.isFinite, count >= 1 else { return nil }
                return (id, Int(min(count, 9999)))
            }, uniquingKeysWith: max)
            self.snapshot.files = results.4
            switch results.5 {
            case .loaded(let rows):
                self.snapshot.sent = .loaded(rows.compactMap { row in
                    guard let channel = row["channel_id"].string, let date = row["creation"].string.flatMap(session.messageDate) else { return nil }
                    return HomePeople.Sent(channelID: channel, date: date)
                })
                self.snapshot.sentTruncated = rows.count >= Self.sentPageLimit
            case .failed(let error): self.snapshot.sent = .failed(error)
            case .loading: break
            }
            // A refresh that produced nothing did not make the feed fresh;
            // leaving it stale lets the next display retry instead of waiting
            // out the window with every module showing a failure.
            let anyModuleLoaded = results.0.value != nil || results.1.value != nil || results.2.value != nil
                || results.3.value != nil || results.4.value != nil || results.5.value != nil
            if anyModuleLoaded { self.loadedAt = Date(); self.lastEmptyRefreshAt = nil }
            else { self.lastEmptyRefreshAt = Date() }
            self.changed()
            self.runPendingForceRefresh()
        }
    }

    /// Starts a forced refresh that arrived while one was in flight.
    private func runPendingForceRefresh() {
        guard pendingForceRefresh, task == nil else { return }
        pendingForceRefresh = false
        refresh(force: true)
    }

    /// Waits for an in-flight refresh, then starts a canonical one and
    /// returns its task. A mutation uses this so Home never reports state
    /// from before the change.
    @discardableResult func refreshAfterInflight(force: Bool = true) async -> Task<Void, Never>? {
        if let task { await task.value }
        refresh(force: force)
        return task
    }

    /// Drafts and unsent messages live in the local store.
    func refreshLocal() {
        guard let session else { return }
        // A write can finish after an active read took its snapshot. Honor
        // requests received during that read with one subsequent refresh.
        if localTask != nil {
            localRefreshPending = true
            return
        }
        localRefreshPending = false
        localTask = Task { [weak self] in
            let drafts = await Self.part { try await session.store.drafts() }
            let unsent = await Self.part { try await session.store.operations() }
            guard let self, !Task.isCancelled, !session.stopped else { return }
            self.localTask = nil
            // A draft holds text only once someone typed; an empty row is
            // what a conversation leaves behind after a send.
            self.snapshot.draftRead = drafts.map { rows in
                rows.filter { draft in
                    !draft.attachments.isEmpty || !((try? RichTextCodec.parse(draft.html)).map { RichTextCodec.plainText($0) } ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
            }
            self.snapshot.outboxRead = unsent.map { rows in
                rows.filter { [.retryable, .needsReview, .rejected].contains($0.state) }
            }
            self.changed()
            if self.localRefreshPending { self.refreshLocal() }
        }
    }

    func cancel() {
        refreshGeneration += 1
        lastEmptyRefreshAt = nil
        task?.cancel(); task = nil; localTask?.cancel(); localTask = nil; latestTask?.cancel(); latestTask = nil
    }

    private var latestTask: Task<Void, Never>?
    private var latestKeys: [String: String] = [:]

    /// Looks up the newest cached message for unread conversations without
    /// server details (older servers, the demo). Each conversation is read
    /// again only when its unread count or newest timestamp changes.
    func loadCachedLatest(for entries: [HomeUnreadEntry]) {
        guard let session, latestTask == nil else { return }
        let wanted = entries.filter { HomeLatestMessage(channel: $0.channel) == nil }
        let keys = Dictionary(wanted.map { ($0.channel.id, "\($0.count)|\($0.channel.raw["last_message_timestamp"].string ?? "")") }, uniquingKeysWith: { first, _ in first })
        let stale = keys.filter { latestKeys[$0.key] != $0.value }
        guard !stale.isEmpty else { return }
        latestTask = Task { [weak self] in
            var found: [String: HomeLatestMessage] = [:]
            for id in stale.keys {
                guard let message = try? await session.cachedMessages(channelID: id, limit: 1).last else { continue }
                let text = (try? RichTextCodec.parse(message.html)).map { RichTextCodec.plainText($0) } ?? ""
                found[id] = HomeLatestMessage(messageID: message.id, authorID: message.authorID, kind: HomeLatestMessage.kind(messageType: message.messageType), text: text, timestamp: message.creation)
            }
            guard let self, !Task.isCancelled else { return }
            self.latestTask = nil
            for (id, key) in stale { self.latestKeys[id] = key }
            self.snapshot.cachedLatest.merge(found) { _, new in new }
            if !found.isEmpty { self.changed() }
        }
    }

    private func changed() {
        guard let session else { return }
        NotificationCenter.default.post(name: .homeFeedChanged, object: session)
    }

    nonisolated private static func part<Value: Sendable>(_ body: @Sendable () async throws -> Value) async -> Part<Value> {
        do { return .loaded(try await body()) }
        catch { return .failed(error.localizedDescription) }
    }

    /// The newest File and Image messages from the search index. The index
    /// is filled by a background job, so a file can take minutes to appear.
    nonisolated private static func recentFiles(_ client: RavenClient) async throws -> [JSONValue] {
        let filters = String(decoding: try JSONEncoder().encode(JSONValue.object(["message_type": .array([.string("File"), .string("Image")])])), as: UTF8.self)
        let rows = try await client.rpc("raven.api.search.sqlite_search", arguments: ["filters": .string(filters), "limit": .number(Double(fileLimit))])
        return rows.array.map(RavenSearchResult.normalize)
    }

    /// The reader's own messages. Raven limits list reads of Raven Message
    /// to the reader's own rows (`raven_message_query`), so this returns
    /// nobody else's messages whatever the filters say.
    nonisolated private static func sentMessages(_ client: RavenClient, since: String) async throws -> [JSONValue] {
        let filters: JSONValue = .array([
            .array([.string("creation"), .string(">="), .string(since)]),
            .array([.string("message_type"), .string("!="), .string("System")]),
            .array([.string("is_bot_message"), .string("="), .number(0)])
        ])
        let response = try await client.rpc("frappe.client.get_list", arguments: [
            "doctype": .string("Raven Message"),
            "fields": .array([.string("channel_id"), .string("creation")]),
            "filters": filters,
            "order_by": .string("creation desc"),
            "limit_page_length": .string(String(sentPageLimit))
        ])
        guard case .array(let rows) = response else { throw RavenError.invalidResponse }
        return rows
    }

    /// The demo has no server; its own cached messages stand in.
    private func loadDemoSent() async {
        guard let session else { return }
        var sent: [HomePeople.Sent] = []
        for channel in session.channels {
            let rows = (try? await session.cachedMessages(channelID: channel.id, limit: 1000)) ?? []
            sent += rows.filter { $0.owner == session.account.user }.compactMap { message in session.messageDate(message.creation).map { HomePeople.Sent(channelID: message.channelID, date: $0) } }
        }
        snapshot.sent = .loaded(sent)
        changed()
    }
}

private extension HomeFeed.Part {
    func map<Other: Sendable>(_ transform: (Value) -> Other) -> HomeFeed.Part<Other> {
        switch self {
        case .loading: .loading
        case .loaded(let value): .loaded(transform(value))
        case .failed(let error): .failed(error)
        }
    }
}
