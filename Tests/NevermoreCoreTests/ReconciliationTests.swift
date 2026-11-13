import Testing
import RavenProtocol
@testable import NevermoreCore

private func row(_ id: String, _ time: String, channel: String = "a") -> RavenMessage {
    RavenMessage(raw: .object(["name": .string(id), "creation": .string(time), "channel_id": .string(channel)]))
}
@Test func missingRowsOutsideCoveredRangeAreNotDeleted() {
    let existing = [row("old", "01"), row("start", "02"), row("deleted", "03"), row("end", "04"), row("new", "05"), row("other", "03", channel: "b")]
    let snapshot = [row("end", "04"), row("start", "02")]
    #expect(MessageReconciliation.observedDeletions(existing: existing, snapshot: snapshot, channelID: "a", authoritative: true) == ["deleted"])
    #expect(MessageReconciliation.observedDeletions(existing: existing, snapshot: snapshot, channelID: "a", authoritative: false).isEmpty)
}
@Test func equalTimestampBoundaryUsesOpaqueIDTieBreaker() {
    let existing = [row("a", "2026-11-07 12:00:00.123456"), row("b", "2026-11-07 12:00:00.123456"), row("c", "2026-11-07 12:00:00.123456"), row("d", "2026-11-07 12:00:00.123456")]
    #expect(MessageReconciliation.observedDeletions(existing: existing, snapshot: [existing[0], existing[2]], channelID: "a", authoritative: true) == ["b"])
}
@Test func malformedAndCrossChannelSnapshotsCannotEraseHistory() {
    let existing = [row("a", "01"), row("b", "02")]
    #expect(MessageReconciliation.observedDeletions(existing: existing, snapshot: [], channelID: "a", authoritative: true).isEmpty)
    #expect(MessageReconciliation.observedDeletions(existing: existing, snapshot: [row("a", "01", channel: "b")], channelID: "a", authoritative: true).isEmpty)
    #expect(MessageReconciliation.observedDeletions(existing: existing, snapshot: [row("a", "01"), row("a", "01")], channelID: "a", authoritative: true).isEmpty)
}
