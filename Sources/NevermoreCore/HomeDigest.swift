import Foundation
import RavenProtocol

/// A section of Home. The raw values are stored in preferences, so a case
/// must never be renamed; a removed case is dropped when layouts load.
public enum HomeModule: String, CaseIterable, Codable, Sendable {
    case favorites, unread, later, people, week, threads, files

    public var title: String {
        switch self {
        case .favorites: "Favorites"
        case .unread: "Unread"
        case .later: "Later"
        case .people: "People You Talk With Most"
        case .week: "Your Week"
        case .threads: "Threads You Follow"
        case .files: "Recent Files"
        }
    }
}

/// Which Home modules show, and in what order. Every module appears in
/// `order` exactly once, so a module added in a later version shows up
/// (at the end) in layouts saved before it existed.
public struct HomeLayout: Equatable, Sendable, Codable {
    public private(set) var order: [HomeModule]
    public private(set) var hidden: Set<HomeModule>

    public static let standard = HomeLayout(order: HomeModule.allCases, hidden: [])
    public static let defaultsKey = "homeLayout"

    public init(order: [HomeModule], hidden: Set<HomeModule>) {
        var seen = Set<HomeModule>()
        let kept = order.filter { seen.insert($0).inserted }
        self.order = kept + HomeModule.allCases.filter { !seen.contains($0) }
        self.hidden = hidden
    }

    public var visible: [HomeModule] { order.filter { !hidden.contains($0) } }

    public mutating func setVisible(_ module: HomeModule, _ visible: Bool) {
        if visible { hidden.remove(module) } else { hidden.insert(module) }
    }

    /// Moves a module to `index` in the full order, clamped to the ends.
    public mutating func move(_ module: HomeModule, to index: Int) {
        guard let from = order.firstIndex(of: module) else { return }
        order.remove(at: from)
        order.insert(module, at: min(max(0, index), order.count))
    }

    private enum CodingKeys: String, CodingKey { case order, hidden }

    /// Unknown raw values (from a newer or older build) are skipped rather
    /// than failing the whole layout.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let order = try container.decodeIfPresent([String].self, forKey: .order) ?? []
        let hidden = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
        self.init(order: order.compactMap(HomeModule.init(rawValue:)), hidden: Set(hidden.compactMap(HomeModule.init(rawValue:))))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(order.map(\.rawValue), forKey: .order)
        try container.encode(HomeModule.allCases.filter(hidden.contains).map(\.rawValue), forKey: .hidden)
    }

    /// The stored layout, or the standard one when nothing valid is stored.
    public static func decode(_ data: Data?) -> HomeLayout {
        guard let data, data.count <= 4096, let layout = try? JSONDecoder().decode(HomeLayout.self, from: data) else { return .standard }
        return layout
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}

/// The newest message of a conversation as the channel list reports it
/// (`last_message_details`). Reading it costs no request and never marks
/// anything read.
public struct HomeLatestMessage: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case text, image, file, poll, system }

    public var messageID: String?
    /// The bot for bot messages, as `RavenMessage.authorID` does.
    public var authorID: String
    public var kind: Kind
    /// One line of plain text; empty for attachments without a caption.
    public var text: String
    public var timestamp: String?

    static let maximumTextLength = 240

    public init(messageID: String?, authorID: String, kind: Kind, text: String, timestamp: String?) {
        self.messageID = messageID
        self.authorID = authorID
        self.kind = kind
        self.text = Self.oneLine(text)
        self.timestamp = timestamp
    }

    public static func kind(messageType: String?) -> Kind {
        switch messageType {
        case "Image": .image
        case "File": .file
        case "Poll": .poll
        case "System": .system
        default: .text
        }
    }

    public init?(channel: RavenChannel) {
        let details = channel.raw["last_message_details"].nested
        guard case .object = details else { return nil }
        let owner = details["owner"].string ?? ""
        let bot = details["bot"].string ?? ""
        authorID = details["is_bot_message"].bool && !bot.isEmpty ? bot : owner
        messageID = details["message_id"].string
        kind = Self.kind(messageType: details["message_type"].string)
        text = Self.oneLine(details["content"].string ?? "")
        timestamp = channel.raw["last_message_timestamp"].string
        guard !authorID.isEmpty || !text.isEmpty else { return nil }
    }

    /// Collapses runs of whitespace, including line breaks, and bounds the
    /// length so a pasted log cannot stretch a row's layout work.
    static func oneLine(_ text: String) -> String {
        let words = text.prefix(maximumTextLength * 4).split(whereSeparator: \.isWhitespace)
        let line = words.joined(separator: " ")
        guard line.count > maximumTextLength else { return line }
        return String(line.prefix(maximumTextLength)) + "…"
    }
}

/// One conversation in Home's Unread module.
public struct HomeUnreadEntry: Equatable, Sendable {
    public var channel: RavenChannel
    public var count: Int
    public var mentioned: Bool
    public var latest: HomeLatestMessage?
}

/// Unread conversations for Home. Muted and archived conversations are not
/// news (see `AttentionPolicy`); muted ones are only summed for one quiet
/// line, and archived ones are left out.
public struct HomeUnreadDigest: Equatable, Sendable {
    /// Newest first.
    public var entries: [HomeUnreadEntry]
    public var mutedMessages: Int
    public var mutedConversations: Int

    public var total: Int { entries.reduce(0) { min(9999, $0 + $1.count) } }

    /// `fallback` stands in for channels the server sent without
    /// `last_message_details`, from the newest cached message.
    public static func make(channels: [RavenChannel], unread: JSONValue, mentioned: Set<String>, fallback: [String: HomeLatestMessage] = [:]) -> HomeUnreadDigest {
        var counts: [String: Int] = [:]
        for row in unread.array {
            guard let id = row["name"].string, case .number(let value) = row["unread_count"], value.isFinite, value >= 1 else { continue }
            counts[id] = max(counts[id, default: 0], Int(min(9999, value)))
        }
        var entries: [HomeUnreadEntry] = []
        var mutedMessages = 0, mutedConversations = 0
        // A malformed channel list can name a conversation twice; count it once.
        var seen: Set<String> = []
        for channel in channels {
            guard let count = counts[channel.id], !channel.raw["is_archived"].bool, !channel.raw["is_thread"].bool, seen.insert(channel.id).inserted else { continue }
            if channel.raw["muted"].bool {
                mutedMessages = min(9999, mutedMessages + count); mutedConversations += 1
                continue
            }
            entries.append(HomeUnreadEntry(channel: channel, count: count, mentioned: mentioned.contains(channel.id), latest: HomeLatestMessage(channel: channel) ?? fallback[channel.id]))
        }
        // Server timestamps share one fixed-width format, so they sort as
        // strings. Conversations without one go last, by title.
        func newest(_ entry: HomeUnreadEntry) -> String { entry.channel.raw["last_message_timestamp"].string ?? entry.latest?.timestamp ?? "" }
        entries.sort { a, b in
            let left = newest(a), right = newest(b)
            if left != right { return left > right }
            return a.channel.title.localizedCaseInsensitiveCompare(b.channel.title) == .orderedAscending
        }
        return HomeUnreadDigest(entries: entries, mutedMessages: mutedMessages, mutedConversations: mutedConversations)
    }
}

/// The newest message in one conversation's local cache, or why it could
/// not be read. Mark All Read collects these before it confirms anything,
/// so the sheet never promises a conversation it cannot acknowledge.
public enum HomeCachedNewest: Equatable, Sendable {
    /// The newest cached creation timestamp, in Frappe's datetime format.
    case message(String)
    /// The cache answered but held no message for the conversation.
    case empty
    /// Reading the cache failed.
    case failed
}

/// One conversation Mark All Read can acknowledge, with the newest
/// timestamp it will mark seen.
public struct HomeMarkAllReadTarget: Equatable, Sendable {
    public let channel: RavenChannel
    public let timestamp: String
}

/// The conversations Mark All Read can acknowledge and the ones it
/// cannot. Resolved from the unread digest plus the newest cached message
/// of every conversation whose reported timestamp is missing or unusable,
/// all before the confirmation appears.
public struct HomeMarkAllReadPlan: Equatable, Sendable {
    public let targets: [HomeMarkAllReadTarget]
    /// Conversations with neither a usable reported timestamp nor a
    /// cached message.
    public let skipped: Int
    /// Conversations whose cache could not be read.
    public let unavailable: Int

    public var isEmpty: Bool { targets.isEmpty }

    public init(entries: [HomeUnreadEntry], cached: [String: HomeCachedNewest]) {
        var targets: [HomeMarkAllReadTarget] = []
        var skipped = 0
        var unavailable = 0
        for entry in entries {
            if let reported = entry.latest?.timestamp, Self.acceptsTimestamp(reported) {
                targets.append(HomeMarkAllReadTarget(channel: entry.channel, timestamp: reported))
                continue
            }
            switch cached[entry.channel.id] {
            case .message(let creation) where Self.acceptsTimestamp(creation):
                targets.append(HomeMarkAllReadTarget(channel: entry.channel, timestamp: creation))
            case .failed:
                unavailable += 1
            default:
                // `.empty`, an invalid cached timestamp and a channel the
                // caller never asked about all leave nothing to mark.
                skipped += 1
            }
        }
        self.targets = targets
        self.skipped = skipped
        self.unavailable = unavailable
    }

    /// Whether `markSeen` will accept this timestamp. The server validates
    /// the same format with `ServerTimestampParser`, so an unparseable
    /// value would silently mark nothing.
    public static func acceptsTimestamp(_ timestamp: String?) -> Bool {
        guard let timestamp, !timestamp.isEmpty else { return false }
        return ServerTimestampParser(siteTimeZone: .gmt).date(from: timestamp) != nil
    }
}

/// The reader's own sending over the last two weeks. Built only from
/// messages the reader wrote; nothing here describes anyone else.
public struct HomeWeekSummary: Equatable, Sendable {
    /// Messages per day for the last seven days, oldest first; the last
    /// entry is today.
    public var days: [Int]
    public var previousWeek: Int
    /// Start of the hour (0 to 23) with the most messages in the last
    /// seven days; the earlier hour wins a tie. Nil without messages.
    public var busiestHour: Int?
    public var busiestHourCount: Int

    public var thisWeek: Int { days.reduce(0, +) }

    /// The line under the week's count. Neither more nor fewer is good or
    /// bad, so both read the same way; a count up from nothing says so
    /// rather than calling all of it "more".
    public var comparison: String {
        let difference = thisWeek - previousWeek
        if difference == 0 { return "Same as the week before" }
        if previousWeek == 0 { return "None the week before" }
        return "\(abs(difference)) \(difference > 0 ? "more" : "fewer") than the week before"
    }

    public static let dayCount = 7

    public static func make(sent: [Date], now: Date, calendar: Calendar) -> HomeWeekSummary {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let previousStart = calendar.date(byAdding: .day, value: -dayCount, to: start),
              let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
            return HomeWeekSummary(days: Array(repeating: 0, count: dayCount), previousWeek: 0, busiestHour: nil, busiestHourCount: 0)
        }
        var days = Array(repeating: 0, count: dayCount)
        var hours = Array(repeating: 0, count: 24)
        var previous = 0
        for date in sent where date < tomorrow {
            if date >= start {
                // Day steps, not 86,400-second steps: a daylight saving
                // change makes one day 23 or 25 hours long.
                let day = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day ?? -1
                guard days.indices.contains(day) else { continue }
                days[day] += 1
                hours[calendar.component(.hour, from: date)] += 1
            } else if date >= previousStart {
                previous += 1
            }
        }
        let peak = hours.max() ?? 0
        return HomeWeekSummary(days: days, previousWeek: previous, busiestHour: peak > 0 ? hours.firstIndex(of: peak) : nil, busiestHourCount: peak)
    }
}

/// The people the reader writes to most in direct messages.
public enum HomePeople {
    public struct Sent: Equatable, Sendable {
        public var channelID: String
        public var date: Date
        public init(channelID: String, date: Date) { self.channelID = channelID; self.date = date }
    }

    public static let window: TimeInterval = 30 * 24 * 60 * 60

    /// Ranks direct-message peers by how many messages the reader sent them
    /// in the last 30 days, the most recent winning a tie. When fewer than
    /// `limit` people qualify, the most recently active direct messages
    /// fill the rest. The reader's own notes-to-self conversation and
    /// archived conversations are skipped.
    public static func rank(sent: [Sent], channels: [RavenChannel], me: String, now: Date, limit: Int = 5) -> [String] {
        var peers: [String: String] = [:]
        var recent: [(peer: String, timestamp: String)] = []
        for channel in channels where channel.isDM && !channel.raw["is_archived"].bool {
            guard let peer = channel.raw["peer_user_id"].string, !peer.isEmpty, peer != me else { continue }
            peers[channel.id] = peer
            recent.append((peer, channel.raw["last_message_timestamp"].string ?? ""))
        }
        var counts: [String: Int] = [:], latest: [String: Date] = [:]
        let cutoff = now.addingTimeInterval(-window)
        for message in sent where message.date >= cutoff && message.date <= now {
            guard let peer = peers[message.channelID] else { continue }
            counts[peer, default: 0] += 1
            latest[peer] = max(latest[peer] ?? .distantPast, message.date)
        }
        var ranked = counts.keys.sorted { a, b in
            if counts[a] != counts[b] { return counts[a, default: 0] > counts[b, default: 0] }
            if latest[a] != latest[b] { return latest[a, default: .distantPast] > latest[b, default: .distantPast] }
            return a < b
        }
        ranked = Array(ranked.prefix(limit))
        for candidate in recent.sorted(by: { $0.timestamp > $1.timestamp }) where ranked.count < limit && !candidate.timestamp.isEmpty {
            if !ranked.contains(candidate.peer) { ranked.append(candidate.peer) }
        }
        return ranked
    }
}
