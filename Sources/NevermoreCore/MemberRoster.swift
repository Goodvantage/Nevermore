import Foundation
import RavenProtocol

/// One member of a channel, as returned by the server's permission-scoped
/// membership list. The response is an object keyed by user ID; each value
/// carries `is_admin` and the `channel_member_name` membership document.
public struct MemberRosterEntry: Identifiable, Hashable, Sendable {
    public let userID: String
    public let displayName: String
    public let isAdmin: Bool
    /// The Raven Channel Member document name, distinct from `userID`.
    public let memberID: String?
    public var id: String { userID }

    public init(userID: String, displayName: String, isAdmin: Bool, memberID: String?) {
        self.userID = userID
        self.displayName = displayName
        self.isAdmin = isAdmin
        self.memberID = memberID
    }
}

/// The roster rules behind the native Members sheet: parse the pinned
/// `get_channel_members` response, sort it deterministically, filter it, and
/// keep its count. The server is the authority on who belongs to the channel.
public enum MemberRoster {
    /// Parses a response whose keys are user IDs. A non-object response is a
    /// contract change, not a shorter roster, so it yields no rows.
    public static func entries(from response: JSONValue, names: [String: String]) -> [MemberRosterEntry] {
        guard case .object(let object) = response else { return [] }
        return object.compactMap { key, value in
            guard !key.isEmpty else { return nil }
            return MemberRosterEntry(
                userID: key,
                displayName: names[key] ?? key,
                isAdmin: value["is_admin"].bool,
                memberID: value["channel_member_name"].string
            )
        }
        .sorted { left, right in
            let leftName = fold(left.displayName), rightName = fold(right.displayName)
            if leftName != rightName { return leftName < rightName }
            return left.userID < right.userID
        }
    }

    /// Case- and diacritic-insensitive search over the display name, user ID
    /// and membership document name. The input order is preserved.
    public static func filtered(_ entries: [MemberRosterEntry], query: String) -> [MemberRosterEntry] {
        SearchIndex(entries: entries).filtered(query: query)
    }

    /// A roster prepared for repeated filtering: each entry's folded
    /// haystack is computed once in `init`, not on every keystroke.
    /// Building the index folds every entry once (O(roster)); each
    /// `filtered(query:)` call then costs O(entries × words × haystack).
    public struct SearchIndex: Sendable {
        private let indexed: [(entry: MemberRosterEntry, haystack: String)]
        private let allEntries: [MemberRosterEntry]

        public init(entries: [MemberRosterEntry]) {
            self.indexed = entries.map { ($0, fold([$0.displayName, $0.userID, $0.memberID ?? ""].joined(separator: " "))) }
            self.allEntries = entries
        }

        public var all: [MemberRosterEntry] { allEntries }

        /// Case- and diacritic-insensitive search; an empty query returns the
        /// whole roster. The input order is preserved.
        public func filtered(query: String) -> [MemberRosterEntry] {
            let text = fold(query).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return all }
            let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
            return indexed.compactMap { entry, haystack in
                words.allSatisfy(haystack.contains) ? entry : nil
            }
        }
    }

    public static func countLabel(total: Int, shown: Int) -> String {
        if total == 0 { return "No members" }
        if shown == total { return total == 1 ? "1 member" : "\(total) members" }
        return "\(shown) of \(total) members"
    }

    /// The existing DM flow is for another user; messaging yourself is not a
    /// roster action, and an empty key is never a selectable identity.
    public static func canMessage(_ entry: MemberRosterEntry, accountUser: String) -> Bool {
        !entry.userID.isEmpty && entry.userID != accountUser
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
