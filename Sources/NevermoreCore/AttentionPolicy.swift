import Foundation
import RavenProtocol

public enum DockBadgeMode: String, Codable, Sendable, CaseIterable {
    case attention, allUnread, none
}

public enum AttentionPolicy {
    /// The server counts logical sends, including grouped attachments. Never
    /// reconstruct this count from cached message rows.
    public static func unreadCount(channels: [RavenChannel], unread: JSONValue, directMessagesOnly: Bool = false) -> Int {
        let allowed = Set(channels.filter {
            !$0.raw["muted"].bool && !$0.raw["is_archived"].bool && (!directMessagesOnly || $0.isDM)
        }.map(\.id))
        var counts: [String: Int] = [:]
        for row in unread.array {
            guard let id = row["name"].string, allowed.contains(id),
                  case .number(let value) = row["unread_count"], value.isFinite, value > 0 else { continue }
            counts[id] = max(counts[id, default: 0], Int(min(9999, value)))
        }
        return counts.values.reduce(0) { min(9999, $0 + $1) }
    }

    public static func badge(mode: DockBadgeMode, unreadCount: Int, hasAttention: Bool) -> String? {
        switch mode {
        case .none: return nil
        case .attention: return hasAttention ? "•" : nil
        case .allUnread: return unreadCount > 0 ? (unreadCount >= 9999 ? "9999+" : String(unreadCount)) : nil
        }
    }
}
