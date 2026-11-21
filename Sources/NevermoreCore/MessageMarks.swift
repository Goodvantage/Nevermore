import Foundation
import RavenProtocol

/// Whether a message is saved by the reader or pinned in its conversation,
/// read from the fields Raven already sends with every row: `_liked_by` on
/// `chat_stream.get_messages` rows, and `pinned_messages_string` on each
/// channel of `get_all_channels`.
public enum MessageMarks {
    /// A personal save is the user's ID inside `_liked_by`, a JSON array
    /// that Raven usually serializes into a string.
    public static func isSaved(_ message: RavenMessage, by user: String) -> Bool {
        guard !user.isEmpty else { return false }
        return message.raw["_liked_by"].nested.array.contains { $0.string == user }
    }

    /// Raven joins the pinned message IDs with newlines
    /// (`RavenChannel.set_pinned_messages_string`).
    public static func pinnedMessageIDs(in channel: RavenChannel) -> Set<String> {
        guard let text = channel.raw["pinned_messages_string"].string else { return [] }
        let ids = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        return Set(ids.filter { !$0.isEmpty })
    }
}
