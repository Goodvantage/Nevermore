import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

struct TranscriptLayoutTests {
    private var zurich: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Zurich")!
        return calendar
    }
    private func date(_ value: String) -> Date {
        ServerTimestampParser(siteTimeZone: TimeZone(identifier: "Europe/Zurich")!).date(from: value)!
    }
    private func entry(_ author: String, _ time: String?, system: Bool = false, batch: String? = nil) -> TranscriptGrouping.Entry {
        TranscriptGrouping.Entry(authorID: author, date: time.map(date), isSystem: system, batchID: batch)
    }

    @Test func messagesFromOneAuthorWithinFiveMinutesShareAHeader() {
        let calendar = zurich
        #expect(!TranscriptGrouping.continues(entry("a", "2026-11-05 12:23:00"), after: nil, calendar: calendar))
        #expect(TranscriptGrouping.continues(entry("a", "2026-11-05 12:24:00"), after: entry("a", "2026-11-05 12:23:00"), calendar: calendar))
        #expect(TranscriptGrouping.continues(entry("a", "2026-11-05 12:28:00"), after: entry("a", "2026-11-05 12:23:00"), calendar: calendar))
        #expect(!TranscriptGrouping.continues(entry("a", "2026-11-05 12:28:01"), after: entry("a", "2026-11-05 12:23:00"), calendar: calendar))
        #expect(!TranscriptGrouping.continues(entry("b", "2026-11-05 12:23:30"), after: entry("a", "2026-11-05 12:23:00"), calendar: calendar))
    }

    @Test func systemEventsDayChangesAndUnknownDatesStartNewGroups() {
        let calendar = zurich
        #expect(!TranscriptGrouping.continues(entry("a", "2026-11-05 12:23:10"), after: entry("a", "2026-11-05 12:23:00", system: true), calendar: calendar))
        #expect(!TranscriptGrouping.continues(entry("a", "2026-11-05 12:23:10", system: true), after: entry("a", "2026-11-05 12:23:00"), calendar: calendar))
        #expect(!TranscriptGrouping.continues(entry("a", "2026-11-06 00:01:00"), after: entry("a", "2026-11-05 23:59:00"), calendar: calendar))
        #expect(!TranscriptGrouping.continues(entry("a", nil), after: entry("a", "2026-11-05 12:23:00"), calendar: calendar))
        #expect(!TranscriptGrouping.continues(entry("", "2026-11-05 12:23:10"), after: entry("", "2026-11-05 12:23:00"), calendar: calendar))
    }

    @Test func oneBatchStaysTogetherEvenWithoutDates() {
        let calendar = zurich
        #expect(TranscriptGrouping.continues(entry("a", nil, batch: "send-1"), after: entry("a", nil, batch: "send-1"), calendar: calendar))
        #expect(!TranscriptGrouping.continues(entry("b", nil, batch: "send-1"), after: entry("a", nil, batch: "send-1"), calendar: calendar))
    }

    @Test func botMessagesGroupByTheBotNotTheOwner() {
        let calendar = zurich
        func message(_ owner: String, bot: String?) -> RavenMessage {
            var fields: [String: JSONValue] = ["name": .string(UUID().uuidString), "owner": .string(owner), "creation": .string("2026-11-05 12:23:00"), "message_type": .string("Text")]
            if let bot { fields["is_bot_message"] = .number(1); fields["bot"] = .string(bot) }
            return RavenMessage(raw: .object(fields))
        }
        let human = message("admin", bot: nil), bot = message("admin", bot: "hours-bot")
        #expect(bot.authorID == "hours-bot" && bot.owner == "admin")
        #expect(human.authorID == "admin")
        let instant = date("2026-11-05 12:23:00")
        let fromBot = TranscriptGrouping.Entry(bot, date: instant), fromHuman = TranscriptGrouping.Entry(human, date: instant)
        #expect(fromBot.authorID == "hours-bot")
        #expect(!TranscriptGrouping.continues(fromBot, after: fromHuman, calendar: calendar))
        var unnamed = message("admin", bot: nil).raw.object; unnamed["is_bot_message"] = .number(1); unnamed["bot"] = .string("")
        #expect(RavenMessage(raw: .object(unnamed)).authorID == "admin")
    }

    @Test func dayDividersMarkTheFirstDatedMessageAndEachNewDay() {
        let calendar = zurich
        #expect(TranscriptGrouping.startsNewDay(date("2026-11-05 12:23:00"), after: nil, calendar: calendar))
        #expect(!TranscriptGrouping.startsNewDay(date("2026-11-05 23:59:59"), after: date("2026-11-05 00:00:00"), calendar: calendar))
        #expect(TranscriptGrouping.startsNewDay(date("2026-11-06 00:00:00"), after: date("2026-11-05 23:59:59"), calendar: calendar))
        #expect(!TranscriptGrouping.startsNewDay(nil, after: date("2026-11-05 12:00:00"), calendar: calendar))
    }

    @Test func dayLabelsAreRelativeForAWeekThenDated() {
        let calendar = zurich, now = date("2026-11-09 08:00:00")
        #expect(TranscriptDay.classify(date("2026-11-09 00:00:00"), now: now, calendar: calendar) == .today)
        #expect(TranscriptDay.classify(date("2026-11-08 23:59:00"), now: now, calendar: calendar) == .yesterday)
        #expect(TranscriptDay.classify(date("2026-11-03 12:00:00"), now: now, calendar: calendar) == .recent)
        #expect(TranscriptDay.classify(date("2026-11-02 12:00:00"), now: now, calendar: calendar) == .thisYear)
        #expect(TranscriptDay.classify(date("2025-12-31 12:00:00"), now: now, calendar: calendar) == .otherYear)
        // A clock running behind the server must not call a future day "recent".
        #expect(TranscriptDay.classify(date("2026-11-10 09:00:00"), now: now, calendar: calendar) == .thisYear)
    }

    @MainActor @Test func dayLabelsFollowTheLocale() {
        let formatter = MessageTimestampFormatter(siteTimeZone: .gmt, locale: Locale(identifier: "en_US"), displayTimeZone: .gmt)
        let now = Date()
        let today = formatter.dayLabel(for: now), yesterday = formatter.dayLabel(for: now.addingTimeInterval(-86_400))
        // Foundation names relative days from the real clock.
        guard formatter.calendar.isDate(now, inSameDayAs: Date()) else { return }
        #expect(today == "Today")
        #expect(yesterday == "Yesterday")
        let older = formatter.calendar.date(byAdding: .day, value: -3, to: now)!
        let weekday = DateFormatter(); weekday.locale = Locale(identifier: "en_US"); weekday.timeZone = .gmt; weekday.dateFormat = "EEEE"
        #expect(formatter.dayLabel(for: older) == weekday.string(from: older))
        let dated = formatter.dayLabel(for: date("2024-03-07 12:00:00"))
        #expect(dated.contains("Thursday") && dated.contains("March") && dated.contains("2024"))
        formatter.updateDisplay(locale: Locale(identifier: "de_CH"), timeZone: .gmt)
        #expect(formatter.dayLabel(for: now) == "Heute")
        #expect(formatter.time(from: "2026-11-05 12:23:00") == "12:23")
        formatter.updateDisplay(locale: Locale(identifier: "en_US"), timeZone: .gmt)
        #expect(formatter.time(from: "2026-11-05 15:23:00").hasSuffix("PM"))
        #expect(formatter.compactTime(from: "2026-11-05 15:23:00") == "3:23")
    }

    @Test func monogramsUseFirstAndLastInitials() {
        #expect(AvatarMonogram.initials(for: "Benedikt") == "B")
        #expect(AvatarMonogram.initials(for: "Lukas Mathis") == "LM")
        #expect(AvatarMonogram.initials(for: "  maria von sans  ") == "MS")
        #expect(AvatarMonogram.initials(for: "alex.rivera@example.com") == "AR")
        #expect(AvatarMonogram.initials(for: "小敏") == "小")
        #expect(AvatarMonogram.initials(for: "") == "?")
        #expect(AvatarMonogram.initials(for: "🙂 ") == "?")
    }

    @Test func monogramColorsAreStableAndInRange() {
        let index = AvatarMonogram.paletteIndex(for: "benedikt@example.com", count: 9)
        #expect((0..<9).contains(index))
        #expect(AvatarMonogram.paletteIndex(for: "benedikt@example.com", count: 9) == index)
        // FNV-1a of "a" is 0xaf63dc4c8601ec8c.
        #expect(AvatarMonogram.paletteIndex(for: "a", count: 7) == Int(UInt64(0xaf63dc4c8601ec8c) % 7))
        #expect(AvatarMonogram.paletteIndex(for: "a", count: 0) == 0)
    }

    @Test func reactionChipsMarkTheReadersOwnReaction() throws {
        let json = JSONValue.object([
            "👍": .object(["count": .number(2), "users": .array([.string("me"), .string("b")]), "reaction": .string("👍")]),
            "party": .object(["count": .number(1), "users": .array([.string("b")]), "is_custom": .bool(true), "emoji_name": .string("party"), "reaction": .string("/files/party.png")]),
            "zero": .object(["count": .number(0), "reaction": .string("😶")]),
            "legacy": .number(3)
        ])
        let chips = try #require(ReactionChip.chips(json, currentUser: "me"))
        #expect(chips == [
            ReactionChip(label: "legacy", count: 3, includesCurrentUser: false),
            ReactionChip(label: ":party:", count: 1, includesCurrentUser: false),
            ReactionChip(label: "👍", count: 2, includesCurrentUser: true)
        ])
        #expect(ReactionChip.chips(json, currentUser: "")?.contains { $0.includesCurrentUser } == false)
        #expect(ReactionChip.chips(.object([:]), currentUser: "me") == nil)
        #expect(ReactionChip.chips(.object(["x": .string("bad")]), currentUser: "me") == nil)
        #expect(ReactionChip.chips(.array([]), currentUser: "me") == nil)
    }
}
