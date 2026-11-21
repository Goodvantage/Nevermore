import RavenProtocol

/// One label/value row in the Channel Details sheet.
public struct ChannelDetailRow: Sendable, Equatable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

/// The current channel facts shown by Conversation Info ▸ Channel Details.
/// Everything comes from the `RavenChannel` snapshot the session already
/// holds, so building it performs no request. A channel whose access changed
/// yields no rows rather than a stale identity or description.
public enum ChannelDetails {
    public static func rows(for channel: RavenChannel, revoked: Set<String>, threadParents: [String: String], deleted: Set<String>) -> [ChannelDetailRow] {
        guard !channel.id.isEmpty, !ChannelPolicy.isRevoked(channelID: channel.id, revoked: deleted, threadParents: threadParents),
              !ChannelPolicy.isRevoked(channelID: channel.id, revoked: revoked, threadParents: threadParents) else { return [] }

        var rows = [ChannelDetailRow(label: "Name", value: channel.title)]
        rows.append(ChannelDetailRow(label: "Channel ID", value: channel.id))
        if let visibility = visibility(of: channel) {
            rows.append(ChannelDetailRow(label: "Type", value: visibility))
        }
        let workspace = channel.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        if !workspace.isEmpty {
            rows.append(ChannelDetailRow(label: "Workspace", value: workspace))
        }
        if let description = channel.raw["channel_description"].string,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(ChannelDetailRow(label: "Description", value: description))
        }
        return rows
    }

    /// DMs and threads are conversation kinds, not channel visibility values;
    /// a regular channel keeps its Open/Public/Private type. An absent or
    /// blank type is omitted instead of shown as an empty label.
    private static func visibility(of channel: RavenChannel) -> String? {
        if channel.raw["is_thread"].bool { return "Thread" }
        if channel.isDM { return "Direct message" }
        guard let type = channel.raw["type"].string?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty else { return nil }
        return type
    }
}
