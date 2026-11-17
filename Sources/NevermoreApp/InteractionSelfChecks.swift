import AppKit
import NevermoreCore
import RavenProtocol

@MainActor enum InteractionSelfChecks {
    static func descendants<T: NSView>(_ view: NSView, of type: T.Type) -> [T] {
        (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { descendants($0, of: type) }
    }
    static func key(_ code: UInt16, window: NSWindow, modifiers: NSEvent.ModifierFlags = [], characters: String = "\r") -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }
    static func run(window: ConversationWindow, session: AccountSession) async throws -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        guard let parent = window.window else { return [("interaction fixture has a window", false)] }
        results += try await OutboxArchiveSelfChecks.run()
        results += try await ChoiceSheetSelfChecks.run(on: parent)
        let testAccount = UUID(), otherAccountForSearch = UUID()
        defer { SavedSearchStore.clear(testAccount); SavedSearchStore.clear(otherAccountForSearch) }
        let searchFixture = SavedSearch(title: "Fixture", criteria: SearchCriteria(query: "private fixture", scope: .workspace("fixture")))
        try SavedSearchStore.save([searchFixture], account: testAccount)
        results.append(("saved searches are account-scoped and retain exact search criteria", SavedSearchStore.load(testAccount) == [searchFixture] && SavedSearchStore.load(otherAccountForSearch).isEmpty))
        SavedSearchStore.clear(testAccount)
        results.append(("removing account search settings clears its private saved queries", SavedSearchStore.load(testAccount).isEmpty))
        let originalChannel = window.channel
        let originalDraftText = window.composer.string
        if let originalChannel {
            var fields = originalChannel.raw.object; fields["is_archived"] = .bool(true)
            window.channel = RavenChannel(raw: .object(fields)); window.updateContext()
            results.append(("archived conversations disable sending and preserve local drafts", !window.sendButton.isEnabled && window.composer.string == originalDraftText))
            window.channel = originalChannel; window.updateContext()
        }
        let dismissedSuggestions = MentionPopover()
        dismissedSuggestions.candidates = [MentionCandidate(kind: .person, serverID: "fixture@example.invalid", title: "Fixture", detail: "")]
        dismissedSuggestions.table.reloadData(); dismissedSuggestions.close()
        results.append(("dismissed mention suggestions safely reject a delayed row request", dismissedSuggestions.numberOfRows(in: dismissedSuggestions.table) == 0 && dismissedSuggestions.tableView(dismissedSuggestions.table, viewFor: nil, row: 0) == nil))
        let chooser = ConversationChooser(session: session)
        chooser.search.stringValue = "@Alex"; chooser.updateMatches()
        results.append(("conversation chooser filters people without creating a DM", !chooser.matches.isEmpty && chooser.matches.allSatisfy { $0.kind == .person }))
        var picked: MentionCandidate?
        chooser.onPick = { candidate, _ in picked = candidate }
        chooser.present(on: parent); chooser.chooseSelected()
        results.append(("conversation chooser resolves a stable server identity and closes", picked?.serverID == "alex@example.com" && parent.attachedSheet == nil))
        // Exercise the real asynchronous sheet, not a second fake editor.
        let html = "<p><strong>scheduled</strong> text</p>"
        let edit = Task { try await MessageEditorSheet.edit(html: html, title: "Self-check editor", on: parent) }
        for _ in 0..<100 { if parent.attachedSheet != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        guard let sheet = parent.attachedSheet, let content = sheet.contentView,
              let editor = descendants(content, of: ComposerView.self).first else { throw AppError.message("Scheduled editor fixture did not appear") }
        content.layoutSubtreeIfNeeded()
        results.append(("scheduled editor text wraps within the native sheet", editor.enclosingScrollView.map { $0.contentSize.width > 0 && abs(editor.frame.width - $0.contentSize.width) < 1 } == true))
        sheet.makeFirstResponder(editor)
        let before = editor.string
        if let event = key(36, window: sheet) { editor.keyDown(with: event) }
        results.append(("scheduled editor Return inserts a newline and keeps the sheet open", parent.attachedSheet === sheet && editor.string.count > before.count))
        if let event = key(36, window: sheet, modifiers: .command) { editor.keyDown(with: event) }
        let edited = try await edit.value
        results.append(("scheduled editor Command-Return saves native rich text", edited?.contains("<strong>scheduled</strong>") == true && parent.attachedSheet == nil))
        let cancelled = Task { try await MessageEditorSheet.edit(html: html, title: "Self-check cancel", on: parent) }
        for _ in 0..<100 { if parent.attachedSheet != nil { break }; try await Task.sleep(for: .milliseconds(10)) }
        if let sheet = parent.attachedSheet, let content = sheet.contentView, let editor = descendants(content, of: ComposerView.self).first, let event = key(53, window: sheet, characters: "\u{1b}") { editor.keyDown(with: event) }
        else { throw AppError.message("Cancellation fixture did not appear") }
        results.append(("cancelling a scheduled edit returns no mutation", try await cancelled.value == nil && parent.attachedSheet == nil))
        for source in ["<p>a</p><hr><p>b</p>", "<blockquote><p>a</p><hr><p>b</p></blockquote>", "<ol start=\"5\"><li>a</li></ol><ol start=\"9\"><li>b</li></ol>"] {
            let document = try RichTextCodec.parse(source)
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: document))
            let range = (text.string as NSString).range(of: "b", options: .backwards)
            text.insert(NSAttributedString(string: "!"), at: range.location)
            let exported = RichTextCodec.html(try NativeRichText.document(from: text))
            let label = source.contains("start") ? "adjacent ordered lists retain independent numbering after an edit" : source.contains("blockquote") ? "horizontal rules survive edits inside blockquotes" : "horizontal rules survive surrounding text edits"
            results.append((label, exported.contains(source.contains("start") ? "start=\"9\"" : "<hr") && exported.contains("!b")))
        }
        let formatting = ComposerView()
        formatting.isRichText = true; formatting.allowsUndo = true; formatting.sharedUndoManager = UndoManager()
        formatting.textStorage?.setAttributedString(NativeRichText.attributedString(document: try RichTextCodec.parse("<p>first</p><p>second</p><p>tail</p>")))
        formatting.setSelectedRange(NSRange(location: 0, length: "first\nsecond".utf16.count))
        formatting.bulletedList(nil)
        let listed = RichTextCodec.html(try NativeRichText.document(from: formatting.attributedString()))
        results.append(("native list formatting preserves unselected following paragraphs", listed.contains("<ul><li>first</li><li>second</li></ul>") && listed.contains("<p>tail</p>")))
        let tail = (formatting.string as NSString).range(of: "tail")
        formatting.setSelectedRange(tail); formatting.toggleStrikethrough(nil)
        let struck = RichTextCodec.html(try NativeRichText.document(from: formatting.attributedString()))
        results.append(("native strikethrough survives rich-text export", struck.contains("<s>tail</s>")))
        try await SelfCheck.finishInputEvent(formatting)
        formatting.undoManager?.removeAllActions()
        formatting.toggleSpoiler(nil)
        let spoiled = RichTextCodec.html(try NativeRichText.document(from: formatting.attributedString()))
        results.append(("native spoiler formatting retains existing marks", spoiled.contains("data-spoiler") && spoiled.contains("<s>tail</s>")))
        try await SelfCheck.finishInputEvent(formatting)
        formatting.undoManager?.undo()
        results.append(("native Undo removes newly authored spoiler formatting", !RichTextCodec.html(try NativeRichText.document(from: formatting.attributedString())).contains("data-spoiler")))
        formatting.textStorage?.setAttributedString(NativeRichText.attributedString(document: try RichTextCodec.parse("<pre><code>protected</code></pre>"), revealSpoilers: true))
        formatting.setSelectedRange(NSRange(location: 0, length: 3))
        let priorCode = formatting.attributedString()
        formatting.toggleSpoiler(nil)
        results.append(("spoiler authoring preserves code blocks that cannot contain inline marks", priorCode.isEqual(to: formatting.attributedString())))
        let originalQuiet = NotificationPreferenceStore.quietHours(accountID: session.account.id)
        let otherAccount = UUID()
        let otherQuiet = QuietHours(startMinute: 60, endMinute: 120, timezone: "UTC", enabled: true)
        NotificationPreferenceStore.setQuietHours(otherQuiet, accountID: otherAccount)
        defer {
            NotificationPreferenceStore.setQuietHours(originalQuiet, accountID: session.account.id)
            NotificationPreferenceStore.setQuietHours(nil, accountID: otherAccount)
        }
        let preferences = AccountPreferencesController(session: session)
        preferences.showWindow(nil)
        await Task.yield()
        preferences.save()
        results.append(("account quiet hours are isolated and can save without a Raven connection", NotificationPreferenceStore.quietHours(accountID: session.account.id) != nil && NotificationPreferenceStore.quietHours(accountID: otherAccount) == otherQuiet))
        preferences.close()
        NotificationPreferenceStore.setQuietHours(nil, accountID: session.account.id)
        preferences.save()
        results.append(("closed preference windows cannot restore removed account settings", NotificationPreferenceStore.quietHours(accountID: session.account.id) == nil))
        parent.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); parent.makeFirstResponder(window.composer)
        for _ in 0..<100 { if parent.isKeyWindow { break }; try await Task.sleep(for: .milliseconds(10)) }
        let searchTarget = NSApp.target(forAction: #selector(ConversationWindow.advancedSearch(_:))) as? ConversationWindow
        results.append(("native search commands resolve through the conversation responder chain", searchTarget === window))
        window.search.stringValue = "  "
        window.performSearch()
        results.append(("empty quick searches do not open the results screen", !window.isSearching))
        _ = NSApp.sendAction(#selector(ConversationWindow.advancedSearch(_:)), to: nil, from: nil)
        results.append(("the native Search with Filters command opens the results screen in the window", window.isSearching && !window.searchView.isHidden))
        window.leaveSearch()
        results.append(("leaving search returns the pane", !window.isSearching && window.searchView.isHidden))
        return results
    }
}
