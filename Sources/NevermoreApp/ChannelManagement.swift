import AppKit
import NevermoreCore
import RavenProtocol

extension ConversationWindow {
    var isArchivedConversation: Bool {
        guard let channel else { return false }
        if channel.raw["is_archived"].bool { return true }
        let channels = session?.channels ?? [], parents = session?.threadParents ?? [:]
        if let parent = channel.raw["parent_channel_id"].string, ChannelPolicy.isArchived(channelID: parent, channels: channels, threadParents: parents) { return true }
        return ChannelPolicy.isArchived(channelID: channel.id, channels: channels, threadParents: parents)
    }

    @objc func toggleArchivedChannels(_ sender: Any?) {
        showsArchivedChannels.toggle()
        refreshSidebar()
    }

    @objc func toggleChannelMute(_ sender: Any?) { if let channel { toggleMute(for: channel) } }

    /// Mutes or unmutes any conversation in this window's account, including
    /// one chosen from the sidebar's contextual menu.
    func toggleMute(for channel: RavenChannel) {
        guard let session, ChannelPolicy.canMute(channel),
              let memberID = channel.raw["member_id"].string else { return }
        let muted = !channel.raw["muted"].bool
        action {
            let member = try await session.client.resource("Raven Channel Member", name: memberID, values: nil)
            guard self.isCurrent(session) else { return }
            guard member["user_id"].string == session.account.user, member["channel_id"].string == channel.id else { throw AppError.message("Your channel membership changed. Refresh the account before changing its notification preference.") }
            if member["muted"].bool != muted {
                _ = try await session.mutateResource("Raven Channel Member", name: memberID, values: ["muted": .bool(muted)])
            }
            try await session.refresh()
        }
    }

    @objc func toggleChannelArchive(_ sender: Any?) {
        guard let session, let channel, ChannelPolicy.canManage(channel, user: session.account.user, roles: session.roles) else { return }
        let archived = !channel.raw["is_archived"].bool
        action {
            let message = archived ? "The conversation remains readable. Nevermore will pause new and queued sends until an administrator unarchives it. Your local drafts remain saved." : "Nevermore will allow new sends again. Paused queued sends require review and an explicit retry."
            guard await SheetPrompt.confirm("\(archived ? "Archive" : "Unarchive") \(channel.title)?", message: message, confirm: archived ? "Archive" : "Unarchive", on: self.window), self.isCurrent(session, channelID: channel.id) else { return }
            _ = try await session.mutateResource("Raven Channel", name: channel.id, values: ["is_archived": .bool(archived)])
            try await session.refresh()
        }
    }

    @objc func joinChannel(_ sender: Any?) {
        guard let session, let channel, ChannelPolicy.canJoin(channel) else { return }
        action {
            _ = try await session.mutate("raven.api.raven_channel_member.add_channel_members", ["channel_id": .string(channel.id), "members": .array([.string(session.account.user)])])
            try await session.refresh()
        }
    }

    @objc func addChannelMember(_ sender: Any?) {
        guard let session, let channel, ChannelPolicy.canManage(channel, user: session.account.user, roles: session.roles) else { return }
        action {
            let members = try await session.client.rpc("raven.api.raven_channel_member.get_channel_members", arguments: ["channel_id": .string(channel.id)])
            guard self.isCurrent(session, channelID: channel.id) else { return }
            let available = session.userNames.keys.filter { members[$0] == .null }.sorted { (session.userNames[$0] ?? $0).localizedCaseInsensitiveCompare(session.userNames[$1] ?? $1) == .orderedAscending }
            guard !available.isEmpty else { throw AppError.message("No additional Raven users are available to add.") }
            guard let window = self.window,
                  let users = try await ChoiceSheet.choose(title: "Add Channel Members", prompt: "Choose up to 50 people to add to \(channel.title). The server checks workspace access and your permissions.", choices: available.map { ChoiceSheet.Choice(id: $0, title: session.userNames[$0] ?? $0, detail: $0) }, maximum: 50, on: window), self.isCurrent(session, channelID: channel.id) else { return }
            _ = try await session.mutate("raven.api.raven_channel_member.add_channel_members", ["channel_id": .string(channel.id), "members": .array(users.map(JSONValue.string))])
            try await session.refresh()
        }
    }

    @objc func removeChannelMember(_ sender: Any?) {
        guard let session, let channel, ChannelPolicy.canManage(channel, user: session.account.user, roles: session.roles), channel.raw["type"].string != "Open" else { return }
        action {
            let members = try await session.client.rpc("raven.api.raven_channel_member.get_channel_members", arguments: ["channel_id": .string(channel.id)])
            guard self.isCurrent(session, channelID: channel.id) else { return }
            let users = members.object.keys.filter { $0 != session.account.user }.sorted()
            guard let index = await self.choose("Remove Channel Member", items: users.map { "\(session.userNames[$0] ?? $0) · \($0)" }, confirm: "Continue") else { return }
            let user = users[index]
            guard await SheetPrompt.confirm("Remove \(session.userNames[user] ?? user) from \(channel.title)?", message: "This changes access to the conversation on the server.", confirm: "Remove Member", destructive: true, on: self.window), self.isCurrent(session, channelID: channel.id) else { return }
            _ = try await session.mutate("raven.api.raven_channel_member.remove_channel_member", ["user_id": .string(user), "channel_id": .string(channel.id)])
            try await session.refresh()
        }
    }
}
