import Foundation

/// Only these generic messages can reach spoken status announcements. Account
/// names, conversation titles, message bodies and error payloads are not inputs.
public enum StatusAnnouncement: CaseIterable, Hashable, Sendable {
    case accountAttention, conversationAccessLost

    public var message: String {
        switch self {
        case .accountAttention:
            return StatusLocalization.text(.accountAttention)
        case .conversationAccessLost:
            return StatusLocalization.text(.conversationAccessLost)
        }
    }
}

public struct StatusAnnouncementPolicy: Sendable {
    private var context: UUID?
    private var previous: Set<StatusAnnouncement> = []

    public init() {}

    /// Observe suppressed transitions too: background activity or the end of
    /// marked-text composition must not replay an earlier announcement later.
    /// State is bounded to one opaque context token and the two typed statuses.
    public mutating func update(context: UUID?, attention: Set<StatusAnnouncement>, isForegroundKeyWindow: Bool, isComposing: Bool) -> [StatusAnnouncement] {
        guard let context else { reset(); return [] }
        if self.context != context { previous.removeAll(); self.context = context }
        let incoming = attention.subtracting(previous)
        previous = attention
        guard isForegroundKeyWindow, !isComposing else { return [] }
        return StatusAnnouncement.allCases.filter { incoming.contains($0) }
    }

    public mutating func reset() { context = nil; previous.removeAll() }
}
