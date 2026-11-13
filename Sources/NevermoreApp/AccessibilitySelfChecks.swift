import AppKit
import NevermoreCore
import RavenProtocol

/// Synthetic native checks, never VoiceOver certification. The fixture window
/// stays hidden and uses the existing demo account without server mutations.
@MainActor enum AccessibilitySelfChecks {
    @MainActor private final class CallbackProbe {
        var calls = 0
    }
    static func run(owner: ConversationWindow) async throws -> [(String, Bool)] {
        guard let session = owner.session, session.demo else { throw AppError.message("Accessibility checks require a demo account.") }
        let probe = CallbackProbe()
        let backgroundHandler = TranscriptAccessibility.mainThreadHandler { probe.calls += 1; return true }
        let backgroundResult = await Task.detached { backgroundHandler() }.value
        let fixture = ConversationWindow(app: owner.app, session: session)
        defer { fixture.close() }
        let channel = RavenChannel(raw: .object(["name": .string("accessibility-fixture"), "channel_name": .string("Accessibility fixture")]))
        fixture.channel = channel
        fixture.composer.isEditable = true
        let html = "<p>Visible <span data-spoiler=\"true\">HIDDEN-SPOILER</span> <a href=\"https://private.invalid/route?token=HIDDEN-TOKEN\">Safe link label</a></p><pre><code>HIDDEN-CODE</code></pre>"
        let first = RavenMessage(raw: .object(["name": .string("ax-first"), "channel_id": .string(channel.id), "owner": .string("Fixture author"), "creation": .string("2026-11-07 10:41:00.000000"), "text": .string(html), "message_type": .string("Text")]))
        let second = RavenMessage(raw: .object(["name": .string("ax-second"), "channel_id": .string(channel.id), "owner": .string("Second author"), "creation": .string("2026-11-07 10:42:00.000000"), "text": .string("<p>Second message</p>"), "message_type": .string("Text")]))
        let plain = "Fixture author\nVisible [Spoiler] Safe link label\n"
        let secondText = "Second author\nSecond message\n"
        fixture.transcript.string = plain + secondText
        let firstRange = NSRange(location: 0, length: (plain as NSString).length)
        let secondRange = NSRange(location: firstRange.length, length: (secondText as NSString).length)
        fixture.messageRanges = [(firstRange, first), (secondRange, second)]
        fixture.transcriptAccessibility.refresh()
        let helper = fixture.transcriptAccessibility
        func parameters(_ direction: NSAccessibilityCustomRotor.SearchDirection = .next, current: NSAccessibilityCustomRotor.ItemResult? = nil, filter: String = "") -> NSAccessibilityCustomRotor.SearchParameters {
            let value = NSAccessibilityCustomRotor.SearchParameters()
            value.searchDirection = direction; value.currentItem = current; value.filterString = filter
            return value
        }
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ result: Bool) { checks.append((label, result)) }
        check("off-main accessibility actions decline before entering MainActor or touching UI", !backgroundResult && probe.calls == 0)
        let firstResult = helper.result(for: parameters())
        let secondResult = helper.result(for: parameters(current: firstResult))
        let lastResult = helper.result(for: parameters(.previous))
        check("Messages rotor targets native text ranges in chronological order", firstResult?.targetElement as AnyObject? === fixture.transcript && firstResult?.targetRange == firstRange && secondResult?.targetRange == secondRange && lastResult?.targetRange == secondRange)
        check("Messages rotor stops at bounds and searches backwards", helper.result(for: parameters(current: secondResult)) == nil && helper.result(for: parameters(.previous, current: firstResult)) == nil && helper.result(for: parameters(.previous, current: secondResult))?.targetRange == firstRange)
        check("Messages rotor filters summaries without exposing spoilers, code or hidden routes", helper.result(for: parameters(filter: "second MESSAGE"))?.targetRange == secondRange && helper.result(for: parameters(filter: "HIDDEN-SPOILER")) == nil && helper.result(for: parameters(filter: "HIDDEN-TOKEN")) == nil && helper.result(for: parameters(filter: "HIDDEN-CODE")) == nil && firstResult?.customLabel?.contains("[Spoiler]") == true && firstResult?.customLabel?.contains("<p>") == false)
        let composerSelection = fixture.composer.selectedRange()
        fixture.transcript.setSelectedRange(firstRange)
        let moved = helper.move(forward: true)
        check("message navigation changes only transcript selection and honors bounds", moved && fixture.transcript.selectedRange() == secondRange && !helper.move(forward: true) && helper.move(forward: false) && fixture.transcript.selectedRange() == firstRange && fixture.composer.selectedRange() == composerSelection)
        fixture.transcript.setSelectedRange(NSRange(location: 3, length: firstRange.length + 5))
        check("message accessibility preserves continuous selectable native text", fixture.transcript.isSelectable && fixture.transcript.selectedRange().length == firstRange.length + 5 && fixture.transcript.string == plain + secondText)
        fixture.transcript.setSelectedRange(firstRange)
        let actions = helper.actions()
        check("selected messages expose guarded Reply and Copy Message Link actions", actions.contains { $0.name == "Reply" } && actions.contains { $0.name == "Copy Message Link" })
        fixture.composer.isEditable = false
        check("message Reply accessibility action respects write availability", !helper.actions().contains { $0.name == "Reply" })
        fixture.composer.isEditable = true
        fixture.transcript.setSelectedRange(secondRange)
        check("retained accessibility actions cannot target another selection", actions.allSatisfy { $0.handler?() == false })
        fixture.transcript.setSelectedRange(firstRange)
        helper.refresh()
        check("old rotor results and action handlers expire after rendering", helper.result(for: parameters(current: firstResult)) == nil && actions.allSatisfy { $0.handler?() == false })
        fixture.session = nil
        check("accessibility callbacks reject a stale account", helper.result(for: parameters()) == nil && helper.actions().isEmpty && !helper.canMove(forward: true))
        fixture.session = session
        session.revokedChannels.insert(channel.id)
        check("accessibility callbacks reject revoked projections immediately", helper.result(for: parameters()) == nil && helper.actions().isEmpty)
        session.revokedChannels.remove(channel.id)
        session.deletedIDs.insert(first.id)
        check("Messages rotor omits deleted messages before a render completes", helper.result(for: parameters())?.targetRange == secondRange)
        session.deletedIDs.remove(first.id)
        fixture.transcript.string = String(repeating: "x\n", count: 501)
        fixture.messageRanges = (0..<501).map { index in
            let message = RavenMessage(raw: .object(["name": .string("ax-bound-\(index)"), "channel_id": .string(channel.id), "owner": .string("Fixture author"), "text": .string("<p>Bounded message</p>")]))
            return (NSRange(location: index * 2, length: 2), message)
        }
        helper.refresh()
        var count = 0
        var current = helper.result(for: parameters())
        while let item = current, count < 502 {
            count += 1; current = helper.result(for: parameters(current: item))
        }
        check("Messages rotor bounds its projection to 500 existing text ranges", count == 500 && current == nil)
        let retained = helper.actions()
        fixture.close()
        check("closed transcripts clear rotor items and reject retained actions", helper.result(for: parameters()) == nil && retained.allSatisfy { $0.handler?() == false })
        return checks
    }
}
