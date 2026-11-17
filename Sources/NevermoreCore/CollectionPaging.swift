import Foundation
import CryptoKit
import RavenProtocol

/// A verified server collection endpoint that a `CollectionWindow` can refetch
/// and (when the server contract supports it) page through.
///
/// Only offset arguments confirmed against the pinned server contracts are
/// exposed: `raven.api.notifications.get_notifications(start)`,
/// `raven.api.threads.get_all_threads(start_after)` and
/// `raven.api.raven_message.get_saved_messages(start)` accept a numeric offset.
/// `raven.api.search.sqlite_search` has **no** offset/cursor argument, and
/// `get_reminders` / `get_scheduled_messages` take no paging arguments, so
/// those sources use `.none` and never offer "Load More".
public struct CollectionSource: Sendable, Equatable {
    public enum Strategy: Sendable, Equatable {
        /// The endpoint accepts a numeric offset under `parameter`.
        case offset(parameter: String)
        /// No verified server paging argument; refresh only.
        case none
        public var label: String {
            switch self {
            case .offset(let parameter): return "offset(\(parameter))"
            case .none: return "no server paging"
            }
        }
    }
    public let method: String
    public let arguments: [String: JSONValue]
    public let strategy: Strategy
    public let pageSize: Int
    /// Server list endpoints cap `limit` at 100; the default page is 50.
    public static let defaultPageSize = 50
    public init(method: String, arguments: [String: JSONValue] = [:], strategy: Strategy = .none, pageSize: Int = defaultPageSize) {
        self.method = method
        self.arguments = arguments
        self.strategy = strategy
        self.pageSize = max(1, min(pageSize, 100))
    }
    /// True only when the server contract verifiably supports offset paging.
    public var supportsPaging: Bool {
        if case .offset = strategy { return true }
        return false
    }
    /// Account-store projection key for the cached copy of this collection.
    public var cacheKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(JSONValue.object(arguments))) ?? Data()
        return method + "." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Pure helpers for collection paging, deduplication and response handling.
public enum CollectionPaging {
    /// Preserve a requested channel scope even if an older server adapter
    /// returns a broader candidate set. Used for first loads and refreshes.
    public static func scopedSearchRows(_ rows: [JSONValue], source: CollectionSource) -> [JSONValue] {
        if source.method == LinkSearch.method {
            if let id = source.arguments["channel_id"]?.string { return rows.filter { $0["channel_id"].string == id } }
            // A conversation with its threads: replies carry the parent.
            if let id = source.arguments["parent_channel_id"]?.string { return rows.filter { $0["channel_id"].string == id || $0["parent_channel_id"].string == id } }
            return rows
        }
        guard source.method == "raven.api.search.sqlite_search" else { return rows }
        let filter = source.arguments["filters"]?.nested["channel_id"] ?? .null
        let ids: Set<String>
        switch filter {
        case .null: return rows
        case .string(let id): ids = id.isEmpty ? [] : [id]
        case .array(let values): ids = Set(values.compactMap(\.string).filter { !$0.isEmpty })
        default: return []
        }
        return rows.filter { ids.contains($0["channel_id"].string ?? "") }
    }
    /// Request arguments for one page: the source's base arguments plus
    /// `limit = pageSize` and, only for `.offset` strategies, the offset
    /// argument. `.none` sources never receive an offset parameter.
    public static func pageArguments(_ source: CollectionSource, offset: Int = 0) -> [String: JSONValue] {
        var arguments = source.arguments
        if source.supportsPaging || source.method == "raven.api.search.sqlite_search" || arguments["limit"] != nil { arguments["limit"] = .number(Double(source.pageSize)) }
        if case .offset(let parameter) = source.strategy {
            arguments[parameter] = .number(Double(max(0, offset)))
        }
        return arguments
    }

    /// A full page means more rows may exist; a short page ends paging.
    public static func hasMore(received: Int, pageSize: Int) -> Bool {
        received >= max(1, pageSize)
    }

    /// The opaque server id of a record. Notification rows are keyed by their
    /// own notification id (`name`), never by the message they reference, so a
    /// mention and a reaction about the same message both survive dedup; the
    /// `message_id` fallback only applies when no id exists at all.
    public static func recordKey(_ record: JSONValue) -> String? {
        if let key = record["Nevermore.LinkKey"].string { return key }
        guard let id = record["name"].string ?? record["id"].string ?? record["message_id"].string else { return nil }
        return record["notification_type"].string.map { $0 + ":" + id } ?? id
    }

    /// Keeps the first occurrence of each key; records without a key are kept
    /// and never treated as duplicates of each other.
    public static func deduplicate(_ records: [JSONValue], key: (JSONValue) -> String? = recordKey) -> [JSONValue] {
        var seen = Set<String>()
        var output: [JSONValue] = []
        for record in records {
            if let id = key(record) {
                guard !seen.contains(id) else { continue }
                seen.insert(id)
            }
            output.append(record)
        }
        return output
    }

    public static func decodeRows(_ response: JSONValue) throws -> [JSONValue] {
        if case .array(let rows) = response { return rows }
        if case .array(let rows) = response["messages"] { return rows }
        throw RavenError.invalidResponse
    }
    /// Collection endpoints answer either a bare array or a `messages` envelope.
    public static func extractRows(_ response: JSONValue) -> [JSONValue] {
        if case .array(let rows) = response { return rows }
        return response["messages"].array
    }
}

/// Pure paging/dedup state for one collection window, with a generation token
/// so delayed responses from a closed, switched or superseded collection are
/// rejected instead of repopulating it.
public struct CollectionPager: Sendable, Equatable {
    public var records: [JSONValue]
    /// Server offset of the next page (advances by received rows, not by the
    /// deduplicated local count, because the server counts its own rows).
    public var nextOffset: Int
    public var hasMore: Bool
    public var generation: Int
    public let pageSize: Int

    public init(records: [JSONValue] = [], pageSize: Int = CollectionSource.defaultPageSize) {
        self.pageSize = max(1, min(pageSize, 100))
        self.records = CollectionPaging.deduplicate(records)
        self.nextOffset = records.count
        self.hasMore = true
        self.generation = 0
    }

    /// Starts a refresh and returns its generation. In-flight pages captured
    /// against an older generation become stale.
    public mutating func beginRefresh() -> Int {
        generation &+= 1
        hasMore = true
        return generation
    }

    /// Invalidates every in-flight page (window closed, account switched,
    /// access revoked). Delayed results are then rejected.
    public mutating func invalidate() {
        generation &+= 1
        hasMore = false
    }

    /// Replaces all records with a first page. Returns false when stale.
    @discardableResult
    public mutating func applyRefresh(_ page: [JSONValue], generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        records = CollectionPaging.deduplicate(page)
        nextOffset = page.count
        hasMore = CollectionPaging.hasMore(received: page.count, pageSize: pageSize)
        return true
    }

    /// Appends a page, deduplicating across page boundaries. Returns false when
    /// stale or when paging already ended.
    @discardableResult
    public mutating func applyAppend(_ page: [JSONValue], generation: Int) -> Bool {
        guard generation == self.generation, hasMore else { return false }
        records = CollectionPaging.deduplicate(records + page)
        nextOffset += page.count
        hasMore = CollectionPaging.hasMore(received: page.count, pageSize: pageSize)
        return true
    }
}
