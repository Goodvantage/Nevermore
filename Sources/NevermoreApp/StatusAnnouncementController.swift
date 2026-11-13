import AppKit
import NevermoreCore

@MainActor final class StatusAnnouncementController {
    private var context = UUID()
    private var policy = StatusAnnouncementPolicy()
    private var fixturePost: ((String) -> Void)?

    func resetContext() { context = UUID(); policy.reset() }
    func invalidate() { resetContext(); fixturePost = nil }

    func installFixturePost(_ post: @escaping (String) -> Void, session: AccountSession) -> Bool {
        guard session.demo, !session.stopped else { return false }
        resetContext(); fixturePost = post
        return true
    }

    func update(attention: Set<StatusAnnouncement>, isForegroundKeyWindow: Bool, isComposing: Bool, window: NSWindow, demo: Bool) {
        for announcement in policy.update(context: context, attention: attention, isForegroundKeyWindow: isForegroundKeyWindow, isComposing: isComposing) {
            // Only a demo fixture may redirect speech. Other demo windows in
            // a self-check run stay silent even while fixtures switch context.
            if demo {
                if let fixturePost { fixturePost(announcement.message); continue }
                if CommandLine.arguments.contains("--self-check") { continue }
            }
            let priority: NSAccessibilityPriorityLevel = announcement == .conversationAccessLost ? .high : .medium
            NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [
                .announcement: announcement.message,
                .priority: priority.rawValue
            ])
        }
    }
}
