import Testing
import RavenProtocol
@testable import NevermoreCore

@Suite struct PresenceReadTests {
    @Test func readsAnArrayOfUsers() {
        #expect(PresenceRead.activeUsers(from: .array([.string("a@example.com"), .string("b@example.com"), .string("a@example.com")])) == ["a@example.com", "b@example.com"])
        #expect(PresenceRead.activeUsers(from: .array([])) == [])
    }

    @Test func rejectsWhatIsNotAListOfUsers() {
        #expect(PresenceRead.activeUsers(from: .object(["message": .array([.string("a@example.com")])])) == nil)
        #expect(PresenceRead.activeUsers(from: .null) == nil)
        #expect(PresenceRead.activeUsers(from: .string("a@example.com")) == nil)
        #expect(PresenceRead.activeUsers(from: .array([.string("a@example.com"), .number(3)])) == nil)
        // A user ID is never empty: "" is malformed, not a skippable entry.
        #expect(PresenceRead.activeUsers(from: .array([.string("")])) == nil)
    }

    @Test func nullEntriesAreSkippedNotFatal() {
        // A cache key expiring between the server's two reads yields null;
        // it must not reject the whole refresh.
        #expect(PresenceRead.activeUsers(from: .array([.string("a@example.com"), .null, .string("b@example.com")])) == ["a@example.com", "b@example.com"])
        #expect(PresenceRead.activeUsers(from: .array([.null])) == [])
        // A null never relaxes the rest of the reply: malformed entries still reject.
        #expect(PresenceRead.activeUsers(from: .array([.null, .number(3)])) == nil)
        // Mirror boundary cases: a trailing null, and a null before an empty string.
        #expect(PresenceRead.activeUsers(from: .array([.string("a@example.com"), .null])) == ["a@example.com"])
        #expect(PresenceRead.activeUsers(from: .array([.null, .string("")])) == nil)
    }
}
