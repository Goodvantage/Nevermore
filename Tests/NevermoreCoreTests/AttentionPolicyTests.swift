import Testing
import RavenProtocol
@testable import NevermoreCore

@Suite struct AttentionPolicyTests {
    @Test func countsCanonicalBatchesAndRejectsStaleOrMalformedRows() {
        let channels = [RavenChannel(raw: .object(["name": .string("dm"), "is_direct_message": .bool(true)])), RavenChannel(raw: .object(["name": .string("muted"), "muted": .bool(true)]))]
        let unread: JSONValue = .array([
            .object(["name": .string("dm"), "unread_count": .number(3)]),
            .object(["name": .string("dm"), "unread_count": .number(2)]),
            .object(["name": .string("muted"), "unread_count": .number(20)]),
            .object(["name": .string("revoked"), "unread_count": .number(30)]),
            .object(["name": .string("dm"), "unread_count": .number(.infinity)])
        ])
        #expect(AttentionPolicy.unreadCount(channels: channels, unread: unread) == 3)
        #expect(AttentionPolicy.unreadCount(channels: channels, unread: unread, directMessagesOnly: true) == 3)
    }
    @Test func dotDoesNotPretendToCountTheAttentionInbox() {
        #expect(AttentionPolicy.badge(mode: .attention, unreadCount: 500, hasAttention: false) == nil)
        #expect(AttentionPolicy.badge(mode: .attention, unreadCount: 0, hasAttention: true) == "•")
        #expect(AttentionPolicy.badge(mode: .none, unreadCount: 10, hasAttention: true) == nil)
        #expect(AttentionPolicy.badge(mode: .allUnread, unreadCount: 9999, hasAttention: false) == "9999+")
    }
}
