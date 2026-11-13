import AppKit
import NevermoreCore

@MainActor enum StatusAnnouncementSelfChecks {
    private final class Capture { var messages: [String] = [] }

    static func run(owner: ConversationWindow) async throws -> [(String, Bool)] {
        guard let session = owner.session, session.demo, !session.stopped, let channel = owner.channel, let window = owner.window else {
            throw AppError.message("Status announcement checks require the isolated demo account.")
        }
        let previousState = session.state, previousAttention = session.statusAttention
        let previousRevoked = session.revokedChannels
        let previousResponder = window.firstResponder
        var results: [(String, Bool)] = []
        var spoken: [String] = []
        let privateError = "Private fixture body user@example.invalid https://private.invalid/path?token=secret"
        defer {
            owner.clearStatusAnnouncementPostForSelfChecks()
            session.stopped = false
            session.state = previousState; session.revokedChannels = previousRevoked
            session.setStatusAttention(previousAttention)
            if owner.session !== session { owner.use(session); owner.select(channel) }
            window.makeFirstResponder(previousResponder)
        }
        func focus(_ target: NSWindow) async throws -> Bool {
            target.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            for _ in 0..<100 {
                if NSApp.isActive && NSApp.keyWindow === target && target.isKeyWindow { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        guard try await focus(window) else { throw AppError.message("The status fixture could not focus its demo window.") }
        session.setStatusAttention(nil)
        results.append(("status post injection is limited to a current demo account", owner.installStatusAnnouncementPostForSelfChecks { spoken.append($0) }))
        session.fail(AppError.message(privateError))
        session.notify(); owner.updateContext()
        results.append(("account failure speaks generic actionable copy once", spoken == [StatusAnnouncement.accountAttention.message] && !spoken.joined().contains("secret") && !spoken.joined().contains("example.invalid")))

        let other = ConversationWindow(app: owner.app, session: session)
        other.channel = channel
        var otherSpoken: [String] = []
        _ = other.installStatusAnnouncementPostForSelfChecks { otherSpoken.append($0) }
        defer { other.close() }
        guard let otherWindow = other.window, try await focus(otherWindow) else { throw AppError.message("The status fixture could not focus its second demo window.") }
        session.setStatusAttention(nil)
        let beforeBackground = spoken.count
        session.fail(AppError.message(privateError))
        results.append(("only the key window for the account posts a status announcement", spoken.count == beforeBackground && otherSpoken == [StatusAnnouncement.accountAttention.message]))
        guard try await focus(window) else { throw AppError.message("The status fixture could not restore its demo window.") }
        owner.updateContext(); session.notify()
        results.append(("background status is not replayed by later message or presence refreshes", spoken.count == beforeBackground))
        other.close()

        session.setStatusAttention(nil)
        let input = NSTextView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        window.contentView?.addSubview(input); window.makeFirstResponder(input)
        defer { input.unmarkText(); input.removeFromSuperview() }
        input.setMarkedText("入力", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let beforeComposition = spoken.count
        session.fail(AppError.message(privateError))
        input.unmarkText(); owner.updateContext(); session.notify()
        results.append(("marked text suppresses announcements without a delayed replay", spoken.count == beforeComposition))
        input.removeFromSuperview(); window.makeFirstResponder(owner.composer)

        session.setStatusAttention(nil)
        session.revokedChannels.insert(channel.id); session.notify()
        let afterRevocation = spoken.count
        session.notify(); owner.updateContext()
        results.append(("access loss announces once without private conversation metadata", afterRevocation == beforeComposition + 1 && spoken.last == StatusAnnouncement.conversationAccessLost.message && spoken.count == afterRevocation))
        session.revokedChannels = previousRevoked; session.setStatusAttention(nil); owner.updateContext()

        var capture: Capture? = Capture()
        weak var released = capture
        do {
            let retained = capture!
            _ = owner.installStatusAnnouncementPostForSelfChecks { retained.messages.append($0) }
        }
        capture = nil
        owner.use(nil)
        session.fail(AppError.message(privateError))
        results.append(("account switching releases announcement capture and rejects old-account callbacks", released == nil && !owner.installStatusAnnouncementPostForSelfChecks { _ in }))
        owner.use(session); owner.select(channel)
        await owner.loadTask?.value; await owner.renderTask?.value

        var stoppedCapture: Capture? = Capture()
        weak var releasedOnStop = stoppedCapture
        do {
            let retained = stoppedCapture!
            _ = owner.installStatusAnnouncementPostForSelfChecks { retained.messages.append($0) }
        }
        stoppedCapture = nil
        // Exercise the stop notification's routing state without destructively
        // stopping the shared demo session used by subsequent native checks.
        session.stopped = true; session.setStatusAttention(nil)
        session.fail(AppError.message(privateError))
        results.append(("a stopped account clears announcement state and ignores late failures", releasedOnStop == nil && session.statusAttention == nil))
        session.stopped = false

        let closing = ConversationWindow(app: owner.app, session: session)
        closing.channel = channel
        var closingCapture: Capture? = Capture()
        weak var releasedOnClose = closingCapture
        do {
            let retained = closingCapture!
            _ = closing.installStatusAnnouncementPostForSelfChecks { retained.messages.append($0) }
        }
        closingCapture = nil
        closing.close(); closing.updateStatusAnnouncements()
        results.append(("closing a conversation releases announcement callbacks and context", closing.isClosed && releasedOnClose == nil))
        return results
    }
}
