import AppKit
import NevermoreCore
import RavenProtocol

@MainActor enum EmojiSelfChecks {
    static func run(owner: ConversationWindow) async throws -> [(String, Bool)] {
        guard let session = owner.session, session.demo, let parent = owner.window else { throw AppError.message("Emoji checks require the isolated demo account.") }
        var results: [(String, Bool)] = []
        func wait(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<200 { if condition() { return true }; try await Task.sleep(for: .milliseconds(10)) }
            return condition()
        }
        func table(in parent: NSWindow) -> NSTableView? { parent.attachedSheet?.contentView.flatMap { InteractionSelfChecks.descendants($0, of: NSTableView.self).first } }
        func choose(in parent: NSWindow) { parent.attachedSheet?.contentView.flatMap { InteractionSelfChecks.descendants($0, of: NSButton.self).first { $0.title == "Choose" } }?.performClick(nil) }
        let pick = Task { try await EmojiPickerSheet.pick(on: parent, session: session, purpose: .compose, active: { true }) }
        let loaded = try await wait { table(in: parent)?.numberOfRows == 3 }
        results.append(("native custom emoji picker loads an isolated catalog", loaded))
        if let search = parent.attachedSheet?.contentView.flatMap({ InteractionSelfChecks.descendants($0, of: NSSearchField.self).first }) {
            search.stringValue = "raven"
            (search.delegate as? EmojiPickerSheet)?.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        }
        let filtered = try await wait { table(in: parent)?.numberOfRows == 1 }
        if filtered { table(in: parent)?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false); choose(in: parent) }
        else { pick.cancel() }
        let selected = try await pick.value
        if case .custom(let emoji) = selected { results.append(("custom emoji search returns stable identity and image path", filtered && emoji.id == "fixture-raven" && emoji.imagePath == "/files/raven.png")) }
        else { results.append(("custom emoji search returns stable identity and image path", false)) }
        _ = try await wait { parent.attachedSheet == nil }

        let reaction = Task { try await EmojiPickerSheet.pick(on: parent, session: session, purpose: .reaction, active: { true }) }
        _ = try await wait { parent.attachedSheet != nil }
        let family = "👩🏽‍💻"
        if let field = parent.attachedSheet?.contentView.flatMap({ InteractionSelfChecks.descendants($0, of: NSTextField.self).first { $0.placeholderString == "For example, 👍" } }) {
            field.stringValue = family
            (field.delegate as? EmojiPickerSheet)?.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            choose(in: parent)
        } else { reaction.cancel() }
        let chosenReaction = try await reaction.value
        if case .unicode(let value) = chosenReaction { results.append(("Unicode reaction input preserves joined emoji and modifiers", value == family)) }
        else { results.append(("Unicode reaction input preserves joined emoji and modifiers", false)) }
        _ = try await wait { parent.attachedSheet == nil }

        var active = true
        let context = Task { try await EmojiPickerSheet.pick(on: parent, session: session, purpose: .compose, active: { active }) }
        _ = try await wait { table(in: parent)?.numberOfRows == 3 }
        let oldTable = table(in: parent)
        active = false; session.notify()
        let cancelled = try await context.value
        _ = try await wait { parent.attachedSheet == nil }
        results.append(("invalidating emoji context dismisses the sheet and clears its rows", cancelled == nil && parent.attachedSheet == nil && oldTable?.numberOfRows == 0))

        let channel = RavenChannel(raw: .object(["name": .string("emoji-check-\(UUID())"), "channel_name": .string("Emoji fixture"), "is_archived": .bool(false)]))
        session.channels.append(channel)
        owner.app.open(session: session, channel: channel)
        guard let window = owner.app.windows.last, window !== owner else { throw AppError.message("Emoji composition fixture did not open.") }
        defer { window.close(); session.channels.removeAll { $0.id == channel.id } }
        await window.loadTask?.value; await window.renderTask?.value
        window.insertCustomEmoji(nil)
        let insertion = window.emojiSelectionTask
        let rowsLoaded = try await wait { window.window.flatMap { table(in: $0)?.numberOfRows } == 3 }
        if let parent = window.window, rowsLoaded { table(in: parent)?.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false); choose(in: parent) }
        else { insertion?.cancel() }
        await insertion?.value
        window.composer.insertText("!", replacementRange: window.composer.selectedRange())
        try await SelfCheck.finishInputEvent(window.composer)
        let draft = try window.currentDraft()
        let plainDraft = RichTextCodec.plainText(try RichTextCodec.parse(draft.html), revealSpoilers: true)
        results.append(("custom emoji insertion preserves the entity and following typed text", draft.html.contains("customEmoji") && draft.html.contains("/files/wave.png") && draft.html.components(separatedBy: "customEmoji").count == 2 && plainDraft.hasSuffix("!")))
        await window.saveTask?.value

        // The system palette points at the rect the composer reports for the
        // start of its selection. Opened from the button, that first answer
        // is the button; every other answer stays in the text.
        let anchorLabels = ["the button anchor checks start from composer text and a laid-out emoji button", "Emoji & Symbols opened from the composer button points at the button", "the button anchor answers one selection query and no other text query", "with text selected the button anchor answers the palette's first-character query", "a button anchor the palette never asked for expires", "a selection query during a composition uses up the button anchor at the insertion point", "the emoji button opens nothing while another view keeps the keyboard focus"]
        if let host = window.window {
            host.contentView?.layoutSubtreeIfNeeded()
            let composer = window.composer, caret = composer.selectedRange(), start = NSRange(location: 0, length: 0)
            func rect(_ range: NSRange) -> NSRect { composer.firstRect(forCharacterRange: range, actualRange: nil) }
            let button = host.convertToScreen(window.emojiButton.convert(window.emojiButton.bounds, to: nil))
            let anchor = NSRect(x: button.midX, y: button.minY, width: 0, height: button.height)
            let caretRect = rect(caret), startRect = rect(start)
            let fixtureReady = caret.location > 1 && button.width > 0
            results.append((anchorLabels[0], fixtureReady))
            let prepared = fixtureReady && window.prepareEmojiPalette() && host.firstResponder === composer
            let completion = rect(start), opening = rect(caret), inserting = rect(caret)
            results.append((anchorLabels[1], prepared && opening == anchor && opening != caretRect))
            results.append((anchorLabels[2], prepared && completion == startRect && inserting == caretRect))

            let selected = NSRange(location: 0, length: caret.location), firstCharacter = NSRange(location: 0, length: 1)
            composer.setSelectedRange(selected)
            let selectedRect = rect(selected), firstCharacterRect = rect(firstCharacter)
            let preparedSelection = window.prepareEmojiPalette() && composer.selectedRange() == selected
            let openingSelection = rect(firstCharacter), covering = rect(selected)
            results.append((anchorLabels[3], preparedSelection && openingSelection == anchor && openingSelection != firstCharacterRect && covering == selectedRect))
            composer.setSelectedRange(caret)

            composer.anchorNextCharacterPalette(to: window.emojiButton, for: 0)
            results.append((anchorLabels[4], rect(caret) == caretRect))

            // A separate composer, so that composing touches no draft.
            let composing = ComposerView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
            host.contentView?.addSubview(composing)
            composing.string = "ab"
            composing.setSelectedRange(NSRange(location: 2, length: 0))
            composing.setMarkedText("c", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            func composingRect() -> NSRect { composing.firstRect(forCharacterRange: composing.selectedRange(), actualRange: nil) }
            let markedRect = composingRect(), isComposing = composing.hasMarkedText()
            composing.anchorNextCharacterPalette(to: window.emojiButton)
            let duringComposition = composingRect()
            composing.unmarkText()
            let afterComposition = composingRect()
            composing.removeFromSuperview()
            results.append((anchorLabels[5], isComposing && !composing.hasMarkedText() && duringComposition == markedRect && afterComposition != anchor))

            let holder = FocusHolder(frame: .zero)
            host.contentView?.addSubview(holder)
            let held = host.makeFirstResponder(holder)
            let declined = !window.prepareEmojiPalette()
            results.append((anchorLabels[6], held && declined && host.firstResponder === holder && rect(caret) == caretRect))
            holder.holds = false
            host.makeFirstResponder(composer)
            holder.removeFromSuperview()
        } else { results.append(contentsOf: anchorLabels.map { ($0, false) }) }

        window.insertCustomEmoji(nil)
        let owned = window.emojiSelectionTask
        _ = try await wait { window.window?.attachedSheet != nil }
        window.use(nil)
        await owned?.value
        results.append(("account switching cancels an owned emoji picker", window.window?.attachedSheet == nil && window.composer.string.isEmpty))
        return results
    }
}

/// Keeps the keyboard focus until told to let go, as a field holding
/// input it rejects does.
private final class FocusHolder: NSView {
    var holds = true
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool { !holds }
}
