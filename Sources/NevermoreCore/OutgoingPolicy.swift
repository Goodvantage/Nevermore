import Foundation
import RavenProtocol

/// The org working-hours window is separate from this Mac's notification window.
public enum OutgoingPolicy {
    public enum Decision: Equatable, Sendable { case normal, ask, silent }
    public static func decision(now: Date, workingHours: RavenQuietHoursConfig?, timezone: String, preference: RavenQuietHoursNudge) -> Decision {
        guard preference != .noNudge, let workingHours,
              let start = workingHours.startMinute, let end = workingHours.endMinute,
              start != end, TimeZone(identifier: timezone) != nil else { return .normal }
        let inside = QuietHours(startMinute: start, endMinute: end, timezone: timezone, enabled: true).contains(now)
        guard !inside else { return .normal }
        return preference == .autoSilent ? .silent : .ask
    }
}
