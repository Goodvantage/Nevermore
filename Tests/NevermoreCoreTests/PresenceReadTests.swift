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
        #expect(PresenceRead.activeUsers(from: .array([.string("")])) == nil)
    }
}
