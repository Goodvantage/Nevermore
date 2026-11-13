import AppKit
import NevermoreCore
import RavenProtocol

/// The grouped transcript layout in a disposable demo store: who gets a
/// header, where day dividers and system events go, what copies, and what
/// the avatar column draws.
@MainActor enum TranscriptLayoutSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreLayoutCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "reader@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        let channel = RavenChannel(raw: .object(["name": .string("layout-fixture"), "channel_name": .string("Layout fixture")]))
        session.channels = [channel]
        session.userNames = ["alice@example.invalid": "Alice Example", "bob@example.invalid": "Bob Builder", "hours-bot": "Hours Bot", "admin@example.invalid": "Administrator"]
        func row(_ id: String, _ owner: String, _ creation: String, _ html: String, type: String = "Text", extra: [String: JSONValue] = [:]) -> RavenMessage {
            var fields: [String: JSONValue] = ["name": .string(id), "channel_id": .string(channel.id), "owner": .string(owner), "creation": .string(creation), "text": .string(html), "message_type": .string(type)]
            fields.merge(extra) { _, new in new }
            return RavenMessage(raw: .object(fields))
        }
        let reactions = #"{"👍": {"count": 2, "users": ["reader@example.invalid", "alice@example.invalid"], "reaction": "👍"}, "🎉": {"count": 1, "users": ["alice@example.invalid"], "reaction": "🎉"}}"#
        let rows = [
            row("event", "alice@example.invalid", "2026-11-05 12:23:00.000000", "Alice Example created fixture.", type: "System"),
            row("first", "alice@example.invalid", "2026-11-05 12:23:30.000000", "<p>First from Alice.</p>"),
            row("second", "alice@example.invalid", "2026-11-05 12:24:00.000000", "<p>Second from Alice.</p>"),
            row("later", "alice@example.invalid", "2026-11-05 12:35:00.000000", "<p>Later from Alice.</p>"),
            row("reply", "bob@example.invalid", "2026-11-05 12:36:00.000000", "<p>Bob replies.</p>", extra: ["message_reactions": .string(reactions)]),
            row("nextDay", "bob@example.invalid", "2026-11-06 09:00:00.000000", "<p>Next day from Bob.</p>"),
            row("bot", "admin@example.invalid", "2026-11-06 09:00:30.000000", "<p>Bot report.</p>", extra: ["is_bot_message": .number(1), "bot": .string("hours-bot")]),
            row("answer", "alice@example.invalid", "2026-11-06 09:01:00.000000", "<p>Answering Bob.</p>", extra: ["is_reply": .bool(true), "linked_message": .string("nextDay")])
        ]
        try await session.store.cacheMessages(rows)
        let defaults = UserDefaults.standard
        let savedCompact = defaults.object(forKey: "compactMessages")
        defaults.set(false, forKey: "compactMessages")
        let controller = ConversationWindow(app: app, session: session)
        defer {
            if let savedCompact { defaults.set(savedCompact, forKey: "compactMessages") } else { defaults.removeObject(forKey: "compactMessages") }
            controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory)
        }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.select(channel)
        // Everything is read, so no unread divider splits a group.
        session.recordTranscriptVisit(.timestamp("2026-11-06 23:00:00"), channelID: channel.id)
        await controller.loadTask?.value; await controller.renderTask?.value
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        let transcript = controller.transcript
        guard let storage = transcript.textStorage, let layout = transcript.layoutManager, let container = transcript.textContainer else { return [("layout fixture has a text system", false)] }
        // Read the text afresh: the compact check re-renders it.
        var text: NSString { storage.string as NSString }
        func range(_ id: String) -> NSRange? { controller.messageRanges.first { $0.1.id == id }?.0 }
        func has(_ key: NSAttributedString.Key, in range: NSRange?) -> Bool {
            guard let range else { return false }
            var found = false
            storage.enumerateAttribute(key, in: range) { value, _, stop in if value != nil { found = true; stop.pointee = true } }
            return found
        }
        func firstLine(_ id: String) -> String {
            guard let range = range(id) else { return "" }
            return text.substring(with: text.lineRange(for: NSRange(location: range.location, length: 0)))
        }
        func lineRect(at location: Int) -> NSRect {
            let origin = transcript.textContainerOrigin
            return layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: location), effectiveRange: nil).offsetBy(dx: origin.x, dy: origin.y)
        }

        check("all fixture messages render", controller.messageRanges.count == rows.count)
        let headed = Set(controller.messageRanges.filter { has(.nevermoreAvatar, in: $0.0) }.map(\.1.id))
        check("a sender header starts each group: new author, a gap over five minutes, a new day or a bot", headed == ["first", "later", "reply", "nextDay", "bot", "answer"])
        let secondTime = session.displayTime(rows[2].creation)
        check("a continued message has no header and keeps its time for the avatar column", !has(.nevermoreAvatar, in: range("second")) && range("second").map { storage.attribute(.nevermoreGutterTime, at: $0.location, effectiveRange: nil) as? String == session.compactTime(rows[2].creation) } == true && range("first").map { storage.attribute(.nevermoreGutterTime, at: $0.location, effectiveRange: nil) == nil } == true)
        let firstTime = session.displayTime(rows[1].creation), firstFull = session.displayTimestamp(rows[1].creation)
        check("headers show the time of day; the date moves to a divider", firstLine("first") == "Alice Example  \(firstTime)\n" && !storage.string.contains(firstFull))
        var dividers: [String] = []
        storage.enumerateAttribute(.nevermoreDayDivider, in: NSRange(location: 0, length: storage.length)) { value, range, _ in if value as? Bool == true { dividers.append(text.substring(with: range)) } }
        let days = [rows[1], rows[5]].compactMap { session.messageDate($0.creation) }.map { session.dayLabel(for: $0) + "\n" }
        check("one day divider per day, labelled for the reader", dividers == days && days.count == 2)
        guard days.count == 2 else { return checks }
        let eventStyle = range("event").flatMap { storage.attribute(.paragraphStyle, at: $0.location, effectiveRange: nil) as? NSParagraphStyle }
        check("system events are a centered line without a sender header", !has(.nevermoreAvatar, in: range("event")) && eventStyle?.alignment == .center && firstLine("event").hasPrefix("Alice Example created fixture.") && !headed.contains("event"))
        // Centered means the middle of the pane, although the text column
        // itself starts right of the avatars.
        func offCenter(_ label: String) -> CGFloat {
            let found = text.range(of: label)
            guard found.location != NSNotFound else { return .infinity }
            let line = layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: found.location), effectiveRange: nil)
            return abs(line.midX + transcript.textContainerOrigin.x - transcript.bounds.midX)
        }
        check("day dividers and system events sit in the middle of the pane", transcript.metrics.gutter > 0 && offCenter(days[0]) < 1 && offCenter("Alice Example created fixture.") < 1)
        check("bot messages name the bot, not the account it posts as", firstLine("bot").hasPrefix("Hours Bot  "))
        var chips: [(String, Bool)] = []
        if let reply = range("reply") { storage.enumerateAttribute(.nevermoreReactionChip, in: reply) { value, range, _ in if let mine = value as? Bool { chips.append((text.substring(with: range), mine)) } } }
        check("reactions are chips, with the reader's own marked", chips.count == 2 && chips.contains { $0 == ("👍 2", true) } && chips.contains { $0 == ("🎉 1", false) })

        if let answer = range("answer") {
            transcript.setSelectedRange(answer)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("NevermoreLayoutCheck-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            let copied = transcript.writeSelection(to: pasteboard, type: .string) ? pasteboard.string(forType: .string) ?? "" : ""
            check("reply quotes show the quoted author with a bar and copy as before", has(.nevermoreQuoteBar, in: answer) && text.substring(with: answer).contains("Bob Builder  Next day from Bob.\n") && copied.contains("↪ Bob Builder:  Next day from Bob.\nAnswering Bob."))
            transcript.setSelectedRange(NSRange(location: 0, length: 0))
        } else { check("reply fixture renders", false) }
        // A quote must not reveal what its message hides.
        let hidden = row("hidden", "bob@example.invalid", "2026-11-06 09:02:00.000000", #"<p>The butler <span data-spoiler="true">did it</span>.</p>"#)
        check("reply quotes keep spoilers masked", controller.replyPreview(hidden) == "The butler [Spoiler].")

        // Copying keeps full timestamps and leaves divider labels behind.
        if let first = range("first"), let second = range("second") {
            transcript.setSelectedRange(NSRange(location: 0, length: NSMaxRange(second)))
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("NevermoreLayoutCheck-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            let copied = transcript.writeSelection(to: pasteboard, type: .string) ? pasteboard.string(forType: .string) ?? "" : ""
            check("copied headers carry the full timestamp; day labels stay out", copied.contains("Alice Example  \(firstFull)\n") && copied.contains("Second from Alice.") && !copied.contains(days[0]) && !copied.contains(secondTime + "\n"))
            // Rich copies keep each message's last line at full height: the
            // spacing line's fixed height must not leak into it.
            pasteboard.clearContents()
            let rich = transcript.writeSelection(to: pasteboard, type: .rtf) ? pasteboard.data(forType: .rtf).flatMap { NSAttributedString(rtf: $0, documentAttributes: nil) } : nil
            let lastLine = rich.map { ($0.string as NSString).range(of: "First from Alice.") }
            let lastLineStyle = rich.flatMap { value in lastLine.flatMap { $0.location == NSNotFound ? nil : value.attribute(.paragraphStyle, at: $0.location, effectiveRange: nil) as? NSParagraphStyle } }
            check("rich copies keep message lines at their natural height", rich != nil && lastLine.map { $0.location != NSNotFound } == true && lastLineStyle.map { $0.maximumLineHeight == 0 && $0.minimumLineHeight == 0 } ?? true)
            transcript.setSelectedRange(NSRange(location: first.location, length: 0))
            controller.updateMessageHighlight()
            check("the selected-message highlight includes the avatar column", abs((transcript.highlightRect?.minX ?? -1) - (transcript.readingColumnInset - 10)) < 0.5)
            transcript.setSelectedRange(NSRange(location: 0, length: 0)); transcript.highlightRect = nil; transcript.caretMessageLocation = nil
        } else { check("copy fixture ranges exist", false) }

        let printed = NSMutableAttributedString(attributedString: storage)
        TranscriptView.prepareForExport(printed)
        let printedEvent = (printed.string as NSString).range(of: "Alice Example created fixture.")
        let printedEventStyle = printedEvent.location == NSNotFound ? nil : printed.attribute(.paragraphStyle, at: printedEvent.location, effectiveRange: nil) as? NSParagraphStyle
        check("printing uses the copy text: dated headers, no divider labels, centered events on the page", printed.string.contains("Alice Example  \(firstFull)\n") && !printed.string.contains(days[0]) && !printed.string.contains(days[1]) && printedEventStyle?.alignment == .center && printedEventStyle?.tailIndent == 0)

        // The text column starts right of the avatars and ends one inset
        // from the right edge, and clicks still land on the right text.
        let metrics = transcript.metrics
        let origin = transcript.textContainerOrigin
        check("the text column leaves room for avatars", metrics.gutter > metrics.avatarDiameter && abs(origin.x - (transcript.readingColumnInset + metrics.gutter)) < 0.5 && abs(container.size.width - (transcript.bounds.width - 2 * transcript.readingColumnInset - metrics.gutter)) < 1)
        let body = text.range(of: "First from Alice.")
        if body.location != NSNotFound {
            let glyph = layout.glyphRange(forCharacterRange: NSRange(location: body.location + 2, length: 1), actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyph, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let hit = transcript.characterIndexForInsertion(at: NSPoint(x: rect.midX - 0.5, y: rect.midY))
            check("clicks in the shifted column map to the text under the pointer", abs(hit - (body.location + 2)) <= 1)
        } else { check("hit-test fixture text exists", false) }

        // Pixels: an avatar beside each header, an empty column beside a
        // continued message until it is hovered, when its time appears.
        if let first = range("first"), let second = range("second") {
            func ink(in rect: NSRect) -> Int {
                guard let rep = transcript.bitmapImageRepForCachingDisplay(in: rect) else { return -1 }
                transcript.cacheDisplay(in: rect, to: rep)
                var count = 0
                for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { count += 1 } }
                return count
            }
            let avatarLine = lineRect(at: first.location), continuedLine = lineRect(at: second.location)
            let column = { (line: NSRect) in NSRect(x: transcript.readingColumnInset, y: line.minY, width: metrics.gutter - 4, height: line.height).integral }
            let avatarInk = ink(in: column(avatarLine).offsetBy(dx: 0, dy: 4))
            transcript.hoverMessageLocation = nil
            let idle = ink(in: column(continuedLine))
            transcript.hoverMessageLocation = second.location
            let hovered = ink(in: column(continuedLine))
            transcript.hoverMessageLocation = nil
            check("avatars draw in the column beside headers", avatarInk > 40)
            check("a continued message shows its time in the column only while pointed at", idle == 0 && hovered > 10)
        } else { check("pixel fixture ranges exist", false) }

        // Compact mode drops avatars and gives their column back to text.
        defaults.set(true, forKey: "compactMessages")
        controller.render(); await controller.renderTask?.value
        let compactHeaders = controller.messageRanges.filter { has(.nevermoreAvatar, in: $0.0) }.count
        let compactTimes = controller.messageRanges.filter { has(.nevermoreGutterTime, in: $0.0) }.count
        check("compact messages keep grouped headers without avatars or column times", compactHeaders == 0 && compactTimes == 0 && transcript.metrics.gutter == 0 && abs(transcript.textContainerOrigin.x - transcript.readingColumnInset) < 0.5 && firstLine("first").hasPrefix("Alice Example  ") && !firstLine("second").hasPrefix("Alice Example"))
        return checks
    }
}
