import Foundation
import RavenProtocol

/// Reads `user_availability.get_active_users`, a JSON array of user IDs.
public enum PresenceRead {
    /// The active users, or nil when the reply is not an array, so a
    /// malformed success never clears every presence indicator. Null entries
    /// are skipped, not fatal: the server reads cache keys one by one, and a
    /// key expiring in between yields a null that must not freeze every
    /// presence dot for a whole refresh cycle. An empty string is not a null
    /// though: a user ID is never "", so it is malformed input and rejects the
    /// reply (nil means "leave presence untouched", an empty set would clear
    /// every indicator). A null means the per-user cache key expired, i.e.
    /// that user is inactive, so an all-null reply is a legitimate "nobody
    /// active" answer, same as an empty array.
    public static func activeUsers(from value: JSONValue) -> Set<String>? {
        guard case .array(let rows) = value else { return nil }
        var users = Set<String>()
        for row in rows {
            switch row {
            case .string(let user) where !user.isEmpty: users.insert(user)
            case .null: continue
            default: return nil
            }
        }
        return users
    }
}
