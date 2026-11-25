import Foundation
import RavenProtocol

/// A per-account quiet-hours window stored locally on this Mac.
///
/// `startMinute` and `endMinute` are wall-clock minutes in `timezone`. A
/// window whose start is greater than its end crosses midnight (for example
/// 22:00–06:00). A window whose start equals its end is degenerate and never
/// suppresses notifications. `enabled == false` disables the window entirely.
public struct QuietHours: Codable, Sendable, Equatable {
    public var startMinute: Int
    public var endMinute: Int
    public var timezone: String
    public var enabled: Bool

    public init(startMinute: Int, endMinute: Int, timezone: String, enabled: Bool) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.timezone = timezone
        self.enabled = enabled
    }

    /// True when `date` falls inside the window.
    ///
    /// The instant is converted to wall-clock components in `timezone`, so
    /// DST transitions, midnight, and week boundaries are handled by
    /// Foundation's calendar math rather than by arithmetic on the device
    /// clock. A disabled, degenerate, out-of-range, or unresolvable-timezone
    /// window is never quiet; failing open avoids suppressing notifications
    /// when the site timezone cannot be honored.
    public func contains(_ date: Date) -> Bool {
        guard enabled,
              (0..<1440).contains(startMinute),
              (0..<1440).contains(endMinute),
              startMinute != endMinute,
              let zone = TimeZone(identifier: timezone) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let components = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = components.hour, let minute = components.minute else { return false }
        let minuteOfDay = hour * 60 + minute
        if startMinute < endMinute {
            return minuteOfDay >= startMinute && minuteOfDay < endMinute
        }
        return minuteOfDay >= startMinute || minuteOfDay < endMinute
    }
}

public enum NotificationPolicy {
    /// Pure running-app notification gate.
    ///
    /// Notifications are opt-in (`enabled`), never delivered for a muted
    /// account/channel, and never delivered while the app is foregrounded
    /// (the existing running-app behavior). A non-nil quiet-hours window
    /// suppresses delivery while `quietHours.contains(now)` is true; a nil
    /// window or a disabled/degenerate window does not.
    public static func shouldNotify(now: Date, quietHours: QuietHours?, isForeground: Bool, enabled: Bool, muted: Bool) -> Bool {
        guard enabled, !muted, !isForeground else { return false }
        if let quietHours, quietHours.contains(now) { return false }
        return true
    }

    /// The newest message not authored by `user`, regardless of the page's
    /// row order. The newest rows can all be the reader's own (sent from
    /// another device after an incoming one); the page must still yield the
    /// incoming one instead of dropping its notification.
    public static func newestForeign(_ messages: [RavenMessage], user: String) -> RavenMessage? {
        messages.filter { $0.owner != user }.max(by: { $0.creation < $1.creation })
    }

    /// The message a notification run should surface: the newest foreign row
    /// that was not already delivered and is newer than the reader's
    /// high-water mark. Filtering happens before picking, so one delivered or
    /// already-seen row can never mask an older un-notified one.
    ///
    /// `seen` is the channel's last-seen server timestamp; both it and
    /// `creation` are server-generated in the same format, so the textual
    /// comparison is chronological. A nil `seen` means nothing recorded yet.
    public static func nextNotification(in page: [RavenMessage], user: String, seen: String?, notified: (String) -> Bool) -> RavenMessage? {
        let pending = page.filter { message in
            !notified(message.batchID ?? message.id) && (seen.map { message.creation > $0 } ?? true)
        }
        return newestForeign(pending, user: user)
    }
}
