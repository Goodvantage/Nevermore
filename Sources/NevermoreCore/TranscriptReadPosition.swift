import Foundation
import RavenProtocol

/// UI-local reading position, independent of the server's unread counts and
/// visit mutations. Only already-authorized message projections are inputs.
public struct TranscriptReadPosition: Sendable {
    public enum Visit: Equatable, Sendable {
        case neverVisited
        case timestamp(String)
    }
    private let parser = ServerTimestampParser(siteTimeZone: .gmt)
    private var resolvedVisit = false
    private var boundary: Date?
    private var frontier: Date?
    private var latest: Date?
    private var frontierIdentities: Set<Data> = []
    private var latestIdentities: Set<Data> = []
    private var frontierIdentitiesComplete = true
    private var latestIdentitiesComplete = true
    private static let maximumIdentities = 2048
    private static let maximumIdentityBytes = 128 * 1024
    public private(set) var hasNewMessages = false

    public init() {}

    /// A locally observed watermark can be ahead of the last server snapshot
    /// while its durable visit is flushing. Neither source is an unread count.
    public static func effectiveVisit(server: Visit?, observedTimestamp: String?) -> Visit? {
        let parser = ServerTimestampParser(siteTimeZone: .gmt)
        guard let raw = observedTimestamp, let observed = parser.date(from: raw) else { return server }
        if case .timestamp(let timestamp) = server, let remote = parser.date(from: timestamp), remote > observed { return server }
        return .timestamp(raw)
    }

    /// Freeze the first known visit for this view. A nil visit means unknown,
    /// not "everything is unread". Compare wall-clock components consistently
    /// with Raven's naive timestamp rule, including its fractional precision.
    public mutating func observe(_ messages: [RavenMessage], currentUser: String, visit: Visit?, following: Bool, historicalIDs: Set<Data> = [], historicalIDsComplete: Bool = true) {
        if !resolvedVisit, let visit {
            switch visit {
            case .neverVisited: resolvedVisit = true
            case .timestamp(let raw):
                if let value = parser.date(from: raw) { boundary = value; resolvedVisit = true }
            }
        }
        let dated = messages.compactMap { message in parser.date(from: message.creation).map { (message, $0) } }
        latest = dated.map(\.1).max()
        let latestSnapshot = Self.identities(dated.filter { $0.1 == latest }.map(\.0))
        latestIdentities = latestSnapshot.ids; latestIdentitiesComplete = latestSnapshot.complete
        if following || frontier == nil { followedLatest() }
        // An older page can discover another ID at the same timestamp. It is
        // history expansion, not a newly received message. Absorb it without
        // advancing the timestamp watermark or the server unread divider.
        if !historicalIDs.isEmpty {
            let historical = dated.filter { $0.1 == frontier && Self.identity($0.0.id).map { historicalIDs.contains($0) } == true }.map(\.0)
            let merged = Self.merging(frontierIdentities, with: Self.identities(historical))
            frontierIdentities = merged.ids; frontierIdentitiesComplete = frontierIdentitiesComplete && merged.complete
        }
        if !historicalIDsComplete { frontierIdentitiesComplete = false }
        hasNewMessages = !following && frontier.map { frontier in
            dated.contains { message, date in
                guard Self.isIncoming(message, currentUser: currentUser) else { return false }
                if date > frontier { return true }
                guard date == frontier, frontierIdentitiesComplete, let id = Self.identity(message.id) else { return false }
                return !frontierIdentities.contains(id)
            }
        } == true
    }

    public func firstUnreadID(in messages: [RavenMessage], currentUser: String) -> String? {
        guard let boundary else { return nil }
        return messages.first { message in
            Self.isIncoming(message, currentUser: currentUser) && parser.date(from: message.creation).map { $0 > boundary } == true
        }?.id
    }

    // Match chat_stream's first-unread rule. Bots may post with the caller as
    // owner; System activity does not form an unread message boundary.
    private static func isIncoming(_ message: RavenMessage, currentUser: String) -> Bool {
        message.messageType != "System" && (message.raw["is_bot_message"].bool || (!message.owner.isEmpty && message.owner != currentUser))
    }

    /// Snapshot identities are byte-exact and independently bounded. If a
    /// timestamp group exceeds the bound, decline ambiguous tied-ID alerts;
    /// the generic Jump to Latest control remains available while away.
    private static func identity(_ value: String) -> Data? {
        let bytes = Data(value.utf8.prefix(8193))
        return !bytes.isEmpty && bytes.count <= 8192 ? bytes : nil
    }
    private static func identities(_ messages: [RavenMessage]) -> (ids: Set<Data>, complete: Bool) {
        var ids = Set<Data>(), bytes = 0
        for message in messages {
            guard let id = identity(message.id) else { return (ids, false) }
            if ids.contains(id) { continue }
            guard ids.count < maximumIdentities, id.count <= maximumIdentityBytes - bytes else { return (ids, false) }
            ids.insert(id); bytes += id.count
        }
        return (ids, true)
    }
    private static func merging(_ existing: Set<Data>, with incoming: (ids: Set<Data>, complete: Bool)) -> (ids: Set<Data>, complete: Bool) {
        var ids = existing, bytes = existing.reduce(0) { $0 + $1.count }
        for id in incoming.ids where !ids.contains(id) {
            guard ids.count < maximumIdentities, id.count <= maximumIdentityBytes - bytes else { return (ids, false) }
            ids.insert(id); bytes += id.count
        }
        return (ids, incoming.complete)
    }

    public mutating func followedLatest() {
        if let latest, frontier.map({ latest > $0 }) ?? true {
            frontier = latest; frontierIdentities = latestIdentities; frontierIdentitiesComplete = latestIdentitiesComplete
        } else if latest == frontier {
            let merged = Self.merging(frontierIdentities, with: (latestIdentities, latestIdentitiesComplete))
            frontierIdentities = merged.ids; frontierIdentitiesComplete = frontierIdentitiesComplete && merged.complete
        }
        hasNewMessages = false
    }
    public mutating func caughtUp() {
        followedLatest()
        if boundary != nil { boundary = frontier }
    }
    public mutating func reset() { self = Self() }
}
