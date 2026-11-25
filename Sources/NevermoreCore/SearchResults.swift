import Foundation
import RavenProtocol

// The search results screen (docs/design/search/SEARCH-RESULTS.md): the
// pure rules behind it, kept here so they can be tested without a window.

/// A date restriction for search. The index stores `creation` as server
/// local time text ("2026-11-10 09:30:00.123456"), so each range becomes
/// `LIKE` patterns on that text: a day, a month or a year prefix.
public enum SearchDateRange: Codable, Sendable, Equatable, Hashable {
    case today
    case yesterday
    /// The last `n` days including today, 2 to `maximumDays`.
    case lastDays(Int)
    case month(year: Int, month: Int)
    case year(Int)

    public static let maximumDays = 31

    /// `LIKE` patterns, any of which matches; newest first. `calendar` must
    /// be in the server's time zone, the zone `creation` is written in.
    public func patterns(now: Date, calendar: Calendar) -> [String] {
        switch self {
        case .today: return [Self.day(now, calendar)]
        case .yesterday: return calendar.date(byAdding: .day, value: -1, to: now).map { [Self.day($0, calendar)] } ?? []
        case .lastDays(let count):
            let days = min(max(count, 1), Self.maximumDays)
            return (0..<days).compactMap { calendar.date(byAdding: .day, value: -$0, to: now).map { Self.day($0, calendar) } }
        case .month(let year, let month):
            guard Self.valid(year: year), (1...12).contains(month) else { return [] }
            return [String(format: "%04d-%02d-", year, month)]
        case .year(let year):
            guard Self.valid(year: year) else { return [] }
            return [String(format: "%04d-", year)]
        }
    }

    /// The month before or after this one, for stepping through older
    /// matches. Other ranges have no neighbour.
    public func steppingMonth(by offset: Int) -> SearchDateRange? {
        guard case .month(let year, let month) = self else { return nil }
        let index = year * 12 + (month - 1) + offset
        let next = SearchDateRange.month(year: index / 12, month: index % 12 + 1)
        guard case .month(let newYear, _) = next, Self.valid(year: newYear) else { return nil }
        return next
    }

    /// The month `now` falls in, in `calendar`'s time zone.
    public static func monthContaining(_ now: Date, calendar: Calendar) -> SearchDateRange {
        let parts = calendar.dateComponents([.year, .month], from: now)
        return .month(year: parts.year ?? 2000, month: parts.month ?? 1)
    }

    private static func valid(year: Int) -> Bool { (1900...9999).contains(year) }

    private static func day(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private enum CodingKeys: String, CodingKey { case kind, days, year, month }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "today": self = .today
        case "yesterday": self = .yesterday
        case "lastDays":
            let days = try container.decode(Int.self, forKey: .days)
            guard (2...Self.maximumDays).contains(days) else { throw DecodingError.dataCorruptedError(forKey: .days, in: container, debugDescription: "Unsupported day count") }
            self = .lastDays(days)
        case "month":
            let year = try container.decode(Int.self, forKey: .year), month = try container.decode(Int.self, forKey: .month)
            guard Self.valid(year: year), (1...12).contains(month) else { throw DecodingError.dataCorruptedError(forKey: .month, in: container, debugDescription: "Invalid month") }
            self = .month(year: year, month: month)
        case "year":
            let year = try container.decode(Int.self, forKey: .year)
            guard Self.valid(year: year) else { throw DecodingError.dataCorruptedError(forKey: .year, in: container, debugDescription: "Invalid year") }
            self = .year(year)
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown date range")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .today: try container.encode("today", forKey: .kind)
        case .yesterday: try container.encode("yesterday", forKey: .kind)
        case .lastDays(let days): try container.encode("lastDays", forKey: .kind); try container.encode(days, forKey: .days)
        case .month(let year, let month): try container.encode("month", forKey: .kind); try container.encode(year, forKey: .year); try container.encode(month, forKey: .month)
        case .year(let year): try container.encode("year", forKey: .kind); try container.encode(year, forKey: .year)
        }
    }
}

/// One line of result text with the words the search matched. Server
/// snippets arrive with `<mark>` around matches (FTS5 `snippet()`); they are
/// read as plain text plus ranges and never rendered as HTML.
public struct SearchSnippet: Equatable, Sendable {
    public var text: String
    /// Matched ranges in UTF-16 offsets of `text`, ascending, not overlapping.
    public var highlights: [Range<Int>]

    public static let maximumLength = 400
    static let open = "<mark>", close = "</mark>"

    public init(text: String, highlights: [Range<Int>] = []) { self.text = text; self.highlights = highlights }

    /// Reads a server snippet. Runs of whitespace become one space; a
    /// `<mark>` left open closes at the end, a stray `</mark>` is dropped.
    /// Any other markup is kept as the literal text Raven indexed.
    public static func marked(_ raw: String) -> SearchSnippet {
        var text = ""
        var length = 0
        var highlights: [Range<Int>] = []
        var openAt: Int?
        var pendingSpace = false
        var full = false
        let bounded = raw.prefix(maximumLength * 4)
        var rest = Substring(bounded)
        /// Adds a character, with the space before it; false once the
        /// text would pass `maximumLength`.
        func append(_ character: Character) -> Bool {
            if character.isWhitespace { pendingSpace = !text.isEmpty; return true }
            let added = (pendingSpace ? 1 : 0) + character.utf16.count
            guard length + added <= maximumLength else { return false }
            if pendingSpace { text.append(" "); length += 1; pendingSpace = false }
            text.append(character); length += character.utf16.count
            return true
        }
        while let first = rest.first, !full {
            if first == "<", rest.hasPrefix(open) {
                rest = rest.dropFirst(open.count)
                if openAt == nil {
                    if pendingSpace, length < maximumLength { text.append(" "); length += 1 }
                    pendingSpace = false
                    openAt = length
                }
                continue
            }
            if first == "<", rest.hasPrefix(close) {
                rest = rest.dropFirst(close.count)
                if let start = openAt { if length > start { highlights.append(start..<length) }; openAt = nil }
                continue
            }
            guard append(first) else { full = true; break }
            rest = rest.dropFirst()
        }
        if let start = openAt, length > start { highlights.append(start..<length) }
        let cut = full || bounded.count < raw.count
        if cut, rest.contains(where: { !$0.isWhitespace }) || bounded.count < raw.count { text.append("…") }
        return SearchSnippet(text: text, highlights: highlights)
    }

    /// Decodes percent escapes (as in stored file names) piece by piece,
    /// so the highlights still cover the same words.
    public func removingPercentEncoding() -> SearchSnippet {
        let ns = text as NSString
        var bounds = Set([0, ns.length])
        for range in highlights where range.upperBound <= ns.length { bounds.insert(range.lowerBound); bounds.insert(range.upperBound) }
        let cuts = bounds.sorted()
        var output = ""
        var offset = 0
        var mapped: [Range<Int>] = []
        for (lower, upper) in zip(cuts, cuts.dropFirst()) {
            let piece = ns.substring(with: NSRange(location: lower, length: upper - lower))
            let decoded = piece.removingPercentEncoding ?? piece
            let count = (decoded as NSString).length
            if highlights.contains(where: { $0.lowerBound <= lower && upper <= $0.upperBound }) && count > 0 { mapped.append(offset..<(offset + count)) }
            output += decoded
            offset += count
        }
        return SearchSnippet(text: output, highlights: mapped)
    }

    /// Finds the query's words in local text, as the cache's prefix search
    /// matched them: case and diacritics are ignored, and a match starts a
    /// word. The text is cut to a window around the first match.
    public static func local(_ plain: String, query: String) -> SearchSnippet {
        // Normalize runs of whitespace for the single-line row, but search the
        // whole indexed body. Truncating to a word count first hides matches
        // late in a long pasted log and shows the message's opening instead.
        let line = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init).filter { !$0.isEmpty }
        let ns = line as NSString
        var found: [Range<Int>] = []
        for term in terms {
            var search = NSRange(location: 0, length: ns.length)
            while search.length > 0 {
                let match = ns.range(of: term, options: [.caseInsensitive, .diacriticInsensitive], range: search)
                guard match.location != NSNotFound else { break }
                let startsWord = match.location == 0 || ns.substring(with: NSRange(location: match.location - 1, length: 1)).rangeOfCharacter(from: .alphanumerics) == nil
                if startsWord { found.append(match.location..<(match.location + match.length)) }
                let next = match.location + max(match.length, 1)
                search = NSRange(location: next, length: ns.length - next)
            }
        }
        let merged = merge(found)
        // Start a little before the first match, at a word boundary. A
        // long unbroken token there, such as a pasted link, is cut instead,
        // so the match stays in the window.
        var start = 0
        if let first = merged.first?.lowerBound, first > 40 {
            let lead = first - 30
            let near = max(0, lead - 40)
            let before = ns.range(of: " ", options: .backwards, range: NSRange(location: near, length: lead - near))
            start = before.location == NSNotFound ? ns.rangeOfComposedCharacterSequence(at: lead).location : before.location + 1
        }
        let end = min(ns.length, start + maximumLength)
        var text = ns.substring(with: NSRange(location: start, length: end - start))
        var shift = 0
        if start > 0 { text = "…" + text; shift = 1 }
        if end < ns.length { text += "…" }
        let highlights = merged.compactMap { range -> Range<Int>? in
            let lower = max(range.lowerBound, start), upper = min(range.upperBound, end)
            return lower < upper ? (lower - start + shift)..<(upper - start + shift) : nil
        }
        return SearchSnippet(text: text, highlights: highlights)
    }

    private static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, range.lowerBound <= last.upperBound { merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound) }
            else { merged.append(range) }
        }
        return merged
    }
}

/// One search result, from the server index or the local cache.
public struct SearchHit: Equatable, Sendable, Identifiable {
    public var id: String
    public var channelID: String
    /// The conversation results group under: the parent for thread replies.
    public var conversationID: String
    public var isThreadReply: Bool
    /// The bot for bot messages, as `RavenMessage.authorID` does.
    public var authorID: String
    public var creation: String
    public var messageType: String
    public var snippet: SearchSnippet
    /// The file name for File and Image messages, with matched words.
    public var fileName: SearchSnippet?
    public var fileSize: Int?
    public var hasReactions: Bool
    public var startsThread: Bool
    public var isSaved: Bool
    /// The row as the server or cache sent it, for opening and attachments.
    public var raw: JSONValue

    public var isFile: Bool { messageType == "File" || messageType == "Image" }

    /// A `sqlite_search` row. Rows without a message or channel are skipped.
    public init?(row: JSONValue, currentUser: String) {
        let row = RavenSearchResult.normalize(row)
        guard let id = Self.identifier(row["name"]), let channel = Self.identifier(row["channel_id"]) else { return nil }
        self.id = id
        channelID = channel
        let parent = Self.identifier(row["parent_channel_id"])
        isThreadReply = row["is_thread_message"].bool && parent != nil && parent != channel
        conversationID = isThreadReply ? parent ?? channel : channel
        let bot = row["bot"].string ?? ""
        authorID = row["is_bot_message"].bool && !bot.isEmpty ? bot : row["owner"].string ?? ""
        creation = row["creation"].string ?? ""
        messageType = row["message_type"].string ?? "Text"
        let isFile = messageType == "File" || messageType == "Image"
        let content = SearchSnippet.marked(row["content"].string ?? "")
        let title = row["title"].string ?? ""
        // The index's title is already the file name, percent-encoded.
        fileName = isFile && !title.isEmpty ? SearchSnippet.marked(title).removingPercentEncoding() : nil
        // A file's content is its caption, or the file name when it has none.
        // Compare decoded forms: the index title is percent-encoded and the
        // caption can still carry those escapes, so a raw comparison would
        // leave the encoded name on screen twice. A caption that decodes to
        // the same name counts as an echo of it, not as distinct text. Only
        // this test decodes; the displayed caption stays as the index wrote
        // it, because genuine captions are user text and may contain `%`.
        snippet = isFile && (content.text == fileName?.text || content.removingPercentEncoding().text == fileName?.text) ? SearchSnippet(text: "") : content
        fileSize = Self.integer(row["file_size"])
        hasReactions = row["has_reactions"].bool
        startsThread = row["is_thread"].bool
        isSaved = Self.likedBy(row["liked_by"], user: currentUser)
        raw = row
    }

    /// A cached message, for the instant results shown while the server
    /// answers. `threadParents` places thread replies under their parent.
    public init(message: RavenMessage, plainText: String, query: String, threadParents: [String: String], currentUser: String) {
        id = message.id
        channelID = message.channelID
        let parent = threadParents[message.channelID] ?? message.raw["parent_channel_id"].string
        isThreadReply = parent != nil && parent != message.channelID
        conversationID = isThreadReply ? parent ?? message.channelID : message.channelID
        authorID = message.authorID
        creation = message.creation
        messageType = message.messageType
        let file = message.raw["file"].string.map(Self.lastPathComponent)
        fileName = (messageType == "File" || messageType == "Image") ? file.map { SearchSnippet.local($0, query: query) } : nil
        snippet = SearchSnippet.local(plainText, query: query)
        fileSize = Self.integer(message.raw["file_size"])
        if case .object(let reactions) = message.raw["message_reactions"].nested { hasReactions = !reactions.isEmpty } else { hasReactions = false }
        startsThread = message.raw["is_thread"].bool
        isSaved = Self.likedBy(message.raw["_liked_by"], user: currentUser) || Self.likedBy(message.raw["liked_by"], user: currentUser)
        raw = message.raw
    }

    /// The server's matches in its order, then the cached matches it did
    /// not return. Raven's index is built in the background and corrects
    /// words it does not know to ones it does, so it can miss messages
    /// this Mac holds; an answer from it must not hide them. Cache-only
    /// hits keep the cache's order and come after every server hit.
    public static func merging(server: [SearchHit], cached: [SearchHit]) -> [SearchHit] {
        var returned = Set(server.map(\.id))
        return server + cached.filter { returned.insert($0.id).inserted }
    }

    private static func identifier(_ value: JSONValue) -> String? {
        guard let text = value.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1024,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return text
    }

    private static func integer(_ value: JSONValue) -> Int? {
        switch value {
        case .number(let number) where number.isFinite && number >= 0 && number < 1e15: return Int(number)
        case .string(let text): return Int(text).flatMap { $0 >= 0 ? $0 : nil }
        default: return nil
        }
    }

    /// `liked_by` is a JSON array of users, stored as text in the index.
    private static func likedBy(_ value: JSONValue, user: String) -> Bool {
        guard !user.isEmpty else { return false }
        return value.nested.array.contains { $0.string == user }
    }

    static func lastPathComponent(_ path: String) -> String {
        let withoutQuery = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? path
        let last = withoutQuery.split(separator: "/").last.map(String.init) ?? withoutQuery
        return last.removingPercentEncoding ?? last
    }
}

/// How the Messages and Files tabs order their results.
public enum SearchOrder: String, Codable, Sendable, CaseIterable {
    /// Grouped by conversation; groups and hits in the server's order.
    case bestMatch
    /// One list, newest first.
    case newest
}

/// The rows of the results list, from hits and what the reader expanded.
public enum SearchResultLayout {
    public enum Row: Equatable, Sendable {
        /// A conversation heading: its hits in this search, in total.
        case conversation(id: String, count: Int)
        case hit(SearchHit)
        /// "Show all": the conversation has `hidden` more hits.
        case more(conversationID: String, hidden: Int)
    }

    /// Hits shown per conversation until the reader asks for all of them.
    public static let collapsedHits = 3

    public static func rows(_ hits: [SearchHit], order: SearchOrder, expanded: Set<String> = []) -> [Row] {
        var seen = Set<String>()
        let unique = hits.filter { seen.insert($0.id).inserted }
        switch order {
        case .newest:
            // Stable: equal times keep the server's order.
            return unique.enumerated().sorted { a, b in
                a.element.creation != b.element.creation ? a.element.creation > b.element.creation : a.offset < b.offset
            }.map { .hit($0.element) }
        case .bestMatch:
            var order: [String] = []
            var groups: [String: [SearchHit]] = [:]
            for hit in unique {
                if groups[hit.conversationID] == nil { order.append(hit.conversationID) }
                groups[hit.conversationID, default: []].append(hit)
            }
            var rows: [Row] = []
            for id in order {
                let group = groups[id] ?? []
                rows.append(.conversation(id: id, count: group.count))
                let shown = expanded.contains(id) ? group : Array(group.prefix(collapsedHits))
                rows += shown.map(Row.hit)
                if shown.count < group.count { rows.append(.more(conversationID: id, hidden: group.count - shown.count)) }
            }
            return rows
        }
    }
}

/// The tabs of the results screen. Messages and Files search the index,
/// Links its own endpoint; Conversations and People match locally.
public enum SearchTab: String, Codable, Sendable, CaseIterable {
    case messages, files, links, conversations, people

    public var title: String {
        switch self {
        case .messages: "Messages"
        case .files: "Files"
        case .links: "Links"
        case .conversations: "Conversations"
        case .people: "People"
        }
    }
}

extension SearchCriteria {
    /// The tab a saved or restored search belongs on.
    public var tab: SearchTab {
        switch kind {
        case .files, .images: .files
        case .links: .links
        case .all, .text, .polls: .messages
        }
    }

    /// The same search for another tab: the kind changes, every other
    /// filter stays. Local tabs keep the Messages kind.
    public func on(_ tab: SearchTab) -> SearchCriteria {
        var copy = self
        switch tab {
        case .files: if ![.files, .images].contains(kind) { copy.kind = .files }
        case .links: copy.kind = .links
        case .messages, .conversations, .people: if ![.all, .text, .polls].contains(kind) { copy.kind = .all }
        }
        return copy
    }

    /// Whether any filter beyond the query is set, so a blank query still
    /// lists something worth showing.
    public var hasFilters: Bool {
        author != nil || savedOnly || mentionsMe || date != nil || attribute != nil || kind != .all || scope != .account
    }
}

/// Threads in a search scope, from `get_all_threads` and `get_other_threads`
/// rows: the thread is `name`, its parent conversation `channel_id`.
public enum SearchThreads {
    /// Thread IDs whose parent is one of `parents`, newest activity first,
    /// without repeats. Equal timestamps break by ascending thread id, so the
    /// order is deterministic even when the input row order changes.
    public static func ids(_ rows: [JSONValue], parents: Set<String>) -> [String] {
        var seen = Set<String>()
        // Newest activity first, then the thread id: equal timestamps are
        // common (one burst, a whole day at minute precision) and Swift's sort
        // is not stable, so without the tiebreak the list could reorder itself
        // with no new data. The timestamp is compared as text, which is only
        // correct while every row uses the same zero-padded site-local format.
        // The sort keys are read once per row, not once per comparison, and
        // the filter consumes the same entry instead of re-reading the id.
        // The id tiebreak is textual too: "t10" sorts before "t2", so it is
        // chronological only while every thread id has the same width.
        return rows
            .map { row in (row: row, time: row["last_message_timestamp"].string ?? "", id: row["name"].string ?? "") }
            .sorted { $0.time != $1.time ? $0.time > $1.time : $0.id < $1.id }
            .compactMap { entry in
                guard !entry.id.isEmpty, let parent = entry.row["channel_id"].string, parents.contains(parent), seen.insert(entry.id).inserted else { return nil }
                return entry.id
            }
    }

    /// Each thread with its parent, for placing cached replies.
    public static func parents(_ rows: [JSONValue]) -> [String: String] {
        var parents: [String: String] = [:]
        for row in rows {
            guard let id = row["name"].string, !id.isEmpty, let parent = row["channel_id"].string, !parent.isEmpty else { continue }
            parents[id] = parent
        }
        return parents
    }
}

/// Conversations and people whose names match a query, for Top hits and
/// the Conversations and People tabs. Matching is local and costs nothing.
public enum SearchTopHits {
    public static func conversations(_ query: String, channels: [RavenChannel], limit: Int) -> [RavenChannel] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let byID = Dictionary(channels.filter { !$0.raw["is_thread"].bool && !$0.id.isEmpty }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = byID.values.map { MentionCandidate(kind: .channel, serverID: $0.id, title: $0.title, detail: $0.isDM ? "" : $0.workspace) }
        let ranked = MentionCompletion.matches(candidates, query: MentionQuery(kind: .channel, range: NSRange(location: 0, length: 0), text: text), limit: 100)
        // Archived conversations go after the rest.
        let active = ranked.filter { byID[$0.serverID]?.raw["is_archived"].bool != true }
        let archived = ranked.filter { byID[$0.serverID]?.raw["is_archived"].bool == true }
        return (active + archived).prefix(max(0, limit)).compactMap { byID[$0.serverID] }
    }

    /// User IDs whose name or ID matches.
    public static func people(_ query: String, names: [String: String], limit: Int) -> [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let candidates = names.map { MentionCandidate(kind: .person, serverID: $0.key, title: $0.value) }
        return MentionCompletion.matches(candidates, query: MentionQuery(kind: .person, range: NSRange(location: 0, length: 0), text: text), limit: limit).map(\.serverID)
    }
}
