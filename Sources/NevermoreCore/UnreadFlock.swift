import Foundation
import RavenProtocol

/// Which conversations have a raven on their sidebar row, and what the
/// birds do when unread counts change. Counts come from the server, as
/// everywhere else; nothing here is reconstructed from cached messages.
public enum UnreadFlock {
    public enum Change: Equatable, Sendable {
        /// A read conversation became unread: a bird flies in.
        case arrived(String)
        /// An unread conversation got more: its bird hops.
        case grew(String)
        /// The conversation was read: its bird leaves.
        case left(String)
    }

    /// Unread counts of the conversations that get a bird. Muted and
    /// archived conversations keep their count but call for no attention,
    /// as with the Dock badge.
    public static func perching(channels: [RavenChannel], unread: JSONValue) -> [String: Int] {
        let allowed = Set(channels.filter { !$0.raw["muted"].bool && !$0.raw["is_archived"].bool }.map(\.id))
        var counts: [String: Int] = [:]
        for row in unread.array {
            guard let id = row["name"].string, allowed.contains(id),
                  case .number(let value) = row["unread_count"], value.isFinite, value >= 1 else { continue }
            counts[id] = max(counts[id, default: 0], Int(min(9999, value)))
        }
        return counts
    }

    /// Changes between two observations, ordered by conversation ID so
    /// simultaneous flights are staggered the same way every time.
    public static func changes(from old: [String: Int], to new: [String: Int]) -> [Change] {
        var result: [Change] = []
        for id in Set(old.keys).union(new.keys).sorted() {
            let before = old[id] ?? 0, after = new[id] ?? 0
            if before == 0, after > 0 { result.append(.arrived(id)) }
            else if before > 0, after == 0 { result.append(.left(id)) }
            else if after > before { result.append(.grew(id)) }
        }
        return result
    }

    /// True when the last unread conversation was just read.
    public static func cleared(from old: [String: Int], to new: [String: Int]) -> Bool {
        !old.isEmpty && new.isEmpty
    }
}
