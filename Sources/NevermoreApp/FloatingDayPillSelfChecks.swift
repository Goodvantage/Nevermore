import AppKit
import NevermoreCore
import RavenProtocol

/// Hidden-window checks of the floating day pill: it names the day being
/// read only while the reader scrolls history, gives way to a day divider
/// near the top, and fades once scrolling stops. Uses a disposable store
/// and the demo wire.
@MainActor enum FloatingDayPillSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreDayPillCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "day-pill-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        session.demoWire = DemoWire(session: session)
        let channel = RavenChannel(raw: .object(["name": .string("days"), "channel_name": .string("days")]))
        let other = RavenChannel(raw: .object(["name": .string("elsewhere"), "channel_name": .string("elsewhere")]))
        session.channels = [channel, other]
        let days = ["2026-11-03", "2026-11-04", "2026-11-05"]
        var rows: [RavenMessage] = []
        for (dayIndex, day) in days.enumerated() {
            for index in 0..<20 {
                let id = "d\(dayIndex)-\(index)"
                rows.append(RavenMessage(raw: .object(["name": .string(id), "channel_id": .string(channel.id), "owner": .string(index.isMultiple(of: 2) ? "a@example.invalid" : "b@example.invalid"),
                    "creation": .string(String(format: "%@ %02d:%02d:00.000000", day, 8 + index / 4, (index % 4) * 15)), "text": .string("<p>Message \(id) with enough words to wrap onto a second line in a normal window, so the day takes real height.</p>"), "message_type": .string("Text")])))
            }
        }
        try await session.store.cacheMessages(rows)
        let lingering = FloatingDayPill.lingering
        FloatingDayPill.lingering = .milliseconds(50)
        let controller = ConversationWindow(app: app, session: session)
        defer { FloatingDayPill.lingering = lingering; controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.select(channel)
        await controller.loadTask?.value; await controller.renderTask?.value
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        func scroll(toTopOf id: String, offset: CGFloat = 2) {
            guard let range = controller.messageRanges.first(where: { $0.1.id == id })?.0 else { return }
            let clip = controller.transcriptScroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: controller.rect(for: range).minY - offset - controller.transcriptScroll.contentInsets.top))
            controller.transcriptScroll.reflectScrolledClipView(clip)
        }
        func dayLabel(_ index: Int) -> String {
            guard let first = rows.first(where: { $0.id == "d\(index)-0" }), let date = session.messageDate(first.creation) else { return "?" }
            return session.dayLabel(for: date)
        }

        check("the pill is hidden when a conversation opens at the latest message", !controller.dayPill.isShown)
        scroll(toTopOf: "d1-10")
        check("scrolling placed by the app shows no pill", !controller.dayPill.isShown)
        controller.isTranscriptLiveScrolling = true
        controller.updateFloatingDayPill()
        check("scrolling by the reader names the day being read", controller.dayPill.isShown && controller.dayPill.day == dayLabel(1))
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        let pillFrame = controller.dayPill.convert(controller.dayPill.bounds, to: nil)
        let readableTop = controller.transcript.convert(NSPoint(x: 0, y: controller.readableTranscriptRect.minY), to: nil).y
        check("the pill sits just under the toolbar, inside the pane", controller.dayPill.isShown && pillFrame.height > 10 && abs(pillFrame.maxY - (readableTop - 8)) <= 2)
        check("the pill is centered on the transcript's own day pills", { () -> Bool in
            guard let found = controller.floatingDayLabel() else { return false }
            let expected = controller.transcript.convert(NSPoint(x: found.centerX, y: 0), to: nil).x
            return abs(pillFrame.midX - expected) <= 1
        }())
        check("a scrolled pill shows above the transcript, below the composer", { () -> Bool in
            guard let chat = controller.dayPill.superview, let pill = chat.subviews.firstIndex(of: controller.dayPill), let scroll = chat.subviews.firstIndex(of: controller.transcriptScroll) else { return false }
            return pill > scroll
        }())
        if let range = controller.messageRanges.first(where: { $0.1.id == "d2-0" })?.0 {
            let clip = controller.transcriptScroll.contentView
            let dividerTop = controller.rect(for: range).minY - 60
            clip.scroll(to: NSPoint(x: 0, y: dividerTop - controller.transcriptScroll.contentInsets.top))
            controller.transcriptScroll.reflectScrolledClipView(clip)
            controller.updateFloatingDayPill()
            check("a day divider reaching the top hides the pill so a day never shows twice", !controller.dayPill.isShown && controller.floatingDayLabel() == nil)
        } else { check("a day divider reaching the top hides the pill so a day never shows twice", false) }
        scroll(toTopOf: "d0-5")
        controller.updateFloatingDayPill()
        check("the pill follows the reader back to an earlier day", controller.dayPill.day == dayLabel(0))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: controller.transcriptScroll)
        try? await Task.sleep(for: .milliseconds(600))
        check("the pill fades once scrolling stops", !controller.dayPill.isShown)
        // Deliver a pixel-scroll with a trackpad momentum phase through the
        // real scroll view after the previous pill has faded.
        scroll(toTopOf: "d1-10")
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -24, wheel2: 0, wheel3: 0) {
            cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
            if let wheel = NSEvent(cgEvent: cg) { controller.transcriptScroll.scrollWheel(with: wheel) }
        }
        check("a momentum scroll shows the day again after fading", controller.dayPill.isShown && controller.dayPill.day == dayLabel(1))
        controller.isTranscriptLiveScrolling = true
        scroll(toTopOf: "d1-12")
        controller.updateFloatingDayPill()
        controller.select(other)
        check("opening another conversation removes the pill at once", !controller.dayPill.isShown)
        controller.isTranscriptLiveScrolling = false
        check("the pill is not an accessibility element and lets clicks through", !controller.dayPill.isAccessibilityElement() && controller.dayPill.hitTest(NSPoint(x: 5, y: 5)) == nil)
        return checks
    }
}
