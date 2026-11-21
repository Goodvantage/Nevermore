import Foundation
import RavenProtocol

/// The client side of completing a fired, unread reminder.
///
/// `get_reminders` returns `notified` and `is_read` per reminder.
/// `mark_reminder_read(message_id)` is a POST that marks every reminder of
/// the current user on that message with `notified == 1` and `is_read == 0`
/// read, then returns no state. The server filters by user itself, so the
/// client only needs the message; a row without both flags cannot be
/// identified as fired and unread and is never offered for completion.
public enum ReminderCompletion {
    /// The pinned server route; see docs/RAVEN-RESEARCH.md.
    public static let markReadMethod = "raven.api.reminders.mark_reminder_read"

    /// The server's fired-unread predicate. Missing or out-of-range flags
    /// mean an unidentified row, not a completed one.
    public static func isFiredUnread(_ reminder: JSONValue) -> Bool {
        guard let notified = flag(reminder["notified"]), let isRead = flag(reminder["is_read"]) else { return false }
        return notified && !isRead
    }

    /// The message `mark_reminder_read` keys on, validated as untrusted
    /// server data. The reminder name is never sent.
    public static func messageID(_ reminder: JSONValue) -> String? {
        guard let id = reminder["message"].string,
              !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              id.utf8.count <= 1024,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return id
    }

    /// True only when a completion can be offered and sent.
    public static func canComplete(_ reminder: JSONValue) -> Bool {
        isFiredUnread(reminder) && messageID(reminder) != nil
    }

    /// Frappe stores these flags as 0/1; accept the boolean and string forms
    /// a JSON API may produce, but treat anything else as unidentified.
    private static func flag(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let value): return value
        case .number(let value): if value == 1 { return true }; if value == 0 { return false }; return nil
        case .string(let value):
            if value == "1" || value == "true" { return true }
            if value == "0" || value == "false" { return false }
            return nil
        default: return nil
        }
    }
}
