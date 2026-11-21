import Testing
import RavenProtocol
@testable import NevermoreCore

@Suite struct ChannelDetailsTests {
    private func channel(_ fields: [String: JSONValue] = [:]) -> RavenChannel {
        RavenChannel(raw: .object(["name": .string("general"), "channel_name": .string("General"), "workspace": .string("Acme")].merging(fields) { _, new in new }))
    }

    @Test func identityVisibilityWorkspaceAndDescriptionComeFromTheSnapshot() {
        let rows = ChannelDetails.rows(for: channel(["type": .string("Private"), "channel_description": .string("Secret work\nSecond line")]), revoked: [], threadParents: [:], deleted: [])
        #expect(rows == [
            ChannelDetailRow(label: "Name", value: "General"),
            ChannelDetailRow(label: "Channel ID", value: "general"),
            ChannelDetailRow(label: "Type", value: "Private"),
            ChannelDetailRow(label: "Workspace", value: "Acme"),
            ChannelDetailRow(label: "Description", value: "Secret work\nSecond line")
        ])
    }

    @Test func directMessagesAndThreadsReplaceTheChannelVisibility() {
        let direct = channel(["name": .string("dm-morgan"), "channel_name": .string("Morgan"), "is_direct_message": .bool(true), "type": .string("Public")])
        #expect(ChannelDetails.rows(for: direct, revoked: [], threadParents: [:], deleted: []).first { $0.label == "Type" }?.value == "Direct message")
        let thread = channel(["name": .string("thread-root"), "is_thread": .bool(true), "parent_channel_id": .string("general"), "type": .string("Public")])
        #expect(ChannelDetails.rows(for: thread, revoked: [], threadParents: [:], deleted: []).first { $0.label == "Type" }?.value == "Thread")
    }

    @Test func missingFieldsAreOmittedWithoutEmptyLabels() {
        let rows = ChannelDetails.rows(for: channel(["type": .string(""), "workspace": .string("  "), "channel_description": .string("\n \n")]), revoked: [], threadParents: [:], deleted: [])
        #expect(rows.map(\.label) == ["Name", "Channel ID"])
        #expect(rows.allSatisfy { !$0.value.isEmpty })
    }

    @Test func revokedOrDeletedChannelsExposeNoStaleFields() {
        let ordinary = channel()
        #expect(ChannelDetails.rows(for: ordinary, revoked: ["general"], threadParents: [:], deleted: []).isEmpty)
        #expect(ChannelDetails.rows(for: ordinary, revoked: [], threadParents: [:], deleted: ["general"]).isEmpty)
        let thread = channel(["name": .string("thread-child"), "is_thread": .bool(true), "parent_channel_id": .string("general")])
        #expect(ChannelDetails.rows(for: thread, revoked: ["general"], threadParents: ["thread-child": "general"], deleted: []).isEmpty)
        #expect(ChannelDetails.rows(for: channel(["name": .string("")]), revoked: [], threadParents: [:], deleted: []).isEmpty)
    }
    @Test func aDeletedAncestorWithdrawsNestedThreadDetails() {
        let thread = channel(["name": .string("reply"), "is_thread": .bool(true)])
        let rows = ChannelDetails.rows(for: thread, revoked: [], threadParents: ["reply": "parent"], deleted: ["parent"])
        #expect(rows.isEmpty)
    }

}
