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
    /// True when the channel or an ancestor is archived. A cyclic or
    /// over-deep ancestry also returns true: it cannot be resolved, so it
    /// must never authorize transmission. A channel whose ancestry is simply
    /// absent from the local cache returns false; the server remains
    /// authoritative for archive state, and failing closed on a cold cache
    /// would block sends to conversations the reader can still post in.
    public static func isArchived(channelID: String, channels: [RavenChannel], threadParents: [String: String]) -> Bool {
        var id = channelID, visited = Set<String>()
        while visited.insert(id).inserted, visited.count <= 8 {
            let channel = channels.first { $0.id == id }
            if channel?.raw["is_archived"].bool == true { return true }
            guard let parent = threadParents[id] ?? channel?.raw["parent_channel_id"].string else { return false }
            id = parent
        }
        // Loop exit means either a revisited id (a true cycle) or an
        // exhausted depth guard (over-deep ancestry). Neither is literally
        // archived, but both fail closed so neither can authorize
        // transmission.
        return true
    }
    /// The notification gate for a channel or thread, as a pure function of
    /// the cached rows. Revocation is checked on the channel itself and its
    /// whole ancestry. Threads are synthesized locally and never listed in
    /// `channels` (the server's channel list filters `is_thread`), so a
    /// thread is gated on its top-most ancestor's row — mute, archive and
    /// allow_notifications are intentionally inherited from the parent
    /// conversation, the only row that exists. An unknown ID never notifies.
    /// The top-most ancestor of `channelID` in the thread map, with a cycle
    /// guard: a walk that revisits a node stops at that node and reports the
    /// cycle via `cyclic == true`.
    public static func rootAncestor(of channelID: String, threadParents: [String: String]) -> (id: String, cyclic: Bool) {
        var id = channelID, visited = Set([channelID])
        while let parent = threadParents[id], !visited.contains(parent) {
            visited.insert(parent)
            id = parent
        }
        return (id, threadParents[id] != nil)
    }

    public static func shouldNotify(channelID: String, channels: [RavenChannel], revoked: Set<String>, threadParents: [String: String]) -> Bool {
        if revoked.contains(channelID) || isRevoked(channelID: channelID, revoked: revoked, threadParents: threadParents) { return false }
        let (gateID, cyclic) = rootAncestor(of: channelID, threadParents: threadParents)
        // A cycle in the ancestry map is corrupt state; fail closed rather
        // than gating on whichever node happened to close the loop.
        if cyclic { return false }
        guard let channel = channels.first(where: { $0.id == gateID }),
              !isArchived(channelID: gateID, channels: channels, threadParents: threadParents),
              !channel.raw["muted"].bool,
              channel.raw["allow_notifications"] == .null || channel.raw["allow_notifications"].bool else { return false }
        return true
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
