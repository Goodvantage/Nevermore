import Testing
import RavenProtocol
@testable import NevermoreCore

@Suite struct ChannelPolicyTests {
    private func channel(_ fields: [String: JSONValue] = [:]) -> RavenChannel {
        RavenChannel(raw: .object(["name": .string("c"), "type": .string("Public")].merging(fields) { _, new in new }))
    }

    @Test func administrationRequiresTheCorrectMembership() {
        #expect(!ChannelPolicy.canManage(channel(["owner": .string("me")]), user: "me", roles: []))
        #expect(!ChannelPolicy.canManage(channel(), user: "me", roles: ["Raven Admin"]))
        #expect(ChannelPolicy.canManage(channel(["member_id": .string("member")]), user: "me", roles: ["Raven Admin"]))
        #expect(ChannelPolicy.canManage(channel(["is_admin": .bool(true)]), user: "me", roles: []))
        #expect(ChannelPolicy.canManage(channel(), user: "Administrator", roles: []))
        #expect(!ChannelPolicy.canManage(channel(["is_direct_message": .bool(true)]), user: "Administrator", roles: []))
        #expect(!ChannelPolicy.canManage(channel(["is_thread": .bool(true)]), user: "Administrator", roles: []))
    }

    @Test func muteRequiresAnExplicitMembershipAndJoiningDoesNot() {
        #expect(!ChannelPolicy.canMute(channel()))
        #expect(ChannelPolicy.canMute(channel(["member_id": .string("member")])))
        #expect(ChannelPolicy.canJoin(channel()))
        #expect(!ChannelPolicy.canJoin(channel(["member_id": .string("member")])))
        #expect(!ChannelPolicy.canJoin(channel(["type": .string("Private")])))
        #expect(!ChannelPolicy.canJoin(channel(["is_archived": .bool(true)])))
    }

    @Test func archivedParentsAlsoProtectThreadSends() {
        let parent = channel(["is_archived": .bool(true)])
        let thread = RavenChannel(raw: .object(["name": .string("t"), "parent_channel_id": .string("c")]))
        #expect(ChannelPolicy.isArchived(parent, channels: []))
        #expect(ChannelPolicy.isArchived(thread, channels: [parent]))
        #expect(!ChannelPolicy.isArchived(thread, channels: [channel()]))
        #expect(!ChannelPolicy.isArchived(channel(), channels: [parent]))
        #expect(ChannelPolicy.isArchived(channelID: "thread", channels: [parent], threadParents: ["thread": "c"]))
        #expect(ChannelPolicy.isArchived(channelID: "nested", channels: [parent], threadParents: ["nested": "thread", "thread": "c"]))
        #expect(!ChannelPolicy.isArchived(channelID: "thread", channels: [channel()], threadParents: ["thread": "c"]))
    }
    @Test func revokedOrCyclicThreadAncestorsNeverAuthorizeTransmission() {
        #expect(ChannelPolicy.isRevoked(channelID: "thread", revoked: ["parent"], threadParents: ["thread": "parent"]))
        #expect(!ChannelPolicy.isRevoked(channelID: "thread", revoked: ["unrelated"], threadParents: ["thread": "parent"]))
        #expect(ChannelPolicy.isRevoked(channelID: "thread", revoked: [], threadParents: ["thread": "parent", "parent": "thread"]))
    }
}
