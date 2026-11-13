import AppKit
import NevermoreCore

/// Composer typing preferences. An absent value means on, so the features
/// work before the user has opened Settings.
enum ComposerPreferences {
    static let markdownShortcutsKey = "composerMarkdownShortcuts"

    static var formatsMarkdownShortcuts: Bool {
        UserDefaults.standard.object(forKey: markdownShortcutsKey) as? Bool != false
    }

    static let linkPreviewsKey = "composerLinkPreviews"

    static var showsLinkPreviews: Bool {
        UserDefaults.standard.object(forKey: linkPreviewsKey) as? Bool != false
    }
}

/// A Markdown shortcut or web address the last key completed, waiting for
/// that key's undo group to close.
struct PendingShortcut {
    enum Match {
        case block(MarkdownShortcut.BlockMatch)
        case inline(MarkdownShortcut.InlineMatch)
        /// The web address in front of the typed space becomes a link.
        case link(endingAt: Int)
    }

    var match: Match
    /// The paragraph's text up to the typed trigger. The shortcut is dropped
    /// when the draft no longer holds exactly this there.
    var guardRange: NSRange
    var guardText: String
}

/// Undo callbacks run on the main actor, like the text view. Keeping the
/// attribute snapshot here lets them restore non-Sendable AppKit values
/// without transferring those values between executors.
@MainActor private final class ComposerCheckpoint {
    let selection: NSRange
    let typingAttributes: [NSAttributedString.Key: Any]?

    init(selection: NSRange, typingAttributes: [NSAttributedString.Key: Any]?) {
        self.selection = selection
        self.typingAttributes = typingAttributes
    }
}

/// How `ComposerView` reacts to typing: Markdown shortcuts as the closing
/// character is typed, and line breaks, Backspace and Down Arrow that respect
/// quotes, lists and code blocks. The text rules themselves are pure functions
/// in ComposerStructure.swift; this file decides when they run and applies
/// their result as one undo step.
///
/// Nothing here runs during input-method composition: marked text is not the
/// user's final text yet.
///
/// Undo: a shortcut is formatted one run-loop step after the key that
/// completed it. `UndoManager` groups everything registered during one event,
/// so formatting inside the key's own event would make a single Undo remove
/// the typed character too. Applied after that group has closed, the first
/// Undo restores exactly what was typed (as in Notes and Raven's web editor)
/// and typing on from there stays literal.
@MainActor extension ComposerView {
    /// The characters that can complete a shortcut. Checked first so ordinary
    /// typing does no matching at all.
    private static let shortcutTriggers: Set<Character> = [" ", "`", "*", "_", "~", "|"]

    /// Before a typed character lands. A caret inside a generated marker
    /// ("│ ", "1. ") moves behind it, and the character does not inherit the
    /// marker's flag; otherwise it would be sent as part of the marker text.
    func prepareForTypedText(_ string: Any, replacementRange: NSRange) {
        flushPendingShortcut()
        guard isEditable, string is String, !hasMarkedText(), replacementRange.location == NSNotFound else { return }
        moveCaretOutOfMarker()
        if typingAttributes[.generated] != nil { typingAttributes.removeValue(forKey: .generated) }
    }

    /// Makes room for text that is about to replace the selection: a
    /// selection that reaches into a marker or across lines is deleted by
    /// the structure rule first, and a caret inside a marker moves behind it.
    func moveCaretOutOfMarker() {
        flushPendingShortcut()
        guard isEditable, !hasMarkedText() else { return }
        deleteStructuredSelection()
        guard let location = NativeRichText.typingLocation(in: attributedString(), for: selectedRange()) else { return }
        setSelectedRange(NSRange(location: location, length: 0))
    }

    /// After a typed character landed: note the shortcut it completed, or
    /// the web address a space ended.
    func completeTypedText(_ string: Any) {
        guard isEditable, !hasMarkedText(), let typed = string as? String, typed.count == 1, let character = typed.first else { return }
        let selection = selectedRange()
        guard selection.length == 0 else { return }

        let value = attributedString()
        guard let match = completedMatch(for: character, in: value, selection: selection) else { return }

        let text = value.string as NSString
        let paragraphStart = text.paragraphRange(for: NSRange(location: selection.location, length: 0)).location
        let guardRange = NSRange(location: paragraphStart, length: selection.location - paragraphStart)
        pendingShortcut = PendingShortcut(match: match, guardRange: guardRange, guardText: text.substring(with: guardRange))
        // Right after the undo manager closes this key's group, and before
        // the next event is handled.
        RunLoop.main.perform(#selector(applyPendingShortcut(_:)), target: self, argument: nil, order: Int(NSUndoCloseGroupingRunLoopOrdering) + 1, modes: [.common])
    }

    /// How long to wait for the key's undo group to close before formatting
    /// anyway (Undo then also removes that key). AppKit closes the group
    /// when the key event finishes, normally before the first retry.
    private static let shortcutDeferralAttempts = 50
    private static let shortcutDeferralStep = DispatchTimeInterval.milliseconds(2)

    @objc func applyPendingShortcut(_ attempt: Any?) {
        let attempts = (attempt as? NSNumber)?.intValue ?? 0
        if pendingShortcut != nil, (undoManager?.groupingLevel ?? 0) > 0, attempts < Self.shortcutDeferralAttempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.shortcutDeferralStep) { [weak self] in
                self?.applyPendingShortcut(NSNumber(value: attempts + 1))
            }
            return
        }
        flushPendingShortcut()
    }

    /// Formats the waiting shortcut now. Every other editing command calls
    /// this first, so none of them ever acts on half-converted text.
    func flushPendingShortcut() {
        guard let pending = pendingShortcut else { return }
        pendingShortcut = nil
        guard isEditable, !hasMarkedText() else { return }

        let value = attributedString()
        let text = value.string as NSString
        let selection = selectedRange()
        let end = NSMaxRange(pending.guardRange)
        guard end <= text.length, text.substring(with: pending.guardRange) == pending.guardText,
              text.paragraphRange(for: NSRange(location: pending.guardRange.location, length: 0)).location == pending.guardRange.location,
              selection.length == 0, selection.location >= end,
              var edit = shortcutEdit(for: pending.match, in: value, selection: selection) else { return }
        // Keys typed since then already carry the right attributes.
        if selection.location != end { edit.typingAttributes = nil }
        apply(edit)
    }

    /// What the typed character completed, if the result would be valid.
    private func completedMatch(for character: Character, in value: NSAttributedString, selection: NSRange) -> PendingShortcut.Match? {
        if ComposerPreferences.formatsMarkdownShortcuts, Self.shortcutTriggers.contains(character) {
            var markdown: PendingShortcut.Match?
            if let block = MarkdownShortcut.block(in: value.string, caret: selection.location) { markdown = .block(block) }
            else if let inline = MarkdownShortcut.inline(in: value.string, caret: selection.location) { markdown = .inline(inline) }
            if let markdown, shortcutEdit(for: markdown, in: value, selection: selection) != nil { return markdown }
        }

        guard character.isWhitespace, selection.location > 0 else { return nil }
        let link = PendingShortcut.Match.link(endingAt: selection.location - 1)
        return shortcutEdit(for: link, in: value, selection: selection) == nil ? nil : link
    }

    private func shortcutEdit(for match: PendingShortcut.Match, in value: NSAttributedString, selection: NSRange) -> ComposerEdit? {
        switch match {
        case .block(let block): return NativeRichText.blockShortcut(block, in: value, selection: selection)
        case .inline(let inline): return NativeRichText.inlineShortcut(inline, in: value, selection: selection)
        case .link(let end):
            guard let linked = NativeRichText.linkingAddress(endingAt: end, in: value) else { return nil }
            return ComposerEdit(text: linked, selection: selection, typingAttributes: nil, actionName: "Link")
        }
    }

    /// Deletes the selection by the structure rule when it reaches into a
    /// marker or across lines. False when AppKit's deletion is right.
    @discardableResult
    func deleteStructuredSelection(actionName: String = "Typing") -> Bool {
        flushPendingShortcut()
        guard isEditable, !hasMarkedText(),
              let edit = NativeRichText.deletingSelection(in: attributedString(), selection: selectedRange(), actionName: actionName) else { return false }
        return apply(edit)
    }

    func insertStructuredLineBreak() -> Bool {
        flushPendingShortcut()
        deleteStructuredSelection()
        linkAddressBeforeCaret()
        guard isEditable, !hasMarkedText(),
              let edit = NativeRichText.lineBreak(in: attributedString(), selection: selectedRange(), typing: typingAttributes) else { return false }
        return apply(edit)
    }

    func deleteStructuredBackward() -> Bool {
        flushPendingShortcut()
        if selectedRange().length > 0 { return deleteStructuredSelection() }
        guard isEditable, !hasMarkedText(), let edit = NativeRichText.backspace(in: attributedString(), selection: selectedRange()) else { return false }
        return apply(edit)
    }

    func deleteStructuredForward() -> Bool {
        flushPendingShortcut()
        if selectedRange().length > 0 { return deleteStructuredSelection() }
        guard isEditable, !hasMarkedText(), let edit = NativeRichText.forwardDelete(in: attributedString(), selection: selectedRange()) else { return false }
        return apply(edit)
    }

    /// Option-Backspace at the start of a quoted line or list item acts like
    /// Backspace there; AppKit would delete the marker as if it were a word.
    func deleteStructuredWordBackward() -> Bool {
        flushPendingShortcut()
        let selection = selectedRange()
        if selection.length > 0 { return deleteStructuredSelection() }
        guard isEditable, !hasMarkedText() else { return false }
        let value = attributedString()
        let target = NativeRichText.paragraph(in: value, at: selection.location)
        guard target.markerRange.length > 0, selection.location <= NSMaxRange(target.markerRange),
              let edit = NativeRichText.backspace(in: value, selection: selection) else { return false }
        return apply(edit)
    }

    /// `wholeParagraph` is true for the command that deletes to the start
    /// of the paragraph instead of the start of the wrapped line.
    func deleteStructuredToLineStart(wholeParagraph: Bool) -> Bool {
        flushPendingShortcut()
        let selection = selectedRange()
        if selection.length > 0 { return deleteStructuredSelection() }
        guard isEditable, !hasMarkedText() else { return false }
        let value = attributedString()
        let target = NativeRichText.paragraph(in: value, at: selection.location)
        guard target.markerRange.length > 0,
              let edit = NativeRichText.deleteToLineStart(in: value, selection: selection, onFirstLine: wholeParagraph || isOnFirstLine(selection.location, of: target)) else { return false }
        return apply(edit)
    }

    /// Whether `location` is laid out in the same line as the paragraph's
    /// marker. Without a layout (a view not yet in a window) every paragraph
    /// counts as one line.
    private func isOnFirstLine(_ location: Int, of paragraph: ComposerParagraph) -> Bool {
        guard let layoutManager, let textContainer, paragraph.range.length > 0 else { return true }
        layoutManager.ensureLayout(for: textContainer)
        let last = max(paragraph.range.location, min(location, NSMaxRange(paragraph.range)) - 1)
        var firstLine = NSRange(), caretLine = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: paragraph.range.location), effectiveRange: &firstLine)
        layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: last), effectiveRange: &caretLine)
        return firstLine == caretLine
    }

    func moveBelowCodeBlock() -> Bool {
        flushPendingShortcut()
        guard isEditable, !hasMarkedText(),
              let edit = NativeRichText.lineBelowCodeBlock(in: attributedString(), selection: selectedRange(), typing: typingAttributes) else { return false }
        return apply(edit)
    }

    /// Applies a proposed rewrite as one undo step. The result must pass the
    /// same checks as sending; when it does not, nothing changes and the
    /// caller falls back to AppKit's plain behavior.
    @discardableResult
    func apply(_ edit: ComposerEdit) -> Bool {
        guard let document = try? NativeRichText.document(from: edit.text), document.canEdit,
              (try? RichTextCodec.parse(RichTextCodec.html(document)))?.canEdit == true else { return false }

        if let change = NativeRichText.replacement(from: attributedString(), to: edit.text) {
            let before = ComposerCheckpoint(selection: selectedRange(), typingAttributes: typingAttributes)
            let after = ComposerCheckpoint(selection: edit.selection, typingAttributes: edit.typingAttributes)
            // Seal the typing run first: AppKit registers this change's undo
            // inside shouldChangeText and would otherwise merge it with the
            // key that was just typed.
            breakUndoCoalescing()
            let undo = undoManager
            // A rewrite outside any key event (a deferred shortcut) must be
            // a closed group of its own. Left to automatic grouping, its
            // group would stay open until the next event ends and swallow
            // the next typed characters.
            let standalone = undo?.groupingLevel == 0 && undo?.groupsByEvent == true
            if standalone { undo?.groupsByEvent = false }
            undo?.beginUndoGrouping()
            defer {
                undo?.endUndoGrouping()
                if standalone { undo?.groupsByEvent = true }
                breakUndoCoalescing()
            }
            registerEditingCheckpoint(undone: before, redone: after)
            // Not insertText(_:replacementRange:): it fills attributes the new
            // text lacks from the typing attributes, which would put a
            // paragraph that just left a quote straight back into it.
            guard shouldChangeText(in: change.range, replacementString: change.text.string) else { return false }
            textStorage?.replaceCharacters(in: change.range, with: change.text)
            didChangeText()
            registerEditingCheckpoint(undone: before, redone: after)
            undo?.setActionName(edit.actionName)
        }

        setSelectedRange(edit.selection)
        if let typing = edit.typingAttributes { typingAttributes = typing }
        return true
    }

    /// Restore both the caret and typing context: otherwise the next key
    /// could replace restored text or inherit the shortcut's formatting.
    /// A checkpoint on each side of the change makes the correct state run
    /// last in either direction.
    private func registerEditingCheckpoint(undone: ComposerCheckpoint, redone: ComposerCheckpoint) {
        undoManager?.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.registerEditingCheckpoint(undone: undone, redone: redone)
                let state = target.undoManager?.isUndoing == true ? undone : redone
                guard NSMaxRange(state.selection) <= target.string.utf16.count else { return }
                target.setSelectedRange(state.selection)
                if let typing = state.typingAttributes { target.typingAttributes = typing }
            }
        }
    }
}
