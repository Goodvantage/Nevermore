import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

@Suite struct HomeDigestTests {
    // MARK: - Helpers

    private func channel(_ raw: [String: JSONValue]) -> RavenChannel {
        RavenChannel(raw: .object(raw))
    }

    private func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private func date(_ calendar: Calendar, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func daysAgo(_ days: Int, from now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: -days, to: now)!
    }

    private func dmChannel(id: String, peer: String?, timestamp: String, archived: Bool = false) -> RavenChannel {
        var raw: [String: JSONValue] = [
            "name": .string(id),
            "is_direct_message": .number(1),
            "is_archived": .bool(archived),
            "last_message_timestamp": .string(timestamp)
        ]
        if let peer { raw["peer_user_id"] = .string(peer) }
        return channel(raw)
    }

    // MARK: - HomeLayout

    @Test func standardLayoutHasEveryModuleOnceAndNothingHidden() {
        let layout = HomeLayout.standard
        #expect(layout.order == HomeModule.allCases)
        #expect(layout.order.count == HomeModule.allCases.count)
        #expect(layout.hidden.isEmpty)
        #expect(layout.visible == HomeModule.allCases)
    }

    @Test func initDropsDuplicateModulesAndAppendsMissingOnes() {
        let layout = HomeLayout(order: [.week, .week, .files, .favorites], hidden: [])
        #expect(layout.order == [.week, .files, .favorites, .unread, .later, .people, .threads])
    }

    @Test func moveClampsOutOfRangeIndices() {
        var layout = HomeLayout.standard
        layout.move(.week, to: 1)
        #expect(layout.order == [.favorites, .week, .unread, .later, .people, .threads, .files])
        layout.move(.favorites, to: 99)
        #expect(layout.order == [.week, .unread, .later, .people, .threads, .files, .favorites])
        layout.move(.favorites, to: -3)
        #expect(layout.order == [.favorites, .week, .unread, .later, .people, .threads, .files])
    }

    @Test func setVisibleTogglesHiddenKeepingVisibleOrder() {
        var layout = HomeLayout.standard
        layout.setVisible(.unread, false)
        layout.setVisible(.week, false)
        #expect(layout.hidden == Set([HomeModule.unread, HomeModule.week]))
        #expect(layout.visible == [.favorites, .later, .people, .threads, .files])
        layout.setVisible(.unread, true)
        #expect(layout.hidden == Set([HomeModule.week]))
        #expect(layout.visible == [.favorites, .unread, .later, .people, .threads, .files])
    }

    @Test func decodeFallsBackToStandardForMissingOrGarbageData() {
        #expect(HomeLayout.decode(nil) == .standard)
        #expect(HomeLayout.decode(Data("this is not JSON".utf8)) == .standard)
        #expect(HomeLayout.decode(Data("{\"order\": 7}".utf8)) == .standard)
        #expect(HomeLayout.decode(Data(repeating: 0, count: 5000)) == .standard)
    }

    @Test func decodeSkipsUnknownRawValuesAndRoundTrips() throws {
        let json = #"{"order":["week","bogus","unread"],"hidden":["files","nope"]}"#
        let layout = HomeLayout.decode(Data(json.utf8))
        #expect(layout.order == [.week, .unread, .favorites, .later, .people, .threads, .files])
        #expect(layout.hidden == Set([HomeModule.files]))
        let data = try #require(layout.encoded())
        #expect(HomeLayout.decode(data) == layout)
    }

    // MARK: - HomeLatestMessage

    @Test func latestMessageParsesStringifiedDetails() throws {
        let details = #"{"owner":"u1","message_id":"m1","content":"hello there"}"#
        let message = try #require(HomeLatestMessage(channel: channel([
            "name": .string("c1"),
            "last_message_details": .string(details),
            "last_message_timestamp": .string("2026-11-15 10:00:00")
        ])))
        #expect(message.authorID == "u1")
        #expect(message.messageID == "m1")
        #expect(message.kind == .text)
        #expect(message.text == "hello there")
        #expect(message.timestamp == "2026-11-15 10:00:00")
    }

    @Test func latestMessageReportsTheBotAsAuthor() throws {
        let details = #"{"owner":"frappe","bot":"Deploy Bot","is_bot_message":1,"message_id":"m2","content":"shipped"}"#
        let message = try #require(HomeLatestMessage(channel: channel([
            "name": .string("c1"),
            "last_message_details": .string(details)
        ])))
        #expect(message.authorID == "Deploy Bot")
        #expect(message.messageID == "m2")
    }

    @Test func latestMessageMapsMessageTypes() throws {
        let types: [(String, HomeLatestMessage.Kind)] = [
            ("Image", .image), ("File", .file), ("Poll", .poll),
            ("System", .system), ("Text", .text), ("AnythingElse", .text)
        ]
        for (type, kind) in types {
            let details = #"{"owner":"u1","message_type":"\#(type)","content":""}"#
            let message = try #require(HomeLatestMessage(channel: channel([
                "name": .string("c1"),
                "last_message_details": .string(details)
            ])))
            #expect(message.kind == kind)
            #expect(message.text.isEmpty)
        }
    }

    @Test func latestMessageCollapsesWhitespaceAndTruncatesLongText() throws {
        let messy = #"{"owner":"u1","content":"  first\n\nsecond   line\t\tthird  "}"#
        let messyMessage = try #require(HomeLatestMessage(channel: channel([
            "name": .string("c1"),
            "last_message_details": .string(messy)
        ])))
        #expect(messyMessage.text == "first second line third")

        let long = String(repeating: "a", count: 241)
        let longMessage = try #require(HomeLatestMessage(channel: channel([
            "name": .string("c1"),
            "last_message_details": .string("{\"owner\":\"u1\",\"content\":\"\(long)\"}")
        ])))
        #expect(longMessage.text == String(repeating: "a", count: 240) + "…")
        #expect(longMessage.text.count == 241)

        let exact = String(repeating: "a", count: 240)
        let exactMessage = try #require(HomeLatestMessage(channel: channel([
            "name": .string("c1"),
            "last_message_details": .string("{\"owner\":\"u1\",\"content\":\"\(exact)\"}")
        ])))
        #expect(exactMessage.text == exact)
    }

    @Test func latestMessageIsNilWithoutUsableDetails() {
        #expect(HomeLatestMessage(channel: channel(["name": .string("c1")])) == nil)
        #expect(HomeLatestMessage(channel: channel(["name": .string("c1"), "last_message_details": .string("not JSON")])) == nil)
        #expect(HomeLatestMessage(channel: channel(["name": .string("c1"), "last_message_details": .string("{}")])) == nil)
    }

    // MARK: - HomeUnreadDigest

    @Test func unreadDigestSplitsMutedFromEntriesAndSkipsArchivedThreadsAndBadCounts() {
        let channels = [
            channel(["name": .string("alpha"), "channel_name": .string("Alpha"), "last_message_timestamp": .string("2026-11-15 10:00:00")]),
            channel(["name": .string("beta"), "channel_name": .string("Beta"), "last_message_timestamp": .string("2026-11-14 09:00:00")]),
            channel(["name": .string("muted1"), "channel_name": .string("Muted One"), "muted": .bool(true)]),
            channel(["name": .string("muted2"), "channel_name": .string("Muted Two"), "muted": .bool(true)]),
            channel(["name": .string("mutedBig"), "channel_name": .string("Muted Big"), "muted": .bool(true)]),
            channel(["name": .string("arch"), "channel_name": .string("Archived"), "is_archived": .bool(true)]),
            channel(["name": .string("archMuted"), "channel_name": .string("Archived Muted"), "is_archived": .bool(true), "muted": .bool(true)]),
            channel(["name": .string("thread"), "channel_name": .string("Thread"), "is_thread": .bool(true)]),
            channel(["name": .string("zero"), "channel_name": .string("Zero")]),
            channel(["name": .string("neg"), "channel_name": .string("Negative")]),
            channel(["name": .string("str"), "channel_name": .string("String Count")]),
            channel(["name": .string("inf"), "channel_name": .string("Infinite")]),
            channel(["name": .string("ghost"), "channel_name": .string("Ghost")])
        ]
        let unread: JSONValue = .array([
            .object(["name": .string("alpha"), "unread_count": .number(3)]),
            .object(["name": .string("beta"), "unread_count": .number(5)]),
            .object(["name": .string("muted1"), "unread_count": .number(2)]),
            .object(["name": .string("muted2"), "unread_count": .number(4)]),
            .object(["name": .string("mutedBig"), "unread_count": .number(15000)]),
            .object(["name": .string("arch"), "unread_count": .number(7)]),
            .object(["name": .string("archMuted"), "unread_count": .number(50)]),
            .object(["name": .string("thread"), "unread_count": .number(9)]),
            .object(["name": .string("zero"), "unread_count": .number(0)]),
            .object(["name": .string("neg"), "unread_count": .number(-3)]),
            .object(["name": .string("str"), "unread_count": .string("5")]),
            .object(["name": .string("inf"), "unread_count": .number(.infinity)]),
            .object(["name": .string("nowhere"), "unread_count": .number(12)])
        ])
        let digest = HomeUnreadDigest.make(channels: channels, unread: unread, mentioned: ["alpha"])
        #expect(digest.entries.map(\.channel.id) == ["alpha", "beta"])
        #expect(digest.entries.map(\.count) == [3, 5])
        #expect(digest.entries[0].mentioned)
        #expect(!digest.entries[1].mentioned)
        #expect(digest.mutedMessages == 9999)
        #expect(digest.mutedConversations == 3)
        #expect(digest.total == 8)
    }

    @Test func unreadDigestSortsNewestFirstThenByTitleAndCapsCounts() {
        let channels = [
            channel(["name": .string("newer"), "channel_name": .string("Alpha"), "last_message_timestamp": .string("2026-11-12 08:00:00")]),
            channel(["name": .string("old"), "channel_name": .string("Zulu"), "last_message_timestamp": .string("2026-11-10 08:00:00")]),
            channel(["name": .string("xray"), "channel_name": .string("Xray")]),
            channel(["name": .string("yankee"), "channel_name": .string("Yankee")])
        ]
        let unread: JSONValue = .array([
            .object(["name": .string("newer"), "unread_count": .number(20000)]),
            .object(["name": .string("old"), "unread_count": .number(2)]),
            .object(["name": .string("xray"), "unread_count": .number(1)]),
            .object(["name": .string("yankee"), "unread_count": .number(1)])
        ])
        let digest = HomeUnreadDigest.make(channels: channels, unread: unread, mentioned: ["xray"])
        #expect(digest.entries.map(\.channel.id) == ["newer", "old", "xray", "yankee"])
        #expect(digest.entries.map(\.count) == [9999, 2, 1, 1])
        #expect(digest.entries[2].mentioned)
        #expect(digest.total == 9999)
    }

    /// A malformed channel list can name a conversation twice; Unread
    /// lists it once and counts its unread messages once.
    @Test func unreadDigestListsARepeatedChannelOnce() {
        let news = channel(["name": .string("news"), "channel_name": .string("News")])
        let quiet = channel(["name": .string("quiet"), "channel_name": .string("Quiet"), "muted": .bool(true)])
        let unread: JSONValue = .array([
            .object(["name": .string("news"), "unread_count": .number(3)]),
            .object(["name": .string("quiet"), "unread_count": .number(5)])
        ])
        let digest = HomeUnreadDigest.make(channels: [news, quiet, news, quiet], unread: unread, mentioned: [])
        #expect(digest.entries.map(\.channel.id) == ["news"])
        #expect(digest.total == 3)
        #expect(digest.mutedConversations == 1 && digest.mutedMessages == 5)
    }

    // MARK: - HomeWeekSummary

    @Test func weekSummaryBucketsByLocalDay() {
        let calendar = gregorian(TimeZone(identifier: "Europe/Zurich")!)
        let now = date(calendar, 2026, 11, 15, 14)
        let summary = HomeWeekSummary.make(sent: [
            date(calendar, 2026, 11, 15, 9),
            date(calendar, 2026, 11, 15, 23, 30),
            date(calendar, 2026, 11, 9, 8),
            date(calendar, 2026, 11, 8, 12),
            date(calendar, 2026, 11, 2, 6),
            date(calendar, 2026, 11, 1, 23),
            date(calendar, 2026, 11, 16, 0, 30)
        ], now: now, calendar: calendar)
        #expect(summary.days == [1, 0, 0, 0, 0, 0, 2])
        #expect(summary.previousWeek == 2)
        #expect(summary.thisWeek == 3)
        #expect(summary.busiestHour == 8)
        #expect(summary.busiestHourCount == 1)
    }

    @Test func weekSummaryKeepsTheEarlierHourOnATie() {
        let calendar = gregorian(TimeZone(identifier: "Europe/Zurich")!)
        let now = date(calendar, 2026, 11, 15, 14)
        let summary = HomeWeekSummary.make(sent: [
            date(calendar, 2026, 11, 12, 9),
            date(calendar, 2026, 11, 13, 14),
            date(calendar, 2026, 11, 14, 14)
        ], now: now, calendar: calendar)
        #expect(summary.days == [0, 0, 0, 1, 1, 1, 0])
        #expect(summary.busiestHour == 14)
        #expect(summary.busiestHourCount == 2)
    }

    @Test func weekSummaryHandlesTheDaylightSavingChange() {
        let calendar = gregorian(TimeZone(identifier: "Europe/Zurich")!)
        let now = date(calendar, 2026, 4, 1, 12)
        let summary = HomeWeekSummary.make(sent: [date(calendar, 2026, 3, 29, 10)], now: now, calendar: calendar)
        #expect(summary.days == [0, 0, 0, 1, 0, 0, 0])
        #expect(summary.previousWeek == 0)
        #expect(summary.thisWeek == 1)
    }

    @Test func weekSummaryWithNoMessages() {
        let calendar = gregorian(TimeZone(identifier: "Europe/Zurich")!)
        let now = date(calendar, 2026, 11, 15, 14)
        let summary = HomeWeekSummary.make(sent: [], now: now, calendar: calendar)
        #expect(summary.days == Array(repeating: 0, count: HomeWeekSummary.dayCount))
        #expect(summary.previousWeek == 0)
        #expect(summary.thisWeek == 0)
        #expect(summary.busiestHour == nil)
        #expect(summary.busiestHourCount == 0)
    }

    // MARK: - HomePeople

    @Test func peopleRankCountsRecentDirectMessagesAndFillsFromRecentChannels() {
        let calendar = gregorian(TimeZone(identifier: "UTC")!)
        let now = date(calendar, 2026, 11, 15, 14)
        let channels = [
            dmChannel(id: "dm-alice", peer: "alice", timestamp: "2026-11-15 10:00:00"),
            dmChannel(id: "dm-bob", peer: "bob", timestamp: "2026-11-14 10:00:00"),
            dmChannel(id: "dm-carol", peer: "carol", timestamp: "2026-11-10 10:00:00"),
            dmChannel(id: "dm-dave", peer: "dave", timestamp: ""),
            dmChannel(id: "dm-me", peer: "me", timestamp: "2026-11-15 11:00:00"),
            dmChannel(id: "dm-erin", peer: "erin", timestamp: "2026-11-15 12:00:00", archived: true),
            dmChannel(id: "dm-gina", peer: "gina", timestamp: ""),
            dmChannel(id: "dm-nopeer", peer: nil, timestamp: "2026-11-15 08:00:00"),
            dmChannel(id: "dm-frank", peer: "frank", timestamp: "2026-11-13 10:00:00"),
            channel(["name": .string("grp"), "is_direct_message": .number(0), "peer_user_id": .string("frank-group"), "last_message_timestamp": .string("2026-11-15 09:00:00")])
        ]
        func sent(_ channelID: String, _ days: Int) -> HomePeople.Sent {
            HomePeople.Sent(channelID: channelID, date: daysAgo(days, from: now, calendar: calendar))
        }
        let messages = [
            sent("dm-alice", 1), sent("dm-alice", 2), sent("dm-alice", 5),
            sent("dm-bob", 3), sent("dm-bob", 4), sent("dm-bob", 5),
            sent("dm-carol", 10),
            sent("dm-dave", 2), sent("dm-dave", 6),
            sent("dm-me", 0), sent("dm-me", 0), sent("dm-me", 0), sent("dm-me", 0), sent("dm-me", 0),
            sent("dm-erin", 1), sent("dm-erin", 1), sent("dm-erin", 1), sent("dm-erin", 1),
            sent("grp", 1), sent("grp", 1), sent("grp", 1),
            sent("dm-nopeer", 1), sent("dm-nopeer", 2), sent("dm-nopeer", 3),
            sent("dm-nopeer", 4), sent("dm-nopeer", 5), sent("dm-nopeer", 6),
            sent("dm-alice", 31),
            sent("dm-bob", -1)
        ]
        let ranked = HomePeople.rank(sent: messages, channels: channels, me: "me", now: now)
        #expect(ranked == ["alice", "bob", "dave", "carol", "frank"])
        #expect(!ranked.contains("me"))
        #expect(!ranked.contains("erin"))
        #expect(!ranked.contains("frank-group"))
    }

    @Test func peopleRankRespectsTheLimit() {
        let calendar = gregorian(TimeZone(identifier: "UTC")!)
        let now = date(calendar, 2026, 11, 15, 14)
        let channels = [
            dmChannel(id: "dm-alice", peer: "alice", timestamp: "2026-11-15 10:00:00"),
            dmChannel(id: "dm-bob", peer: "bob", timestamp: "2026-11-14 10:00:00"),
            dmChannel(id: "dm-carol", peer: "carol", timestamp: "2026-11-13 10:00:00")
        ]
        let messages = [
            HomePeople.Sent(channelID: "dm-alice", date: daysAgo(1, from: now, calendar: calendar)),
            HomePeople.Sent(channelID: "dm-bob", date: daysAgo(2, from: now, calendar: calendar)),
            HomePeople.Sent(channelID: "dm-carol", date: daysAgo(3, from: now, calendar: calendar))
        ]
        #expect(HomePeople.rank(sent: messages, channels: channels, me: "me", now: now, limit: 2) == ["alice", "bob"])
        #expect(HomePeople.rank(sent: messages, channels: channels, me: "me", now: now, limit: 0) == [])
        #expect(HomePeople.rank(sent: messages, channels: channels, me: "me", now: now, limit: 10) == ["alice", "bob", "carol"])
    }

    @Test func peopleRankFillsNewestFirstSkippingUntimestampedChannels() {
        let calendar = gregorian(TimeZone(identifier: "UTC")!)
        let now = date(calendar, 2026, 11, 15, 14)
        let channels = [
            dmChannel(id: "dm-gina", peer: "gina", timestamp: ""),
            dmChannel(id: "dm-old", peer: "old", timestamp: "2026-11-01 10:00:00"),
            dmChannel(id: "dm-new", peer: "new", timestamp: "2026-11-12 10:00:00")
        ]
        #expect(HomePeople.rank(sent: [], channels: channels, me: "me", now: now) == ["new", "old"])
    }
}
