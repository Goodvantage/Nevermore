import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

struct TranscriptReadPositionTests {
    private func message(_ id: String, _ second: String, owner: String = "other") -> RavenMessage {
        RavenMessage(raw: .object(["name": .string(id), "channel_id": .string("c"), "owner": .string(owner), "creation": .string("2026-11-08 12:00:" + second)]))
    }

    @Test func newInboundWhileAwayAndJumpToLatest() {
        var policy = TranscriptReadPosition()
        let initial = [message("old", "00")]
        policy.observe(initial, currentUser: "me", visit: .neverVisited, following: true)
        policy.observe(initial + [message("new", "01")], currentUser: "me", visit: nil, following: false)
        #expect(policy.hasNewMessages)
        policy.caughtUp()
        #expect(!policy.hasNewMessages)
        policy.observe(initial + [message("new", "01")], currentUser: "me", visit: nil, following: false)
        #expect(!policy.hasNewMessages)
        policy.observe(initial + [message("newer", "02")], currentUser: "me", visit: nil, following: false)
        #expect(policy.hasNewMessages)
    }

    @Test func knownVisitUsesStrictPrecisionAndExcludesOwnOrUnknownAuthor() {
        var policy = TranscriptReadPosition()
        let rows = [message("same", "00.1"), message("mine", "00.100001", owner: "me"), message("unknown", "00.100002", owner: ""), message("first", "00.100003")]
        policy.observe(rows, currentUser: "me", visit: .timestamp("2026-11-08 12:00:00.100000"), following: false)
        #expect(policy.firstUnreadID(in: rows, currentUser: "me") == "first")
        policy.observe(rows, currentUser: "me", visit: .timestamp("2026-11-08 12:00:59"), following: false)
        #expect(policy.firstUnreadID(in: rows, currentUser: "me") == "first")
        policy.caughtUp()
        #expect(policy.firstUnreadID(in: rows, currentUser: "me") == nil)
    }

    @Test func unknownOrNeverVisitedDoesNotInventADivider() {
        let rows = [message("new", "01")]
        var unknown = TranscriptReadPosition()
        unknown.observe(rows, currentUser: "me", visit: nil, following: false)
        #expect(unknown.firstUnreadID(in: rows, currentUser: "me") == nil)
        unknown.observe(rows, currentUser: "me", visit: .timestamp("invalid"), following: false)
        #expect(unknown.firstUnreadID(in: rows, currentUser: "me") == nil)
        var never = TranscriptReadPosition()
        never.observe(rows, currentUser: "me", visit: .neverVisited, following: false)
        #expect(never.firstUnreadID(in: rows, currentUser: "me") == nil)
    }

    @Test func deletionsOwnSendsAndOlderHistoryDoNotProduceNewArrivals() {
        var policy = TranscriptReadPosition()
        let newest = message("latest", "10")
        policy.observe([newest], currentUser: "me", visit: nil, following: true)
        policy.observe([message("older", "00"), newest, message("mine", "11", owner: "me")], currentUser: "me", visit: nil, following: false)
        #expect(!policy.hasNewMessages)
        policy.observe([newest, message("new", "12")], currentUser: "me", visit: nil, following: false)
        #expect(policy.hasNewMessages)
        policy.observe([newest], currentUser: "me", visit: nil, following: false)
        #expect(!policy.hasNewMessages)
    }

    @Test func contextOrRevocationResetDropsPrivateReadingState() {
        var policy = TranscriptReadPosition()
        policy.observe([message("old", "00")], currentUser: "me", visit: .timestamp("2026-11-08 11:59:00"), following: true)
        policy.observe([message("new", "01")], currentUser: "me", visit: nil, following: false)
        #expect(policy.hasNewMessages)
        policy.reset()
        #expect(!policy.hasNewMessages)
        #expect(policy.firstUnreadID(in: [message("other-account", "01")], currentUser: "me") == nil)
        policy.observe([message("other-account", "59")], currentUser: "me", visit: nil, following: false)
        #expect(!policy.hasNewMessages)
    }

    @Test func newTailDoesNotDiscardAnOlderVisibleAnchor() {
        let rows = (0..<700).map { index in
            RavenMessage(raw: .object(["name": .string("m\(index)"), "channel_id": .string("c"), "text": .string("<p>bounded</p>")]))
        }
        let projection = MessageWindow.bounded(rows, anchorID: "m100")
        #expect(projection.count <= 500)
        #expect(projection.contains { $0.id == "m100" })
    }

    @Test func observedVisitsDoNotRegressBehindAnOlderServerSnapshot() {
        let earlier = "2026-11-08 12:00:00.1", later = "2026-11-08 12:00:00.100001"
        #expect(TranscriptReadPosition.effectiveVisit(server: .timestamp(earlier), observedTimestamp: later) == .timestamp(later))
        #expect(TranscriptReadPosition.effectiveVisit(server: .timestamp(later), observedTimestamp: earlier) == .timestamp(later))
        #expect(TranscriptReadPosition.effectiveVisit(server: .neverVisited, observedTimestamp: later) == .timestamp(later))
        #expect(TranscriptReadPosition.effectiveVisit(server: nil, observedTimestamp: nil) == nil)
    }

    @Test func serverUnreadRulesExcludeSystemAndIncludeOwnBotMessages() {
        var system = message("system", "01").raw.object; system["message_type"] = .string("System")
        var bot = message("bot", "02", owner: "me").raw.object; bot["is_bot_message"] = .number(1)
        let rows = [RavenMessage(raw: .object(system)), RavenMessage(raw: .object(bot))]
        var policy = TranscriptReadPosition()
        policy.observe([], currentUser: "me", visit: .timestamp("2026-11-08 12:00:00"), following: true)
        policy.observe(rows, currentUser: "me", visit: nil, following: false)
        #expect(policy.firstUnreadID(in: rows, currentUser: "me") == "bot")
        var arrival = TranscriptReadPosition()
        arrival.observe([message("old", "00")], currentUser: "me", visit: nil, following: true)
        arrival.observe([message("old", "00"), RavenMessage(raw: .object(system))], currentUser: "me", visit: nil, following: false)
        #expect(!arrival.hasNewMessages)
        arrival.observe([message("old", "00"), RavenMessage(raw: .object(bot))], currentUser: "me", visit: nil, following: false)
        #expect(arrival.hasNewMessages)
    }

    @Test func equalTimestampArrivalsAreTrackedByIdentityUntilCaughtUpOrDeleted() {
        let old = message("old", "00"), new = message("new", "00")
        var policy = TranscriptReadPosition()
        policy.observe([old], currentUser: "me", visit: nil, following: true)
        policy.observe([old, new], currentUser: "me", visit: nil, following: false)
        #expect(policy.hasNewMessages)
        policy.observe([old, new], currentUser: "me", visit: nil, following: false)
        #expect(policy.hasNewMessages)
        policy.observe([old], currentUser: "me", visit: nil, following: false)
        #expect(!policy.hasNewMessages)
        policy.observe([old, new], currentUser: "me", visit: nil, following: false)
        policy.caughtUp()
        policy.observe([old, new], currentUser: "me", visit: nil, following: false)
        #expect(!policy.hasNewMessages)
    }

    @Test func olderPagesDoNotMasqueradeAsTiedArrivalsAndOpaqueIDsStayDistinct() {
        let old = message("é", "01"), tiedHistory = message("historical", "01"), new = message("e\u{301}", "01")
        var policy = TranscriptReadPosition()
        policy.observe([old], currentUser: "me", visit: nil, following: true)
        policy.observe([message("older", "00"), old, tiedHistory], currentUser: "me", visit: nil, following: false, historicalIDs: [Data(tiedHistory.id.utf8)])
        #expect(!policy.hasNewMessages)
        policy.observe([old, tiedHistory, new], currentUser: "me", visit: nil, following: false)
        #expect(policy.hasNewMessages)
    }

    @Test func oversizedTimestampGroupsAndIncompleteHistoryDeclineAmbiguousTies() {
        let rows = (0..<2049).map { message("id-\($0)", "00") }
        var policy = TranscriptReadPosition()
        policy.observe(rows, currentUser: "me", visit: nil, following: true)
        policy.observe(rows + [message("new-tie", "00")], currentUser: "me", visit: nil, following: false)
        #expect(!policy.hasNewMessages)
        policy.observe(rows + [message("newer", "01")], currentUser: "me", visit: nil, following: false)
        #expect(policy.hasNewMessages)
        var incomplete = TranscriptReadPosition()
        incomplete.observe([rows[0]], currentUser: "me", visit: nil, following: true)
        incomplete.observe([rows[0], message("ambiguous", "00")], currentUser: "me", visit: nil, following: false, historicalIDsComplete: false)
        #expect(!incomplete.hasNewMessages)
    }
}
