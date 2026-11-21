import Foundation
import RavenProtocol

/// Decisions for Conversation ▸ Schedule after its single create request.
///
/// `create_scheduled_message` has no idempotency key, so an ambiguous answer
/// must never be replayed: the user reviews Scheduled Messages first. The
/// policy stays UI-free; ConversationActions supplies window and draft state.
public enum ScheduledMessagePolicy {
    public enum Completion: Equatable, Sendable {
        /// The request may already have been applied. Review before retrying.
        case indeterminate
        /// The site authoritatively refused the request; nothing was created.
        case rejected
    }

    public enum Clearance: Equatable, Sendable {
        case clear
        /// Another window saved a newer shared draft revision.
        case newerRevision
        /// The shared draft content changed while the date was chosen.
        case changedDraft
        /// Another conversation or account is showing now.
        case differentContext
    }

    /// The site picker shows minutes, but its Date can retain seconds from
    /// the initial value. Only the minute the reader saw selects the slot.
    public static func slot(for selection: Date, in timeZone: TimeZone, now: Date = Date()) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let minute = calendar.dateInterval(of: .minute, for: selection)?.start else { return nil }
        let slotMinutes = 5
        let remainder = calendar.component(.minute, from: minute) % slotMinutes
        let advance = remainder == 0 ? 0 : slotMinutes - remainder
        guard let slot = calendar.date(byAdding: .minute, value: advance, to: minute), slot > now else { return nil }
        return slot
    }

    /// Classifies a failed create. Transport failures, timeouts, throttling
    /// and server-side errors can follow a committed insert; permission and
    /// validation refusals cannot.
    public static func completion(for error: Error) -> Completion {
        guard let raven = error as? RavenError else { return .indeterminate }
        return raven.definitivelyRefusedMutation ? .rejected : .indeterminate
    }

    public static func clearance(originatingConversationVisible: Bool, revisionUnchanged: Bool, draftUnchanged: Bool) -> Clearance {
        if !originatingConversationVisible { return .differentContext }
        if !revisionUnchanged { return .newerRevision }
        if !draftUnchanged { return .changedDraft }
        return .clear
    }
}
