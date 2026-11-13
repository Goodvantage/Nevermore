import RavenProtocol

/// UI affordances mirror the pinned Raven controller rules. The server remains
/// authoritative; these checks never substitute for a permission check there.
public enum ChannelPolicy {
    public static func isRevoked(channelID: String, revoked: Set<String>, threadParents: [String: String]) -> Bool {
        var id = channelID, visited = Set<String>()
        while visited.insert(id).inserted, visited.count <= 8 {
            if revoked.contains(id) { return true }
            guard let parent = threadParents[id] else { return false }
            id = parent
        }
        return true // invalid/cyclic ancestry never authorizes transmission
    }
    public static func isArchived(channelID: String, channels: [RavenChannel], threadParents: [String: String]) -> Bool {
        var id = channelID, visited = Set<String>()
        while visited.insert(id).inserted, visited.count <= 8 {
            let channel = channels.first { $0.id == id }
            if channel?.raw["is_archived"].bool == true { return true }
            guard let parent = threadParents[id] ?? channel?.raw["parent_channel_id"].string else { return false }
            id = parent
        }
        return false
    }
    public static func canManage(_ channel: RavenChannel, user: String, roles: Set<String>) -> Bool {
        guard !channel.isDM, !channel.raw["is_thread"].bool else { return false }
        return user == "Administrator" || channel.raw["is_admin"].bool ||
            (roles.contains("Raven Admin") && channel.raw["member_id"].string?.isEmpty == false)
    }

    public static func canMute(_ channel: RavenChannel) -> Bool {
        channel.raw["member_id"].string?.isEmpty == false && !channel.raw["is_thread"].bool
    }

    public static func canJoin(_ channel: RavenChannel) -> Bool {
        !channel.isDM && !channel.raw["is_thread"].bool && !channel.raw["is_archived"].bool &&
            channel.raw["member_id"].string?.isEmpty != false && ["Open", "Public"].contains(channel.raw["type"].string ?? "")
    }

    public static func isArchived(_ channel: RavenChannel, channels: [RavenChannel]) -> Bool {
        if channel.raw["is_archived"].bool { return true }
        guard let parent = channel.raw["parent_channel_id"].string else { return false }
        return channels.first { $0.id == parent }?.raw["is_archived"].bool == true
    }
}
