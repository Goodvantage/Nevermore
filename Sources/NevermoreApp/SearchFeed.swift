import Foundation
import NevermoreCore
import RavenProtocol

struct SavedSearch: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var criteria: SearchCriteria
}

/// Saved searches are local, per account, and purged with the account.
@MainActor enum SavedSearchStore {
    static let limit = 30
    private static func key(_ account: UUID) -> String { "savedSearches.\(account.uuidString)" }
    static func load(_ account: UUID) -> [SavedSearch] {
        guard let data = UserDefaults.standard.data(forKey: key(account)), data.count <= 256 * 1024,
              let items = try? JSONDecoder().decode([SavedSearch].self, from: data), items.count <= limit else { return [] }
        return items
    }
    static func save(_ items: [SavedSearch], account: UUID) throws {
        guard items.count <= limit else { throw AppError.message("You can save up to \(limit) searches per account. Remove an old search first.") }
        let data = try JSONEncoder().encode(items)
        guard data.count <= 256 * 1024 else { throw AppError.message("Saved searches exceed the local size limit.") }
        UserDefaults.standard.set(data, forKey: key(account))
        NotificationCenter.default.post(name: .savedSearchesChanged, object: account)
    }
    static func clear(_ account: UUID) { UserDefaults.standard.removeObject(forKey: key(account)) }
}

extension Notification.Name {
    /// Posted with the account ID whose saved searches changed.
    static let savedSearchesChanged = Notification.Name("NevermoreSavedSearchesChanged")
}

/// Runs one window's search: the cached matches at once, then the server's.
///
/// Every request is a read. Nothing here marks a message or conversation
/// read. A newer search cancels the one in flight, so only the latest
/// search's answers are ever shown.
@MainActor final class SearchFeed {
    enum Part<Value: Sendable>: Sendable {
        case idle
        case loading
        case loaded(Value)
        case failed(String)

        var value: Value? { if case .loaded(let value) = self { return value }; return nil }
        var isLoading: Bool { if case .loading = self { return true }; return false }
        func map<Other: Sendable>(_ transform: (Value) -> Other) -> Part<Other> {
            switch self {
            case .idle: .idle
            case .loading: .loading
            case .loaded(let value): .loaded(transform(value))
            case .failed(let message): .failed(message)
            }
        }
    }

    struct Results {
        var messages: Part<[SearchHit]> = .idle
        var files: Part<[SearchHit]> = .idle
        var links: Part<[JSONValue]> = .idle
        /// The Messages and Files lists come from this Mac's cache: the
        /// server has not answered yet, failed, or there is none (the demo).
        var fromCache = false
        var serverError: String?
        /// Why thread replies may be missing, when they may be.
        var threadNote: String?
        /// Tabs listing cached matches the server's answer lacked.
        var cacheOnly: Set<SearchTab> = []
        /// Hits the server itself returned per tab, so the footer can tell
        /// real truncation from cache-only additions.
        var serverHits: [SearchTab: Int] = [:]
    }

    /// How long typing must pause before a search is sent.
    static let pause: Duration = .milliseconds(350)
    /// Frappe's `MAX_SEARCH_RESULTS`: a query never returns more.
    nonisolated static let serverLimit = 100
    nonisolated static let linkPageSize = 50
    /// Threads asked for per endpoint when replies are included.
    static let threadLimit = 200
    static let threadFreshness: TimeInterval = 120

    private(set) var criteria = SearchCriteria()
    private(set) var results = Results()
    /// Called on the main actor after `results` changes.
    var onChange: (() -> Void)?

    private weak var session: AccountSession?
    private var task: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var generation = 0
    private var loadedTabs: Set<SearchTab> = []
    /// Tabs the running load has not finished. A newer run cancels that
    /// load, so these load again rather than wait forever.
    private var unfinished: Set<SearchTab> = []
    private var threadCache: [String: (rows: [JSONValue], note: String?, at: Date)] = [:]

    init(session: AccountSession?) { self.session = session }

    var isRunning: Bool { task != nil || pending != nil }

    /// Searches for `criteria` on `tab`. Typing waits for `pause`; filters
    /// and Return search at once. `refresh` asks the server again for tabs
    /// the same search already loaded (Return, say after a failure).
    func search(_ criteria: SearchCriteria, tab: SearchTab, immediately: Bool, refresh: Bool = false) {
        pending?.cancel(); pending = nil
        guard immediately else {
            pending = Task { [weak self] in
                try? await Task.sleep(for: Self.pause)
                guard !Task.isCancelled, let self else { return }
                self.pending = nil
                self.run(criteria, tab: tab, refresh: refresh)
            }
            return
        }
        run(criteria, tab: tab, refresh: refresh)
    }

    /// A tab whose list a blank search has not loaded yet.
    func ensureLoaded(_ tab: SearchTab) {
        guard !loadedTabs.contains(tab), [.messages, .files, .links].contains(tab), pending == nil else { return }
        run(criteria, tab: tab)
    }

    func cancel() {
        pending?.cancel(); pending = nil
        task?.cancel(); task = nil
        loadedTabs.subtract(unfinished); unfinished = []
        generation += 1
    }

    /// Drops results that a revoked or deleted conversation no longer
    /// allows. True when any result went.
    @discardableResult func restrict() -> Bool {
        guard let session else { return false }
        func counts(_ results: Results) -> [Int] { [results.messages.value?.count ?? 0, results.files.value?.count ?? 0, results.links.value?.count ?? 0] }
        let before = counts(results)
        results = Self.restricted(results, session: session)
        return before != counts(results)
    }

    /// `results` without what `session` no longer allows.
    static func restricted(_ results: Results, session: AccountSession) -> Results {
        var results = results
        func allowed(_ hit: SearchHit) -> Bool { Self.allowed(hit.channelID, hit.conversationID, session) && !session.deletedIDs.contains(hit.id) }
        if case .loaded(let hits) = results.messages { results.messages = .loaded(hits.filter(allowed)) }
        if case .loaded(let hits) = results.files { results.files = .loaded(hits.filter(allowed)) }
        if case .loaded(let rows) = results.links {
            results.links = .loaded(rows.filter { linkAllowed($0, session) })
        }
        return results
    }

    /// Whether a blank query still lists something on `tab`: the newest
    /// files or links, or messages narrowed by a filter.
    static func listsWithoutQuery(_ criteria: SearchCriteria, tab: SearchTab) -> Bool {
        switch tab {
        case .files, .links: true
        case .messages: criteria.author != nil || criteria.savedOnly || criteria.mentionsMe || criteria.date != nil || criteria.attribute != nil || criteria.kind == .polls || criteria.kind == .text
        case .conversations, .people: false
        }
    }

    // MARK: Running

    private func run(_ criteria: SearchCriteria, tab: SearchTab, refresh: Bool = false) {
        task?.cancel(); task = nil
        loadedTabs.subtract(unfinished); unfinished = []
        generation += 1
        let attempt = generation
        let sameSearch = criteria == self.criteria
        self.criteria = criteria
        if !sameSearch { results = Results(); loadedTabs = [] }
        if refresh { loadedTabs = [] }
        guard let session, !session.stopped else { return }
        let blank = criteria.query.isEmpty
        // A blank query only loads the tab on screen; a query loads every
        // server tab, so the counts on the tabs are real.
        var wanted: Set<SearchTab> = blank ? [tab] : [.messages, .files, .links]
        wanted = wanted.filter { [.messages, .files, .links].contains($0) && (!blank || Self.listsWithoutQuery(criteria, tab: $0)) }
        if sameSearch { wanted.subtract(loadedTabs) }
        guard !wanted.isEmpty else { onChange?(); return }
        // A reloaded tab's footer notes come from its new answer, not the
        // old one.
        for tab in wanted.intersection([.messages, .files]) {
            results.cacheOnly.remove(tab)
            results.serverHits.removeValue(forKey: tab)
        }
        loadedTabs.formUnion(wanted)
        unfinished = wanted
        // Results already shown for the same search stay until new ones come.
        if wanted.contains(.messages), results.messages.value == nil { results.messages = .loading }
        if wanted.contains(.files), results.files.value == nil { results.files = .loading }
        if wanted.contains(.links), results.links.value == nil { results.links = .loading }
        onChange?()
        task = Task { [weak self] in
            await self?.load(criteria, wanted: wanted, attempt: attempt, session: session)
            guard let self, self.generation == attempt else { return }
            self.task = nil
            self.unfinished = []
            self.onChange?()
        }
    }

    private func current(_ attempt: Int, _ session: AccountSession) -> Bool { generation == attempt && !Task.isCancelled && !session.stopped }

    private func load(_ criteria: SearchCriteria, wanted: Set<SearchTab>, attempt: Int, session: AccountSession) async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: session.account.timezone) ?? .gmt
        let now = Date()

        // Thread replies in a conversation or workspace need the threads'
        // IDs; the channel list has none.
        var threadRows: [JSONValue] = []
        if criteria.scopeHasThreads, criteria.includeThreads, wanted.contains(.messages) || wanted.contains(.files), !session.demo {
            let (rows, note) = await threads(for: criteria.scope, session: session)
            guard current(attempt, session) else { return }
            threadRows = rows
            results.threadNote = note
        }
        let parents = session.threadParents.merging(SearchThreads.parents(threadRows)) { _, fetched in fetched }
        let threadIDs = SearchThreads.ids(threadRows, parents: Self.parents(of: criteria.scope, session: session))

        // Matches on this Mac show at once and stay, whatever the server
        // answers: its index can lack them.
        let indexTabs = wanted.intersection([.messages, .files])
        var cached = Cached(messages: [], files: [])
        if !criteria.query.isEmpty, !indexTabs.isEmpty {
            cached = await cachedHits(criteria, parents: parents, now: now, calendar: calendar, session: session)
            guard current(attempt, session) else { return }
            if indexTabs.contains(.messages), results.messages.isLoading { results.messages = .loaded(cached.messages) }
            if indexTabs.contains(.files), results.files.isLoading { results.files = .loaded(cached.files) }
            results.fromCache = true
            onChange?()
        }

        if session.demo {
            if results.messages.isLoading { results.messages = .loaded([]) }
            if results.files.isLoading { results.files = .loaded([]) }
            if wanted.contains(.links) { results.links = .failed("The local demo has no server to search links on.") }
            results.fromCache = true
            onChange?()
            return
        }

        let client = session.client
        let user = session.account.user
        async let links: Part<[JSONValue]> = wanted.contains(.links) ? Self.links(criteria.on(.links), client: client) : .idle
        var messageError: String?
        var filesDerived = false
        if wanted.contains(.messages) {
            let messageCriteria = criteria.on(.messages)
            do {
                let filters = try messageCriteria.filters(channels: session.channels, threads: threadIDs, now: now, calendar: calendar)
                let rows = try await Self.index(query: messageCriteria.query, filters: filters, client: client)
                guard current(attempt, session) else { return }
                let hits = rows.compactMap { SearchHit(row: $0, currentUser: user) }.filter { Self.allowed($0.channelID, $0.conversationID, session) && !session.deletedIDs.contains($0.id) }
                results.messages = .loaded(merged(hits, cached.messages, tab: .messages))
                // Below the cap the server returned every match, so the
                // files among them are every matching file.
                if wanted.contains(.files), messageCriteria.kind == .all, rows.count < Self.serverLimit {
                    let images = criteria.on(.files).kind == .images
                    results.files = .loaded(merged(hits.filter { $0.isFile && (!images || $0.messageType == "Image") }, cached.files, tab: .files))
                    filesDerived = true
                }
            } catch {
                guard current(attempt, session) else { return }
                messageError = StatusLocalization.errorDescription(error)
                if results.messages.isLoading { results.messages = .failed(messageError ?? "") }
            }
            onChange?()
        }
        if wanted.contains(.files), !filesDerived {
            let fileCriteria = criteria.on(.files)
            do {
                let filters = try fileCriteria.filters(channels: session.channels, threads: threadIDs, now: now, calendar: calendar)
                let rows = try await Self.index(query: fileCriteria.query, filters: filters, client: client)
                guard current(attempt, session) else { return }
                let hits = rows.compactMap { SearchHit(row: $0, currentUser: user) }.filter { Self.allowed($0.channelID, $0.conversationID, session) && !session.deletedIDs.contains($0.id) }
                results.files = .loaded(merged(hits, cached.files, tab: .files))
            } catch {
                guard current(attempt, session) else { return }
                messageError = messageError ?? StatusLocalization.errorDescription(error)
                if results.files.isLoading { results.files = .failed(messageError ?? "") }
            }
        }
        results.serverError = messageError
        results.fromCache = messageError != nil && !criteria.query.isEmpty
        // Files and the footer are ready; links can take longer.
        if wanted.contains(.links) { onChange?() }
        let linkResult = await links
        guard current(attempt, session) else { return }
        if wanted.contains(.links) {
            if case .loaded(let rows) = linkResult {
                results.links = .loaded(rows.filter { Self.linkAllowed($0, session) })
            } else { results.links = linkResult }
        }
        onChange?()
    }

    private struct Cached { var messages: [SearchHit]; var files: [SearchHit] }

    /// The server's hits for `tab` plus the cached ones it lacked, noted
    /// in `results.cacheOnly` for the footer.
    private func merged(_ server: [SearchHit], _ cached: [SearchHit], tab: SearchTab) -> [SearchHit] {
        let hits = SearchHit.merging(server: server, cached: cached)
        results.serverHits[tab] = server.count
        if hits.count > server.count { results.cacheOnly.insert(tab) } else { results.cacheOnly.remove(tab) }
        return hits
    }

    /// The cache's matches, narrowed by the same filters the server
    /// applies. Saved and mention filters need metadata the cache may lack,
    /// so cached results can be incomplete; the footer says so.
    private func cachedHits(_ criteria: SearchCriteria, parents: [String: String], now: Date, calendar: Calendar, session: AccountSession) async -> Cached {
        guard let cached = try? await session.store.search(criteria.query) else { return Cached(messages: [], files: []) }
        let user = session.account.user
        let known = Set(session.channels.map(\.id))
        func hits(_ criteria: SearchCriteria) -> [SearchHit] {
            cached.compactMap { message in
                let conversation = parents[message.channelID] ?? message.channelID
                guard known.contains(conversation), Self.allowed(message.channelID, conversation, session), !session.deletedIDs.contains(message.id),
                      criteria.matches(message, channels: session.channels, currentUser: user, threadParents: parents, now: now, calendar: calendar) else { return nil }
                let plain = (try? RichTextCodec.parse(message.html)).map { RichTextCodec.plainText($0) } ?? ""
                return SearchHit(message: message, plainText: plain, query: criteria.query, threadParents: parents, currentUser: user)
            }
        }
        return Cached(messages: hits(criteria.on(.messages)), files: hits(criteria.on(.files)))
    }

    /// Threads in a conversation or workspace: the ones the reader follows
    /// and the others they can see, most recently active first.
    private func threads(for scope: SearchCriteria.Scope, session: AccountSession) async -> ([JSONValue], String?) {
        let key: String
        var arguments: [String: JSONValue] = ["limit": .number(Double(Self.threadLimit)), "start_after": .number(0), "fetch_members": .bool(false)]
        switch scope {
        case .account: return ([], nil)
        case .conversation(let id): key = "c:" + id; arguments["channel_id"] = .string(id)
        case .workspace(let id): key = "w:" + id; arguments["workspace"] = .string(id)
        }
        if let cached = threadCache[key], Date().timeIntervalSince(cached.at) < Self.threadFreshness { return (cached.rows, cached.note) }
        let client = session.client
        async let mine = Self.rows("raven.api.threads.get_all_threads", arguments, client: client)
        async let others = Self.rows("raven.api.threads.get_other_threads", arguments, client: client)
        let (followed, visible) = await (mine, others)
        var note: String?
        if followed == nil || visible == nil { note = "Some thread replies could not be included." }
        else if (followed?.count ?? 0) >= Self.threadLimit || (visible?.count ?? 0) >= Self.threadLimit { note = "Thread replies come from the most recently active threads." }
        let rows = (followed ?? []) + (visible ?? [])
        // A failed list is not kept, so the next search asks again.
        if followed != nil, visible != nil { threadCache[key] = (rows, note, Date()) }
        return (rows, note)
    }

    private static func parents(of scope: SearchCriteria.Scope, session: AccountSession) -> Set<String> {
        switch scope {
        case .account: []
        case .conversation(let id): [id]
        case .workspace(let workspace): Set(session.channels.filter { !$0.isDM && !$0.raw["is_thread"].bool && $0.workspace == workspace }.map(\.id))
        }
    }

    private static func linkAllowed(_ row: JSONValue, _ session: AccountSession) -> Bool {
        allowed(row["channel_id"].string ?? "", row["parent_channel_id"].string ?? row["channel_id"].string ?? "", session) && !session.deletedIDs.contains(row["message_id"].string ?? "")
    }

    private static func allowed(_ channel: String, _ conversation: String, _ session: AccountSession) -> Bool {
        // A deleted thread's ID is its root message's, kept in deletedIDs.
        !channel.isEmpty && !session.revokedChannels.contains(channel) && !session.revokedChannels.contains(conversation)
            && !session.deletedIDs.contains(channel) && !session.deletedIDs.contains(conversation)
            && !ChannelPolicy.isRevoked(channelID: channel, revoked: session.revokedChannels, threadParents: session.threadParents)
    }

    // MARK: Requests

    nonisolated private static func index(query: String, filters: [String: JSONValue], client: RavenClient) async throws -> [JSONValue] {
        let json = String(decoding: try JSONEncoder().encode(JSONValue.object(filters)), as: UTF8.self)
        let arguments: [String: JSONValue] = ["query": .string(query), "filters": .string(json), "limit": .number(Double(serverLimit))]
        let response = try await client.rpc("raven.api.search.sqlite_search", arguments: arguments)
        // Narrow again here: a server that ignored the channel filter must
        // not widen the scope the reader chose.
        return CollectionPaging.scopedSearchRows(try CollectionPaging.decodeRows(response), source: CollectionSource(method: "raven.api.search.sqlite_search", arguments: arguments, strategy: .none, pageSize: serverLimit))
    }

    nonisolated private static func links(_ criteria: SearchCriteria, client: RavenClient) async -> Part<[JSONValue]> {
        do {
            let source = try LinkSearch.source(criteria)
            let response = try await client.rpc(source.method, arguments: CollectionPaging.pageArguments(source, offset: 0))
            return .loaded(CollectionPaging.scopedSearchRows(try CollectionPaging.decodeRows(response), source: source).map(LinkSearch.normalize))
        } catch let error as SearchCriteriaError {
            return .failed(error.errorDescription ?? "Links cannot be searched here.")
        } catch {
            return .failed("Links search failed: \(StatusLocalization.errorDescription(error)). This site may not support it.")
        }
    }

    nonisolated private static func rows(_ method: String, _ arguments: [String: JSONValue], client: RavenClient) async -> [JSONValue]? {
        guard let response = try? await client.rpc(method, arguments: arguments), case .array(let rows) = response else { return nil }
        return rows
    }
}
