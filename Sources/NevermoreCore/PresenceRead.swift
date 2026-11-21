import Foundation
import RavenProtocol

/// Reads `user_availability.get_active_users`, a JSON array of user IDs.
public enum PresenceRead {
    /// The active users, or nil when the reply is not an array of strings,
    /// so a malformed success never clears every presence indicator.
    public static func activeUsers(from value: JSONValue) -> Set<String>? {
        guard case .array(let rows) = value else { return nil }
        var users = Set<String>()
        for row in rows {
            guard let user = row.string, !user.isEmpty else { return nil }
            users.insert(user)
        }
        return users
    }
}
