import Testing
import Foundation
import RavenProtocol
@testable import NevermoreCore

// MARK: - Fixtures

private let resultsMe = "me@example.com"

private func resultsCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
    return calendar
}

/// A date in the server's time zone, built from components in that calendar.
private func resultsZurichDate(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return resultsCalendar().date(from: components)!
}

private func resultsChannel(_ id: String, workspace: String? = nil, dm: Bool = false, extra: [String: JSONValue] = [:]) -> RavenChannel {
    var object: [String: JSONValue] = ["name": .string(id)]
    if let workspace { object["workspace"] = .string(workspace) }
    if dm { object["is_direct_message"] = .bool(true) }
    for (key, value) in extra { object[key] = value }
    return RavenChannel(raw: .object(object))
}

/// The small fixture: two channels in "engineering", one in "ops".
private let resultsChannels = [
    resultsChannel("general", workspace: "engineering"),
    resultsChannel("design", workspace: "engineering"),
    resultsChannel("random", workspace: "ops"),
]

private func resultsMessage(id: String, channel: String, owner: String = "other@example.com", type: String = "Text", creation: String = "2026-11-15 09:00:00", reactions: JSONValue? = nil) -> RavenMessage {
    var object: [String: JSONValue] = [
        "name": .string(id),
        "channel_id": .string(channel),
        "owner": .string(owner),
        "message_type": .string(type),
        "creation": .string(creation),
    ]
    if let reactions { object["message_reactions"] = reactions }
    return RavenMessage(raw: .object(object))
}

/// A plain index hit in `channel`; fixtures always decode.
private func resultsHit(id: String, channel: String, creation: String = "2026-11-15 09:00:00") -> SearchHit {
    guard let hit = SearchHit(row: .object([
        "id": .string("Raven Message:\(id)"),
        "channel_id": .string(channel),
        "author": .string("u1"),
        "creation": .string(creation),
        "message_type": .string("Text"),
    ]), currentUser: resultsMe) else { fatalError("resultsHit fixture must decode") }
    return hit
}

// MARK: - SearchDateRange.patterns

@Test func dateRangePatternsFollowZurichDays() {
    let calendar = resultsCalendar()
    let now = resultsZurichDate(year: 2026, month: 11, day: 15, hour: 0, minute: 30)
    #expect(SearchDateRange.today.patterns(now: now, calendar: calendar) == ["2026-11-15"])
    #expect(SearchDateRange.yesterday.patterns(now: now, calendar: calendar) == ["2026-11-14"])
    #expect(SearchDateRange.lastDays(3).patterns(now: now, calendar: calendar) == ["2026-11-15", "2026-11-14", "2026-11-13"])
    #expect(SearchDateRange.lastDays(0).patterns(now: now, calendar: calendar) == ["2026-11-15"])
    #expect(SearchDateRange.lastDays(100).patterns(now: now, calendar: calendar).count == 31)
    #expect(SearchDateRange.monthContaining(now, calendar: calendar) == .month(year: 2026, month: 11))
}

@Test func dateRangePatternsCrossMonthBoundary() {
    let calendar = resultsCalendar()
    let now = resultsZurichDate(year: 2026, month: 3, day: 1, hour: 12, minute: 0)
    #expect(SearchDateRange.lastDays(2).patterns(now: now, calendar: calendar) == ["2026-03-01", "2026-02-28"])
}

@Test func dateRangeMonthAndYearPatterns() {
    let calendar = resultsCalendar()
    let now = resultsZurichDate(year: 2026, month: 11, day: 15, hour: 0, minute: 30)
    #expect(SearchDateRange.month(year: 2026, month: 3).patterns(now: now, calendar: calendar) == ["2026-03-"])
    #expect(SearchDateRange.month(year: 2026, month: 13).patterns(now: now, calendar: calendar) == [])
    #expect(SearchDateRange.year(2025).patterns(now: now, calendar: calendar) == ["2025-"])
}

@Test func dateRangeStepsMonthsAndRejectsOtherRanges() {
    #expect(SearchDateRange.month(year: 2026, month: 1).steppingMonth(by: -1) == .month(year: 2025, month: 12))
    #expect(SearchDateRange.month(year: 2026, month: 12).steppingMonth(by: 1) == .month(year: 2027, month: 1))
    #expect(SearchDateRange.today.steppingMonth(by: -1) == nil)
}

@Test func dateRangeCodableRoundTripAndRejections() throws {
    for range in [SearchDateRange.today, .yesterday, .lastDays(7), .month(year: 2026, month: 2), .year(2024)] {
        #expect(try JSONDecoder().decode(SearchDateRange.self, from: JSONEncoder().encode(range)) == range)
    }
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(SearchDateRange.self, from: Data(#"{"kind":"lastDays","days":1}"#.utf8))
    }
    #expect(throws: (any Error).self) {
        _ = try JSONDecoder().decode(SearchDateRange.self, from: Data(#"{"kind":"bogus"}"#.utf8))
    }
}

// MARK: - SearchCriteria Codable

@Test func criteriaWithoutDateAttributeOrThreadsDecodesWithDefaults() throws {
    let criteria = SearchCriteria(query: "q", scope: .conversation("general"))
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(criteria)) as! [String: Any]
    json.removeValue(forKey: "date")
    json.removeValue(forKey: "attribute")
    json.removeValue(forKey: "includeThreads")
    let decoded = try JSONDecoder().decode(SearchCriteria.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.query == "q")
    #expect(decoded.scope == .conversation("general"))
    #expect(decoded.includeThreads)
    #expect(decoded.date == nil)
    #expect(decoded.attribute == nil)
}

@Test func criteriaWithUnknownDateDecodesAndDropsIt() throws {
    let criteria = SearchCriteria(query: "q", scope: .conversation("general"))
    var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(criteria)) as! [String: Any]
    json["date"] = ["kind": "bogus"]
    let decoded = try JSONDecoder().decode(SearchCriteria.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(decoded.query == "q")
    #expect(decoded.date == nil)
}

@Test func criteriaRoundTripKeepsDateAttributeAndThreads() throws {
    let criteria = SearchCriteria(query: "x", date: .lastDays(7), attribute: .reactions, includeThreads: false)
    #expect(try JSONDecoder().decode(SearchCriteria.self, from: JSONEncoder().encode(criteria)) == criteria)
}

// MARK: - SearchCriteria.filters

@Test func conversationScopeBuildsChannelIDFilterWithThreads() throws {
    let filters = try SearchCriteria(scope: .conversation("general")).filters(channels: resultsChannels, threads: ["t1", "t2"])
    #expect(filters["channel_id"] == .array([.string("general"), .string("t1"), .string("t2")]))
}

@Test func conversationScopeOmitsThreadsWhenExcluded() throws {
    let filters = try SearchCriteria(scope: .conversation("general"), includeThreads: false).filters(channels: resultsChannels, threads: ["t1", "t2"])
    #expect(filters["channel_id"] == .string("general"))
}

@Test func conversationScopeNormalizesAndBoundsThreadIDs() throws {
    let messy = try SearchCriteria(scope: .conversation("general")).filters(channels: resultsChannels, threads: [" ", "t1", "t1", "general"])
    #expect(messy["channel_id"] == .array([.string("general"), .string("t1")]))

    let many = try SearchCriteria(scope: .conversation("general")).filters(channels: resultsChannels, threads: (0..<500).map { "t\($0)" })
    #expect(many["channel_id"]?.array.count == 401)

    let none = try SearchCriteria(scope: .conversation("general")).filters(channels: resultsChannels)
    #expect(none["channel_id"] == .string("general"))
}

@Test func workspaceScopeResolvesChannelsAndAddsThreads() throws {
    let filters = try SearchCriteria(scope: .workspace("engineering")).filters(channels: resultsChannels, threads: ["t9"])
    #expect(filters["channel_id"] == .array([.string("design"), .string("general"), .string("t9")]))
}

@Test func dateAndAttributeFiltersUseVerifiedKeys() throws {
    let calendar = resultsCalendar()
    let now = resultsZurichDate(year: 2026, month: 11, day: 15, hour: 0, minute: 30)
    let dateFilters = try SearchCriteria(date: .today).filters(channels: resultsChannels, now: now, calendar: calendar)
    #expect(dateFilters["creation"] == .array([.string("LIKE"), .array([.string("2026-11-15")])]))
    #expect(try SearchCriteria(attribute: .reactions).filters(channels: resultsChannels)["has_reactions"] == .number(1))
    #expect(try SearchCriteria(attribute: .thread).filters(channels: resultsChannels)["is_thread"] == .number(1))
}

// MARK: - SearchCriteria.matches

@Test func criteriaMatchesDatesScopesAndReactions() {
    let calendar = resultsCalendar()
    let now = resultsZurichDate(year: 2026, month: 11, day: 15, hour: 0, minute: 30)
    let hit = resultsMessage(id: "m1", channel: "general")
    #expect(SearchCriteria(date: .today).matches(hit, channels: resultsChannels, currentUser: resultsMe, now: now, calendar: calendar))
    #expect(!SearchCriteria(date: .yesterday).matches(hit, channels: resultsChannels, currentUser: resultsMe, now: now, calendar: calendar))

    let threadParents = ["t1": "general"]
    #expect(SearchCriteria(scope: .conversation("general")).matches(resultsMessage(id: "m2", channel: "t1"), channels: resultsChannels, currentUser: resultsMe, threadParents: threadParents))
    #expect(!SearchCriteria(scope: .conversation("general"), includeThreads: false).matches(resultsMessage(id: "m3", channel: "t1"), channels: resultsChannels, currentUser: resultsMe, threadParents: threadParents))
    #expect(SearchCriteria(scope: .conversation("general"), includeThreads: false).matches(resultsMessage(id: "m4", channel: "general"), channels: resultsChannels, currentUser: resultsMe, threadParents: threadParents))

    let reacted = resultsMessage(id: "m5", channel: "general", reactions: .string(#"{"👍":{"count":1}}"#))
    #expect(SearchCriteria(attribute: .reactions).matches(reacted, channels: resultsChannels, currentUser: resultsMe))
    #expect(!SearchCriteria(attribute: .reactions).matches(resultsMessage(id: "m6", channel: "general"), channels: resultsChannels, currentUser: resultsMe))
}

// MARK: - SearchCriteria tab / hasFilters

@Test func criteriaTabMapsKinds() {
    #expect(SearchCriteria(kind: .files).tab == .files)
    #expect(SearchCriteria(kind: .images).tab == .files)
    #expect(SearchCriteria(kind: .links).tab == .links)
    #expect(SearchCriteria(kind: .all).tab == .messages)
    #expect(SearchCriteria(kind: .text).tab == .messages)
    #expect(SearchCriteria(kind: .polls).tab == .messages)
}

@Test func criteriaOnTabKeepsOtherFilters() {
    #expect(SearchCriteria(kind: .images).on(.files).kind == .images)
    #expect(SearchCriteria(kind: .all).on(.files).kind == .files)
    let moved = SearchCriteria(kind: .files, savedOnly: true).on(.messages)
    #expect(moved.kind == .all)
    #expect(moved.savedOnly)
    #expect(SearchCriteria().on(.links).kind == .links)
    #expect(SearchCriteria(kind: .polls).on(.links).kind == .links)
}

@Test func criteriaHasFiltersOnlyWhenSet() {
    #expect(!SearchCriteria().hasFilters)
    #expect(SearchCriteria(savedOnly: true).hasFilters)
    #expect(SearchCriteria(date: .today).hasFilters)
    #expect(SearchCriteria(scope: .conversation("x")).hasFilters)
}

// MARK: - SearchSnippet.marked

/// Decoding shrinks the string, so a highlight after an escape must shift
/// with it; a malformed escape keeps the text and its ranges untouched.
@Test func removingPercentEncodingRemapsLaterHighlights() {
    let decoded = SearchSnippet(text: "Never%20Core.pdf", highlights: [8..<12]).removingPercentEncoding()
    #expect(decoded.text == "Never Core.pdf")
    #expect(decoded.highlights == [6..<10])

    let literal = SearchSnippet(text: "50%.pdf", highlights: [0..<2]).removingPercentEncoding()
    #expect(literal.text == "50%.pdf")
    #expect(literal.highlights == [0..<2])
}

@Test func markedSnippetReadsServerMarkup() {
    let first = SearchSnippet.marked("a <mark>b</mark> c")
    #expect(first.text == "a b c")
    #expect(first.highlights == [2..<3])

    #expect(SearchSnippet.marked("<mark>x</mark> y").highlights == [0..<1])

    let spaces = SearchSnippet.marked("a \n\t b")
    #expect(spaces.text == "a b")
    #expect(spaces.highlights.isEmpty)

    let open = SearchSnippet.marked("<mark>abc")
    #expect(open.text == "abc")
    #expect(open.highlights == [0..<3])

    let stray = SearchSnippet.marked("</mark>abc")
    #expect(stray.text == "abc")
    #expect(stray.highlights.isEmpty)

    let markup = SearchSnippet.marked("<b>x</b>")
    #expect(markup.text == "<b>x</b>")
    #expect(markup.highlights.isEmpty)
}

@Test func markedSnippetHandlesUnicodeAndAdjacentMarks() {
    let emoji = SearchSnippet.marked("😀 <mark>é</mark>")
    #expect(emoji.text == "😀 é")
    #expect(emoji.highlights == [3..<4])

    let adjacent = SearchSnippet.marked("<mark>a</mark><mark>b</mark>")
    #expect(adjacent.text == "ab")
    #expect(adjacent.highlights == [0..<1, 1..<2])
}

@Test func markedSnippetTruncatesLongInput() {
    let snippet = SearchSnippet.marked(String(repeating: "word ", count: 1000))
    #expect(snippet.text.utf16.count <= 401)
    #expect(snippet.text.hasSuffix("…"))
}

// MARK: - SearchSnippet.local

@Test func localSnippetHighlightsQueryWords() {
    #expect(SearchSnippet.local("Hello World", query: "wor").highlights == [6..<9])
    #expect(SearchSnippet.local("Café crème", query: "creme").highlights == [5..<10])
    #expect(SearchSnippet.local("password", query: "word").highlights.isEmpty)
}

@Test func localSnippetWindowsLongTextAroundFirstMatch() throws {
    let plain = String(repeating: "lorem ", count: 60) + "target end"
    let snippet = SearchSnippet.local(plain, query: "target")
    #expect(snippet.text.hasPrefix("…"))
    #expect(snippet.highlights.count == 1)
    let highlight = try #require(snippet.highlights.first)
    #expect((snippet.text as NSString).substring(with: NSRange(location: highlight.lowerBound, length: highlight.count)) == "target")
}

@Test func localSnippetKeepsAMatchAfterALongUnbrokenToken() throws {
    // A pasted link longer than the window has no space to start at.
    for lead in ["", "See "] {
        let plain = lead + "https://example.invalid/" + String(repeating: "a", count: 600) + " target end"
        let snippet = SearchSnippet.local(plain, query: "target")
        let highlight = try #require(snippet.highlights.first)
        #expect((snippet.text as NSString).substring(with: NSRange(location: highlight.lowerBound, length: highlight.count)) == "target")
    }
}

// MARK: - SearchHit

@Test func searchHitReadsIndexRow() throws {
    let hit = try #require(SearchHit(row: .object([
        "id": .string("Raven Message:m1"),
        "channel_id": .string("c1"),
        "author": .string("u1"),
        "creation": .string("2026-11-15 09:00:00"),
        "message_type": .string("Text"),
        "content": .string("hi <mark>there</mark>"),
        "parent_channel_id": .string("c1"),
        "is_thread_message": .number(0),
    ]), currentUser: resultsMe))
    #expect(hit.id == "m1")
    #expect(hit.channelID == "c1")
    #expect(hit.conversationID == "c1")
    #expect(!hit.isThreadReply)
    #expect(hit.authorID == "u1")
    #expect(hit.snippet.text == "hi there")
    #expect(hit.snippet.highlights == [3..<8])
}

@Test func searchHitAttributesThreadReplyBotFileAndFlags() throws {
    let reply = try #require(SearchHit(row: .object([
        "id": .string("Raven Message:m2"),
        "channel_id": .string("t1"),
        "author": .string("u1"),
        "creation": .string("2026-11-15 09:00:00"),
        "message_type": .string("Text"),
        "parent_channel_id": .string("c1"),
        "is_thread_message": .number(1),
    ]), currentUser: resultsMe))
    #expect(reply.conversationID == "c1")
    #expect(reply.isThreadReply)

    let bot = try #require(SearchHit(row: .object([
        "id": .string("Raven Message:m3"),
        "channel_id": .string("c1"),
        "author": .string("u1"),
        "creation": .string("2026-11-15 09:00:00"),
        "message_type": .string("Text"),
        "is_bot_message": .number(1),
        "bot": .string("b1"),
    ]), currentUser: resultsMe))
    #expect(bot.authorID == "b1")

    let file = try #require(SearchHit(row: .object([
        "id": .string("Raven Message:m4"),
        "channel_id": .string("c1"),
        "author": .string("u1"),
        "creation": .string("2026-11-15 09:00:00"),
        "message_type": .string("File"),
        "title": .string("<mark>report</mark>%20Q3.pdf"),
        "content": .string("<mark>report</mark>%20Q3.pdf"),
        "file_size": .number(2048),
    ]), currentUser: resultsMe))
    #expect(file.fileName?.text == "report Q3.pdf")
    #expect(file.fileName?.highlights == [0..<6])
    #expect(file.fileSize == 2048)
    #expect(file.isFile)
    // The caption is the percent-encoded file name, so it must not repeat
    // the decoded title as a second line, and no stale highlight may remain.
    #expect(file.snippet.text.isEmpty)
    #expect(file.snippet.highlights.isEmpty)

    let saved = try #require(SearchHit(row: .object([
        "id": .string("Raven Message:m5"),
        "channel_id": .string("c1"),
        "author": .string("u1"),
        "creation": .string("2026-11-15 09:00:00"),
        "message_type": .string("Text"),
        "liked_by": .string(#"["me@example.com"]"#),
    ]), currentUser: resultsMe))
    #expect(saved.isSaved)

    let other = try #require(SearchHit(row: .object([
        "id": .string("Raven Message:m6"),
        "channel_id": .string("c1"),
        "author": .string("u1"),
        "creation": .string("2026-11-15 09:00:00"),
        "message_type": .string("Text"),
        "liked_by": .string(#"["other"]"#),
    ]), currentUser: resultsMe))
    #expect(!other.isSaved)

    let flagged = try #require(SearchHit(row: .object([
        "id": .string("Raven Message:m7"),
        "channel_id": .string("c1"),
        "author": .string("u1"),
        "creation": .string("2026-11-15 09:00:00"),
        "message_type": .string("Text"),
        "has_reactions": .number(1),
        "is_thread": .number(1),
    ]), currentUser: resultsMe))
    #expect(flagged.hasReactions)
    #expect(flagged.startsThread)

    #expect(SearchHit(row: .object(["id": .string("Raven Message:m8"), "author": .string("u1")]), currentUser: resultsMe) == nil)
}

// MARK: - SearchResultLayout

@Test func layoutGroupsBestMatchByConversation() {
    let a = resultsHit(id: "a", channel: "c1")
    let b = resultsHit(id: "b", channel: "c2")
    let c = resultsHit(id: "c", channel: "c1")
    let d = resultsHit(id: "d", channel: "c1")
    let e = resultsHit(id: "e", channel: "c1")
    let hits = [a, b, c, d, e]
    #expect(SearchResultLayout.rows(hits, order: .bestMatch) == [
        .conversation(id: "c1", count: 4), .hit(a), .hit(c), .hit(d), .more(conversationID: "c1", hidden: 1),
        .conversation(id: "c2", count: 1), .hit(b),
    ])

    let expanded = SearchResultLayout.rows(hits, order: .bestMatch, expanded: ["c1"])
    #expect(expanded == [
        .conversation(id: "c1", count: 4), .hit(a), .hit(c), .hit(d), .hit(e),
        .conversation(id: "c2", count: 1), .hit(b),
    ])
    #expect(!expanded.contains { if case .more = $0 { return true }; return false })
}

@Test func layoutNewestOrdersByCreationAndKeepsInputOrderOnTies() {
    let first = resultsHit(id: "h1", channel: "c1", creation: "2026-11-10 09:00:00")
    let second = resultsHit(id: "h2", channel: "c1", creation: "2026-11-12 09:00:00")
    let third = resultsHit(id: "h3", channel: "c1", creation: "2026-11-11 09:00:00")
    #expect(SearchResultLayout.rows([first, second, third], order: .newest) == [.hit(second), .hit(third), .hit(first)])

    let tiedA = resultsHit(id: "h4", channel: "c1", creation: "2026-11-12 09:00:00")
    let tiedB = resultsHit(id: "h5", channel: "c1", creation: "2026-11-12 09:00:00")
    #expect(SearchResultLayout.rows([tiedA, tiedB], order: .newest) == [.hit(tiedA), .hit(tiedB)])
}

@Test func layoutShowsDuplicateIDsOnce() {
    let first = resultsHit(id: "dup", channel: "c1")
    let second = resultsHit(id: "dup", channel: "c2")
    let third = resultsHit(id: "other", channel: "c1")
    #expect(SearchResultLayout.rows([first, second, third], order: .bestMatch) == [
        .conversation(id: "c1", count: 2), .hit(first), .hit(third),
    ])
}

// MARK: - SearchThreads

@Test func threadsIdsFollowActivityAndParents() {
    let rows: [JSONValue] = [
        .object(["name": .string("t1"), "channel_id": .string("general"), "last_message_timestamp": .string("2026-11-01 10:00:00")]),
        .object(["name": .string("t2"), "channel_id": .string("general"), "last_message_timestamp": .string("2026-11-05 10:00:00")]),
        .object(["name": .string("t3"), "channel_id": .string("random"), "last_message_timestamp": .string("2026-11-06 10:00:00")]),
        .object(["name": .string("t2"), "channel_id": .string("general"), "last_message_timestamp": .string("2026-11-05 10:00:00")]),
    ]
    #expect(SearchThreads.ids(rows, parents: ["general"]) == ["t2", "t1"])
    #expect(SearchThreads.parents(rows)["t3"] == "random")
}

@Test func threadsIdsBreakEqualTimestampsByName() {
    let rows: [JSONValue] = [
        .object(["name": .string("t3"), "channel_id": .string("general"), "last_message_timestamp": .string("2026-11-05 10:00:00")]),
        .object(["name": .string(""), "channel_id": .string("general"), "last_message_timestamp": .string("2026-11-08 10:00:00")]),
        .object(["name": .string("t1"), "channel_id": .string("general"), "last_message_timestamp": .string("2026-11-05 10:00:00")]),
        .object(["name": .string("t2"), "channel_id": .string("general"), "last_message_timestamp": .string("2026-11-05 10:00:00")]),
        .object(["name": .string("t2"), "channel_id": .string("general"), "last_message_timestamp": .string("2026-11-05 10:00:00")]),
        .object(["name": .string("t0"), "channel_id": .string("general"), "last_message_timestamp": .string("2026-11-06 10:00:00")]),
        .object(["name": .string("t9"), "channel_id": .string("elsewhere"), "last_message_timestamp": .string("2026-11-07 10:00:00")]),
    ]
    #expect(SearchThreads.ids(rows, parents: ["general"]) == ["t0", "t1", "t2", "t3"])
}

// MARK: - SearchTopHits

@Test func topHitsConversationsRankArchivedLast() {
    let channels = [
        resultsChannel("web-design", workspace: "engineering"),
        resultsChannel("design", workspace: "engineering"),
        resultsChannel("random", workspace: "ops"),
        resultsChannel("design-old", workspace: "engineering", extra: ["is_archived": .bool(true)]),
        resultsChannel("design-thread", workspace: "engineering", extra: ["is_thread": .bool(true)]),
    ]
    let result = SearchTopHits.conversations("des", channels: channels, limit: 10)
    #expect(result.map(\.id) == ["design", "web-design", "design-old"])
    #expect(result.contains(where: { $0.id == "web-design" }))
    #expect(!result.contains(where: { $0.id == "random" || $0.id == "design-thread" }))
    #expect(result.last?.id == "design-old")
}

@Test func topHitsPeopleMatchNamesAndIDs() {
    let names = ["u1": "Alice Smith", "u2": "Bob", "u3": "Malik Ali"]
    let result = SearchTopHits.people("ali", names: names, limit: 5)
    #expect(result.contains("u1"))
    #expect(result.contains("u3"))
    #expect(!result.contains("u2"))
    #expect(SearchTopHits.people("ali", names: names, limit: 1).count == 1)
    #expect(SearchTopHits.people("", names: names, limit: 5).isEmpty)
    #expect(SearchTopHits.people("   ", names: names, limit: 5).isEmpty)
    #expect(SearchTopHits.conversations("", channels: [], limit: 5).isEmpty)
    #expect(SearchTopHits.conversations("   ", channels: [], limit: 5).isEmpty)
}

// MARK: - NavigationHistory

@Test func navigationHistoryReplacesSearchEntriesAndTruncatesForward() {
    var history = NavigationHistory()
    history.visit(ConversationLocation(channelID: "a"))
    history.visitSearch(SearchCriteria(query: "x"))
    history.visitSearch(SearchCriteria(query: "xy"))
    #expect(history.entries.count == 2)
    #expect(history.currentEntry == .search(SearchCriteria(query: "xy")))

    history.visit(ConversationLocation(channelID: "b"))
    #expect(history.entries.count == 3)
    #expect(history.back() == .search(SearchCriteria(query: "xy")))
    #expect(history.current == nil)
    #expect(history.back() == .conversation(ConversationLocation(channelID: "a")))
    #expect(history.current?.channelID == "a")

    // Forward to b, back to the search, then a new conversation truncates
    // the forward entries.
    #expect(history.forward() == .search(SearchCriteria(query: "xy")))
    #expect(history.forward() == .conversation(ConversationLocation(channelID: "b")))
    #expect(history.back() == .search(SearchCriteria(query: "xy")))
    history.visit(ConversationLocation(channelID: "c"))
    #expect(!history.canGoForward)
}

// MARK: - Server and cached matches

private func indexHit(_ id: String) -> SearchHit? {
    SearchHit(row: .object(["id": .string("Raven Message:" + id), "channel_id": .string("c1"), "content": .string(id)]), currentUser: resultsMe)
}

/// The server's index lags and its spelling correction can swap a word,
/// so an empty answer must not hide matches this Mac already found.
@Test func serverAnswerKeepsCachedMatchesItLacks() throws {
    let cached = [try #require(indexHit("m1")), try #require(indexHit("m2"))]

    #expect(SearchHit.merging(server: [], cached: cached).map(\.id) == ["m1", "m2"])

    let server = [try #require(indexHit("m3")), try #require(indexHit("m2"))]
    let merged = SearchHit.merging(server: server, cached: cached)
    // The server's ranking first, its copy of a shared match, then the rest.
    #expect(merged.map(\.id) == ["m3", "m2", "m1"])
    #expect(merged[1] == server[1])
}

/// The merge dedups on `id`, so the cache's message id and the index
/// row's id for one message must agree. Raven rows carry the id prefixed;
/// `RavenSearchResult.normalize` strips the prefix back to the name the
/// cache stores.
@Test func cachedAndIndexedHitsShareAnID() throws {
    let message = resultsMessage(id: "m1", channel: "c1")
    let cached = try #require(SearchHit(message: message, plainText: "m1", query: "m1", threadParents: [:], currentUser: resultsMe))
    let indexed = try #require(indexHit("m1"))

    #expect(cached.id == indexed.id)
    #expect(SearchHit.merging(server: [indexed], cached: [cached]).count == 1)
}

/// A caption with a stray `%` is free text, not a broken escape. Decoding it
/// fails and the snippet must survive untouched rather than be dropped or
/// mis-compared against the file name.
@Test func malformedPercentCaptionSurvivesFileDeduplication() throws {
    let hit = try #require(SearchHit(row: .object([
        "id": .string("Raven Message:m8"),
        "channel_id": .string("c1"),
        "author": .string("u1"),
        "creation": .string("2026-11-15 09:00:00"),
        "message_type": .string("File"),
        "title": .string("other.pdf"),
        "content": .string("50%.pdf"),
    ]), currentUser: resultsMe))
    #expect(hit.fileName?.text == "other.pdf")
    #expect(hit.snippet.text == "50%.pdf")
}

@Test func decodedFilenameWithLiteralPercentEscapeDoesNotRepeat() throws {
    let hit = try #require(SearchHit(row: .object([
        "id": .string("Raven Message:m8"), "channel_id": .string("c1"),
        "message_type": .string("File"), "title": .string("Budget%2520Q4.pdf"),
        "content": .string("Budget%20Q4.pdf"),
    ]), currentUser: resultsMe))
    #expect(hit.fileName?.text == "Budget%20Q4.pdf")
    #expect(hit.snippet.text.isEmpty)
}

/// A cached list that repeats an id must not repeat the row.
@Test func mergingDropsDuplicateCachedHits() throws {
    let cached = [try #require(indexHit("m1")), try #require(indexHit("m1")), try #require(indexHit("m2"))]

    #expect(SearchHit.merging(server: [], cached: cached).map(\.id) == ["m1", "m2"])
}
