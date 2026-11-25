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
        // A cyclic ancestry is unreadable, so it must fail closed like
        // revocation instead of treating the conversation as sendable.
        #expect(ChannelPolicy.isArchived(channelID: "thread", channels: [channel()], threadParents: ["thread": "parent", "parent": "thread"]))
        #expect(ChannelPolicy.isArchived(channelID: "thread", channels: [], threadParents: ["thread": "thread"]))
        // Over-deep but acyclic ancestry trips the depth guard and also
        // fails closed.
        #expect(ChannelPolicy.isArchived(channelID: "n1", channels: [], threadParents: [
            "n1": "n2", "n2": "n3", "n3": "n4", "n4": "n5",
            "n5": "n6", "n6": "n7", "n7": "n8", "n8": "n9",
        ]))
    }
    @Test func revokedOrCyclicThreadAncestorsNeverAuthorizeTransmission() {
        #expect(ChannelPolicy.isRevoked(channelID: "thread", revoked: ["parent"], threadParents: ["thread": "parent"]))
        #expect(!ChannelPolicy.isRevoked(channelID: "thread", revoked: ["unrelated"], threadParents: ["thread": "parent"]))
        #expect(ChannelPolicy.isRevoked(channelID: "thread", revoked: [], threadParents: ["thread": "parent", "parent": "thread"]))
    }
    @Test func distantRevocationAndChannelSelfParentFailClosed() {
        let parents = Dictionary(uniqueKeysWithValues: (0..<20).map { ("n\($0)", "n\($0 + 1)") })
        #expect(ChannelPolicy.isRevoked(channelID: "n0", revoked: ["n20"], threadParents: parents))
        #expect(ChannelPolicy.isRevoked(channelID: "n0", revoked: [], threadParents: parents))
        let selfParent = channel(["parent_channel_id": .string("c")])
        #expect(ChannelPolicy.isArchived(channelID: "c", channels: [selfParent], threadParents: [:]))
    }

    @Test func notificationGateCoversRevocationAncestryAndThreadRows() {
        let open = channel()
        // A plain channel notifies; revoking the channel itself suppresses it.
        #expect(ChannelPolicy.shouldNotify(channelID: "c", channels: [open], revoked: [], threadParents: [:]))
        #expect(!ChannelPolicy.shouldNotify(channelID: "c", channels: [open], revoked: ["c"], threadParents: [:]))
        // Muted, archived or notifications-off rows suppress.
        #expect(!ChannelPolicy.shouldNotify(channelID: "c", channels: [channel(["muted": .bool(true)])], revoked: [], threadParents: [:]))
        #expect(!ChannelPolicy.shouldNotify(channelID: "c", channels: [channel(["is_archived": .bool(true)])], revoked: [], threadParents: [:]))
        #expect(!ChannelPolicy.shouldNotify(channelID: "c", channels: [channel(["allow_notifications": .bool(false)])], revoked: [], threadParents: [:]))
        #expect(ChannelPolicy.shouldNotify(channelID: "c", channels: [channel(["allow_notifications": .bool(true)])], revoked: [], threadParents: [:]))
        // An unknown ID never notifies.
        #expect(!ChannelPolicy.shouldNotify(channelID: "ghost", channels: [open], revoked: [], threadParents: [:]))
        // A thread is gated on its parent's row: parent muted/revoked/
        // archived suppresses, an open parent allows.
        let threads = ["thread": "c"]
        #expect(ChannelPolicy.shouldNotify(channelID: "thread", channels: [open], revoked: [], threadParents: threads))
        #expect(!ChannelPolicy.shouldNotify(channelID: "thread", channels: [channel(["muted": .bool(true)])], revoked: [], threadParents: threads))
        #expect(!ChannelPolicy.shouldNotify(channelID: "thread", channels: [open], revoked: ["c"], threadParents: threads))
        #expect(!ChannelPolicy.shouldNotify(channelID: "thread", channels: [channel(["is_archived": .bool(true)])], revoked: [], threadParents: threads))
        #expect(!ChannelPolicy.shouldNotify(channelID: "thread", channels: [channel(["allow_notifications": .bool(false)])], revoked: [], threadParents: threads))
        // Nested threads walk to the top-most ancestor; a cycle stops there
        // and fails closed (the root is not in `channels`).
        let nested = ["t2": "t1", "t1": "c"]
        #expect(ChannelPolicy.shouldNotify(channelID: "t2", channels: [open], revoked: [], threadParents: nested))
        #expect(!ChannelPolicy.shouldNotify(channelID: "t2", channels: [open], revoked: ["c"], threadParents: nested))
        // A revoked intermediate ancestor must also suppress the thread.
        #expect(!ChannelPolicy.shouldNotify(channelID: "t2", channels: [open], revoked: ["t1"], threadParents: nested))
        #expect(!ChannelPolicy.shouldNotify(channelID: "t2", channels: [], revoked: [], threadParents: ["t2": "t1", "t1": "t2"]))
        // A cycle fails closed even when a row for a cycle node exists.
        #expect(!ChannelPolicy.shouldNotify(channelID: "t2", channels: [open], revoked: [], threadParents: ["t2": "c", "c": "t2"]))
        // An immediate self-parent is the other corrupt shape; it fails closed too.
        #expect(!ChannelPolicy.shouldNotify(channelID: "c", channels: [open], revoked: [], threadParents: ["c": "c"]))
        // A thread whose parent row is missing never notifies.
        #expect(!ChannelPolicy.shouldNotify(channelID: "thread", channels: [], revoked: [], threadParents: threads))
    }
}
