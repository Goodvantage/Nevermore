import Foundation
import RavenProtocol

/// Rules for how the transcript groups messages under a sender header,
/// as Slack and Teams do: one avatar and name per run of messages.
public enum TranscriptGrouping {
    /// Messages from one author closer together than this share a header.
    public static let continuationWindow: TimeInterval = 5 * 60

    public struct Entry: Sendable, Equatable {
        public let authorID: String
        public let date: Date?
        public let isSystem: Bool
        public let batchID: String?

        public init(authorID: String, date: Date?, isSystem: Bool, batchID: String?) {
            self.authorID = authorID; self.date = date; self.isSystem = isSystem; self.batchID = batchID
        }

        public init(_ message: RavenMessage, date: Date?) {
            self.init(authorID: message.authorID, date: date, isSystem: message.messageType == "System", batchID: message.batchID)
        }
    }

    /// Whether `current` continues the group `previous` belongs to and so
    /// needs no header. System events always stand alone. An unknown date
    /// or author starts a new group rather than hiding who wrote what.
    public static func continues(_ current: Entry, after previous: Entry?, calendar: Calendar) -> Bool {
        guard let previous, !current.isSystem, !previous.isSystem, !current.authorID.isEmpty, current.authorID == previous.authorID else { return false }
        // One multi-file send is one logical message.
        if let batch = current.batchID, batch == previous.batchID { return true }
        guard let date = current.date, let earlier = previous.date, calendar.isDate(date, inSameDayAs: earlier) else { return false }
        return abs(date.timeIntervalSince(earlier)) <= continuationWindow
    }

    /// Whether a day divider belongs before `date`. The first dated message
    /// gets one so the loaded history always says which day it starts on.
    public static func startsNewDay(_ date: Date?, after previous: Date?, calendar: Calendar) -> Bool {
        guard let date else { return false }
        guard let previous else { return true }
        return !calendar.isDate(date, inSameDayAs: previous)
    }
}

/// How a day divider names its day, relative to now.
public enum TranscriptDay: Sendable, Equatable {
    case today, yesterday
    /// Two to six days ago: the weekday name alone is unambiguous.
    case recent
    case thisYear, otherYear

    public static func classify(_ date: Date, now: Date, calendar: Calendar) -> TranscriptDay {
        let start = calendar.startOfDay(for: date), today = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: start, to: today).day ?? Int.max
        switch days {
        case 0: return .today
        case 1: return .yesterday
        case 2...6: return .recent
        default:
            return calendar.component(.year, from: date) == calendar.component(.year, from: now) ? .thisYear : .otherYear
        }
    }
}

/// Initials and a stable color slot for avatars without a photo.
public enum AvatarMonogram {
    /// "Benedikt" → "B", "Lukas Mathis" → "LM", "alex.rivera@example.com" → "AR".
    public static func initials(for name: String) -> String {
        var source = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.contains(" "), let at = source.firstIndex(of: "@") { source = String(source[..<at]) }
        let words = source.split { $0.isWhitespace || $0 == "." || $0 == "_" || $0 == "-" }
            .filter { $0.first.map { $0.isLetter || $0.isNumber } == true }
        guard let first = words.first?.first else { return "?" }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }

    /// FNV-1a over the user ID, so a person keeps one color across launches
    /// (Swift's `Hasher` is seeded per process).
    public static func paletteIndex(for id: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return Int(hash % UInt64(count))
    }
}

/// One reaction under a message: "👍 2", marked when it includes yours.
public struct ReactionChip: Sendable, Equatable {
    public let label: String
    public let count: Int
    public let includesCurrentUser: Bool

    public init(label: String, count: Int, includesCurrentUser: Bool) {
        self.label = label; self.count = count; self.includesCurrentUser = includesCurrentUser
    }

    /// Chips for Raven's `message_reactions` map, or nil for shapes it
    /// cannot read. Raven stores `{key: {count, users, reaction, is_custom,
    /// emoji_name}}`; older rows may hold a bare count.
    public static func chips(_ json: JSONValue, currentUser: String) -> [ReactionChip]? {
        guard case .object(let object) = json, !object.isEmpty else { return nil }
        var chips: [ReactionChip] = []
        for key in object.keys.sorted().prefix(20) {
            let value = object[key] ?? .null
            var count: Double?
            var label = key
            var mine = false
            switch value {
            case .number(let number): count = number
            case .object:
                if case .number(let number) = value["count"] { count = number }
                if value["is_custom"].bool { label = ":\(value["emoji_name"].string ?? key):" }
                else if let reaction = value["reaction"].string, !reaction.isEmpty { label = reaction }
                mine = !currentUser.isEmpty && value["users"].array.contains { $0.string == currentUser }
            default: return nil
            }
            guard let count, count.isFinite, count >= 1 else { continue }
            chips.append(ReactionChip(label: label, count: Int(min(count, 9999)), includesCurrentUser: mine))
        }
        return chips.isEmpty ? nil : chips
    }
}
