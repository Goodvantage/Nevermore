import XCTest
import Foundation
import RavenProtocol
@testable import NevermoreCore

final class NotificationPolicyTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        date(year, month, day, hour, minute, timeZone: TimeZone(identifier: "UTC")!)
    }

    private func quietHours(_ start: Int, _ end: Int, _ zone: String, enabled: Bool = true) -> QuietHours {
        QuietHours(startMinute: start, endMinute: end, timezone: zone, enabled: enabled)
    }

    // MARK: - QuietHours boundaries

    func testSameDayWindowUsesSiteTimezoneBoundaries() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let quiet = quietHours(9 * 60, 17 * 60, "Asia/Tokyo")
        XCTAssertFalse(quiet.contains(date(2026, 4, 1, 8, 59, timeZone: tokyo)))
        XCTAssertTrue(quiet.contains(date(2026, 4, 1, 9, 0, timeZone: tokyo)))
        XCTAssertTrue(quiet.contains(date(2026, 4, 1, 16, 59, timeZone: tokyo)))
        XCTAssertFalse(quiet.contains(date(2026, 4, 1, 17, 0, timeZone: tokyo)))
        // The same instant is the middle of the night in New York: the site
        // timezone, not the device timezone, defines the window.
        XCTAssertTrue(quiet.contains(utcDate(2026, 4, 1, 0, 30)))
    }

    func testOvernightWindowCrossesMidnight() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let quiet = quietHours(22 * 60, 6 * 60, "America/New_York")
        XCTAssertFalse(quiet.contains(date(2026, 3, 6, 21, 59, timeZone: newYork)))
        XCTAssertTrue(quiet.contains(date(2026, 3, 6, 22, 0, timeZone: newYork)))
        XCTAssertTrue(quiet.contains(date(2026, 3, 7, 5, 59, timeZone: newYork)))
        XCTAssertFalse(quiet.contains(date(2026, 3, 7, 6, 0, timeZone: newYork)))
        XCTAssertFalse(quiet.contains(date(2026, 3, 7, 12, 0, timeZone: newYork)))
    }

    func testMidnightBoundaryIsHalfOpenAtBothEnds() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let quiet = quietHours(23 * 60, 30, "America/New_York")
        XCTAssertFalse(quiet.contains(date(2026, 3, 6, 22, 59, timeZone: newYork)))
        XCTAssertTrue(quiet.contains(date(2026, 3, 6, 23, 0, timeZone: newYork)))
        XCTAssertTrue(quiet.contains(date(2026, 3, 7, 0, 0, timeZone: newYork)))
        XCTAssertTrue(quiet.contains(date(2026, 3, 7, 0, 29, timeZone: newYork)))
        XCTAssertFalse(quiet.contains(date(2026, 3, 7, 0, 30, timeZone: newYork)))
    }

    func testWeekBoundaryOvernightWindow() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let quiet = quietHours(23 * 60, 60, "America/New_York")
        // Sunday 2026-03-08 23:30 EDT (DST began earlier that morning).
        XCTAssertTrue(quiet.contains(date(2026, 3, 8, 23, 30, timeZone: newYork)))
        // Monday 2026-03-09 00:30 EDT.
        XCTAssertTrue(quiet.contains(date(2026, 3, 9, 0, 30, timeZone: newYork)))
        XCTAssertFalse(quiet.contains(date(2026, 3, 9, 1, 30, timeZone: newYork)))
    }

    // MARK: - DST

    func testDSTSpringForwardKeepsOvernightWindow() {
        let quiet = quietHours(22 * 60, 6 * 60, "America/New_York")
        // 2026-03-08 01:30 EST (UTC-5) = 06:30 UTC, before the 02:00 jump.
        XCTAssertTrue(quiet.contains(utcDate(2026, 3, 8, 6, 30)))
        // 2026-03-08 03:30 EDT (UTC-4) = 07:30 UTC. 02:30 local does not exist.
        XCTAssertTrue(quiet.contains(utcDate(2026, 3, 8, 7, 30)))
        // 2026-03-08 06:30 EDT = 10:30 UTC, after the window.
        XCTAssertFalse(quiet.contains(utcDate(2026, 3, 8, 10, 30)))
        // 2026-03-07 21:30 EST = 2026-03-08 02:30 UTC, before the window.
        XCTAssertFalse(quiet.contains(utcDate(2026, 3, 8, 2, 30)))
    }

    func testDSTFallBackKeepsOvernightWindow() {
        let quiet = quietHours(22 * 60, 6 * 60, "America/New_York")
        // 2026-11-01 01:30 EDT (UTC-4) = 05:30 UTC.
        XCTAssertTrue(quiet.contains(utcDate(2026, 11, 1, 5, 30)))
        // 2026-11-01 01:30 EST (UTC-5) = 06:30 UTC; both ambiguous local
        // instants are inside the window.
        XCTAssertTrue(quiet.contains(utcDate(2026, 11, 1, 6, 30)))
        // 2026-11-01 06:30 EST = 11:30 UTC, after the window.
        XCTAssertFalse(quiet.contains(utcDate(2026, 11, 1, 11, 30)))
    }

    // MARK: - Disabled and invalid windows

    func testDisabledQuietHoursNeverContains() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let quiet = quietHours(0, 1439, "America/New_York", enabled: false)
        XCTAssertFalse(quiet.contains(date(2026, 3, 7, 12, 0, timeZone: newYork)))
        XCTAssertFalse(quiet.contains(date(2026, 3, 7, 23, 0, timeZone: newYork)))
    }

    func testDegenerateWindowNeverContains() {
        let newYork = TimeZone(identifier: "America/New_York")!
        let quiet = quietHours(9 * 60, 9 * 60, "America/New_York")
        XCTAssertFalse(quiet.contains(date(2026, 3, 7, 9, 0, timeZone: newYork)))
    }

    func testOutOfRangeOrUnknownTimezoneNeverContains() {
        let newYork = TimeZone(identifier: "America/New_York")!
        XCTAssertFalse(quietHours(-1, 120, "America/New_York").contains(date(2026, 3, 7, 1, 0, timeZone: newYork)))
        XCTAssertFalse(quietHours(0, 1440, "America/New_York").contains(date(2026, 3, 7, 12, 0, timeZone: newYork)))
        XCTAssertFalse(quietHours(0, 120, "Not/AZone").contains(date(2026, 3, 7, 1, 0, timeZone: newYork)))
    }

    func testQuietHoursCodableRoundTrip() throws {
        let quiet = quietHours(22 * 60, 6 * 60, "America/New_York")
        let data = try JSONEncoder().encode(quiet)
        let decoded = try JSONDecoder().decode(QuietHours.self, from: data)
        XCTAssertEqual(quiet, decoded)
    }

    // MARK: - NotificationPolicy

    func testPolicyAllowsBackgroundUnmutedEnabledOutsideQuietHours() {
        let now = utcDate(2026, 3, 7, 12, 0)
        XCTAssertTrue(NotificationPolicy.shouldNotify(now: now, quietHours: nil, isForeground: false, enabled: true, muted: false))
        let quiet = quietHours(22 * 60, 6 * 60, "America/New_York")
        XCTAssertTrue(NotificationPolicy.shouldNotify(now: now, quietHours: quiet, isForeground: false, enabled: true, muted: false))
    }

    func testPolicySuppressesDisabledMutedOrForeground() {
        let now = utcDate(2026, 3, 7, 12, 0)
        XCTAssertFalse(NotificationPolicy.shouldNotify(now: now, quietHours: nil, isForeground: false, enabled: false, muted: false))
        XCTAssertFalse(NotificationPolicy.shouldNotify(now: now, quietHours: nil, isForeground: false, enabled: true, muted: true))
        XCTAssertFalse(NotificationPolicy.shouldNotify(now: now, quietHours: nil, isForeground: true, enabled: true, muted: false))
    }

    func testPolicySuppressesInsideQuietHours() {
        let now = utcDate(2026, 3, 7, 3, 0) // 2026-03-06 22:00 EST
        let quiet = quietHours(22 * 60, 6 * 60, "America/New_York")
        XCTAssertTrue(quiet.contains(now))
        XCTAssertFalse(NotificationPolicy.shouldNotify(now: now, quietHours: quiet, isForeground: false, enabled: true, muted: false))
    }

    func testPolicyAllowsWhenQuietHoursDisabled() {
        let now = utcDate(2026, 3, 7, 3, 0)
        let quiet = quietHours(22 * 60, 6 * 60, "America/New_York", enabled: false)
        XCTAssertTrue(NotificationPolicy.shouldNotify(now: now, quietHours: quiet, isForeground: false, enabled: true, muted: false))
    }

    private func message(id: String, owner: String, creation: String = "2026-11-23 10:00:00.000000") -> RavenMessage {
        RavenMessage(raw: .object(["name": .string(id), "channel_id": .string("c"), "owner": .string(owner), "creation": .string(creation), "text": .string("<p>hi</p>")]))
    }

    func testNewestForeignSkipsTheReadersOwnNewestRows() {
        // Newest first: the reader sent from the phone after the incoming
        // message, so the newest row is theirs; the incoming one still wins.
        let page = [message(id: "own", owner: "me@example.com", creation: "2026-11-23 10:03:00.000000"), message(id: "theirs", owner: "alex@example.com", creation: "2026-11-23 10:02:00.000000"), message(id: "older", owner: "morgan@example.com", creation: "2026-11-23 10:01:00.000000")]
        XCTAssertEqual(NotificationPolicy.newestForeign(page, user: "me@example.com")?.id, "theirs")
        XCTAssertNil(NotificationPolicy.newestForeign([message(id: "own", owner: "me@example.com")], user: "me@example.com"))
        XCTAssertNil(NotificationPolicy.newestForeign([], user: "me@example.com"))
    }

    func testNewestForeignDoesNotTrustRowOrder() {
        // Ascending input must still yield the newest foreign message, not the
        // oldest one.
        let page = [message(id: "older", owner: "morgan@example.com", creation: "2026-11-23 10:01:00.000000"), message(id: "theirs", owner: "alex@example.com", creation: "2026-11-23 10:02:00.000000"), message(id: "own", owner: "me@example.com", creation: "2026-11-23 10:03:00.000000")]
        XCTAssertEqual(NotificationPolicy.newestForeign(page, user: "me@example.com")?.id, "theirs")
    }

    func testNextNotificationSkipsDeliveredAndSeenRows() {
        // The newest foreign row was already delivered; the older un-notified
        // one must win instead of being masked.
        let page = [
            message(id: "delivered", owner: "alex@example.com", creation: "2026-11-23 10:03:00.000000"),
            message(id: "pending", owner: "morgan@example.com", creation: "2026-11-23 10:02:00.000000"),
            message(id: "seen", owner: "sam@example.com", creation: "2026-11-23 10:01:00.000000"),
        ]
        let notified: Set<String> = ["delivered"]
        let picked = NotificationPolicy.nextNotification(in: page, user: "me@example.com", seen: "2026-11-23 10:01:00.000000", notified: { notified.contains($0) })
        XCTAssertEqual(picked?.id, "pending")
        // A nil high-water mark notifies the newest un-delivered foreign row.
        XCTAssertEqual(NotificationPolicy.nextNotification(in: page, user: "me@example.com", seen: nil, notified: { notified.contains($0) })?.id, "pending")
        // Everything delivered or seen yields nothing.
        XCTAssertNil(NotificationPolicy.nextNotification(in: page, user: "me@example.com", seen: "2026-11-23 10:03:00.000000", notified: { _ in true }))
        // The reader's own rows never qualify.
        XCTAssertNil(NotificationPolicy.nextNotification(in: [message(id: "own", owner: "me@example.com")], user: "me@example.com", seen: nil, notified: { _ in false }))
    }
}
