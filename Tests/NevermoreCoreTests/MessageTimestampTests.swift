import Foundation
import Testing
@testable import NevermoreCore

@Suite struct MessageTimestampTests {
    @Test func acceptsAbsentAndOneThroughSixFractionalDigitsWithoutLosingMicroseconds() throws {
        let parser = ServerTimestampParser(siteTimeZone: .gmt)
        let base = Date(timeIntervalSince1970: 1794141296)
        for (suffix, expected) in [("", 0.0), (".1", 0.1), (".12", 0.12), (".123", 0.123), (".1234", 0.1234), (".12345", 0.12345), (".123456", 0.123456), (".000001", 0.000001)] {
            let date = try #require(parser.date(from: "2026-11-08 12:34:56" + suffix))
            #expect(abs(date.timeIntervalSince(base) - expected) < 0.000001)
        }
    }

    @Test func rejectsMalformedImpossibleAndTrailingInput() {
        let parser = ServerTimestampParser(siteTimeZone: .gmt)
        let invalid = ["", "2026-11-08", "2026-11-08 12:34:56.", "2026-11-08 12:34:56.1234567", "2026-11-08 12:34:56Z", "2026-11-08T12:34:56", "2026-11-08 12:34:56 trailing", "2026-11-08 12:34:56\n", "2026-11-08 12:34:56\0", " 2026-11-08 12:34:56", "2026-02-29 12:34:56", "2026-02-30 12:34:56", "0000-01-01 00:00:00", "2026-13-01 00:00:00", "2026-11-00 00:00:00", "2026-11-08 24:00:00", "2026-11-08 12:60:00", "2026-11-08 12:34:60", "２０２６-11-08 12:34:56", String(repeating: "1", count: 100_000)]
        for raw in invalid { #expect(parser.date(from: raw) == nil) }
        #expect(parser.date(from: "2024-02-29 12:34:56") != nil)
    }

    @Test func interpretsServerWallTimeInTheSiteZone() throws {
        let raw = "2026-11-08 12:34:56"
        let utc = try #require(ServerTimestampParser(siteTimeZone: .gmt).date(from: raw))
        let zurich = try #require(ServerTimestampParser(siteTimeZone: TimeZone(identifier: "Europe/Zurich")!).date(from: raw))
        let kolkata = try #require(ServerTimestampParser(siteTimeZone: TimeZone(identifier: "Asia/Kolkata")!).date(from: raw))
        #expect(utc.timeIntervalSince(zurich) == 3600)
        #expect(utc.timeIntervalSince(kolkata) == 19_800)
    }

    @Test func rejectsNonexistentDSTTimeAndPreservesRepeatedWallTime() throws {
        let zone = TimeZone(identifier: "Europe/Zurich")!
        let parser = ServerTimestampParser(siteTimeZone: zone)
        #expect(parser.date(from: "2026-03-29 02:30:00") == nil)
        let repeated = try #require(parser.date(from: "2026-10-25 02:30:00"))
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        #expect(calendar.component(.hour, from: repeated) == 2)
        #expect(calendar.component(.minute, from: repeated) == 30)
    }

    @MainActor @Test func displayRefreshHonorsLocaleAndDeviceZoneWithoutChangingSiteParsing() {
        let raw = "2026-11-08 12:34:56"
        let instant = Date(timeIntervalSince1970: 1794137696)
        let formatter = MessageTimestampFormatter(siteTimeZone: TimeZone(identifier: "Europe/Zurich")!, locale: Locale(identifier: "en_US"), displayTimeZone: .gmt)
        let reference = DateFormatter()
        reference.locale = Locale(identifier: "en_US"); reference.timeZone = .gmt
        reference.dateStyle = .short; reference.timeStyle = .short
        let original = formatter.string(from: raw)
        #expect(original == reference.string(from: instant))

        let changedLocale = Locale(identifier: "de_DE"), changedZone = TimeZone(identifier: "Asia/Tokyo")!
        formatter.updateDisplay(locale: changedLocale, timeZone: changedZone)
        reference.locale = changedLocale; reference.calendar = changedLocale.calendar; reference.timeZone = changedZone
        #expect(formatter.string(from: raw) == reference.string(from: instant))
        #expect(formatter.string(from: raw) != original)
    }

    @MainActor @Test func unknownTimestampFallbackPreservesABoundedRawPrefix() {
        let formatter = MessageTimestampFormatter(siteTimeZone: .gmt)
        #expect(formatter.string(from: "unrecognized server timestamp") == "unrecognized ser")
        #expect(formatter.string(from: "") == "")
        let combining = "x" + String(repeating: "\u{301}", count: 100_000)
        let fallback = formatter.string(from: combining)
        #expect(fallback.unicodeScalars.count == 16)
        #expect(fallback.utf8.count <= 64)
    }
}
