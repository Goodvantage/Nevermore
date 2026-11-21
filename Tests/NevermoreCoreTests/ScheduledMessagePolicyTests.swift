import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

struct ScheduledMessagePolicyTests {
    @Test func scheduleUsesTheMinuteVisibleInTheSitePicker() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Kathmandu"))
        let parser = ServerTimestampParser(siteTimeZone: zone)
        let now = try #require(parser.date(from: "2026-11-18 10:00:00"))
        for (picked, expected) in [
            ("2026-11-18 10:05:37.125", "2026-11-18 10:05:00"),
            ("2026-11-18 10:06:00", "2026-11-18 10:10:00"),
            ("2026-11-18 23:59:59", "2026-11-19 00:00:00")
        ] {
            let date = try #require(parser.date(from: picked))
            #expect(ScheduledMessagePolicy.slot(for: date, in: zone, now: now) == parser.date(from: expected))
        }
        #expect(ScheduledMessagePolicy.slot(for: now.addingTimeInterval(37), in: zone, now: now) == nil)
    }

    @Test func springForwardSlotCrossesToTheNextValidMinute() throws {
        let zone = try #require(TimeZone(identifier: "Europe/Zurich"))
        let parser = ServerTimestampParser(siteTimeZone: zone)
        let picked = try #require(parser.date(from: "2027-03-28 01:59:24"))
        let expected = try #require(parser.date(from: "2027-03-28 03:00:00"))
        #expect(ScheduledMessagePolicy.slot(for: picked, in: zone, now: picked) == expected)
    }

    @Test func ambiguousTransportAndServerFailuresNeedReviewBeforeAnotherPost() {
        #expect(ScheduledMessagePolicy.completion(for: URLError(.networkConnectionLost)) == .indeterminate)
        #expect(ScheduledMessagePolicy.completion(for: RavenError.transport) == .indeterminate)
        #expect(ScheduledMessagePolicy.completion(for: RavenError.http(500, nil)) == .indeterminate)
        #expect(ScheduledMessagePolicy.completion(for: RavenError.http(408, nil)) == .indeterminate)
        #expect(ScheduledMessagePolicy.completion(for: RavenError.http(409, nil)) == .indeterminate)
        #expect(ScheduledMessagePolicy.completion(for: RavenError.http(429, nil)) == .indeterminate)
        #expect(ScheduledMessagePolicy.completion(for: RavenError.resourceLimit(RavenError.maximumAttachmentBytes)) == .indeterminate)
        #expect(ScheduledMessagePolicy.completion(for: RavenError.invalidResponse) == .indeterminate)
    }

    @Test func authoritativeRefusalsAreNotIndeterminate() {
        #expect(ScheduledMessagePolicy.completion(for: RavenError.http(401, nil)) == .rejected)
        #expect(ScheduledMessagePolicy.completion(for: RavenError.http(403, "PermissionError")) == .rejected)
        #expect(ScheduledMessagePolicy.completion(for: RavenError.http(400, "ValidationError")) == .rejected)
        #expect(ScheduledMessagePolicy.completion(for: RavenError.invalidSite) == .rejected)
        #expect(ScheduledMessagePolicy.completion(for: RavenError.http(404, nil)) == .rejected)
    }

    @Test func unchangedConversationClearsOnlyItsOwnConfirmedDraft() {
        #expect(ScheduledMessagePolicy.clearance(originatingConversationVisible: true, revisionUnchanged: true, draftUnchanged: true) == .clear)
    }

    @Test func navigatingAwayPreservesTheOriginalDraft() {
        #expect(ScheduledMessagePolicy.clearance(originatingConversationVisible: false, revisionUnchanged: true, draftUnchanged: true) == .differentContext)
        #expect(ScheduledMessagePolicy.clearance(originatingConversationVisible: false, revisionUnchanged: false, draftUnchanged: false) == .differentContext)
    }

    @Test func aNewerSharedRevisionWinsOverTheScheduledSnapshot() {
        #expect(ScheduledMessagePolicy.clearance(originatingConversationVisible: true, revisionUnchanged: false, draftUnchanged: true) == .newerRevision)
        #expect(ScheduledMessagePolicy.clearance(originatingConversationVisible: true, revisionUnchanged: false, draftUnchanged: false) == .newerRevision)
    }

    @Test func changedDraftContentIsPreservedEvenWhenTheRevisionMatches() {
        #expect(ScheduledMessagePolicy.clearance(originatingConversationVisible: true, revisionUnchanged: true, draftUnchanged: false) == .changedDraft)
    }
}
