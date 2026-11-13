import Foundation
import Testing
import RavenProtocol
@testable import NevermoreCore

struct TranscriptChannelStateCacheTests {
    @Test func manyDistinctChannelsCannotGrowBeyondAccountBudgets() {
        var cache = TranscriptChannelStateCache()
        for channel in 0..<1000 {
            let id = "channel-\(channel)"
            cache.recordVisit(.timestamp("2026-11-08 12:00:00.123456"), channelID: id)
            cache.recordHistoricalPage(messageIDs: (0..<200).map { "message-\($0)-" + String(repeating: "x", count: 100) }, channelID: id)
            #expect(cache.entryCount <= 16)
            #expect(cache.retainedBytes <= 128 * 1024)
            #expect(cache.retainedIdentityCount <= 2048)
        }
        #expect(cache.visit(for: "channel-0") == nil)
        #expect(cache.historicalPage(for: "channel-0")?.complete == false)
        #expect(cache.historicalPage(for: "channel-0")?.ids.isEmpty == true)
        #expect(cache.historicalPage(for: "channel-999")?.ids.count == 200)
    }

    @Test func byteAndIdentityCapsEvictIndependentlyOfChannelCount() {
        var bytes = TranscriptChannelStateCache(maximumEntries: 16, maximumBytes: 20, maximumIdentities: 100)
        bytes.recordHistoricalPage(messageIDs: ["1234567890"], channelID: "a")
        bytes.recordHistoricalPage(messageIDs: ["abcdefghij"], channelID: "b")
        #expect(bytes.entryCount == 1 && bytes.retainedBytes == 12)
        #expect(bytes.historicalPage(for: "a")?.complete == false)
        var identities = TranscriptChannelStateCache(maximumEntries: 16, maximumBytes: 1000, maximumIdentities: 2)
        identities.recordHistoricalPage(messageIDs: ["one", "two"], channelID: "a")
        identities.recordHistoricalPage(messageIDs: ["three"], channelID: "b")
        #expect(identities.entryCount == 1 && identities.retainedIdentityCount == 1)
        #expect(identities.historicalPage(for: "a")?.ids.isEmpty == true)
    }

    @Test func detachAndParentRevocationDiscardPayloadsWithConservativeMisses() {
        var cache = TranscriptChannelStateCache()
        for channel in ["detached", "parent", "thread", "retained"] {
            cache.recordVisit(.timestamp("2026-11-08 12:00:00"), channelID: channel)
            cache.recordHistoricalPage(messageIDs: ["private-" + channel], channelID: channel)
        }
        let eligible: Set<String> = ["parent", "thread", "retained"]
        cache.retain { eligible.contains($0) }
        #expect(cache.visit(for: "detached") == nil && cache.historicalPage(for: "detached")?.ids.isEmpty == true)
        cache.retain { !ChannelPolicy.isRevoked(channelID: $0, revoked: ["parent"], threadParents: ["thread": "parent"]) }
        #expect(cache.entryCount == 1)
        for removed in ["parent", "thread"] {
            #expect(cache.visit(for: removed) == nil)
            #expect(cache.historicalPage(for: removed)?.ids.isEmpty == true)
            #expect(cache.historicalPage(for: removed)?.complete == false)
        }
        #expect(cache.historicalPage(for: "retained")?.complete == true)
        cache.retain { _ in false }
        #expect(cache.entryCount == 0 && cache.retainedBytes == 0 && cache.retainedIdentityCount == 0)
        cache.removeAll()
        #expect(cache.historicalPage(for: "retained") == nil)
    }

    @Test func visitsRejectResponseSizedMalformedAndImpossibleTimestamps() {
        var cache = TranscriptChannelStateCache()
        for value in [String(repeating: "x", count: 100_000), "2026-02-30 12:00:00", "2026-11-08 12:00:00.1234567", "2026-11-08 12:00:00\n"] {
            cache.recordVisit(.timestamp(value), channelID: "c")
        }
        #expect(cache.entryCount == 0 && cache.retainedBytes == 0)
        cache.recordVisit(.timestamp("2026-11-08 12:00:00.1"), channelID: "c")
        #expect(cache.visit(for: "c") == .timestamp("2026-11-08 12:00:00.1"))
        cache.removeVisit(for: "c")
        #expect(cache.entryCount == 0)
        cache.recordVisit(.neverVisited, channelID: "c")
        #expect(cache.visit(for: "c") == .neverVisited)
    }

    @Test func partialAndEvictedHistoryNeverBecomesATiedArrival() {
        var cache = TranscriptChannelStateCache(maximumEntries: 1, maximumBytes: 1000, maximumIdentities: 10)
        cache.recordHistoricalPage(messageIDs: ["historical"], channelID: "a")
        cache.recordHistoricalPage(messageIDs: ["elsewhere"], channelID: "b")
        let missing = cache.historicalPage(for: "a")
        var policy = TranscriptReadPosition()
        func row(_ id: String) -> RavenMessage {
            RavenMessage(raw: .object(["name": .string(id), "channel_id": .string("a"), "owner": .string("other"), "creation": .string("2026-11-08 12:00:00")]))
        }
        policy.observe([row("known")], currentUser: "me", visit: nil, following: true)
        policy.observe([row("known"), row("historical")], currentUser: "me", visit: nil, following: false, historicalIDs: missing?.ids ?? [], historicalIDsComplete: missing?.complete ?? true)
        #expect(!policy.hasNewMessages)
        cache.recordHistoricalPage(messageIDs: Array(repeating: "x", count: 1001), channelID: "a")
        #expect(cache.historicalPage(for: "a")?.complete == false)
    }

    @Test func channelAndMessageIdentitiesRemainByteExact() {
        var cache = TranscriptChannelStateCache()
        cache.recordHistoricalPage(messageIDs: ["é", "e\u{301}"], channelID: "é")
        cache.recordHistoricalPage(messageIDs: ["different"], channelID: "e\u{301}")
        #expect(cache.entryCount == 2)
        #expect(cache.historicalPage(for: "é")?.ids.count == 2)
        #expect(cache.historicalPage(for: "e\u{301}")?.ids == [Data("different".utf8)])
    }
}
