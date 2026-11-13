import Foundation

/// Account-local reading metadata. A global budget includes channel keys,
/// validated visit strings and historical identities across every open window.
public struct TranscriptChannelStateCache: Sendable {
    public struct HistoricalPage: Sendable, Equatable {
        public let ids: Set<Data>
        public let complete: Bool
    }
    private struct Entry: Sendable {
        let channelID: String
        var visit: TranscriptReadPosition.Visit?
        var page: HistoricalPage?
        var age: UInt64 = 0
        var bytes: Int {
            let visitBytes: Int
            if case .timestamp(let raw) = visit { visitBytes = raw.utf8.count } else { visitBytes = 0 }
            return channelID.utf8.count * 2 + visitBytes + (page?.ids.reduce(0) { $0 + $1.count } ?? 0)
        }
    }
    private let maximumEntries: Int
    private let maximumBytes: Int
    private let maximumIdentities: Int
    private var entries: [Data: Entry] = [:]
    private var age: UInt64 = 0
    // One conservative bit replaces an unbounded set of per-channel tombstones.
    private var discardedHistory = false
    private(set) var retainedBytes = 0
    private(set) var retainedIdentityCount = 0
    var entryCount: Int { entries.count }

    public init() { self.init(maximumEntries: 16, maximumBytes: 128 * 1024, maximumIdentities: 2048) }
    init(maximumEntries: Int, maximumBytes: Int, maximumIdentities: Int) {
        precondition(maximumEntries > 0 && maximumBytes >= 0 && maximumIdentities >= 0)
        self.maximumEntries = maximumEntries; self.maximumBytes = maximumBytes; self.maximumIdentities = maximumIdentities
    }

    private static func key(_ value: String) -> Data? {
        let bytes = Data(value.utf8.prefix(8193))
        return !bytes.isEmpty && bytes.count <= 8192 ? bytes : nil
    }

    public func visit(for channelID: String) -> TranscriptReadPosition.Visit? {
        Self.key(channelID).flatMap { entries[$0]?.visit }
    }
    public func historicalPage(for channelID: String) -> HistoricalPage? {
        if let key = Self.key(channelID), let page = entries[key]?.page { return page }
        return discardedHistory ? HistoricalPage(ids: [], complete: false) : nil
    }

    public mutating func recordVisit(_ visit: TranscriptReadPosition.Visit, channelID: String) {
        if case .timestamp(let raw) = visit, ServerTimestampParser(siteTimeZone: .gmt).date(from: raw) == nil { return }
        guard let key = Self.key(channelID) else { return }
        var entry = entries[key] ?? Entry(channelID: channelID)
        entry.visit = visit
        store(entry, key: key)
    }

    public mutating func recordHistoricalPage(messageIDs: [String], channelID: String) {
        guard let key = Self.key(channelID) else { discardedHistory = true; return }
        var ids = Set<Data>(), bytes = 0
        var complete = messageIDs.count <= 1000
        for raw in messageIDs.prefix(1000) {
            guard let id = Self.key(raw) else { complete = false; continue }
            if ids.contains(id) { continue }
            guard id.count <= 64 * 1024 - bytes else { complete = false; continue }
            ids.insert(id); bytes += id.count
        }
        var entry = entries[key] ?? Entry(channelID: channelID)
        entry.page = HistoricalPage(ids: ids, complete: complete)
        store(entry, key: key)
    }

    public mutating func removeVisit(for channelID: String) {
        guard let key = Self.key(channelID), var entry = entries[key] else { return }
        entry.visit = nil
        if entry.page == nil { remove(key) } else { store(entry, key: key) }
    }

    /// Called as interests or permissions change, before stale async loads can
    /// contribute metadata. No identifiers from discarded contexts survive.
    public mutating func retain(where eligible: (String) -> Bool) {
        for (key, entry) in entries where !eligible(entry.channelID) { remove(key) }
    }
    public mutating func removeAll() {
        entries.removeAll(); retainedBytes = 0; retainedIdentityCount = 0; age = 0; discardedHistory = false
    }

    private mutating func remove(_ key: Data) {
        guard let old = entries.removeValue(forKey: key) else { return }
        retainedBytes -= old.bytes; retainedIdentityCount -= old.page?.ids.count ?? 0
        if old.page != nil { discardedHistory = true }
    }
    private mutating func store(_ value: Entry, key: Data) {
        var entry = value
        if age == .max {
            let hadHistory = discardedHistory || entries.values.contains { $0.page != nil }
            removeAll(); discardedHistory = hadHistory
        }
        if let old = entries.removeValue(forKey: key) {
            retainedBytes -= old.bytes; retainedIdentityCount -= old.page?.ids.count ?? 0
        }
        let bytes = entry.bytes, identities = entry.page?.ids.count ?? 0
        guard bytes <= maximumBytes, identities <= maximumIdentities else {
            if entry.page != nil { discardedHistory = true }
            return
        }
        while entries.count >= maximumEntries || retainedBytes > maximumBytes - bytes || retainedIdentityCount > maximumIdentities - identities {
            guard let oldest = entries.min(by: { $0.value.age < $1.value.age })?.key else { break }
            remove(oldest)
        }
        age += 1; entry.age = age
        entries[key] = entry; retainedBytes += bytes; retainedIdentityCount += identities
    }
}
