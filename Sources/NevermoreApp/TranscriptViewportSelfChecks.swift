import AppKit
import NevermoreCore
import RavenProtocol

/// Hidden-window checks that a transcript keeps its bottom edge when its
/// viewport changes shape: window resizes, the sidebar, the composer and
/// the thread inspector. Positions are measured from the text layout, not
/// read back from the code under test. Disposable demo store; nothing
/// reaches a server.
@MainActor enum TranscriptViewportSelfChecks {
    /// The line at the bottom of a readable band, and how far its bottom
    /// edge sits above the band's.
    private struct BottomLine { let character: Int; let gap: CGFloat }

    private static func lineRect(containing character: Int, in text: NSTextView) -> NSRect? {
        guard let layout = text.layoutManager, layout.numberOfGlyphs > 0 else { return nil }
        let glyph = min(layout.glyphIndexForCharacter(at: character), layout.numberOfGlyphs - 1)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(dx: 0, dy: text.textContainerOrigin.y)
    }

    private static func bottomLine(of text: NSTextView, readableMaxY: CGFloat) -> BottomLine? {
        guard let layout = text.layoutManager, let container = text.textContainer, layout.numberOfGlyphs > 0 else { return nil }
        let glyph = layout.glyphIndex(for: NSPoint(x: 1, y: readableMaxY - text.textContainerOrigin.y - 1), in: container)
        var glyphs = NSRange()
        _ = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
        let character = layout.characterIndexForGlyph(at: glyphs.location)
        return lineRect(containing: character, in: text).map { BottomLine(character: character, gap: readableMaxY - $0.maxY) }
    }

    /// Whether the line holding `line.character` still ends `line.gap`
    /// points above the readable band's bottom edge.
    private static func holds(_ line: BottomLine?, in text: NSTextView, readableMaxY: CGFloat) -> Bool {
        guard let line, let rect = lineRect(containing: line.character, in: text) else { return false }
        return abs(readableMaxY - rect.maxY - line.gap) < 1
    }

    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreViewportCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "viewport-fixture@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        let channel = RavenChannel(raw: .object(["name": .string("viewport-fixture"), "channel_name": .string("Viewport fixture")]))
        let other = RavenChannel(raw: .object(["name": .string("viewport-other"), "channel_name": .string("Viewport other")]))
        let short = RavenChannel(raw: .object(["name": .string("viewport-short"), "channel_name": .string("Viewport short")]))
        session.channels = [channel, other, short]
        let tallIndex = 120, threadRootIndex = 200, count = 240
        func row(_ index: Int, channelID: String, prefix: String) -> RavenMessage {
            // Varied lengths, so a width change moves every message by a
            // different amount. One message is taller than the window.
            let sentences = index == tallIndex && prefix == "viewport" ? 260 : 1 + (index * 7) % 11
            let body = (0..<sentences).map { "Sentence \($0) of fixture message \(index) wraps differently at each width." }.joined(separator: " ")
            return RavenMessage(raw: .object(["name": .string("\(prefix)-\(index)"), "channel_id": .string(channelID), "owner": .string(index % 3 == 0 ? "other-fixture@example.invalid" : "third-fixture@example.invalid"), "creation": .string(String(format: "2026-11-08 12:%02d:%02d.000000", index / 60, index % 60)), "text": .string("<p>\(body)</p>"), "message_type": .string("Text")]))
        }
        try await session.store.cacheMessages((0..<count).map { row($0, channelID: channel.id, prefix: "viewport") })
        let threadRootID = "viewport-\(threadRootIndex)"
        try await session.store.cacheMessages((0..<60).map { row($0, channelID: threadRootID, prefix: "viewport-reply") })
        try await session.store.cacheMessages((0..<80).map { row($0, channelID: other.id, prefix: "viewport-other") })
        try await session.store.cacheMessages((0..<8).map { row($0 * 3 + 2, channelID: short.id, prefix: "viewport-short") })
        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory) }
        guard let window = controller.window else { return [("viewport fixture has a window", false)] }
        let home = NSRect(x: 0, y: 0, width: 1080, height: 760)
        func settle() { window.contentView?.layoutSubtreeIfNeeded() }
        func resize(width: CGFloat? = nil, height: CGFloat? = nil) {
            var frame = window.frame
            if let width { frame.size.width = width }
            if let height { frame.size.height = height }
            window.setFrame(frame, display: true); settle()
        }
        window.setFrame(home, display: false); settle()
        controller.select(channel)
        session.recordTranscriptVisit(.timestamp("2026-11-08 13:00:00"), channelID: channel.id)
        await controller.loadTask?.value; await controller.renderTask?.value
        settle()

        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        let transcript = controller.transcript, clip = controller.transcriptScroll.contentView
        var readableMaxY: CGFloat { controller.readableTranscriptRect.maxY }
        func scroll(to y: CGFloat) {
            clip.scroll(to: NSPoint(x: 0, y: y)); controller.transcriptScroll.reflectScrolledClipView(clip)
            controller.seenVisible()
        }
        /// The newest message ends inside the band above the composer.
        func showsNewest() -> Bool {
            guard let last = controller.messageRanges.last else { return false }
            return controller.rect(for: last.0).maxY <= readableMaxY + 1 && controller.isFollowing
        }
        check("the viewport fixture opens on its newest message", controller.messageRanges.count == count && showsNewest() && transcript.bounds.height > clip.bounds.height * 3)

        resize(height: 520)
        check("a shorter window keeps the newest message above the composer", showsNewest())
        resize(width: 700)
        check("a narrower window keeps a followed transcript on its newest message", showsNewest())
        resize(width: home.width, height: home.height)
        check("a wider, taller window keeps a followed transcript on its newest message", showsNewest())

        // Reading earlier messages: the line at the bottom of the readable
        // band is the newest text in view, and has to stay put.
        guard let earlier = controller.messageRanges.first(where: { $0.1.id == "viewport-60" })?.0 else { return checks + [("viewport fixture has its earlier message", false)] }
        scroll(to: controller.rect(for: earlier).minY + 7)
        let reading = bottomLine(of: transcript, readableMaxY: readableMaxY)
        let readingOrigin = clip.bounds.minY
        check("the viewport fixture can read earlier messages", !controller.isFollowing && reading != nil)
        resize(width: 700)
        check("a narrower window keeps the bottom line of an earlier reading position", holds(reading, in: transcript, readableMaxY: readableMaxY) && !controller.isFollowing)
        resize(width: 1300)
        check("a wider window keeps the bottom line of an earlier reading position", holds(reading, in: transcript, readableMaxY: readableMaxY) && !controller.isFollowing)
        resize(width: home.width)
        check("resizing the width back returns to the same scroll position", abs(clip.bounds.minY - readingOrigin) < 1)
        resize(height: 520)
        check("a shorter window keeps the bottom line of an earlier reading position", holds(reading, in: transcript, readableMaxY: readableMaxY) && !controller.isFollowing)
        resize(height: 900)
        check("a taller window keeps the bottom line of an earlier reading position", holds(reading, in: transcript, readableMaxY: readableMaxY) && !controller.isFollowing)
        resize(height: home.height)
        check("resizing the height back returns to the same scroll position", abs(clip.bounds.minY - readingOrigin) < 1)

        // While a window edge or a divider is dragged, AppKit's text view
        // puts off its own scrolling, and scrolls the line it showed first
        // at the start back to the top when the drag ends. The callbacks
        // are the ones a drag sends; a hidden window has no real drag.
        transcript.viewWillStartLiveResize()
        resize(width: 820, height: 600)
        let heldWhileDragging = holds(reading, in: transcript, readableMaxY: readableMaxY)
        resize(width: 700, height: 500)
        transcript.viewDidEndLiveResize()
        check("a live resize keeps the bottom line of an earlier reading position, also when it ends", heldWhileDragging && holds(reading, in: transcript, readableMaxY: readableMaxY) && !controller.isFollowing)
        resize(width: home.width, height: home.height)
        check("resizing back after a live resize returns to the same scroll position", abs(clip.bounds.minY - readingOrigin) < 1)

        let paneWidth = clip.bounds.width
        controller.toggleSidebar(nil); settle()
        check("hiding the sidebar keeps the bottom line of an earlier reading position", clip.bounds.width > paneWidth + 50 && holds(reading, in: transcript, readableMaxY: readableMaxY))
        controller.toggleSidebar(nil); settle()
        check("showing the sidebar returns to the same scroll position", abs(clip.bounds.width - paneWidth) < 1 && abs(clip.bounds.minY - readingOrigin) < 1)

        // A growing composer covers the bottom of the pane. It shrinks back
        // to one line, not to nothing: on the macOS 26 runner an emptied
        // composer still measured the height of the text it had held.
        let savedDraft = controller.composer.string
        func compose(_ text: String) { controller.composer.string = text; controller.updateComposerHeight(); settle() }
        compose("one")
        let restingInset = controller.transcriptScroll.contentInsets.bottom, restingOrigin = clip.bounds.minY
        compose("one\ntwo\nthree\nfour\nfive")
        let grownInset = controller.transcriptScroll.contentInsets.bottom
        check("a growing composer pushes the bottom line of an earlier reading position up with it", grownInset > restingInset + 20 && holds(reading, in: transcript, readableMaxY: readableMaxY))
        compose("one")
        let shrunkInset = controller.transcriptScroll.contentInsets.bottom
        let returned = abs(shrunkInset - restingInset) < 1 && abs(clip.bounds.minY - restingOrigin) < 1
        if !returned { print("DIAGNOSTIC composer shrink inset=\(shrunkInset) resting=\(restingInset) grown=\(grownInset) origin=\(clip.bounds.minY) resting=\(restingOrigin) composer=\(controller.composerHeight.constant) holds=\(holds(reading, in: transcript, readableMaxY: readableMaxY))") }
        check("a shrinking composer returns to the same scroll position", returned)
        compose(savedDraft)

        // Inside a message taller than the window, the line counts, not
        // the message: its edges are both out of view.
        if let tall = controller.messageRanges.first(where: { $0.1.id == "viewport-\(tallIndex)" })?.0 {
            let rect = controller.rect(for: tall)
            scroll(to: rect.midY)
            let inside = bottomLine(of: transcript, readableMaxY: readableMaxY)
            let coversViewport = rect.minY < clip.bounds.minY && rect.maxY > clip.bounds.maxY
            resize(width: 760)
            check("a width change inside a message taller than the window keeps the line being read", coversViewport && holds(inside, in: transcript, readableMaxY: readableMaxY))
            resize(width: home.width)
        } else { check("viewport fixture has its tall message", false) }

        // At the top of the loaded history there is nothing above to
        // reveal, so the first message stays below the toolbar.
        let top = controller.minimumTranscriptOrigin
        scroll(to: top)
        resize(height: 900)
        let stayedAtTop = abs(clip.bounds.minY - controller.minimumTranscriptOrigin) < 1
        resize(height: home.height)
        check("a taller window at the top of the history keeps the first message below the toolbar", stayedAtTop && abs(clip.bounds.minY - top) < 1 && !controller.isFollowing)

        // The thread inspector is a second transcript with the same rule.
        guard let root = controller.messages.first(where: { $0.id == threadRootID }) else { return checks + [("viewport fixture has its thread root", false)] }
        controller.showThreadInspector(root: root)
        guard let inspector = controller.threadInspector else { return checks + [("viewport fixture opens its thread inspector", false)] }
        await inspector.waitUntilLoaded(); settle()
        let replies = inspector.transcript, replyClip = inspector.scroll.contentView
        func showsNewestReply() -> Bool { replyClip.bounds.maxY >= replies.bounds.maxY - 1 }
        check("the thread inspector opens on its newest reply", inspector.rows.count == 60 && showsNewestReply() && replies.bounds.height > replyClip.bounds.height * 2)
        resize(height: 520)
        check("a shorter window keeps the newest thread reply in view", showsNewestReply())
        // The inspector opens at a preferred width that a divider drag
        // overrides; changing that preference reshapes the pane the same way.
        let inspectorWidth = replyClip.bounds.width
        let preferredWidth = inspector.view.constraints.first { $0.firstItem === inspector.view && $0.firstAttribute == .width && $0.secondItem == nil && $0.relation == .equal }
        let openingWidth = preferredWidth?.constant ?? 0
        func resizeInspector(by delta: CGFloat) { preferredWidth?.constant = openingWidth + delta; settle() }
        resizeInspector(by: 120)
        check("a wider thread inspector keeps the newest thread reply in view", replyClip.bounds.width > inspectorWidth + 50 && showsNewestReply())
        replyClip.scroll(to: NSPoint(x: 0, y: replies.bounds.height / 3)); inspector.scroll.reflectScrolledClipView(replyClip)
        let reply = bottomLine(of: replies, readableMaxY: replyClip.bounds.maxY)
        let replyOrigin = replyClip.bounds.minY
        resizeInspector(by: 0)
        check("a narrower thread inspector keeps the bottom line of an earlier reply", abs(replyClip.bounds.width - inspectorWidth) < 2 && holds(reply, in: replies, readableMaxY: replyClip.bounds.maxY))
        resize(height: home.height)
        check("a taller window keeps the bottom line of an earlier reply", holds(reply, in: replies, readableMaxY: replyClip.bounds.maxY))
        resizeInspector(by: 120)
        resize(height: 520)
        check("resizing the thread inspector back returns to the same scroll position", abs(replyClip.bounds.minY - replyOrigin) < 1)
        controller.closeThreadInspector(); settle()

        // Picking another conversation leaves the previous text in the pane
        // until the first render arrives. Nothing in view belongs to the
        // new conversation yet: not its follow state, not a read receipt.
        resize(height: home.height)
        scroll(to: controller.rect(for: earlier).minY + 7)
        let leftReading = !controller.isFollowing && controller.visibleMessageForReadReceipt != nil
        controller.select(other)
        scroll(to: clip.bounds.minY + 40)
        check("a scroll before a newly picked conversation renders reads nothing from the previous one", leftReading && controller.isFollowing && controller.visibleMessageForReadReceipt == nil)
        // At the top, a scroll would ask for the new conversation's earlier
        // messages, counted from the first message of the previous one.
        scroll(to: controller.minimumTranscriptOrigin)
        controller.loadEarlierIfAtTop()
        check("a scroll to the top before a newly picked conversation renders loads nothing earlier", controller.isFollowing && !controller.isLoadingEarlier)
        await controller.loadTask?.value; await controller.renderTask?.value
        settle()
        check("a newly picked conversation opens on its newest message after a scroll in between", controller.messages.last?.id == "viewport-other-79" && showsNewest() && controller.visibleMessageForReadReceipt?.id == "viewport-other-79")
        // Jump to Latest decides the same way, and waits for its render too.
        scroll(to: controller.minimumTranscriptOrigin + 60)
        let leftLatest = !controller.isFollowing
        controller.jumpToLatest(nil)
        scroll(to: clip.bounds.minY + 40)
        await controller.latestReadTask?.value; await controller.renderTask?.value
        settle()
        check("Jump to Latest reaches the newest message after a scroll in between", leftLatest && showsNewest())

        // A legacy scroller takes width when it appears, so the text wraps
        // once more while it is being placed for the new shape.
        let pane = controller.transcriptScroll
        pane.scrollerStyle = .legacy
        controller.select(short)
        await controller.loadTask?.value; await controller.renderTask?.value
        settle()
        // Tall enough for the whole conversation, with a little room.
        let fitting = window.frame.height - (controller.readableTranscriptRect.height - transcript.bounds.height) + 24
        resize(height: fitting)
        let fits = fitting >= window.minSize.height && pane.verticalScroller?.isHidden != false && showsNewest()
        resize(width: 700)
        let scrolls = pane.verticalScroller?.isHidden == false && abs(transcript.frame.width - pane.contentSize.width) < 1 && transcript.bounds.height > controller.readableTranscriptRect.height + 40
        check("a legacy scroller that appears during a resize leaves a followed transcript on its newest message", fits && scrolls && showsNewest())
        scroll(to: controller.minimumTranscriptOrigin + 20)
        let beside = bottomLine(of: transcript, readableMaxY: readableMaxY)
        resize(height: fitting - 60)
        check("a scroll after a legacy scroller appeared is the place a later resize keeps", !controller.isFollowing && holds(beside, in: transcript, readableMaxY: readableMaxY))
        return checks
    }
}
