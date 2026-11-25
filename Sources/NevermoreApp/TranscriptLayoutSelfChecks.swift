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
            row("first", "alice@example.invalid", "2026-11-05 12:23:30.000000", "<p>First from Alice.</p>", extra: ["link_doctype": .string("Project")]),
            row("second", "alice@example.invalid", "2026-11-05 12:24:00.000000", "<p>Second from Alice.</p>"),
            row("later", "alice@example.invalid", "2026-11-05 12:35:00.000000", "<p>Later from Alice.</p>", extra: ["is_edited": .number(1), "link_doctype": .string("Task"), "link_document": .string("TASK-1")]),
            row("reply", "bob@example.invalid", "2026-11-05 12:36:00.000000", "<p>Bob replies.</p>", extra: ["message_reactions": .string(reactions)]),
            row("nextDay", "bob@example.invalid", "2026-11-06 09:00:00.000000", "<p>Next day from Bob.</p>"),
            row("bot", "admin@example.invalid", "2026-11-06 09:00:30.000000", "<p>Bot report.</p>", extra: ["is_bot_message": .number(1), "bot": .string("hours-bot")]),
            row("answer", "alice@example.invalid", "2026-11-06 09:01:00.000000", "<p>Answering Bob.</p>", extra: ["is_reply": .bool(true), "linked_message": .string("nextDay")]),
            row("upload", "bob@example.invalid", "2026-11-06 09:05:00.000000", "", type: "File", extra: ["file": .string("/files/report.pdf")]),
            row("photo", "alice@example.invalid", "2026-11-06 09:06:00.000000", "", type: "Image", extra: ["file": .string("/files/pic.png")]),
            // Answers a message outside the loaded window; Raven's copy of it
            // names the author, and its plain text holds a spoiler.
            row("lateAnswer", "alice@example.invalid", "2026-11-06 09:06:30.000000", "<p>Answering an old one.</p>", extra: ["is_reply": .bool(true), "linked_message": .string("unloaded-origin"), "replied_message_details": .string(#"{"owner": "bob@example.invalid", "content": "The butler did it", "message_type": "Text", "creation": "2026-11-01 08:00:00"}"#)])
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

        // Hover lookup returns the same message a full scan would, so the
        // binary search over layout order is checked against a visible row.
        let readable = controller.readableTranscriptRect
        if let entry = controller.messageRanges.first(where: { entry in
            let rect = controller.highlightRect(for: entry.0)
            return rect.midY >= readable.minY && rect.midY < readable.maxY
        }) {
            let target = controller.highlightRect(for: entry.0)
            let point = NSPoint(x: target.midX, y: target.midY)
            controller.updateHover(at: point)
            check("hover lookup finds the message under the pointer", controller.hoveredMessageID == entry.1.id)
            controller.hideHoverBar()
        } else { check("layout fixture has a visible message to hover", false) }
        // The bottom-most row pins the search direction; an inverted
        // comparison would still resolve the first row by accident.
        if let entry = controller.messageRanges.reversed().first(where: { entry in
            let rect = controller.highlightRect(for: entry.0)
            return rect.intersects(readable)
        }) {
            let target = controller.highlightRect(for: entry.0)
            // A partially visible tall row has its center outside the band;
            // probe a point that lies inside both the row and the band.
            let y = (max(readable.minY, target.minY) + min(readable.maxY, target.maxY)) / 2
            controller.updateHover(at: NSPoint(x: target.midX, y: y))
            check("hover lookup finds the bottom-most visible message", controller.hoveredMessageID == entry.1.id)
            controller.hideHoverBar()
        } else { check("layout fixture has a bottom-most visible row", false) }
        check("message ranges ascend without overlap",
              zip(controller.messageRanges, controller.messageRanges.dropFirst())
                  .allSatisfy { NSMaxRange($0.0) <= $1.0.location })

        do {
            let originalFontSize = defaults.object(forKey: "fontSize")
            defer {
                if let originalFontSize { defaults.set(originalFontSize, forKey: "fontSize") }
                else { defaults.removeObject(forKey: "fontSize") }
            }
            func fontSize(of string: NSAttributedString, matching label: String) -> CGFloat? {
                let location = (string.string as NSString).range(of: label).location
                guard location != NSNotFound else { return nil }
                return (string.attribute(.font, at: location, effectiveRange: nil) as? NSFont)?.pointSize
            }
            for size: CGFloat in [11, 13, 24] {
                defaults.set(Double(size), forKey: "fontSize")
                controller.render(); await controller.renderTask?.value
                let metrics = TranscriptMetrics(size: size, compact: false)
                let divider = TranscriptStyle.unreadDivider(metrics: metrics)
                check("the unread divider follows reading size at \(Int(size)) pt",
                      fontSize(of: divider, matching: "Unread messages") == max(11, size - 2)
                        && divider.attribute(.nevermoreReadingControl, at: 0, effectiveRange: nil) as? Bool == true)
                check("linked-document metadata follows reading size at \(Int(size)) pt",
                      fontSize(of: storage, matching: "Linked document: Task · TASK-1") == max(11, size - 2))
            }
            check("linked-document metadata omits the separator without an identifier",
                  storage.string.contains("Linked document: Project") && !storage.string.contains("Linked document: Project ·"))
        }
        controller.render(); await controller.renderTask?.value

        check("all fixture messages render", controller.messageRanges.count == rows.count)
        let headed = Set(controller.messageRanges.filter { has(.nevermoreAvatar, in: $0.0) }.map(\.1.id))
        check("a sender header starts each group: new author, a gap over five minutes, a new day or a bot", headed == ["first", "later", "reply", "nextDay", "bot", "answer", "upload", "photo"])
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
        let edited = range("later").map { text.substring(with: $0) } ?? ""
        check("an edited message says so after its text, as in Raven", edited.contains("Later from Alice. (edited)") && !(range("first").map { text.substring(with: $0) } ?? "(edited)").contains("(edited)"))
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
            // The quote is a way to the answered message.
            var target: (NSRange, String)?
            storage.enumerateAttribute(.nevermoreReplyTarget, in: answer) { value, range, stop in if let id = value as? String { target = (range, id); stop.pointee = true } }
            let quoteGlyph = target.map { layout.glyphIndexForCharacter(at: $0.0.location + 1) } ?? 0
            let quoteLine = layout.lineFragmentUsedRect(forGlyphAt: quoteGlyph, effectiveRange: nil)
            let onQuote = NSPoint(x: transcript.textContainerOrigin.x + quoteLine.minX + 20, y: transcript.textContainerOrigin.y + quoteLine.midY)
            let beside = NSPoint(x: transcript.bounds.maxX - 4, y: onQuote.y)
            check("reply quotes carry the answered message, and only their text is a target", target?.1 == "nextDay" && transcript.replyTarget(at: onQuote) == "nextDay" && transcript.replyTarget(at: beside) == nil)
            transcript.setSelectedRange(NSRange(location: answer.location + 1, length: 0))
            let accessibilityJump = controller.transcriptAccessibility.actions().first { $0.name == "Show Answered Message" }
            check("VoiceOver offers the same way to the answered message", accessibilityJump != nil)
            controller.showQuotedMessage("nextDay")
            let caret = transcript.selectedRange()
            check("a click on a reply quote puts the caret on the answered message", caret.length == 0 && range("nextDay").map { NSLocationInRange(caret.location, $0) } == true && transcript.highlightRect != nil && !controller.isFollowing)
            transcript.setSelectedRange(NSRange(location: 0, length: 0)); controller.updateMessageHighlight()
        } else { check("reply fixture renders", false) }
        if let late = range("lateAnswer") {
            check("a reply to an unloaded message names its author from Raven's copy and shows none of its text", text.substring(with: late).hasPrefix("Bob Builder\n") && !text.substring(with: late).contains("butler") && has(.nevermoreReplyTarget, in: late))
        } else { check("reply to an unloaded message renders", false) }
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
        TranscriptView.prepareForExport(printed, for: .print)
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

        // Attachments open on click: a file's card and an image's picture
        // carry an internal link that dispatches to the message's download.
        session.thumbnails["photo"] = NSImage(size: NSSize(width: 48, height: 32))
        controller.render(); await controller.renderTask?.value
        var previewLinks: [(range: NSRange, url: URL)] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let url = value as? URL, url.scheme == "nevermore-attachment" { previewLinks.append((range, url)) }
        }
        check("file and image messages carry one preview link each, on the card and the picture", previewLinks.count == 2 && previewLinks.filter { $0.url.pathComponents.last == "upload" }.count == 1 && previewLinks.filter { $0.url.pathComponents.last == "photo" }.count == 1)
        check("the file card and the picture are the click targets", previewLinks.allSatisfy { $0.range.length == 1 && storage.attribute(.attachment, at: $0.range.location, effectiveRange: nil) != nil })
        if let target = previewLinks.first(where: { $0.url.pathComponents.last == "upload" }) {
            _ = controller.textView(transcript, clickedOnLink: target.url, at: target.range.location)
            let dispatched = controller.status.stringValue == "Downloading attachment…" && !controller.attachmentDownloads.isEmpty
            let movedCaret = controller.selectedMessage?.id == "upload"
            let tasks = controller.attachmentDownloads; controller.clearPreview(); for task in tasks { await task.value }
            check("an attachment link dispatches to the message's download", dispatched)
            check("a click on a file moves the caret to its message, so Space shows the same file", movedCaret)
            // A window wide enough for the File panel shows the file there.
            if let window = controller.window {
                let frame = window.frame
                window.setFrame(NSRect(origin: frame.origin, size: NSSize(width: max(frame.width, FileInspector.minimumWindowWidth + 100), height: frame.height)), display: false)
                _ = controller.textView(transcript, clickedOnLink: target.url, at: target.range.location)
                let panel = controller.fileInspector
                let shown = { controller.splitController.splitViewItems.contains { $0.viewController === panel } }
                let opened = panel?.source.messageID == "upload" && shown()
                // Quick Look of another file has its own download.
                let panelDownload = controller.fileDownload
                if let photo = controller.messages.first(where: { $0.id == "photo" }) { controller.fetchAttachment(save: false, message: photo) }
                let keptDownload = panelDownload != nil && controller.fileDownload == panelDownload && controller.attachmentDownload != nil && controller.fileInspector === panel
                // The fixture cannot download; drop the Quick Look before its error alert.
                controller.attachmentAttempt = UUID(); controller.attachmentDownload?.cancel()
                // A narrow window hides the panel and a wide one brings it back.
                let wide = window.frame
                window.setFrame(NSRect(origin: wide.origin, size: NSSize(width: FileInspector.minimumWindowWidth - 100, height: wide.height)), display: false)
                let hidden = controller.fileInspector === panel && controller.fileInspectorCollapsedByWidth && !shown() && controller.fileDownload == panelDownload
                window.setFrame(wide, display: false)
                let restored = controller.fileInspector === panel && !controller.fileInspectorCollapsedByWidth && shown()
                // Moving the caret to another file's message shows that file.
                if let photo = range("photo") { transcript.setSelectedRange(NSRange(location: photo.location, length: 0)) }
                try? await Task.sleep(for: .milliseconds(400))
                let followed = controller.fileInspector?.source.messageID == "photo" && controller.fileInspector !== panel
                if let first = range("first") { transcript.setSelectedRange(NSRange(location: first.location, length: 0)) }
                try? await Task.sleep(for: .milliseconds(400))
                let stayed = controller.fileInspector?.source.messageID == "photo"
                let wideTasks = controller.attachmentDownloads; controller.clearPreview(); for task in wideTasks { await task.value }
                check("a click on a file opens the File panel beside the conversation, and leaving closes it", opened && controller.fileInspector == nil && !controller.splitController.splitViewItems.contains { $0.viewController is FileInspector })
                check("Quick Look of another file leaves the File panel's download running", keptDownload)
                check("a narrow window hides the File panel with its download, and widening brings it back", hidden && restored)
                check("the File panel follows the caret to another file and stays on messages without one", followed && stayed)
                window.setFrame(frame, display: false)
            } else { check("a click on a file opens the File panel beside the conversation, and leaving closes it", false) }
        } else { check("attachment preview link exists", false) }
        let statusBefore = controller.status.stringValue
        if let stale = TranscriptStyle.attachmentLink(for: "gone") { _ = controller.textView(transcript, clickedOnLink: stale, at: 0) }
        check("stale attachment links cannot start a download", controller.status.stringValue == statusBefore && controller.attachmentDownloads.isEmpty)
        if let window = controller.window {
            window.orderFront(nil)
            let cardIndex = previewLinks.first { $0.url.pathComponents.last == "upload" }?.range.location ?? 0
            let glyphRect = AnimatedImageOverlay.attachmentFrame(at: cardIndex, layout: layout, origin: origin) ?? .zero
            let winPoint = transcript.convert(NSPoint(x: glyphRect.midX, y: glyphRect.midY), to: nil)
            if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: winPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) { NSApp.postEvent(up, atStart: false) }
            if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: winPoint, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) { transcript.mouseDown(with: down) }
            let clicked = controller.status.stringValue == "Downloading attachment…" && !controller.attachmentDownloads.isEmpty
            let tasks = controller.attachmentDownloads; controller.clearPreview(); for task in tasks { await task.value }
            transcript.highlightRect = nil
            check("a click on the file card in the transcript starts its preview", clicked)
        }
        // AppKit reads a clicked link at the press, then tracks it in a
        // nested event loop where main-actor work keeps running. A render
        // that replaced the text there could free the link before AppKit
        // delivered it: clicking a just-sent image crashed. Renders now
        // wait until the press ends.
        if let window = controller.window, let thumbnail = previewLinks.first(where: { $0.range.length == 1 && $0.url.pathComponents.last == "photo" }) {
            let probe = PressProbe()
            let observer = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { _ in
                MainActor.assumeIsolated { if probe.pressing { probe.editsDuringPress += 1 } else { probe.editsAfterPress += 1 } }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: layout.glyphIndexForCharacter(at: thumbnail.range.location), length: 1), in: container).offsetBy(dx: origin.x, dy: origin.y)
            let winPoint = transcript.convert(NSPoint(x: glyphRect.midX, y: glyphRect.midY), to: nil)
            window.makeKey()
            // The fixture cannot download, so a preview a press starts is dropped.
            await holdPress(probe, in: window, at: winPoint, afterPress: { controller.clearPreview() }) {
                // Held until the render task has finished, as a quick answer would.
                controller.render()
                let rendering = controller.renderTask
                Task { @MainActor in await rendering?.value; probe.rendered = true }
                let deadline = Date(timeIntervalSinceNow: 2)
                while !probe.rendered, Date() < deadline { RunLoop.current.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.01)) }
            }
            await controller.renderTask?.value
            transcript.highlightRect = nil
            check("a render waits for a press in the transcript to end, keeping the clicked link alive", probe.tracked && probe.rendered && probe.editsDuringPress == 0 && probe.editsAfterPress > 0)
        } else { check("image thumbnail press fixture exists", false) }
        // A clear cannot wait for the press like a render: it follows lost
        // access. The pane empties at once; the links of the old text live
        // on until the press ends. AppKit and the pane may hold the links
        // they show, so the press adds one only the text owns.
        let photo = previewLinks.first { $0.range.length == 1 && $0.url.pathComponents.last == "photo" }?.range.location
        let plainIndex = photo.flatMap { photo in (0..<photo).reversed().first { storage.attribute(.link, at: $0, effectiveRange: nil) == nil && UnicodeScalar(text.character(at: $0)).map(CharacterSet.alphanumerics.contains) == true } }
        if let window = controller.window, let plainIndex {
            let probe = PressProbe()
            var clearedUnderPress = false
            let glyphRect = layout.boundingRect(forGlyphRange: NSRange(location: layout.glyphIndexForCharacter(at: plainIndex), length: 1), in: container).offsetBy(dx: origin.x, dy: origin.y)
            await holdPress(probe, in: window, at: transcript.convert(NSPoint(x: glyphRect.midX, y: glyphRect.midY), to: nil), afterPress: {}) {
                weak var link: NSURL?
                autoreleasepool {
                    let added = NSURL(string: "nevermore-attachment://message/press-probe")
                    link = added
                    added.map { storage.addAttribute(.link, value: $0, range: NSRange(location: plainIndex, length: 1)) }
                    transcript.clearText()
                }
                clearedUnderPress = link != nil && transcript.string.isEmpty
            }
            controller.render(); await controller.renderTask?.value
            transcript.setSelectedRange(NSRange(location: 0, length: 0))
            check("a clear under a press empties the transcript and keeps its links alive until the press ends", probe.tracked && clearedUnderPress && transcript.string.contains("Answering Bob."))
        } else { check("plain text before the thumbnail exists", false) }
        if let upload = range("upload") {
            transcript.setSelectedRange(upload)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("NevermoreLayoutCheck-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            let plain = transcript.writeSelection(to: pasteboard, type: .string) ? pasteboard.string(forType: .string) ?? "" : ""
            let rich = transcript.writeSelection(to: pasteboard, type: .rtf) ? String(decoding: pasteboard.data(forType: .rtf) ?? Data(), as: UTF8.self) : ""
            check("copied file cards keep the name without the preview command", plain.contains("report.pdf") && !plain.contains("Quick Look") && !rich.contains("nevermore-attachment"))
            transcript.setSelectedRange(NSRange(location: 0, length: 0))
        } else { check("attachment copy fixture range exists", false) }

        // Compact mode drops avatars and gives their column back to text.
        defaults.set(true, forKey: "compactMessages")
        controller.render(); await controller.renderTask?.value
        let compactHeaders = controller.messageRanges.filter { has(.nevermoreAvatar, in: $0.0) }.count
        let compactTimes = controller.messageRanges.filter { has(.nevermoreGutterTime, in: $0.0) }.count
        check("compact messages keep grouped headers without avatars or column times", compactHeaders == 0 && compactTimes == 0 && transcript.metrics.gutter == 0 && abs(transcript.textContainerOrigin.x - transcript.readingColumnInset) < 0.5 && firstLine("first").hasPrefix("Alice Example  ") && !firstLine("second").hasPrefix("Alice Example"))
        return checks
    }
}

/// What happened to the transcript text during and after a held press.
@MainActor final class PressProbe {
    var pressing = false
    var tracked = false
    var released = false
    var releasePosted = false
    var rendered = false
    var editsDuringPress = 0
    var editsAfterPress = 0
}

/// Holds a press at `point` in `window` and runs `midPress` inside AppKit's
/// tracking loop, where main-actor work runs during a real press.
/// `probe.pressing` is set while `mouseDown` runs, `probe.tracked` once
/// `midPress` ran.
@MainActor private func holdPress(_ probe: PressProbe, in window: NSWindow, at point: NSPoint, afterPress: @escaping @MainActor () -> Void, midPress: @escaping @MainActor () -> Void) async {
    // Stamped on delivery: AppKit times the press.
    let press: @MainActor (NSEvent.EventType) -> NSEvent? = { type in NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) }
    // A press into the hidden fixture window is not always tracked (the
    // first may only focus it), so it is repeated until it is.
    for _ in 0..<3 where !probe.tracked {
        probe.released = false; probe.releasePosted = false
        // Delivered from the run loop rather than a main-queue job, as the
        // event loop does, so main-actor work can run mid-press.
        RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated {
            probe.pressing = true; press(.leftMouseDown).map(window.sendEvent); probe.pressing = false
            probe.released = true; afterPress()
        } }
        let timer = Timer(timeInterval: 0, repeats: false) { _ in MainActor.assumeIsolated { probe.tracked = true; midPress() } }
        RunLoop.main.add(timer, forMode: .eventTracking)
        // Ends a tracked press. The next attempt waits for it, so a release
        // meant for an untracked press cannot cut the next one short.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { press(.leftMouseUp).map { NSApp.postEvent($0, atStart: false) }; probe.releasePosted = true }
        let deadline = Date(timeIntervalSinceNow: 5)
        while !(probe.released && probe.releasePosted), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        timer.invalidate()
    }
}
