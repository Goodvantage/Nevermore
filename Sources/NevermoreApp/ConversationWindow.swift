import AppKit
import QuickLookUI
import RavenProtocol
import NevermoreCore

@MainActor final class ComposerView: NSTextView {
    /// NSTextView takes Quick Look whenever it is first responder, ahead of
    /// an attachment preview that joins the window's responder chain, so
    /// a clicked file opened the file actions window instead of a preview.
    override nonisolated func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { false }
    var sharedUndoManager: UndoManager?
    override var undoManager: UndoManager? { sharedUndoManager ?? super.undoManager }
    /// A layout manager's storage swap does not clamp the text view's old
    /// selection. Restore a valid insertion point, never a selection from
    /// the previous document that could overwrite part of this draft.
    func useTextStorage(_ storage: NSTextStorage) {
        let insertionPoint = min(selectedRange().location, storage.length)
        if let layout = layoutManager, layout.textStorage !== storage {
            // replaceTextStorage moves every layout manager sharing the old
            // storage. Move only this editor, leaving peer windows in place.
            layout.textStorage?.removeLayoutManager(layout)
            storage.addLayoutManager(layout)
        }
        setSelectedRange(NSRange(location: insertionPoint, length: 0))
        if storage.length == 0 { typingAttributes = NativeRichText.plainTypingAttributes }
    }
    var alwaysInsertNewline = false
    var onSend: (() -> Void)?
    var onFiles: (([URL]) -> Void)?
    var onPromisedFiles: (([any PromisedFileSource]) -> Void)?
    var onEscape: (() -> Void)?
    var onCompletionKey: ((NSEvent) -> Bool)?
    var onEditLast: (() -> Bool)?
    var onImage: ((Data, String) -> Void)?
    var onAttachmentRequest: (() -> Bool)?
    var onPasteError: ((String) -> Void)?
    static let clipboardImageLimit = 20 * 1024 * 1024
    static let editingAttachmentMessage = "Attachments cannot be added while editing. Send a new message with the file."
    /// Drawn while the composer is empty, like Messages' "iMessage" prompt.
    var placeholder = "" {
        didSet {
            needsDisplay = true
            // The drawn placeholder is invisible to VoiceOver otherwise.
            setAccessibilityPlaceholderValue(placeholder.isEmpty ? nil : placeholder)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText(), !placeholder.isEmpty else { return }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: [.font: ComposerMetrics.font, .foregroundColor: NSColor.placeholderTextColor])
    }
    override func didChangeText() {
        correctAutomaticLinks()
        if string.isEmpty, !hasMarkedText() { typingAttributes = NativeRichText.plainTypingAttributes }
        super.didChangeText()
        needsDisplay = true
    }
    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        guard affectedRanges.allSatisfy({ NativeRichText.allowsTableChange(in: attributedString(), range: $0.rangeValue, replacingText: replacementStrings != nil) }) else { NSSound.beep(); return false }
        if replacementStrings != nil { adoptAddressLinks(near: affectedRanges.map(\.rangeValue)) }
        return super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
    }

    private weak var paletteAnchor: NSView?
    private var paletteAnchorExpires: TimeInterval = 0
    /// Long enough for the palette's process to launch on a busy Mac (its
    /// query arrived 0.2-0.5 s after the click when measured cold), short
    /// enough that a palette which never opens leaves nothing behind.
    static let paletteAnchorLifetime: TimeInterval = 5

    /// The system Emoji & Symbols popover takes no anchor. It points at the
    /// rect this view reports for the start of its selection, which it asks
    /// for once as it opens. Call this before opening the palette from a
    /// button, and that query is answered with the button, so the popover
    /// appears where the click was instead of at the insertion point across
    /// the window.
    ///
    /// The redirection is single-use and expires: the palette asks again
    /// before it inserts the chosen character, and input methods ask the
    /// same question, all of which need the real insertion point. If the
    /// palette never asks, because it did not open or the click closed it,
    /// the next such question within the lifetime gets the button once.
    func anchorNextCharacterPalette(to view: NSView, for lifetime: TimeInterval = ComposerView.paletteAnchorLifetime) {
        paletteAnchor = view; paletteAnchorExpires = ProcessInfo.processInfo.systemUptime + lifetime
    }

    override func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let textRect = super.firstRect(forCharacterRange: range, actualRange: actualRange)
        guard let view = paletteAnchor else { return textRect }
        guard let window, view.window === window, ProcessInfo.processInfo.systemUptime < paletteAnchorExpires else { paletteAnchor = nil; return textRect }
        // The palette asks where the selection starts: the empty selection
        // itself, or the first character of selected text. Input methods ask
        // about marked text and completions about the range being completed.
        let selection = selectedRange()
        guard range.location == selection.location, range.length <= max(selection.length, 1) else { return textRect }
        paletteAnchor = nil
        // During a composition this may be the input method placing its
        // candidates, which belong at the insertion point. The anchor is
        // spent either way, so it cannot outlast the composition.
        guard !hasMarkedText() else { return textRect }
        // The popover's arrow lands on the rect's left edge, above or
        // below it: a zero-width rect at the view's centre points it there.
        let frame = window.convertToScreen(view.convert(view.bounds, to: nil))
        return NSRect(x: frame.midX, y: frame.minY, width: 0, height: frame.height)
    }

    /// Tab and Shift-Tab move focus, as in Mail's and Messages' fields;
    /// Option-Tab still inserts a tab through insertTabIgnoringFieldEditor:.
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
    /// Drafts keep a per-conversation undo manager shared by every window
    /// showing that conversation. NSWindow's undo: would use the window's own
    /// manager, so Edit ▸ Undo/Redo are answered here while the composer has
    /// focus, with the standard "Undo Typing"-style titles.
    @objc func undo(_ sender: Any?) { guard undoManager?.canUndo == true else { NSSound.beep(); return }; undoManager?.undo() }
    @objc func redo(_ sender: Any?) { guard undoManager?.canRedo == true else { NSSound.beep(); return }; undoManager?.redo() }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            (item as? NSMenuItem)?.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo == true && !hasMarkedText()
        }
        if item.action == #selector(redo(_:)) {
            (item as? NSMenuItem)?.title = undoManager?.redoMenuItemTitle ?? "Redo"
            return undoManager?.canRedo == true && !hasMarkedText()
        }
        if item.action == #selector(toggleSpoiler(_:)) {
            let selected = selectedRange()
            let enabled: Bool
            if selected.length == 0 {
                guard NativeRichText.canAuthorSpoiler(typingAttributes) else { return false }
                enabled = NativeRichText.isSpoiler(typingAttributes)
            } else {
                guard let state = try? NativeRichText.spoilerSelection(in: attributedString(), range: selected) else { return false }
                enabled = state.enabled
            }
            (item as? NSMenuItem)?.state = enabled ? .on : .off
            return isEditable && !hasMarkedText()
        }
        return super.validateUserInterfaceItem(item)
    }
    @objc func toggleBoldface(_ sender: Any?) { toggleTrait(.boldFontMask); nameFormattingUndo("Bold") }
    @objc func toggleItalics(_ sender: Any?) { toggleTrait(.italicFontMask); nameFormattingUndo("Italic") }
    private func nameFormattingUndo(_ name: String) { if selectedRange().length > 0 { undoManager?.setActionName(name) } }
    @objc func toggleUnderline(_ sender: Any?) {
        guard isEditable else { return }
        let range = selectedRange()
        let old = range.length > 0 ? attributedString().attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0 : typingAttributes[.underlineStyle] as? Int ?? 0
        if range.length == 0 { typingAttributes[.underlineStyle] = old == 0 ? 1 : 0; return }
        let updated = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: range)); updated.addAttribute(.underlineStyle, value: old == 0 ? 1 : 0, range: NSRange(location: 0, length: updated.length)); replaceFormatting(range, with: updated)
        undoManager?.setActionName("Underline")
    }
    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard isEditable else { return }
        let range = selectedRange(); let manager = NSFontManager.shared
        let font = (range.length > 0 ? attributedString().attribute(.font, at: range.location, effectiveRange: nil) as? NSFont : typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 14)
        let remove = manager.traits(of: font).contains(trait)
        func convert(_ font: NSFont) -> NSFont { remove ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait) }
        if range.length == 0 { typingAttributes[.font] = convert(font); return }
        let old = attributedString().attributedSubstring(from: range); let updated = NSMutableAttributedString(attributedString: old)
        old.enumerateAttribute(.font, in: NSRange(location: 0, length: old.length)) { value, subrange, _ in updated.addAttribute(.font, value: convert(value as? NSFont ?? font), range: subrange) }
        replaceFormatting(range, with: updated)
    }
    func replaceFormatting(_ range: NSRange, with value: NSAttributedString) {
        guard isEditable, NativeRichText.allowsTableChange(in: attributedString(), range: range, replacingText: false) else { return }
        guard NSMaxRange(range) <= attributedString().length else { return }
        let old = attributedString().attributedSubstring(from: range)
        undoManager?.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { target.replaceFormatting(range, with: old) } }
        let selection = selectedRanges, affinity = selectionAffinity
        textStorage?.replaceCharacters(in: range, with: value)
        setSelectedRanges(selection, affinity: affinity, stillSelecting: false)
        didChangeText()
    }
    // Markdown shortcuts and structure-aware keys; the rules are in
    // ComposerTyping.swift and ComposerStructure.swift.
    var pendingShortcut: PendingShortcut?
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let range = replacementRange.location == NSNotFound ? selectedRange() : replacementRange
        guard NativeRichText.allowsTableChange(in: attributedString(), range: range, replacingText: true) else { NSSound.beep(); return }
        if typingAttributes[.editableTable] != nil { typingAttributes = NativeRichText.plainTypingAttributes }
        prepareForTypedText(string, replacementRange: replacementRange)
        super.insertText(string, replacementRange: replacementRange)
        completeTypedText(string)
    }
    override func insertNewline(_ sender: Any?) { if !insertStructuredLineBreak() { super.insertNewline(sender) } }
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) { if !insertStructuredLineBreak() { super.insertNewlineIgnoringFieldEditor(sender) } }
    override func deleteBackward(_ sender: Any?) { if !deleteStructuredBackward() { super.deleteBackward(sender) } }
    override func deleteForward(_ sender: Any?) { if !deleteStructuredForward() { super.deleteForward(sender) } }
    override func deleteWordBackward(_ sender: Any?) { if !deleteStructuredWordBackward() { super.deleteWordBackward(sender) } }
    override func deleteToBeginningOfLine(_ sender: Any?) { if !deleteStructuredToLineStart(wholeParagraph: false) { super.deleteToBeginningOfLine(sender) } }
    override func deleteToBeginningOfParagraph(_ sender: Any?) { if !deleteStructuredToLineStart(wholeParagraph: true) { super.deleteToBeginningOfParagraph(sender) } }
    override func delete(_ sender: Any?) { if !deleteStructuredSelection(actionName: "Delete") { super.delete(sender) } }
    override func cut(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), NativeRichText.deletingSelection(in: attributedString(), selection: selectedRange()) != nil else { super.cut(sender); return }
        copy(sender)
        // A rewrite that fails its checks changes nothing; the plain
        // deletion then removes what was copied, as for Delete.
        if !deleteStructuredSelection(actionName: "Cut") { super.delete(sender) }
    }
    override func moveDown(_ sender: Any?) { if !moveBelowCodeBlock() { super.moveDown(sender) } }
    override func keyDown(with event: NSEvent) {
        guard isEditable else { super.keyDown(with: event); return }
        if !hasMarkedText(), onCompletionKey?(event) == true { return }
        if !hasMarkedText(), event.keyCode == 126, string.isEmpty, onEditLast?() == true { return }
        // While an input method composes, Escape cancels the conversion there.
        if !hasMarkedText(), event.keyCode == 53 { onEscape?(); return }
        if event.keyCode == 36 || event.keyCode == 76 {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !hasMarkedText() {
                if modifiers.contains(.command) || (!alwaysInsertNewline && !UserDefaults.standard.bool(forKey: ComposerSendKey.defaultsKey) && modifiers.intersection([.shift,.option,.control]).isEmpty) { onSend?() }
                else { insertNewlineIgnoringFieldEditor(nil) }
                return
            }
        }
        super.keyDown(with: event)
    }
    override func paste(_ sender: Any?) {
        guard isEditable else { return }
        guard !pasteAttachments(from: .general) else { return }
        guard NSPasteboard.general.availableType(from: [.rtf, .string]) != nil, !pasteAsLink(NSPasteboard.general.string(forType: .string)) else { return }
        // Bound the paste like the Markdown path: an oversized text paste is
        // refused here instead of inserting and failing at the next draft save.
        if let text = NSPasteboard.general.string(forType: .string),
           string.utf8.count - selectedRange().length + text.utf8.count > RichTextCodec.maximumBytes {
            onPasteError?(RichTextError.tooLarge.localizedDescription)
            return
        }
        // Only pasted text replaces the selection; files and pictures are staged.
        moveCaretOutOfMarker()
        pasteLinkingAddresses { super.paste(sender) }
    }
    // Paste only the text formats we handle here. Attachments use their own
    // staging path, and the HTML importer can load remote resources.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.rtf, .string] }

    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if type == .string { return super.readSelection(from: pasteboard, type: type) }
        let range = rangeForUserTextChange
        guard type == .rtf, range.location != NSNotFound, let data = pasteboard.data(forType: .rtf),
              let text = NSMutableAttributedString(rtf: data, documentAttributes: nil),
              text.length > 0 else { return false }

        // Keep the font traits that the Raven codec understands. The source
        // family and size would otherwise carry over into subsequent typing.
        let manager = NSFontManager.shared
        let fullRange = NSRange(location: 0, length: text.length)
        var changed = false
        text.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            let traits = (value as? NSFont).map { manager.traits(of: $0) } ?? []
            let base = traits.contains(.fixedPitchFontMask)
                ? NSFont.monospacedSystemFont(ofSize: NativeRichText.composerFontSize - 1, weight: .regular)
                : ComposerMetrics.font
            let emphasis = traits.intersection([.boldFontMask, .italicFontMask])
            let font = emphasis.isEmpty ? base : manager.convert(base, toHaveTrait: emphasis)
            if font != value as? NSFont {
                text.addAttribute(.font, value: font, range: range)
                changed = true
            }
        }
        guard changed else { return super.readSelection(from: pasteboard, type: .rtf) }

        if selectedRanges.count == 1 { return performValidatedReplacement(in: range, with: text) }

        // AppKit handles discontiguous selections as a single paste across
        // ranges. Give it normalized RTF so it can keep its selection and undo behavior.
        guard let normalized = text.rtf(from: fullRange, documentAttributes: [:]) else { return false }
        let cleaned = NSPasteboard.withUniqueName()
        defer { cleaned.releaseGlobally() }
        guard cleaned.setData(normalized, forType: .rtf) else { return false }
        return super.readSelection(from: cleaned, type: .rtf)
    }
    static func hasAttachments(_ pasteboard: NSPasteboard) -> Bool {
        PromisedFileReceiver.containsPromises(pasteboard) || pasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil
    }
    @discardableResult func pasteAttachments(from pasteboard: NSPasteboard) -> Bool {
        guard Self.hasAttachments(pasteboard) else { return false }
        guard onAttachmentRequest?() != false else { return true }
        if PromisedFileReceiver.containsPromises(pasteboard) {
            let sources = PromisedFileReceiver.sources(from: pasteboard)
            if !sources.isEmpty {
                if let onPromisedFiles { onPromisedFiles(sources) }
                else { onPasteError?("The copied files could not be received. Try copying them again.") }
                return true
            }
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            if let onFiles { onFiles(urls) } else { onPasteError?("Files cannot be attached here. Send a new message with the file.") }
            return true
        }
        for (type, ext) in [(NSPasteboard.PasteboardType.png, "png"), (.tiff, "tiff")] {
            guard pasteboard.availableType(from: [type]) != nil else { continue }
            guard let data = pasteboard.data(forType: type) else { onPasteError?("The copied image could not be read. Try copying it again."); return true }
            guard data.count <= Self.clipboardImageLimit else { onPasteError?("The copied image exceeds the 20 MB paste limit. Attach a smaller image."); return true }
            if let onImage { onImage(data, ext) } else { onPasteError?("Images cannot be attached here. Send a new message with the image.") }
            return true
        }
        onPasteError?("The copied file could not be read. Try copying it again.")
        return true
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        if onPromisedFiles != nil && PromisedFileReceiver.containsPromises(sender.draggingPasteboard) { return .copy }
        if onFiles != nil && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .copy }
        return super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard isEditable else { return [] }
        if onPromisedFiles != nil && PromisedFileReceiver.containsPromises(sender.draggingPasteboard) { return .copy }
        if onFiles != nil && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return .copy }
        return super.draggingUpdated(sender)
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        if onPromisedFiles != nil && PromisedFileReceiver.containsPromises(sender.draggingPasteboard) { return true }
        if onFiles != nil && sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return true }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isEditable else { return false }
        if let onPromisedFiles, PromisedFileReceiver.containsPromises(sender.draggingPasteboard) {
            let sources = PromisedFileReceiver.sources(from: sender.draggingPasteboard)
            if !sources.isEmpty { onPromisedFiles(sources); return true }
        }
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty { guard let onFiles else { return false }; onFiles(urls); return true }
        return super.performDragOperation(sender)
    }
}
@MainActor final class TranscriptView: LiveResizeTextView {
    weak var messageAccessibility: TranscriptAccessibility?
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? { messageAccessibility?.actions() ?? super.accessibilityCustomActions() }
    var preview: (() -> Void)?
    var codeMenuItems: (() -> [NSMenuItem])?
    var messageMenu: (() -> NSMenu?)?
    var onHover: ((NSPoint?) -> Void)?
    var onUserSelection: (() -> Void)?
    /// The message the caret is in, tinted so Message menu commands have a
    /// visible target. Text selections keep the standard selection color.
    var highlightRect: NSRect? { didSet { if oldValue != highlightRect { needsDisplay = true } } }
    /// Margin between the pane edge and the avatar column.
    let readingColumnInset: CGFloat = 24
    /// Sizes for the avatar column and decorations; set before the text so
    /// the container is laid out once.
    var metrics = TranscriptMetrics(size: 14, compact: false) { didSet { if oldValue != metrics { applyColumnInsets(); needsDisplay = true } } }
    var avatarImage: ((String) -> NSImage?)?
    /// Start of the hovered and caret messages; a message without a header
    /// shows its time in the avatar column while either points at it.
    var hoverMessageLocation: Int? { didSet { if oldValue != hoverMessageLocation { invalidateGutterTime(oldValue); invalidateGutterTime(hoverMessageLocation) } } }
    var caretMessageLocation: Int? { didSet { if oldValue != caretMessageLocation { invalidateGutterTime(oldValue); invalidateGutterTime(caretMessageLocation) } } }
    /// Redraws only the first line of a message, where its time appears.
    private func invalidateGutterTime(_ location: Int?) {
        guard let location, let storage = textStorage, location < storage.length,
              storage.attribute(.nevermoreGutterTime, at: location, effectiveRange: nil) != nil, let layout = layoutManager else { return }
        let glyph = layout.glyphIndexForCharacter(at: location)
        guard glyph < layout.numberOfGlyphs else { return }
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        // The time sits left of the text container, in the avatar column.
        setNeedsDisplay(NSRect(x: bounds.minX, y: line.minY + textContainerOrigin.y - 2, width: bounds.width, height: line.height + 4))
    }
    /// Text starts right of the avatar column and ends one reading inset
    /// from the right edge. NSTextView insets both sides equally, so the
    /// inset holds half the column and the origin shifts by the other half.
    func applyColumnInsets() {
        textContainerInset = NSSize(width: readingColumnInset + metrics.gutter / 2, height: textContainerInset.height)
        invalidateTextContainerOrigin()
    }
    override var textContainerOrigin: NSPoint {
        let origin = super.textContainerOrigin
        return NSPoint(x: origin.x + metrics.gutter / 2, y: origin.y)
    }
    /// NSTextView invalidates only the text it changed, inside the text
    /// container. Avatars, divider rules and chip outlines extend past it,
    /// so every invalidation covers the full row.
    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        super.setNeedsDisplay(NSRect(x: bounds.minX, y: invalidRect.minY, width: bounds.width, height: invalidRect.height), avoidAdditionalLayout: flag)
    }
    private var hoverTracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); hoverTracking = area
    }
    /// True over a reaction chip that a click would toggle.
    var onChipHover: ((NSPoint) -> Bool)?
    /// The conversation's undo manager, which the composer owns. With it,
    /// Edit ▸ Undo takes back a send or a reaction (and undoes typing in
    /// the composer) while the transcript has the focus too. NSWindow's
    /// own undo: would use the window's separate, empty manager.
    var borrowedUndoManager: (() -> UndoManager?)?
    override var undoManager: UndoManager? { borrowedUndoManager?() ?? super.undoManager }
    @objc func undo(_ sender: Any?) { guard undoManager?.canUndo == true else { NSSound.beep(); return }; undoManager?.undo() }
    @objc func redo(_ sender: Any?) { guard undoManager?.canRedo == true else { NSSound.beep(); return }; undoManager?.redo() }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) {
            (item as? NSMenuItem)?.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return undoManager?.canUndo == true
        }
        if item.action == #selector(redo(_:)) {
            (item as? NSMenuItem)?.title = undoManager?.redoMenuItemTitle ?? "Redo"
            return undoManager?.canRedo == true
        }
        return super.validateUserInterfaceItem(item)
    }
    /// The hover bar floats inside this text view. NSTextView sets its I-beam
    /// on every pointer move, which would hide that the bar holds buttons.
    /// Reaction chips are buttons too.
    private func isOverHoverBar(_ point: NSPoint) -> Bool { subviews.contains { ($0 is MessageHoverBar || $0 is InkBlot) && !$0.isHidden && $0.frame.contains(point) } || onChipHover?(point) == true }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isOverHoverBar(point) { NSCursor.arrow.set() } else if replyTarget(at: point) != nil { NSCursor.pointingHand.set() } else { super.mouseMoved(with: event) }
        hoveredCardLocation = isOverHoverBar(point) ? nil : cardLocation(at: point)
        onHover?(point)
    }
    /// The link preview or file card under the pointer, drawn with a
    /// stronger edge so it reads as the one thing a click opens.
    var hoveredCardLocation: Int? { didSet { if oldValue != hoveredCardLocation { invalidateCard(oldValue); invalidateCard(hoveredCardLocation) } } }
    private func invalidateCard(_ location: Int?) {
        guard let location, let storage = textStorage, location < storage.length, let layout = layoutManager,
              let cell = (storage.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell as? TranscriptCardCell else { return }
        cell.isHovered = location == hoveredCardLocation
        guard let frame = AnimatedImageOverlay.attachmentFrame(at: location, layout: layout, origin: textContainerOrigin) else { return }
        setNeedsDisplay(frame.insetBy(dx: -2, dy: -2))
    }
    /// The card whose drawn frame holds `point`, as a character location.
    func cardLocation(at point: NSPoint) -> Int? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let glyph = layout.glyphIndex(for: NSPoint(x: point.x - origin.x, y: point.y - origin.y), in: container)
        guard glyph < layout.numberOfGlyphs else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length, (storage.attribute(.attachment, at: index, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell is TranscriptCardCell,
              let frame = AnimatedImageOverlay.attachmentFrame(at: index, layout: layout, origin: origin), frame.contains(point) else { return nil }
        return index
    }
    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isOverHoverBar(point) { NSCursor.arrow.set() } else if replyTarget(at: point) != nil { NSCursor.pointingHand.set() } else { super.cursorUpdate(with: event) }
    }
    /// The message a reply quote under `point` answers, if the point is on
    /// the quote's text rather than in the empty space beside it.
    func replyTarget(at point: NSPoint) -> String? {
        guard let layout = layoutManager, let container = textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let origin = textContainerOrigin
        let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
        let glyph = layout.glyphIndex(for: local, in: container)
        guard glyph < layout.numberOfGlyphs, layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).contains(local) else { return nil }
        let index = layout.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(.nevermoreReplyTarget, at: index, effectiveRange: nil) as? String
    }
    /// A click on a reply quote, after AppKit has handled it as text: a drag
    /// that selects text from a quote stays a selection.
    var onReplyQuotePress: ((String) -> Void)?
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredCardLocation = nil
        let point = convert(event.locationInWindow, from: nil)
        if !subviews.contains(where: { !$0.isHidden && $0.frame.contains(point) }) { onHover?(nil) }
    }
    /// A press on a reaction chip: a click toggles the reaction and a drag
    /// peels the reader's own off. True when the press was handled.
    var onChipPress: ((NSEvent) -> Bool)?
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty, let onChipPress, trackPress({ onChipPress(event) }) { return }
        super.mouseDown(with: event); onUserSelection?()
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty, selectedRange().length == 0,
           let target = replyTarget(at: convert(event.locationInWindow, from: nil)) { onReplyQuotePress?(target) }
    }
    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting, (highlightRect != nil || window?.firstResponder === self) { onUserSelection?() }
    }
    override func becomeFirstResponder() -> Bool { let accepted = super.becomeFirstResponder(); if highlightRect != nil { needsDisplay = true }; return accepted }
    override func resignFirstResponder() -> Bool { let accepted = super.resignFirstResponder(); if highlightRect != nil { needsDisplay = true }; return accepted }
    override func draw(_ dirtyRect: NSRect) {
        if let highlightRect, highlightRect.intersects(dirtyRect) {
            // Like a table selection: accent while the transcript has focus,
            // neutral while typing elsewhere in the window.
            let focused = window?.firstResponder === self && window?.isKeyWindow == true
            (focused ? NSColor.themeAccent.withAlphaComponent(0.10) : NSColor.unemphasizedSelectedContentBackgroundColor.withAlphaComponent(0.6)).setFill()
            NSBezierPath(roundedRect: highlightRect, xRadius: 8, yRadius: 8).fill()
        }
        drawDecorations(in: dirtyRect)
        super.draw(dirtyRect)
    }
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] { [.rtf, .string] }
    /// Transcript text as it leaves the app, for copies and printing:
    /// without reading controls, with full timestamps where headers show
    /// only the time, and without presentation commands or editor-only
    /// attributes reaching Mail, Services, drag destinations or paper.
    /// What an export is for. A copy carries text, so a picture becomes its
    /// file name; a printout keeps the picture.
    enum ExportPurpose { case copy, print }
    static func prepareForExport(_ output: NSMutableAttributedString, for purpose: ExportPurpose) {
        var controls: [NSRange] = []
        output.enumerateAttribute(.nevermoreReadingControl, in: NSRange(location: 0, length: output.length)) { value, range, _ in if value as? Bool == true { controls.append(range) } }
        for range in controls.reversed() { output.deleteCharacters(in: range) }
        var substitutions: [(NSRange, String)] = []
        output.enumerateAttribute(.nevermoreCopyText, in: NSRange(location: 0, length: output.length)) { value, range, _ in if let text = value as? String { substitutions.append((range, text)) } }
        if purpose == .copy {
            output.enumerateAttribute(.nevermorePictureName, in: NSRange(location: 0, length: output.length)) { value, range, _ in if let name = value as? String { substitutions.append((range, name)) } }
        }
        for (range, text) in substitutions.sorted(by: { $0.0.location > $1.0.location }) {
            output.replaceCharacters(in: range, with: text)
            // A file card, or a copied picture, leaves as its file name:
            // text, not the attachment the name stands in for.
            output.removeAttribute(.attachment, range: NSRange(location: range.location, length: (text as NSString).length))
        }
        // Centered lines are offset for the avatar column, which exports lack.
        var centered: [(NSRange, NSParagraphStyle)] = []
        output.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: output.length)) { value, range, _ in
            guard let style = value as? NSParagraphStyle, style.alignment == .center, style.tailIndent < 0, let copy = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            copy.tailIndent = 0; centered.append((range, copy))
        }
        for (range, style) in centered { output.addAttribute(.paragraphStyle, value: style, range: range) }
        // Internal command links open previews here; an export keeps the text.
        var deadLinks: [NSRange] = []
        output.enumerateAttribute(.link, in: NSRange(location: 0, length: output.length)) { value, range, _ in
            let url = (value as? URL) ?? (value as? String).flatMap { URL(string: $0) }
            if url?.scheme?.hasPrefix("nevermore-") == true { deadLinks.append(range) }
        }
        for range in deadLinks { output.removeAttribute(.link, range: range) }
        var privateKeys = Set<NSAttributedString.Key>([.nevermoreReadingControl, .toolTip])
        output.enumerateAttributes(in: NSRange(location: 0, length: output.length)) { attributes, _, _ in
            for key in attributes.keys where key.rawValue.hasPrefix("Nevermore.") { privateKeys.insert(key) }
        }
        for key in privateKeys { output.removeAttribute(key, range: NSRange(location: 0, length: output.length)) }
    }
    override func writeSelection(to pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let output = NSMutableAttributedString(string: "")
        for selection in selectedRanges {
            let range = selection.rangeValue
            guard range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= attributedString().length else { continue }
            if output.length > 0 { output.append(NSAttributedString(string: "\n")) }
            output.append(attributedString().attributedSubstring(from: range))
        }
        Self.prepareForExport(output, for: .copy)
        switch type {
        case .string: return pasteboard.setString(NativeTables.plainText(output), forType: .string)
        case .rtf:
            guard let data = try? output.data(from: NSRange(location: 0, length: output.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else { return false }
            return pasteboard.setData(data, forType: .rtf)
        default: return false
        }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        if selectedRange().length == 0 {
            let point = convert(event.locationInWindow, from: nil)
            setSelectedRange(NSRange(location: characterIndexForInsertion(at: point), length: 0))
        }
        onUserSelection?()
        if let custom = messageMenu?() { return custom }
        let menu = super.menu(for: event) ?? NSMenu()
        if let extra = codeMenuItems?(), !extra.isEmpty { menu.addItem(.separator()); for item in extra { menu.addItem(item) } }
        return menu
    }
    var onTypeToCompose: ((NSEvent) -> Bool)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, selectedRange().length == 0 { preview?(); return }
        // Typing while reading starts a message, as in Messages and Slack.
        if onTypeToCompose?(event) == true { return }
        super.keyDown(with: event)
    }
    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(sender) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(sender) }
}
@MainActor final class ConversationWindow: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate, NSToolbarItemValidation, NSMenuDelegate, NSSearchFieldDelegate {
    unowned let app: AppDelegate
    let windowID: UUID
    private let lastFrameAutosaveName: String?
    private static var defaultFrameAutosaveName: String? {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--self-check") || arguments.contains("--performance-check") ? nil : "NevermoreLastConversationWindow"
    }
    var isClosed = false
    var session: AccountSession?
    var channel: RavenChannel?
    let accountPicker = NSPopUpButton()
    let workspacePicker = NSPopUpButton()
    var sidebarItems: [SidebarItem] = []
    let sidebar = SidebarTableView()
    let sidebarScroll = NSScrollView()
    /// Mail/Messages structure: a glass sidebar, the conversation, and a
    /// Tahoe inspector item that hosts a thread while one is open.
    let splitController = NSSplitViewController()
    var sidebarSplitItem: NSSplitViewItem!
    var inspectorSplitItem: NSSplitViewItem?
    var contentController: LayoutReportingViewController!
    var threadInspector: ThreadInspector?
    /// True while a window narrower than the inspector's minimum hid the
    /// pane. The inspector, its authorized root and its reading position
    /// stay alive until the window widens again.
    private(set) var inspectorCollapsedByWidth = false
    /// A collapsed thread keeps its subscription, but its replies are no
    /// longer on screen and should remain eligible for notifications.
    func displaysConversation(_ channelID: String) -> Bool {
        channel?.id == channelID || (!inspectorCollapsedByWidth && fileInspector == nil && threadInspector?.rootMessage.id == channelID)
    }

    /// Native, keyboard-reachable access to the thread while it is hidden.
    let threadInspectorHiddenButton = NSButton(title: "Open Thread", target: nil, action: nil)
    var conversationChooser: ConversationChooser?
    var channelDetailsSheet: ChannelDetailsSheet?
    var memberRoster: MemberRosterWindow?
    var outboxWindow: OutboxWindow?
    let transcript = TranscriptView()
    let transcriptScroll = TranscriptScrollView()
    let composer = ComposerView()
    lazy var inlineComposer = InlineComposer(owner: self)
    let composerEditorContainer = NSView()
    let composerResizeHandle = ComposerResizeHandle()
    var manualComposerHeight: CGFloat?
    lazy var composerFormatting: ComposerFormattingBar = {
        let bar = ComposerFormattingBar(composer: composer)
        bar.onModeChange = { [weak self] index in self?.inlineComposer.switchMode(index == 0 ? .visual : .markdown) }
        return bar
    }()
    var activeComposer: NSTextView { inlineComposer.activeTextView ?? composer }
    func focusComposer() { window?.makeFirstResponder(activeComposer) }
    let mentionPopover = MentionPopover()
    let quickReactions = QuickReactionPopover()
    let composerScroll = NSScrollView()
    let status = ObservedLabel(labelWithString: "Add an account to get started")
    let context = ObservedLabel(labelWithString: "")
    let attachmentLabel = NSTextField(labelWithString: "")
    let search = NSSearchField()
    let sendButton = NSButton(image: NSImage(systemSymbolName: "arrow.up.circle.fill", accessibilityDescription: "Send")!, target: nil, action: nil)
    let attachButton = NSButton(image: NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach Files")!, target: nil, action: nil)
    let emojiButton = NSButton(image: NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Emoji & Symbols")!, target: nil, action: nil)
    let composerGlass = NSGlassEffectView()
    let composerStack = NSStackView()
    let statusRow = NSStackView()
    let contextRow = NSStackView()
    let contextIcon = NSImageView()
    let contextCancel = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Cancel")!, target: nil, action: nil)
    let attachmentsRow = NSStackView()
    let linkPreviewRow = NSView()
    let linkPreviewCard = LinkPreviewCard()
    let linkPreview = ComposerLinkPreview()
    /// Self-checks answer link previews from a fixture instead of the network.
    var linkPreviewLoaderOverride: (any LinkPreviewLoading)?
    let connectionFooter = ConnectionFooter()
    let hoverBar = MessageHoverBar()
    let earlierProgress = NSProgressIndicator()
    /// The day being read, shown under the toolbar while the reader scrolls.
    let dayPill = FloatingDayPill()
    var dayPillCenter: NSLayoutConstraint?
    var dayPillFade: Task<Void, Never>?
    /// A trackpad gesture or scroller drag is moving the transcript.
    var isTranscriptLiveScrolling = false
    let emptyConversation = NSStackView()
    /// Theme wallpaper behind the transcript and the sidebar's tint; hidden under Classic.
    let themeBackdrop = ThemeBackdropView(role: .conversation)
    let sidebarBackdrop = ThemeBackdropView(role: .sidebar)
    var composerHeight: NSLayoutConstraint!
    var hoveredMessageID: String?
    var autoEarlierFirstID: String?
    var isLoadingEarlier = false
    var rows: [RavenChannel] = []
    var showsArchivedChannels = false
    var messages: [RavenMessage] = []
    var codeCommands: [URL: CodeCommand] = [:]
    var expandedCode = Set<String>()
    var codeReaders: [String: CodeReaderWindow] = [:]
    lazy var transcriptAccessibility = TranscriptAccessibility(owner: self)
    /// In layout order, top to bottom: `messageEntries(intersecting:)`
    /// binary-searches it.
    var messageRanges: [(NSRange, RavenMessage)] = []
    var attachments: [StagedAttachment] = []
    var promisedReceives: [UUID: Task<Void, Never>] = [:]
    var replyTo: String?
    var editing: RavenMessage?
    var threadRoot: RavenMessage?
    var threadContextTask: Task<Void, Never>?
    var applyingDraft = false
    var isAcceptingSend = false
    /// The last bottom-visible message sent to `markSeen`, so an unchanged
    /// viewport does not start a task on every scroll step.
    private var lastSeenReceipt: (channelID: String, creation: String)?
    var displayedHTML = ""
    var draftEncodingFailure: Error?
    private var draftErrorMessage: String?
    var saveTask: Task<Void, Never>?
    var loadTask: Task<Void, Never>?
    var renderTask: Task<Void, Never>?
    private var sidebarOpenTask: Task<Void, Never>?
    /// A row awaiting the keyboard pause or a held click. Preserve its
    /// identity when incoming activity reloads the list.
    private var pendingSidebarTarget: SidebarItem.Target?
    var collectionWindows: [CollectionWindow] = []
    /// The mention pool, rebuilt only when the directory, the channel list
    /// or the revocation generation changes — not on every keystroke.
    private var mentionPoolCache: (directoryVersion: Int, channelsVersion: Int, generation: Int, revokedCount: Int, pool: [MentionCandidate])?
    /// Self-checks count pool constructions to prove the cache holds.
    var mentionPoolBuilds = 0
    /// Self-checks reset the cache to measure pool builds from cold.
    func resetMentionPoolCache() { mentionPoolCache = nil }
    var pollWindows: [PollWindow] = []
    var pollCreationTask: Task<Void, Never>?
    var emojiSelectionTask: Task<Void, Never>?
    /// The GIF picker while it is open.
    var gifSelectionTask: Task<Void, Never>?
    /// Fixture services for self-checks; nil uses the reader's settings.
    var gifSourcesOverride: GIFPickerSheet.Sources?
    let gifButton = NSButton(title: "GIF", target: nil, action: nil)
    /// Reaction toggles on their way to the server, by message. Choosing a
    /// reaction is the commitment, so unlike `emojiSelectionTask` these are
    /// not cancelled when the user switches conversations or closes the
    /// window right after the click.
    var reactionSends: [String: Task<Void, Never>] = [:]
    var navigationGeneration = 0
    var navigation = NavigationHistory()
    var pendingRestoration: SavedWindowState?
    var restoreInspectorTask: Task<Void, Never>?
    /// Puts a restored location's message back at its remembered offset
    /// once its conversation has loaded.
    var restoreLocationTask: Task<Void, Never>?
    var attachmentWindows: [AttachmentWindow] = []
    /// Quick Look and Save As outside the File panel share one download.
    var attachmentDownload: Task<Void, Never>?
    var attachmentAttempt = UUID()
    /// The File panel's own download, so a Quick Look of another file
    /// never cancels it.
    private(set) var fileDownload: Task<Void, Never>?
    private var fileAttempt = UUID()
    /// Every attachment download under way in this window.
    var attachmentDownloads: [Task<Void, Never>] { [attachmentDownload, fileDownload].compactMap { $0 } }
    /// The File panel and its inspector item, while a file is shown there.
    /// It covers an open thread, which comes back when the panel closes.
    private(set) var fileInspector: FileInspector?
    private var fileSplitItem: NSSplitViewItem?
    /// True while a window too narrow for the File panel hides it. The
    /// panel, its file and its download stay until the window widens.
    private(set) var fileInspectorCollapsedByWidth = false
    /// Waits briefly before the File panel follows the transcript's
    /// selection, so arrowing past several files downloads only the last.
    private var followSelectionTask: Task<Void, Never>?
    /// True while a render puts the transcript's selection back, which is
    /// not the reader choosing another message.
    private var restoringTranscriptSelection = false
    /// A Save As started from a window too narrow for the File panel.
    private var attachmentSavePanel: NSSavePanel?
    /// Save As waits for the File panel's download.
    private var saveWhenFileArrives = false
    /// Creates the File panel's Save As panel; self-checks substitute a
    /// recording one so a retry's intent is observed without a real sheet.
    var makeFileInspectorSavePanel: @MainActor () -> NSSavePanel = { NSSavePanel() }
    var readPosition = TranscriptReadPosition()
    let jumpLatestButton = NSButton(title: "Jump to Latest", target: nil, action: nil)
    /// Keeps the bottom of the transcript in place while its pane changes shape.
    lazy var viewportKeeper = TranscriptViewportKeeper(scrollView: transcriptScroll, textView: transcript)
    /// Set while the pane does not show what the window decided to show:
    /// from picking another conversation or Jump to Latest until the render
    /// that places it, and while a render replaces the text. What is in the
    /// pane then says nothing about the reader, so it changes neither
    /// `isFollowing` nor the read position, and offers no hover actions.
    var isUpdatingTranscript = false { didSet { viewportKeeper.isReplacingText = isUpdatingTranscript } }
    /// A render found the transcript under a press and waits for its end.
    private var renderAfterPress = false
    private var latestAuthorizedMessageID: String?
    var latestReadTask: Task<Void, Never>?
    var latestReadAttempt = UUID()
    var isFollowing = true
    var historyUpperID: String?
    var requestedAnchor: String?
    /// Where the first render that has the requested message puts it: in
    /// view for a message opened from search or the inbox, at its remembered
    /// distance below the top of the pane for a restored location. Nil once
    /// that render has placed it.
    enum RequestedPlacement { case inView, belowTop(CGFloat) }
    var requestedPlacement: RequestedPlacement?
    var observerTokens: [NSObjectProtocol] = []
    private let statusAnnouncements = StatusAnnouncementController()
    /// The send animation and the wet state of unacknowledged messages.
    lazy var ink = InkController(owner: self)
    /// The ravens on unread conversations.
    lazy var unkindness = UnkindnessController(owner: self)
    /// Reactions carried, thrown and peeled as stickers.
    lazy var stickers = StickerController(owner: self)
    /// Plays the GIFs in view over their first frames in the transcript.
    lazy var animatedImages: AnimatedImageOverlay = {
        let overlay = AnimatedImageOverlay(textView: transcript, scrollView: transcriptScroll) { [weak self] key in
            guard let session = self?.session else { return nil }
            if let image = session.animatedImages[key] { return image }
            session.requestAnimatedImage(key)
            return nil
        }
        return overlay
    }()
    /// Shown in the conversation pane whenever no conversation is open.
    lazy var home = HomeView(owner: self)
    /// The search results screen, shown in the conversation pane instead
    /// of Home while `isSearching`.
    lazy var searchView = SearchView(owner: self)
    var isSearching = false
    /// Set while a search result opens, so the toolbar field keeps the
    /// query that found it; any other navigation clears the field.
    var openingSearchResult = false
    /// The search whose result this conversation is; editing the query
    /// here refines that search.
    var resultOfSearch: SearchCriteria?
    init(app: AppDelegate, session: AccountSession?, windowID: UUID = UUID(), lastFrameAutosaveName: String? = ConversationWindow.defaultFrameAutosaveName) {
        self.app = app; self.session = session; self.windowID = windowID
        self.lastFrameAutosaveName = lastFrameAutosaveName
        let window = ConversationNativeWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView], backing: .buffered, defer: false)
        super.init(window: window)
        window.conversation = self
        window.registerForDraggedTypes([.fileURL] + PromisedFileReceiver.draggedTypes)
        window.title = "Nevermore"; window.tabbingIdentifier = "NevermoreConversation"; window.delegate = self
        let toolbar = NSToolbar(identifier: ConversationToolbar.identifier); toolbar.delegate = self; toolbar.allowsUserCustomization = true; toolbar.autosavesConfiguration = !ProcessInfo.processInfo.arguments.contains("--performance-check")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar; window.toolbarStyle = .unified
        buildUI()
        window.setContentSize(NSSize(width: 1080, height: 760)); window.minSize = NSSize(width: 650, height: 420)
        // A stable fallback also covers the demo, closed windows and the
        // macOS preference not to reopen conversations on relaunch. Restored
        // conversations still apply their individual frames in AppDelegate.
        if lastFrameAutosaveName.map({ window.setFrameUsingName($0) }) != true { window.center() }
        if !ProcessInfo.processInfo.arguments.contains("--self-check"), !ProcessInfo.processInfo.arguments.contains("--performance-check") { window.setFrameAutosaveName("NevermoreWindow-\(windowID.uuidString)") }
        updateAccounts(); refreshSidebar()
        observerTokens.append(NotificationCenter.default.addObserver(forName: .sessionChanged, object: nil, queue: .main) { [weak self] note in
            let source = note.object as? AccountSession
            MainActor.assumeIsolated { guard let self, source === self.session else { return }; self.refreshSidebar(); self.updateContext(); self.updateCompletions(); for collection in self.collectionWindows { collection.restrictRevoked() }; self.render() }
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: .draftChanged, object: nil, queue: .main) { [weak self] note in
            let source = note.object as? AccountSession
            let changedChannel = note.userInfo?["channel"] as? String
            MainActor.assumeIsolated { guard let self, source === self.session, changedChannel == self.channel?.id, self.editing == nil else { return }; self.restoreDraft() }
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: .sessionStatusAttentionChanged, object: nil, queue: .main) { [weak self] note in
            let source = note.object as? AccountSession
            MainActor.assumeIsolated { guard let self, let source, source === self.session else { return }; self.updateStatusAnnouncements() }
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: .sessionPresenceChanged, object: nil, queue: .main) { [weak self] note in
            let source = note.object as? AccountSession
            // Only the rows on screen show presence; the transcript does not.
            MainActor.assumeIsolated { guard let self, let source, source === self.session else { return }; self.refreshSidebarAvatars() }
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: .sessionDraftMarksChanged, object: nil, queue: .main) { [weak self] note in
            let source = note.object as? AccountSession
            MainActor.assumeIsolated { guard let self, let source, source === self.session else { return }; self.refreshSidebarAvatars() }
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: .sessionAvatarsChanged, object: nil, queue: .main) { [weak self] note in
            let source = note.object as? AccountSession
            MainActor.assumeIsolated { guard let self, let source, source === self.session else { return }; self.transcript.needsDisplay = true; self.refreshSidebarAvatars() }
        })
        viewportKeeper.isFollowing = { [weak self] in self?.isFollowing ?? false }
        transcriptScroll.onWheelMove = { [weak self] in self?.updateFloatingDayPill(readerWheel: true) }
        viewportKeeper.onMove = { [weak self] in self?.seenVisible(); self?.transcriptDidScroll(); self?.updateFloatingDayPill() }
        observerTokens.append(NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification, object: transcriptScroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.loadEarlierIfAtTop() }
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: transcriptScroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isTranscriptLiveScrolling = true }
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: transcriptScroll, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.isTranscriptLiveScrolling = false; if self.dayPill.isShown { self.scheduleFloatingDayPillFade() } }
        })
        observerTokens.append(NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: composer, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateComposerHeight() }
        })
        // Apply the default only once, after the final window geometry and
        // initial layout. Earlier sizing would reset it to the 200-point minimum.
        window.contentView?.layoutSubtreeIfNeeded()
        splitController.splitView.setPosition(300, ofDividerAt: 0)
    }
    required init?(coder: NSCoder) { fatalError() }
    func updateAccounts() {
        let menu = NSMenu()
        let current = session.map { $0.account.displayName.isEmpty ? $0.account.user : $0.account.displayName } ?? "No Account"
        menu.addItem(withTitle: current, action: nil, keyEquivalent: "")
        let active = app.sessions.filter { !$0.stopped }
        for candidate in active {
            let item = NSMenuItem(title: candidate.account.displayName.isEmpty ? candidate.account.user : candidate.account.displayName, action: #selector(switchAccount(_:)), keyEquivalent: "")
            item.subtitle = [candidate.account.user, candidate.account.origin.host].compactMap { $0 }.joined(separator: " · ")
            item.representedObject = candidate.account.id; item.target = self; item.state = candidate === session ? .on : .off
            menu.addItem(item)
        }
        if !active.isEmpty { menu.addItem(.separator()) }
        for (title, action) in [("Set Status…", #selector(setCustomStatus(_:))), ("Account Preferences…", #selector(showCurrentAccountPreferences(_:))), ("Open Raven in Browser", #selector(openBrowser(_:)))] where session != nil {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Add Account…", action: #selector(AppDelegate.addAccount(_:)), keyEquivalent: "").target = app
        accountPicker.menu = menu
        accountPicker.setTitle(current)
        accountPicker.setAccessibilityValue(current)
    }
    func use(_ session: AccountSession?) {
        cancelSidebarKeyboardOpen()
        channelDetailsSheet?.close(); channelDetailsSheet = nil
        ComposerEditorLifetime.cancel(attachedTo: window)
        clearReadPosition(); latestAuthorizedMessageID = nil
        statusAnnouncements.invalidate()
        cancelEmojiPicker()
        closePollWindows()
        outboxWindow?.close(); outboxWindow = nil
        isSearching = false; searchView.reset(session: session); search.stringValue = ""
        transcriptAccessibility.clear(); hideHoverBar(); transcript.highlightRect = nil; transcript.caretMessageLocation = nil; autoEarlierFirstID = nil
        ink.reset(); unkindness.reset(); stickers.reset()
        inlineComposer.load(nil)
        cancelPromisedFiles(); navigationGeneration += 1
        self.session?.attach(window: windowID, channelID: nil)
        conversationChooser?.cancel(); conversationChooser = nil; memberRoster?.cancel(); memberRoster = nil; closeThreadInspector(); mentionPopover.reset(); clearPreview(); closeCodeReaders()
        for collection in Array(collectionWindows) { collection.records.removeAll(); collection.table.reloadData(); collection.close() }; collectionWindows.removeAll()
        loadTask?.cancel(); renderTask?.cancel(); self.session = session; mentionPoolCache = nil; composer.sharedUndoManager = nil; composer.useTextStorage(NSTextStorage()); channel = nil; messages = []; messageRanges = []; transcript.clearText(); animatedImages.removeAll(); isUpdatingTranscript = false; composer.string = ""; attachments = []; replyTo = nil; editing = nil; lastSeenReceipt = nil
        navigation = NavigationHistory(); threadContextTask?.cancel(); threadRoot = nil; pendingRestoration = nil; restoreInspectorTask?.cancel(); updateAccounts(); refreshSidebar(); updateWindowTitle(); updateContext()
        // Home reads the window's session, and a switch posts no Home-shaped
        // notification for the new account until its first reconciliation. Rebuild
        // the visible pane and start the new account's modules now.
        home.setNeedsReload(); home.refreshIfShown()
    }
    @objc func switchAccount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let target = app.sessions.first(where: { $0.account.id == id && !$0.stopped }) else { updateAccounts(); return }
        guard target !== session else { return }
        use(target)
    }
    @objc func accountChanged() { updateAccounts() }
    @objc func showCurrentAccountPreferences(_ sender: Any?) { guard let session else { return }; app.showAccountPreferences(session) }
    func refreshSidebar() {
        updateComposerAvailability()
        rows = (session?.channels ?? []).filter { showsArchivedChannels || !$0.raw["is_archived"].bool }
        let selectedWorkspace = workspacePicker.titleOfSelectedItem ?? "All Workspaces"
        let workspaces = Set(rows.filter { !$0.isDM }.map(\.workspace)).filter { !$0.isEmpty }.sorted()
        workspacePicker.removeAllItems(); workspacePicker.addItems(withTitles: ["All Workspaces"] + workspaces)
        workspacePicker.selectItem(withTitle: selectedWorkspace)
        if let workspace = pendingRestoration?.workspaceID, workspaces.contains(workspace) { workspacePicker.selectItem(withTitle: workspace); pendingRestoration?.workspaceID = nil }
        // A single workspace needs no filter; keep the control for restoration.
        workspacePicker.isHidden = workspaces.count < 2 && workspacePicker.indexOfSelectedItem <= 0
        let filter = workspacePicker.titleOfSelectedItem ?? "All Workspaces"
        // Home leads the list whenever there is an account to show it for.
        sidebarItems = session == nil ? [] : [.home]
        let favorites = rows.filter { session?.favoriteIDs.contains($0.id) == true && (filter == "All Workspaces" || $0.isDM || $0.workspace == filter) }
        let favoriteIDs = Set(favorites.map(\.id))
        if !favorites.isEmpty { sidebarItems.append(.header("Favorites")); sidebarItems += favorites.map(SidebarItem.conversation) }
        for workspace in Set(rows.filter { !$0.isDM && !favoriteIDs.contains($0.id) && (filter == "All Workspaces" || $0.workspace == filter) }.map(\.workspace)).sorted() {
            sidebarItems.append(.header(workspace.isEmpty ? "Channels" : workspace))
            sidebarItems += rows.filter { !$0.isDM && !favoriteIDs.contains($0.id) && $0.workspace == workspace }.map(SidebarItem.conversation)
        }
        let dms = rows.filter { $0.isDM && !favoriteIDs.contains($0.id) }
        if !dms.isEmpty { sidebarItems.append(.header("Direct Messages")); sidebarItems += dms.map(SidebarItem.conversation) }
        if let current = channel, let refreshed = session?.channels.first(where: { $0.id == current.id }) { channel = refreshed }
        updateWindowTitle()
        sidebar.reloadData(); status.stringValue = session?.state ?? "Add an account to get started"
        connectionFooter.update(session: session)
        if let pending = pendingSidebarTarget, let index = sidebarItems.firstIndex(where: { $0.target == pending }) { sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else if let channel, let index = sidebarItems.firstIndex(where: { $0.channel?.id == channel.id }) { sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else if channel == nil, !isSearching, let index = sidebarItems.firstIndex(where: \.isHome) { sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        else if isSearching { sidebar.deselectAll(nil) }
        unkindness.sidebarDidReload()
        sendButton.isEnabled = composer.isEditable && channel != nil && !isArchivedConversation && (session?.pendingFileReceipts.values.contains(channel?.id ?? "") != true) && !isAcceptingSend && session?.readOnly != true && !(session?.revokedChannels.contains(channel?.id ?? "") ?? false) && !(channel?.raw["parent_channel_id"].string.flatMap { session?.revokedChannels.contains($0) } ?? false)
        if let channel, session?.revokedChannels.contains(channel.id) == true { context.stringValue = "Access changed · unsent text remains recoverable" }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { sidebarItems.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { sidebarItems[row].isHeader }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !sidebarItems[row].isHeader }
    @objc func workspaceChanged() { refreshSidebar() }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard sidebarItems.indices.contains(row) else { return nil }
        if sidebarItems[row].isHome {
            let cell = tableView.makeView(withIdentifier: SidebarConversationCell.identifier, owner: self) as? SidebarConversationCell ?? SidebarConversationCell()
            cell.configure(.home, fontSize: sidebarFontSize)
            return cell
        }
        guard let channel = sidebarItems[row].channel else {
            let header = tableView.makeView(withIdentifier: SidebarHeaderCell.identifier, owner: self) as? SidebarHeaderCell ?? SidebarHeaderCell()
            header.textField?.stringValue = sidebarItems[row].title
            return header
        }
        let cell = tableView.makeView(withIdentifier: SidebarConversationCell.identifier, owner: self) as? SidebarConversationCell ?? SidebarConversationCell()
        // Request only rows AppKit materializes, not the entire DM directory.
        if let peer = sidebarAvatarUserID(for: channel) { session?.loadAvatars([peer]) }
        cell.configure(sidebarModel(for: channel, unread: unreadCount(channel.id)), fontSize: sidebarFontSize)
        return cell
    }
    /// How long the sidebar selection rests under the keyboard before its
    /// conversation opens: a held arrow key passes over conversations
    /// without opening each one and marking it read.
    static let sidebarKeyboardDelay: Duration = .milliseconds(250)

    /// The arrow keys moved the sidebar selection: open what it rests on,
    /// as Mail and Messages do.
    func openSidebarSelectionSoon() {
        sidebarOpenTask?.cancel()
        let target = selectedSidebarTarget
        pendingSidebarTarget = target
        sidebarOpenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.sidebarKeyboardDelay)
            guard !Task.isCancelled, let self else { return }
            // The keyboard's selection only speaks for the pane while the
            // sidebar still has focus. Clicking the composer or Tabbing into
            // the transcript during the pause moves on without opening, so
            // drop the pending open instead of switching a moment later.
            guard self.window?.firstResponder === self.sidebar else {
                self.cancelSidebarKeyboardOpen()
                return
            }
            self.pendingSidebarTarget = nil
            // Compared by identity: a reload during the pause may move rows.
            guard self.selectedSidebarTarget == target else { return }
            self.openSidebarSelection()
        }
    }

    /// AppKit tracks a held click across run-loop turns. Keep its row by
    /// identity if incoming activity reloads or reorders the list.
    func trackSidebarClick(row: Int?) {
        cancelSidebarKeyboardOpen()
        if let row, sidebarItems.indices.contains(row) { pendingSidebarTarget = sidebarItems[row].target }
    }

    private var selectedSidebarTarget: SidebarItem.Target? {
        sidebarItems.indices.contains(sidebar.selectedRow) ? sidebarItems[sidebar.selectedRow].target : nil
    }

    /// Drops the open the arrow keys scheduled. Every way of showing a
    /// conversation, Home, search, or a new window or tab calls this first:
    /// otherwise the reload it triggers would put the selection back on the
    /// arrowed row, and the pending open would then replace what was just
    /// shown.
    func cancelSidebarKeyboardOpen() {
        sidebarOpenTask?.cancel(); sidebarOpenTask = nil; pendingSidebarTarget = nil
    }

    /// Opens the selected sidebar row unless the pane already shows it.
    func openSidebarSelection() {
        cancelSidebarKeyboardOpen()
        guard sidebarItems.indices.contains(sidebar.selectedRow) else { return }
        let item = sidebarItems[sidebar.selectedRow]
        let showing = item.isHome ? channel == nil && !isSearching : item.channel.map { $0.id == channel?.id && !isSearching } == true
        guard !showing else { return }
        selectedSidebar()
    }

    @objc func selectedSidebar() {
        cancelSidebarKeyboardOpen()
        guard sidebarItems.indices.contains(sidebar.selectedRow) else { return }
        if sidebarItems[sidebar.selectedRow].isHome { showHome(); return }
        guard let item = sidebarItems[sidebar.selectedRow].channel else { return }
        select(item)
    }
    func select(_ channel: RavenChannel, anchor: String? = nil, record: Bool = true) {
        cancelSidebarKeyboardOpen()
        hideFloatingDayPill(animated: false)
        if self.channel?.id != channel.id {
            memberRoster?.cancel(); memberRoster = nil
            if window?.isVisible == true { app.interfaceSounds.play(.selection) }
            stickers.reset()
        }
        clearReadPosition(); latestAuthorizedMessageID = nil
        if self.channel?.id != channel.id { statusAnnouncements.resetContext(); cancelEmojiPicker() }
        if let parent = channel.raw["parent_channel_id"].string { session?.threadParents[channel.id] = parent }
        if isSearching { isSearching = false; searchView.attachments.cancel() }
        if !openingSearchResult { resultOfSearch = nil; if record { search.stringValue = "" } }
        transcriptAccessibility.clear()
        inlineComposer.load(nil)
        cancelPromisedFiles(); navigationGeneration += 1
        let navigationID = navigationGeneration
        if record { pendingRestoration = nil; captureNavigation(); navigation.visit(ConversationLocation(channelID: channel.id, anchorMessageID: anchor, threadParentChannelID: channel.raw["parent_channel_id"].string)) }
        threadContextTask?.cancel(); threadRoot = nil; codeCommands.removeAll(); expandedCode.removeAll()
        restoreInspectorTask?.cancel(); closeThreadInspector(); closeFileInspector(); mentionPopover.reset(); loadTask?.cancel(); renderTask?.cancel(); self.channel = channel; refreshSidebarAvatars(); historyUpperID = nil; requestedAnchor = anchor; requestedPlacement = anchor == nil ? nil : .inView
        if let session {
            if session.sharedTextStorage[channel.id] == nil { session.sharedTextStorage[channel.id] = NSTextStorage() }
            if session.draftUndoManagers[channel.id] == nil { session.draftUndoManagers[channel.id] = UndoManager() }
            composer.sharedUndoManager = session.draftUndoManagers[channel.id]
            composer.useTextStorage(session.sharedTextStorage[channel.id]!)
        }; editing = nil; replyTo = nil; attachments = []; displayedHTML = ""; context.stringValue = ""; isFollowing = anchor == nil
        // The pane keeps the previous text until the first render arrives.
        isUpdatingTranscript = true
        updateWindowTitle(); hideHoverBar(); transcript.highlightRect = nil; transcript.caretMessageLocation = nil; autoEarlierFirstID = nil
        if self.ink.renderedConversation != channel.id { ink.reset() }
        session?.intentionallyUnread.remove(channel.id)
        if let session { app.lastConversation = (session.account.id, channel.id) }
        session?.attach(window: windowID, channelID: channel.id); refreshSidebar(); restoreDraft(); render()
        guard let session else { return }
        loadThreadContext()
        // The answer scrolls to the opened message only while it is still
        // what the window shows: a send or Jump to Latest may have left it.
        loadTask = Task { [weak self] in do { try await session.load(channelID: channel.id, anchor: anchor); guard !Task.isCancelled, self?.navigationGeneration == navigationID, self?.isCurrent(session, channelID: channel.id) == true else { return }; await self?.renderTask?.value; guard !Task.isCancelled, self?.navigationGeneration == navigationID else { return }; if let anchor, self?.requestedAnchor == anchor { self?.scrollTo(anchor) } } catch { if error is CancellationError || Task.isCancelled { return }; if self?.channel?.id == channel.id { self?.status.stringValue = error.localizedDescription } } }
    }
    /// Leaves the open conversation for Home. Drafts are saved as they are
    /// typed, so leaving loses nothing; Back returns to the conversation.
    func showHome() {
        guard session != nil else { return }
        cancelSidebarKeyboardOpen()
        hideFloatingDayPill(animated: false)
        if isSearching { isSearching = false; searchView.attachments.cancel(); search.stringValue = "" }
        guard channel != nil else { refreshSidebar(); updateWindowTitle(); home.reloadNow(); return }
        if window?.isVisible == true { app.interfaceSounds.play(.selection) }
        leaveConversation()
        refreshSidebar(); updateContext(); updateAttachmentChips()
        home.reloadNow()
        window?.makeFirstResponder(sidebar)
    }
    /// Takes the open conversation out of the pane, for Home or search.
    /// Drafts are saved as they are typed, so leaving loses nothing.
    func leaveConversation() {
        guard channel != nil else { return }
        captureNavigation()
        stickers.reset(); ink.reset()
        clearReadPosition(); latestAuthorizedMessageID = nil
        statusAnnouncements.resetContext(); cancelEmojiPicker()
        transcriptAccessibility.clear()
        inlineComposer.load(nil)
        cancelPromisedFiles(); navigationGeneration += 1
        threadContextTask?.cancel(); threadRoot = nil; codeCommands.removeAll(); expandedCode.removeAll()
        memberRoster?.cancel(); memberRoster = nil
        restoreInspectorTask?.cancel(); restoreLocationTask?.cancel(); closeThreadInspector(); mentionPopover.reset(); loadTask?.cancel(); renderTask?.cancel()
        hideHoverBar(); transcript.highlightRect = nil; transcript.caretMessageLocation = nil; autoEarlierFirstID = nil
        channel = nil; messages = []; messageRanges = []; transcript.clearText(); animatedImages.removeAll(); isUpdatingTranscript = false
        // The conversation left behind may hold a draft to mark.
        refreshSidebarAvatars()
        // A fresh storage: typing can no longer reach the conversation's draft.
        composer.sharedUndoManager = nil; composer.useTextStorage(NSTextStorage())
        editing = nil; replyTo = nil; attachments = []; displayedHTML = ""; context.stringValue = ""
        historyUpperID = nil; requestedAnchor = nil; requestedPlacement = nil
        clearPreview()
        session?.attach(window: windowID, channelID: nil)
    }
    func currentLocation() -> ConversationLocation? {
        guard let channel else { return nil }
        let origin = transcriptScroll.contentView.bounds.minY
        let anchor = messageRanges.first { rect(for: $0.0).maxY >= origin }
        return ConversationLocation(channelID: channel.id, anchorMessageID: isFollowing ? nil : anchor?.1.id, pixelOffset: anchor.map { Double(rect(for: $0.0).minY - origin) } ?? 0, threadParentChannelID: channel.raw["parent_channel_id"].string)
    }
    func captureNavigation() { if let location = currentLocation() { navigation.capture(location) } }
    func restoreLocation(_ location: ConversationLocation) {
        guard let session else { return }
        var fields: [String: JSONValue] = ["name": .string(location.channelID), "channel_name": .string(location.threadParentChannelID == nil ? location.channelID : "Thread")]
        if let parent = location.threadParentChannelID { fields["is_thread"] = .bool(true); fields["parent_channel_id"] = .string(parent) }
        let channel = session.channels.first { $0.id == location.channelID } ?? RavenChannel(raw: .object(fields))
        // The toolbar field belongs to search now; a restored conversation
        // starts with it empty.
        select(channel, anchor: location.anchorMessageID, record: false); search.stringValue = ""
        if location.anchorMessageID != nil { requestedPlacement = .belowTop(location.pixelOffset) }
        let navigationID = navigationGeneration
        restoreLocationTask?.cancel()
        restoreLocationTask = Task { [weak self] in
            await self?.loadTask?.value; await self?.renderTask?.value
            guard !Task.isCancelled, let self, self.navigationGeneration == navigationID, self.isCurrent(session, channelID: location.channelID), let anchor = location.anchorMessageID, self.requestedAnchor == anchor, let range = self.messageRanges.first(where: { $0.1.id == anchor })?.0 else { return }
            self.isFollowing = false
            self.transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: max(self.minimumTranscriptOrigin, self.rect(for: range).minY - location.pixelOffset)))
            self.transcriptScroll.reflectScrolledClipView(self.transcriptScroll.contentView)
        }
    }
    /// From Home, Back returns to where Home was opened from: a
    /// conversation, or the search results.
    @objc func goBack() {
        if channel == nil, !isSearching, let entry = navigation.currentEntry { restore(entry); return }
        captureNavigation(); if let entry = navigation.back() { restore(entry) }
    }
    @objc func goForward() { captureNavigation(); if let entry = navigation.forward() { restore(entry) } }
    func restore(_ entry: NavigationEntry) {
        switch entry {
        case .conversation(let location): restoreLocation(location)
        case .search(let criteria): showSearch(criteria, record: false, immediately: true)
        }
    }
    func renderAfterPressIfNeeded() {
        guard renderAfterPress else { return }
        renderAfterPress = false; render()
    }
    func render() {
        guard let session, let channel else { isUpdatingTranscript = false; return }
        if session.stopped || session.revokedChannels.contains(channel.id) || channel.raw["parent_channel_id"].string.map(session.revokedChannels.contains) == true || session.deletedIDs.contains(channel.id) {
            updateStatusAnnouncements()
            renderTask?.cancel(); threadContextTask?.cancel(); threadRoot = nil; cancelPromisedFiles()
            clearReadPosition(); latestAuthorizedMessageID = nil; ink.reset(); stickers.reset()
            transcriptAccessibility.clear(); hideHoverBar(); transcript.highlightRect = nil
            messages = []; messageRanges = []; codeCommands.removeAll(); transcript.clearText(); animatedImages.removeAll(); clearPreview()
            isUpdatingTranscript = false
            context.stringValue = "Access changed · unsent text remains recoverable"; return
        }
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            do {
                let allMessages = try await session.cachedMessages(channelID: channel.id, limit: 5000)
                var messages = Array(allMessages.suffix(500))
                if let upper = self?.historyUpperID, let index = allMessages.firstIndex(where: { $0.id == upper }) {
                    messages = Array(allMessages.prefix(index + 1).suffix(500))
                } else if let anchor = self?.requestedAnchor, let index = allMessages.firstIndex(where: { $0.id == anchor }) {
                    messages = Array(allMessages[max(0, index - 250)..<min(allMessages.count, index + 250)])
                }
                let operations = try await session.store.operations(channelID: channel.id)
                guard !Task.isCancelled, let self, self.isCurrent(session, channelID: channel.id),
                      !ChannelPolicy.isRevoked(channelID: channel.id, revoked: session.revokedChannels, threadParents: session.threadParents),
                      channel.raw["parent_channel_id"].string.map(session.revokedChannels.contains) != true,
                      !session.deletedIDs.contains(channel.id) else { return }
                // Capture the caret against the ranges currently on screen,
                // before the rebuild below replaces them. Prepending earlier
                // history or deleting a row above it moves every character
                // after it; restoring the raw offset would land in another
                // message, and the Message menu would act on the wrong row.
                let selection = self.transcript.selectedRange()
                let caret: (id: String, offset: Int)? = selection.length == 0
                    ? self.messageRanges.first(where: { NSLocationInRange(selection.location, $0.0) })
                        .map { ($0.1.id, selection.location - $0.0.location) }
                    : nil
                // A caret at the very end of the text is past every
                // half-open message range; it belongs to the last message.
                let endCaret: (id: String, offset: Int)? = caret == nil
                    && selection.length == 0
                    && selection.location == self.transcript.textStorage?.length
                    ? self.messageRanges.max(by: { NSMaxRange($0.0) < NSMaxRange($1.0) })
                        .map { ($0.1.id, selection.location - $0.0.location) }
                    : nil
                let anchoredCaret = caret ?? endCaret
                // Replacing the text under a press would free the link
                // AppKit is about to deliver; render once the press ends.
                if self.transcript.isTrackingPress { self.renderAfterPress = true; return }
                // Only authoritative deletion releases a navigation cursor.
                // An initially uncached context target must keep its intent.
                if let cursor = self.requestedAnchor, session.deletedIDs.contains(cursor) {
                    self.requestedAnchor = nil; self.isFollowing = false
                }
                if let cursor = self.historyUpperID, session.deletedIDs.contains(cursor) {
                    self.historyUpperID = nil; self.isFollowing = false
                }
                let following = self.isFollowing
                let authorizedMessages = allMessages.filter { !session.deletedIDs.contains($0.id) }
                self.latestAuthorizedMessageID = authorizedMessages.last?.id
                messages.removeAll { session.deletedIDs.contains($0.id) }
                let visit = TranscriptReadPosition.effectiveVisit(server: session.transcriptVisit(for: channel.id), observedTimestamp: session.lastSeen[channel.id])
                let historical = session.historicalMessageIDs(for: channel.id)
                self.readPosition.observe(authorizedMessages, currentUser: session.account.user, visit: visit, following: following, historicalIDs: historical?.ids ?? [], historicalIDsComplete: historical?.complete ?? true)
                let oldBounds = self.transcriptScroll.contentView.bounds
                let oldOrigin = oldBounds.origin
                let visibleAnchor: (String, CGFloat)?
                if following {
                    visibleAnchor = nil
                } else {
                    let authorizedIDs = Set(authorizedMessages.map { Data($0.id.utf8) })
                    // Deleting the first visible row must not discard the entire
                    // viewport anchor. Prefer a surviving visible neighbor, then
                    // the nearest surviving old row, with its original pixel offset.
                    let survivors = self.messageRanges.compactMap { range, message -> (id: String, rect: NSRect)? in
                        guard authorizedIDs.contains(Data(message.id.utf8)) else { return nil }
                        return (message.id, self.rect(for: range))
                    }
                    let survivor = survivors.first { $0.rect.maxY > oldBounds.minY && $0.rect.minY < oldBounds.maxY }
                        ?? survivors.min { abs($0.rect.minY - oldOrigin.y) < abs($1.rect.minY - oldOrigin.y) }
                    visibleAnchor = survivor.map { ($0.id, $0.rect.minY - oldOrigin.y) }
                }
                let cursorMissingFromSnapshot: Bool
                if following { cursorMissingFromSnapshot = false }
                else {
                    cursorMissingFromSnapshot = [self.requestedAnchor, self.historyUpperID].compactMap { $0 }.contains { cursor in
                        !authorizedMessages.contains { $0.id.utf8.elementsEqual(cursor.utf8) }
                    }
                }
                if !following, (self.historyUpperID == nil && self.requestedAnchor == nil) || cursorMissingFromSnapshot {
                    // New tail messages must not trim away the reader's anchor
                    // before the bounded window has a chance to retain it.
                    // Local cursor eviction is not deletion: retain navigation
                    // intent while projecting around its surviving viewport.
                    messages = MessageWindow.bounded(authorizedMessages, anchorID: visibleAnchor?.0)
                } else {
                    messages = MessageWindow.bounded(messages, anchorID: self.requestedAnchor ?? (following ? nil : visibleAnchor?.0))
                }
                self.messages = messages
                let output = NSMutableAttributedString(string: ""); self.messageRanges = []
                let storedSize = UserDefaults.standard.double(forKey: "fontSize")
                let size = CGFloat(storedSize.isFinite && storedSize > 0 ? min(30, max(11, storedSize)) : 14)
                var commands: [URL: CodeCommand] = [:]
                var visibleCode = Set<String>()
                let firstUnread = self.readPosition.firstUnreadID(in: messages, currentUser: session.account.user)
                let metrics = TranscriptMetrics(size: size, compact: UserDefaults.standard.bool(forKey: "compactMessages"))
                // New metrics and new text both move the lines; the pane is
                // observed again once the text is placed.
                self.isUpdatingTranscript = true
                defer { self.isUpdatingTranscript = false }
                // Before the text arrives, so the container is laid out once.
                self.transcript.metrics = metrics
                // Grouping is decided up front: each separator's height
                // depends on whether the next message continues the group.
                // Accepted, unacknowledged sends are laid out as the messages
                // they will become, so acknowledgement moves nothing. They
                // stay out of `self.messages` and `messageRanges`: commands
                // act on messages the server knows.
                let pendingSends = Dictionary(uniqueKeysWithValues: operations.map { ("outbox-\($0.id.uuidString)", $0) })
                messages.append(contentsOf: operations.map { session.pendingMessage(for: $0) })
                var inkPending: [InkController.Pending] = []
                var inkBodies: [String: NSRange] = [:]
                let calendar = session.displayCalendar
                let dates = messages.map { session.messageDate($0.creation) }
                var dayBreaks: [Bool] = [], continues: [Bool] = []
                var lastDate: Date?
                for (index, message) in messages.enumerated() {
                    let dayBreak = TranscriptGrouping.startsNewDay(dates[index], after: lastDate, calendar: calendar)
                    dayBreaks.append(dayBreak)
                    let previous = index > 0 ? TranscriptGrouping.Entry(messages[index - 1], date: dates[index - 1]) : nil
                    continues.append(!dayBreak && message.id != firstUnread && TranscriptGrouping.continues(TranscriptGrouping.Entry(message, date: dates[index]), after: previous, calendar: calendar))
                    if let date = dates[index] { lastDate = date }
                }
                var authors = Set<String>()
                // The channel list carries the pins; the window's copy may predate a refresh.
                let pinnedIDs = self.pinnedMessageIDs(in: channel.id) ?? []
                for (index, message) in messages.enumerated() {
                    if dayBreaks[index], let date = dates[index] { output.append(TranscriptStyle.dayDivider(session.dayLabel(for: date), metrics: metrics)) }
                    if message.id == firstUnread { output.append(TranscriptStyle.unreadDivider(metrics: metrics)) }
                    let start = output.length
                    let time = session.displayTime(message.creation)
                    if message.messageType == "System" {
                        // Events read as one quiet line; markup adds nothing.
                        let text: String
                        if !message.html.isEmpty, case .parsed(let doc) = session.messageDocument(for: message) { text = RichTextCodec.plainText(doc) }
                        else { text = message.raw["content"].string ?? "" }
                        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
                        output.append(TranscriptStyle.systemEvent(String(line.prefix(4096)), time: time, fullTime: session.displayTimestamp(message.creation), metrics: metrics))
                        // Consecutive events ("created", "added") stay together.
                        let next = index + 1
                        let nextIsEvent = next < messages.count && messages[next].messageType == "System" && !dayBreaks[next] && messages[next].id != firstUnread
                        output.append(TranscriptStyle.separator(metrics: metrics, nextContinuesGroup: nextIsEvent)); self.messageRanges.append((NSRange(location: start, length: output.length - start), message))
                        continue
                    }
                    if !continues[index] {
                        if !metrics.compact { authors.insert(message.authorID) }
                        let avatar = metrics.compact ? nil : TranscriptAvatar(userID: message.authorID, name: session.authorName(message))
                        output.append(TranscriptStyle.header(name: session.authorName(message), authorID: message.authorID, time: time, fullTime: session.displayTimestamp(message.creation), avatar: avatar, metrics: metrics))
                    }
                    let bodyStart = output.length
                    if message.raw["is_reply"].bool {
                        let target = message.raw["linked_message"].string
                        let quoted = target.flatMap { id in messages.first { $0.id == id } }
                        // An answered message outside the loaded window still
                        // names its author; a click loads it.
                        let author = quoted.map { (session.authorName($0), $0.authorID) }
                            ?? TranscriptStyle.repliedAuthorID(message.raw["replied_message_details"]).map { (session.userNames[$0] ?? $0, $0) }
                        output.append(TranscriptStyle.replyQuote(author: author, preview: quoted.map(self.replyPreview) ?? "", target: target, metrics: metrics))
                    }
                    let inkStart = output.length
                    let pendingSend = pendingSends[message.id]
                    if !message.html.isEmpty, case .parsed(let doc) = session.messageDocument(for: message) { let presented = CodePresentation.render(doc, message: message, fontSize: size, expanded: self.expandedCode, parentChannelID: channel.raw["parent_channel_id"].string)
                        output.append(InlineImagePresentation.embed(presented.text, session: session)); commands.merge(presented.commands) { _, new in new }; visibleCode.formUnion(presented.references.map(\.key))
                        // A GIF message is read only by nature, so it needs no note.
                        if !doc.canEdit, GIFMessage.source(in: doc) == nil { output.append(NSAttributedString(string: "\nNative formatting fallback · edit in Raven", attributes: [.font: TranscriptStyle.secondaryFont(metrics), .foregroundColor: NSColor.themeSecondaryText])) } }
                    else if !message.html.isEmpty { output.append(NSAttributedString(string: "[Message cannot be safely rendered · open Raven for the full content]", attributes: [.font: ThemeFonts.readingBody(ofSize: size), .foregroundColor: NSColor.themeText])) }
                    else if message.messageType == "Poll" { output.append(NSAttributedString(string: "Poll: \(message.raw["content"].string ?? "Choose View / Vote in Poll from Conversation.")", attributes: [.font: ThemeFonts.readingBody(ofSize: size), .foregroundColor: NSColor.themeText])) }
                    else if message.messageType != "File" && message.messageType != "Image" { output.append(NSAttributedString(string: message.raw["content"].string.map { String($0.prefix(4096)) } ?? "[\(message.messageType) message — open in Raven for details]", attributes: [.font: ThemeFonts.readingBody(ofSize: size), .foregroundColor: NSColor.themeText])) }
                    // Raven keeps edits visible: a small "(edited)" follows the text.
                    if message.raw["is_edited"].bool, pendingSend == nil, output.length > inkStart {
                        output.append(TranscriptStyle.editedMark(afterLineBreak: (output.string as NSString).character(at: output.length - 1) == 10, metrics: metrics))
                    }
                    if pendingSend == nil, let marks = TranscriptStyle.stateMarks(pinned: pinnedIDs.contains(message.id), saved: MessageMarks.isSaved(message, by: session.account.user), afterLineBreak: output.length == inkStart || (output.string as NSString).character(at: output.length - 1) == 10, metrics: metrics) {
                        output.append(marks)
                    }
                    // One preview, for the message's first link, as Raven's web
                    // client shows it; none when the sender hid it.
                    if pendingSend == nil, !message.html.isEmpty, case .parsed(let document) = session.messageDocument(for: message),
                       let raw = SentLinkPreviewPresentation.previewedLink(of: message, in: document) {
                        session.sentLinkPreviews.request(raw, session: session)
                        if let preview = session.sentLinkPreviews.preview(for: raw) {
                            output.append(TranscriptMedia.linkCard(preview, image: session.sentLinkPreviews.image(for: raw), imageFailed: session.sentLinkPreviews.imageFailed(raw), metrics: metrics, afterText: output.length > bodyStart))
                        }
                    }
                    let attachmentLink = TranscriptStyle.attachmentLink(for: message.id)
                    // Media takes a line of its own: below a caption, or at the
                    // start of a message without one.
                    func continuesLine() -> Bool { output.length > bodyStart && (output.string as NSString).character(at: output.length - 1) != 10 }
                    if let filename = TranscriptMedia.filename(of: message) {
                        if message.messageType == "Image" {
                            // The picture, or until it loads a box of its size;
                            // the file name is in its tooltip and copies.
                            let image = session.thumbnails[message.id]
                            // A GIF plays over its first frame while it is in view.
                            let animatedKey = AnimatedImageKey.message(message.id)
                            let animated = image != nil && (session.animatedSources[animatedKey] != nil || session.animatedImages.contains(animatedKey))
                            output.append(TranscriptMedia.picture(image, size: session.pictureBox(for: message), filename: filename, link: attachmentLink, animatedKey: animated ? animatedKey : nil, newLine: continuesLine(), afterText: output.length > bodyStart))
                        } else {
                            let detail = AttachmentDetails.summary(filename: filename, byteCount: message.raw["file_size"].nonnegativeCount)
                            output.append(TranscriptMedia.fileCard(filename: filename, detail: detail, link: attachmentLink, metrics: metrics, newLine: continuesLine(), afterText: output.length > bodyStart))
                        }
                    }
                    if let doctype = message.raw["link_doctype"].string, !doctype.isEmpty {
                        let documentID = message.raw["link_document"].string ?? ""
                        let title = documentID.isEmpty ? doctype : "\(doctype) · \(documentID)"
                        output.append(NSAttributedString(
                            string: "\nLinked document: \(title)",
                            attributes: [.font: TranscriptStyle.secondaryFont(metrics), .foregroundColor: NSColor.themeSecondaryText]))
                    }
                    // Staged files show as the cards they will be, without a link:
                    // there is nothing on the server to open yet.
                    for attachment in pendingSend?.attachments ?? [] {
                        let detail = AttachmentDetails.summary(filename: attachment.filename, byteCount: TranscriptMedia.stagedByteCount(attachment))
                        output.append(TranscriptMedia.fileCard(filename: attachment.filename, detail: detail, link: nil, metrics: metrics, newLine: continuesLine(), afterText: output.length > bodyStart))
                    }
                    if metrics.bodyLineSpacing > 0, output.length > bodyStart { TranscriptStyle.addLineSpacing(metrics.bodyLineSpacing, to: output, in: NSRange(location: bodyStart, length: output.length - bodyStart)) }
                    let inkBody = NSRange(location: inkStart, length: output.length - inkStart)
                    inkBodies[message.id] = inkBody
                    if let pendingSend {
                        inkPending.append(.init(operation: pendingSend, body: inkBody))
                        // Said in words too: color and the drop are not the only signals.
                        if InkWetness(pendingSend.state) != .flowing { output.append(TranscriptStyle.pendingStatus(state: pendingSend.state.localizedLabel(), error: pendingSend.error, metrics: metrics)) }
                    }
                    let reactions = message.raw["message_reactions"].nested
                    if let chips = ReactionChip.chips(reactions, currentUser: session.account.user) { output.append(TranscriptStyle.reactions(chips, metrics: metrics)) }
                    else if reactions != .null && reactions != .object([:]) && reactions != .array([]) { output.append(NSAttributedString(string: "\nReactions: \(self.summary(reactions))", attributes: [.font: TranscriptStyle.secondaryFont(metrics), .foregroundColor: NSColor.themeSecondaryText])) }
                    if continues[index], !metrics.compact, output.length > bodyStart { output.addAttribute(.nevermoreGutterTime, value: session.compactTime(message.creation), range: NSRange(location: bodyStart, length: 1)) }
                    output.append(TranscriptStyle.separator(metrics: metrics, nextContinuesGroup: index + 1 < messages.count && continues[index + 1]))
                    if pendingSend == nil { self.messageRanges.append((NSRange(location: start, length: output.length - start), message)) }
                }
                session.loadAvatars(authors)
                self.codeCommands = commands; self.expandedCode.formIntersection(visibleCode)
                self.restoringTranscriptSelection = true
                // Locations move with new text; the pointer marks a card again when it moves.
                self.transcript.hoveredCardLocation = nil
                self.transcript.textStorage?.setAttributedString(output)
                if let anchoredCaret, let range = self.messageRanges.first(where: { $0.1.id == anchoredCaret.id })?.0 {
                    // Keep the caret strictly inside the message: a
                    // location at NSMaxRange would attribute to the next
                    // message when the caret's message shrank.
                    let location = range.location + min(anchoredCaret.offset, max(range.length - 1, 0))
                    self.transcript.setSelectedRange(NSRange(location: location, length: 0))
                } else if anchoredCaret != nil {
                    // The caret's own message is gone. Collapse to the
                    // nearest surviving message rather than jump to the top.
                    let probe = min(selection.location, max(output.length - 1, 0))
                    let fallback = self.messageRanges.first(where: { NSLocationInRange(probe, $0.0) })
                        ?? self.messageRanges.min(by: { abs($0.0.location - probe) < abs($1.0.location - probe) })
                    if let fallback { self.transcript.setSelectedRange(NSRange(location: fallback.0.location, length: 0)) }
                } else if NSMaxRange(selection) <= output.length {
                    self.transcript.setSelectedRange(selection)
                }
                self.restoringTranscriptSelection = false
                self.transcript.layoutManager?.ensureLayout(for: self.transcript.textContainer!)
                // Character offsets moved; follow the messages, not the offsets.
                self.transcript.hoverMessageLocation = self.hoveredMessageID.flatMap { id in self.messageRanges.first { $0.1.id == id }?.0.location }
                if self.transcript.highlightRect != nil { self.updateMessageHighlight() } else { self.transcript.caretMessageLocation = nil }
                if following { self.transcript.scrollToEndOfDocument(nil) }
                // A requested message is shown by the first render that has
                // it, which is at once when it is cached, and not only when
                // the server answers.
                else if let placement = self.requestedPlacement, let requested = self.requestedAnchor, let range = self.messageRanges.first(where: { $0.1.id == requested })?.0 {
                    self.requestedPlacement = nil
                    switch placement {
                    case .inView: self.scrollMessageIntoView(range)
                    case .belowTop(let offset):
                        self.transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: max(self.minimumTranscriptOrigin, self.rect(for: range).minY - offset)))
                        self.transcriptScroll.reflectScrolledClipView(self.transcriptScroll.contentView)
                    }
                }
                else if let (id, offset) = visibleAnchor, let range = self.messageRanges.first(where: { $0.1.id == id })?.0 { self.transcriptScroll.contentView.scroll(to: NSPoint(x: 0, y: max(self.minimumTranscriptOrigin, self.rect(for: range).minY - offset))); self.transcriptScroll.reflectScrolledClipView(self.transcriptScroll.contentView) }
                self.transcriptAccessibility.refresh()
                self.isUpdatingTranscript = false
                self.ink.didRender(pending: inkPending, bodies: inkBodies, messages: self.messages, following: following, previousOrigin: oldOrigin)
                self.stickers.didRender()
                self.animatedImages.update()
                self.repositionQuickReactions()
                self.seenVisible(); self.viewportKeeper.capture(); self.restorePendingInspector()
            } catch {
                if error is CancellationError || Task.isCancelled { return }
                guard let self else { return }
                self.status.stringValue = error.localizedDescription
                // No render follows a failed one. Rows of this conversation
                // that are still in the pane are what the reader has, so
                // they are observed again. Rows of another stay ignored.
                if self.isCurrent(session, channelID: channel.id), self.messages.allSatisfy({ $0.channelID == channel.id }) { self.isUpdatingTranscript = false }
            }
        }
    }
    func rect(for range: NSRange) -> NSRect {
        guard let layout = transcript.layoutManager, let container = transcript.textContainer else { return .zero }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var r = layout.boundingRect(forGlyphRange: glyphs, in: container); r.origin.y += transcript.textContainerInset.height; return r
    }
    var visibleMessageForReadReceipt: RavenMessage? {
        // Context and history navigation cannot acknowledge intervening rows,
        // and a pane that still shows other text has nothing to acknowledge.
        guard receiptWindowOpen else { return nil }
        return receiptCandidate(entries: messageEntries(intersecting: readableTranscriptRect))
    }
    /// The receipt rule shared by the live path and the published property,
    /// so a test probe and `seenVisible()` cannot drift apart.
    private func receiptCandidate(entries: [(NSRange, RavenMessage)]) -> RavenMessage? {
        guard receiptWindowOpen else { return nil }
        return entries.last?.1
    }
    /// True when the visible band is live transcript content eligible for a
    /// read receipt.
    private var receiptWindowOpen: Bool {
        !isUpdatingTranscript && requestedAnchor == nil && historyUpperID == nil
    }
    /// The messages whose text intersects `visible`, in order. Messages are
    /// laid out top to bottom in `messageRanges` order, so a binary search
    /// finds the first one and the scan stops below the band: a scroll step
    /// measures a few messages instead of all 500 (about 0.1 ms instead of
    /// 4 ms for two passes on an M4 Max).
    func messageEntries(intersecting visible: NSRect) -> [(NSRange, RavenMessage)] {
        var low = 0, high = messageRanges.count
        while low < high {
            let middle = (low + high) / 2
            if rect(for: messageRanges[middle].0).maxY <= visible.minY { low = middle + 1 } else { high = middle }
        }
        var found: [(NSRange, RavenMessage)] = []
        var index = low
        while index < messageRanges.count {
            let entry = messageRanges[index]
            let frame = rect(for: entry.0)
            guard frame.minY < visible.maxY else { break }
            if visible.intersects(frame) { found.append(entry) }
            index += 1
        }
        return found
    }
    func seenVisible() {
        guard !isUpdatingTranscript else { return }
        let visible = readableTranscriptRect
        let includesLatest: Bool
        if let latest = latestAuthorizedMessageID {
            includesLatest = messages.last.map { $0.id.utf8.elementsEqual(latest.utf8) } == true
        } else { includesLatest = messages.isEmpty }
        // The bottom of a bounded historical slice is not the live edge.
        // Advancing the frontier there would hide unseen canonical tail rows.
        isFollowing = includesLatest && historyUpperID == nil && requestedAnchor == nil && visible.maxY >= transcript.bounds.maxY - 30
        if isFollowing { readPosition.followedLatest() }
        updateReadPositionControl()
        let inView = messageEntries(intersecting: visible)
        // Preview pictures load in any window that shows them, as they did
        // when every card fetched its own.
        if let session { for entry in inView { session.sentLinkPreviews.loadImage(for: entry.1, session: session) } }
        guard NSApp.isActive, window?.isKeyWindow == true, let session, let channel else { return }
        // `visible` is `readableTranscriptRect`: only the band between the
        // toolbar and the floating composer. The one scan above feeds preview
        // pictures, thumbnails and the read receipt candidate, and
        // `receiptCandidate` is the same rule `visibleMessageForReadReceipt`
        // publishes.
        for entry in inView { session.loadThumbnail(entry.1) }
        guard let message = receiptCandidate(entries: inView) else { return }
        // Server timestamps are fixed-width single-timezone text, which the
        // store and `Session.markSeen` already order lexicographically; an
        // older bottom row scrolled back into view needs no second request.
        if let last = lastSeenReceipt, last.channelID == channel.id, last.creation >= message.creation { return }
        // `markSeen` is best-effort and cannot throw; its local failures call
        // `fail()`, so remembering the candidate here does not drop a retry.
        lastSeenReceipt = (channel.id, message.creation)
        Task { await session.markSeen(channelID: channel.id, timestamp: message.creation) }
    }
    func windowDidBecomeKey(_ notification: Notification) { lastSeenReceipt = nil; seenVisible(); if channel != nil { session?.requestReconciliation() } else { home.refreshIfShown() } }
    /// Keep the toolbar (search, navigation, collections) in full screen, as
    /// Mail and Safari do by default; only the menu bar hides.
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.subtracting(.autoHideToolbar).union([.fullScreen, .autoHideMenuBar])
    }
    func windowWillClose(_ notification: Notification) { cancelSidebarKeyboardOpen(); dayPillFade?.cancel(); channelDetailsSheet?.close(); channelDetailsSheet = nil; inlineComposer.tearDown(); ComposerEditorLifetime.cancel(attachedTo: window); rememberWindowFrame(); linkPreview.cancel(); ink.detach(); unkindness.reset(); stickers.detach(); clearReadPosition(); latestAuthorizedMessageID = nil; transcriptAccessibility.clear(); statusAnnouncements.invalidate(); cancelEmojiPicker(); gifSelectionTask?.cancel(); closePollWindows(); searchView.reset(session: nil); outboxWindow?.close(); outboxWindow = nil; isClosed = true; cancelPromisedFiles(); threadContextTask?.cancel(); threadRoot = nil; closeCodeReaders(); restoreInspectorTask?.cancel(); conversationChooser?.cancel(); conversationChooser = nil; memberRoster?.cancel(); memberRoster = nil; closeThreadInspector(); mentionPopover.reset(); for collection in Array(collectionWindows) { collection.close() }; collectionWindows.removeAll(); clearPreview(); session?.attach(window: windowID, channelID: nil); loadTask?.cancel(); renderTask?.cancel(); viewportKeeper.invalidate(); animatedImages.invalidate(); for token in observerTokens { NotificationCenter.default.removeObserver(token) }; app.windows.removeAll { $0 === self } }
    func restorePendingInspector() {
        guard let state = pendingRestoration, let rootID = state.threadRootID, let session, channel?.id == state.location.channelID, session.account.id == state.accountID else { return }
        pendingRestoration?.threadRootID = nil
        restoreInspectorTask = Task { [weak self] in
            do {
                var parent = try await session.cachedMessages(channelID: state.location.channelID, limit: 5000).first { $0.id == rootID }
                if parent == nil && !session.demo { parent = RavenMessage(raw: try await session.client.resource("Raven Message", name: rootID, values: nil)) }
                guard !Task.isCancelled, let self, self.isCurrent(session, channelID: state.location.channelID), let parent, parent.channelID == state.location.channelID else { return }
                self.showThreadInspector(root: parent)
            } catch { /* An offline/denied inspector restoration never replaces the main conversation. */ }
        }
    }
    func showThreadInspector(root: RavenMessage) {
        guard let session, !session.stopped, !session.revokedChannels.contains(root.channelID) else { return }
        if (window?.frame.width ?? 0) < ThreadInspector.minimumWindowWidth {
            // A deliberate request in a narrow window keeps the documented
            // separate-window route. Resizing itself never opens that window.
            app.open(session: session, channel: threadChannel(forRoot: root))
            return
        }
        closeThreadInspector(); closeFileInspector()
        let inspector = ThreadInspector(session: session, rootMessage: root, conversation: self)
        inspector.onInvalidated = { [weak self] in self?.closeThreadInspector() }
        threadInspector = inspector
        let item = NSSplitViewItem(inspectorWithViewController: inspector)
        item.minimumThickness = 280; item.maximumThickness = 520; item.canCollapse = false
        // Opens at 320 pt; below the divider-drag priority so it stays resizable.
        let width = inspector.view.widthAnchor.constraint(equalToConstant: 320); width.priority = NSLayoutConstraint.Priority(500); width.isActive = true
        inspectorSplitItem = item; inspectorCollapsedByWidth = false
        syncInspectorItems()
        updateThreadInspectorHiddenAffordance()
        inspector.start()
    }
    func closeThreadInspector() {
        if let inspector = threadInspector {
            inspector.onInvalidated = nil
            inspector.detach()
        }
        if let item = inspectorSplitItem, splitController.splitViewItems.contains(item) {
            splitController.removeSplitViewItem(item)
        }
        inspectorSplitItem = nil; threadInspector = nil
        inspectorCollapsedByWidth = false
        updateThreadInspectorHiddenAffordance()
    }
    /// Hides the open inspector while the window is too narrow. The pane and
    /// everything it preserves come back in `restoreThreadInspectorAfterWidening`.
    func collapseThreadInspectorForNarrowWindow() {
        guard !inspectorCollapsedByWidth, threadInspector?.isDetached == false,
              (window?.frame.width ?? 0) < ThreadInspector.minimumWindowWidth else { return }
        inspectorCollapsedByWidth = true
        syncInspectorItems()
        updateThreadInspectorHiddenAffordance()
    }
    /// Restores an inspector the window temporarily hid, with its root and
    /// scroll position untouched.
    func restoreThreadInspectorAfterWidening() {
        guard inspectorCollapsedByWidth, threadInspector != nil else { return }
        inspectorCollapsedByWidth = false
        syncInspectorItems()
        updateThreadInspectorHiddenAffordance()
    }
    /// Puts the thread and File panes in the split view as their state
    /// asks. The File panel covers an open thread, and a narrow window
    /// hides either until it widens; hidden panes keep their state.
    private func syncInspectorItems() {
        let wanted: [(NSSplitViewItem?, Bool)] = [
            (fileSplitItem, fileInspector != nil && !fileInspectorCollapsedByWidth),
            (inspectorSplitItem, threadInspector != nil && !inspectorCollapsedByWidth && fileInspector == nil),
        ]
        // Remove before adding, so the window never holds both panes.
        for case let (item?, shown) in wanted where !shown && splitController.splitViewItems.contains(item) { splitController.removeSplitViewItem(item) }
        for case let (item?, shown) in wanted where shown && !splitController.splitViewItems.contains(item) { splitController.addSplitViewItem(item) }
    }
    /// Keeps the narrow-window affordance and the key view loop in step with
    /// whether the hidden thread is still reachable.
    private func updateThreadInspectorHiddenAffordance() {
        let hidden = inspectorCollapsedByWidth && threadInspector?.isDetached == false
        threadInspectorHiddenButton.isHidden = !hidden
        transcript.nextKeyView = hidden ? threadInspectorHiddenButton : attachButton
        threadInspectorHiddenButton.nextKeyView = attachButton
    }
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard client is NSSearchField else { return nil }
        return (sender as? ConversationNativeWindow)?.attachmentFieldEditor
    }
    private func rememberWindowFrame() {
        guard let name = lastFrameAutosaveName, let window, window.isVisible,
              !isClosed, !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: name)
    }
    func windowDidMove(_ notification: Notification) { rememberWindowFrame() }
    func windowDidResize(_ notification: Notification) {
        rememberWindowFrame()
        let narrowForFile = (window?.frame.width ?? 0) < FileInspector.minimumWindowWidth
        if fileInspector != nil, fileInspectorCollapsedByWidth != narrowForFile { fileInspectorCollapsedByWidth = narrowForFile; syncInspectorItems() }
        guard threadInspector != nil else { return }
        if inspectorCollapsedByWidth {
            if (window?.frame.width ?? 0) >= ThreadInspector.minimumWindowWidth { restoreThreadInspectorAfterWidening() }
        } else if (window?.frame.width ?? 0) < ThreadInspector.minimumWindowWidth {
            collapseThreadInspectorForNarrowWindow()
        }
    }
    @objc func toggleThreadInspector(_ sender: Any?) {
        if inspectorCollapsedByWidth { openThreadInspectorInWindow(sender); return }
        // A thread under the File panel comes back when the panel closes.
        if threadInspector != nil, fileInspector != nil { closeFileInspector(); return }
        if threadInspector != nil { closeThreadInspector() } else { openThread(sender) }
    }

    /// The local shape of a thread channel. An inspector has already attached
    /// its room, so opening it elsewhere needs no further server round trip.
    private func threadChannel(forRoot root: RavenMessage) -> RavenChannel {
        RavenChannel(raw: .object(["name": .string(root.id), "channel_name": .string("Thread · \(root.owner)"), "is_thread": .bool(true), "parent_channel_id": .string(root.channelID)]))
    }
    /// Opens the open thread in its own window. This is the keyboard
    /// affordance used while a narrow window has hidden the inline pane.
    @objc func openThreadInspectorInWindow(_ sender: Any?) {
        guard let session, let inspector = threadInspector else { return }
        guard inspector.hasAccess else { closeThreadInspector(); return }
        app.open(session: session, channel: threadChannel(forRoot: inspector.rootMessage))
    }
    /// A click on a reply's quote goes to the message it answers: in place
    /// when it is loaded, otherwise with the messages around it, the way a
    /// search result opens (Go ▸ Back returns).
    func showQuotedMessage(_ id: String) {
        guard let channel, editing == nil || messageRanges.contains(where: { $0.1.id == id }) else { return }
        guard let range = messageRanges.first(where: { $0.1.id == id })?.0 else { select(channel, anchor: id); return }
        isFollowing = false
        scrollMessageIntoView(range)
        transcript.setSelectedRange(NSRange(location: range.location, length: 0))
        window?.makeFirstResponder(transcript)
        updateMessageHighlight()
    }
    func scrollTo(_ id: String) { if let range = messageRanges.first(where: { $0.1.id == id })?.0 { transcript.scrollRangeToVisible(range); scrollMessageIntoView(range); transcript.setSelectedRange(range); isFollowing = false } }
    func loadThreadContext() {
        guard let session, let channel, let parentID = channel.raw["parent_channel_id"].string else { return }
        let generation = navigationGeneration
        threadContextTask = Task { [weak self] in
            let cached = try? await session.cachedMessages(channelID: parentID, limit: 1000)
            var root = cached?.first { $0.id == channel.id }
            if root == nil && !session.demo, let raw = try? await session.client.resource("Raven Message", name: channel.id, values: nil) { root = RavenMessage(raw: raw) }
            guard let self, !Task.isCancelled, self.navigationGeneration == generation, self.isCurrent(session, channelID: channel.id), !session.revokedChannels.contains(parentID), root?.channelID == parentID else { return }
            self.threadRoot = root; self.updateContext()
        }
    }
    @objc func showInParentChannel(_ sender: Any?) {
        guard let session, let channel, let parentID = channel.raw["parent_channel_id"].string,
              let parent = session.channels.first(where: { $0.id == parentID }), !session.revokedChannels.contains(parentID) else { return }
        select(parent, anchor: channel.id)
    }
    /// Whether a draft says anything. The composer's own string is no guide:
    /// an empty quote or list item still shows its marker ("│ ", "• ").
    /// An unreadable draft is an error, not an empty message or permission
    /// to send unchecked content. The send action reports it to the user.
    static func hasText(_ draft: Draft) throws -> Bool {
        let document = try RichTextCodec.parse(draft.validatedHTML())
        return !RichTextCodec.plainText(document, revealSpoilers: true).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func currentDraft() throws -> Draft {
        guard let channel else { throw AppError.message("Choose a conversation first.") }
        let document = try inlineComposer.currentDocument()
        return Draft(channelID: channel.id, html: RichTextCodec.html(document), replyTo: replyTo, attachments: attachments, caret: composer.selectedRange().location, editorState: inlineComposer.draftEditorState)
    }
    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === composer else { return }
        updateCompletions(); updateLinkPreview()
        persistActiveDraft()
    }
    func persistActiveDraft() {
        guard !applyingDraft, !inlineComposer.applying else { return }
        updateComposerHeight()
        guard editing == nil, let session, let channel else { return }
        let draft: Draft
        do {
            draft = try currentDraft()
            if status.stringValue == draftErrorMessage { status.stringValue = session.state }
            draftErrorMessage = nil
        } catch {
            guard inlineComposer.mode == .markdown else {
                draftEncodingFailure = error; draftErrorMessage = error.localizedDescription; status.stringValue = error.localizedDescription
                session.draftRevisions[channel.id, default: 0] += 1
                session.invalidDraftChannels.insert(channel.id)
                session.recoverableDrafts[channel.id] = Draft(channelID: channel.id, replyTo: replyTo, attachments: attachments, caret: composer.selectedRange().location)
                return
            }
            // Invalid source is still a fully recoverable local draft.
            draft = Draft(channelID: channel.id, html: displayedHTML, replyTo: replyTo, attachments: attachments,
                          caret: composer.selectedRange().location, editorState: inlineComposer.editorState)
            status.stringValue = error.localizedDescription
            draftErrorMessage = error.localizedDescription
        }
        draftEncodingFailure = nil
        session.composerModes[channel.id] = inlineComposer.mode
        session.draftRevisions[channel.id, default: 0] += 1
        let revision = session.draftRevisions[channel.id, default: 0]
        session.unpersistedDraftRevisions[channel.id] = revision
        session.recoverableDrafts[channel.id] = draft
        session.invalidDraftChannels.remove(channel.id)
        displayedHTML = draft.html
        // Publish the recoverable snapshot before disk I/O, so a peer cannot
        // send the previous source while this save is in flight.
        for peer in app.windows where peer !== self && peer.session === session && peer.channel?.id == channel.id && peer.editing == nil && !peer.activeComposer.hasMarkedText() {
            peer.inlineComposer.load(draft.editorState)
        }
        saveTask = Task { [weak self] in
            do { try await session.save(draft, revision: revision) }
            catch { if let self, self.isCurrent(session, channelID: draft.channelID) { self.status.stringValue = "Draft not saved: \(error.localizedDescription)" } }
        }
    }
    func updateCompletions() {
        guard let session, composer.isEditable, !applyingDraft, channel != nil else { mentionPopover.close(); return }
        // The pool covers every user and channel, so build it only when a
        // trigger is actually at the caret; the query scan is a short
        // backwards read, the pool is O(directory).
        let editor = activeComposer
        guard MentionCompletion.query(in: editor.string, selection: editor.selectedRange(), hasMarkedText: editor.hasMarkedText()) != nil else { mentionPopover.close(); return }
        if let cache = mentionPoolCache, cache.directoryVersion == session.directoryVersion, cache.channelsVersion == session.channelsVersion,
           cache.generation == session.generation, cache.revokedCount == session.revokedChannels.count {
            mentionPopover.update(textView: editor, pool: cache.pool)
            return
        }
        let people = session.userNames.map { MentionCandidate(kind: .person, serverID: $0.key, title: $0.value, detail: $0.key) }
        let channels = session.channels.filter { !$0.isDM && !session.revokedChannels.contains($0.id) }.map { MentionCandidate(kind: .channel, serverID: $0.id, title: $0.title, detail: $0.workspace) }
        let pool = people + channels
        mentionPoolCache = (session.directoryVersion, session.channelsVersion, session.generation, session.revokedChannels.count, pool)
        mentionPoolBuilds += 1
        mentionPopover.update(textView: editor, pool: pool)
    }
    func textViewDidChangeSelection(_ notification: Notification) {
        if notification.object as? NSTextView === composer { updateCompletions(); composerFormatting.updateSelection() }
        if notification.object as? NSTextView === transcript { fileInspectorFollowSelection() }
    }
    func insertMention(_ candidate: MentionCandidate, query: MentionQuery) {
        if inlineComposer.mode == .markdown {
            guard let session, !session.stopped, activeComposer.isEditable, !activeComposer.hasMarkedText(),
                  MentionCompletion.query(in: activeComposer.string, selection: activeComposer.selectedRange()) == query else { return }
            let html = RichTextCodec.html(RichDocument(nodes: [candidate.node]))
            activeComposer.insertText(html + " ", replacementRange: query.range)
            composer.undoManager?.setActionName(candidate.kind == .person ? "Mention Person" : "Mention Channel")
            mentionPopover.close(); focusComposer(); return
        }
        guard composer.isEditable, !composer.hasMarkedText(), let session, !session.stopped, NSMaxRange(query.range) <= composer.string.utf16.count,
              MentionCompletion.query(in: composer.string, selection: composer.selectedRange()) == query else { return }
        let typing = composer.typingAttributes.filter { !$0.key.rawValue.hasPrefix("Nevermore.") || ["Nevermore.BlockKind","Nevermore.ListType","Nevermore.ListNumber","Nevermore.MarkerLength","Nevermore.Paragraph"].contains($0.key.rawValue) }
        let document = RichDocument(nodes: [candidate.node, .text(" ")])
        composer.breakUndoCoalescing()
        let undo = composer.undoManager
        undo?.beginUndoGrouping()
        composer.insertText(NativeRichText.attributedString(document: document), replacementRange: query.range)
        undo?.setActionName(candidate.kind == .person ? "Mention Person" : "Mention Channel")
        undo?.endUndoGrouping()
        composer.breakUndoCoalescing()
        composer.typingAttributes = typing; mentionPopover.close(); focusComposer()
    }
    func editLastOwnMessage() -> Bool {
        guard editing == nil, let session, let entry = messageRanges.last(where: { $0.1.owner == session.account.user && $0.1.messageType == "Text" }), !session.readOnly else { return false }
        transcript.setSelectedRange(NSRange(location: entry.0.location, length: 0)); editMessage(nil); return editing != nil
    }
    func restoreDraft() {
        guard let session, let channel else { return }
        let revision = session.draftRevisions[channel.id, default: 0]
        Task { [weak self] in
            do {
                let draft: Draft?
                if let pending = session.recoverableDrafts[channel.id] { draft = pending }
                else { draft = try await session.store.draft(channelID: channel.id) }
                guard let self, self.channel?.id == channel.id, self.session === session, self.editing == nil, session.draftRevisions[channel.id, default: 0] == revision else { return }
                // The input method owns marked text until it commits. Its
                // eventual edit publishes a new shared draft revision.
                guard !self.activeComposer.hasMarkedText() else { return }
                let html = draft?.html ?? ""
                let retainedMode = session.composerModes[channel.id] ?? .visual
                if self.inlineComposer.editorState != draft?.editorState {
                    self.inlineComposer.load(draft?.editorState ?? ((draft?.html.isEmpty ?? true) && retainedMode == .markdown ? DraftEditorState(mode: .markdown) : nil))
                }
                if !session.invalidDraftChannels.contains(channel.id), self.displayedHTML != html {
                    let liveHTML = try? RichTextCodec.html(NativeRichText.document(from: self.composer.attributedString()))
                    if liveHTML != html {
                        self.applyingDraft = true
                        defer { self.applyingDraft = false }
                        let value = try RichTextCodec.parse(html)
                        self.composer.textStorage?.setAttributedString(NativeRichText.attributedString(document: value, revealSpoilers: true))
                        self.composer.setSelectedRange(NSRange(location: min(draft?.caret ?? 0, self.composer.string.utf16.count), length: 0))
                    }
                    if self.composer.string.isEmpty { self.composer.typingAttributes = NativeRichText.plainTypingAttributes }
                    self.displayedHTML = html
                }
                self.draftEncodingFailure = session.invalidDraftChannels.contains(channel.id) ? RichTextError.unsafeEdit : nil
                if self.draftEncodingFailure != nil { self.status.stringValue = "This draft needs attention before it can be saved. Its original text is still here." }
                self.attachments = draft?.attachments ?? []; self.replyTo = draft?.replyTo; self.updateContext()
                if self.inlineComposer.mode == .markdown {
                    do { _ = try self.inlineComposer.currentDocument() }
                    catch { self.status.stringValue = error.localizedDescription }
                }
                // Emptying the shared draft does not resize the editor's
                // frame, so no frame notification shrinks the composer.
                self.updateComposerHeight()
            } catch { if error is CancellationError || Task.isCancelled { return }; self?.status.stringValue = error.localizedDescription }
        }
    }
    func updateComposerAvailability() {
        composer.isEditable = !isClosed && channel != nil && session?.stopped == false && !app.isPreparingToQuit && !isAcceptingSend && !(channel.map { (session?.acceptingChannels.contains($0.id) == true || session?.preparingChannels.contains($0.id) == true) } ?? false)
        composerFormatting.isEnabled = composer.isEditable
        gifButton.isEnabled = composer.isEditable && gifSelectionTask == nil
        inlineComposer.configureSource()
        if !composer.isEditable { mentionPopover.close() }
    }
    func updateContext() {
        updateStatusAnnouncements()
        if editing != nil { context.stringValue = "Editing your message"; contextIcon.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil) }
        else if let replyTo { context.stringValue = "Replying to \(messageSummary(for: replyTo))"; contextIcon.image = NSImage(systemSymbolName: "arrowshape.turn.up.left", accessibilityDescription: nil) }
        else if let root = threadRoot {
            // Through the bounded document cache: updateContext runs on
            // every session notification, and a direct parse would decode a
            // large root again each time.
            let plain: String
            if let session, case .parsed(let document) = session.messageDocument(for: root) { plain = RichTextCodec.plainText(document) } else { plain = "" }
            let preview = plain.isEmpty ? "[\(root.messageType)]" : String(plain.prefix(240))
            context.stringValue = "Thread · \(session?.userNames[root.owner] ?? root.owner) · \(preview)"
            contextIcon.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)
        } else {
            context.stringValue = isArchivedConversation ? "Archived conversation · your local draft remains saved" : channel?.raw["is_thread"].bool == true ? "Thread · Conversation ▸ Show in Channel opens its parent" : ""
            contextIcon.image = NSImage(systemSymbolName: isArchivedConversation ? "archivebox" : "bubble.left.and.text.bubble.right", accessibilityDescription: nil)
        }
        let importing = session?.pendingFileReceipts.values.contains(channel?.id ?? "") == true
        attachmentLabel.stringValue = importing ? (promisedReceives.isEmpty ? "Receiving files in another window…" : "Receiving files…") : ""
        updateAttachmentChips()
        updateLinkPreview()
        updateComposerAvailability()
        let sendLabel = editing == nil ? "Send" : "Save Edit"
        sendButton.image = NSImage(systemSymbolName: editing == nil ? "arrow.up.circle.fill" : "checkmark.circle.fill", accessibilityDescription: sendLabel)
        sendButton.setAccessibilityLabel(sendLabel); sendButton.toolTip = editing == nil ? "Send (Return)" : "Save Edit (Return)"
        sendButton.isEnabled = composer.isEditable && channel != nil && !isArchivedConversation && (session?.pendingFileReceipts.values.contains(channel?.id ?? "") != true) && !isAcceptingSend && session?.readOnly != true && session?.stopped != true && !(session?.revokedChannels.contains(channel?.id ?? "") ?? false) && !(channel?.raw["parent_channel_id"].string.flatMap { session?.revokedChannels.contains($0) } ?? false)
    }
    func updateStatusAnnouncements() {
        guard !isClosed, let session, !session.stopped, let window else { statusAnnouncements.invalidate(); return }
        var attention = Set<StatusAnnouncement>()
        if let accountAttention = session.statusAttention { attention.insert(accountAttention) }
        if let channel, ChannelPolicy.isRevoked(channelID: channel.id, revoked: session.revokedChannels, threadParents: session.threadParents) || (channel.raw["is_thread"].bool && session.deletedIDs.contains(channel.id)) {
            attention.insert(.conversationAccessLost)
        }
        let focused = NSApp.isActive && window.isKeyWindow && NSApp.keyWindow === window && window.attachedSheet == nil
        let composing = composer.hasMarkedText() || (window.firstResponder as? NSTextView)?.hasMarkedText() == true
        statusAnnouncements.update(attention: attention, isForegroundKeyWindow: focused, isComposing: composing, window: window, demo: session.demo)
    }
    func installStatusAnnouncementPostForSelfChecks(_ post: @escaping (String) -> Void) -> Bool {
        guard !isClosed, let session else { return false }
        return statusAnnouncements.installFixturePost(post, session: session)
    }
    func clearStatusAnnouncementPostForSelfChecks() {
        guard session?.demo == true else { return }
        statusAnnouncements.invalidate()
    }
    @objc func send(_ sender: Any?) {
        guard let session, let channel, !activeComposer.hasMarkedText(), !isAcceptingSend, !session.readOnly, !isArchivedConversation else { return }
        do {
            guard !session.preparingChannels.contains(channel.id), !session.acceptingChannels.contains(channel.id) else { return }
            guard !session.revokedChannels.contains(channel.id), channel.raw["parent_channel_id"].string.map(session.revokedChannels.contains) != true else { status.stringValue = "Access changed. Your draft is preserved."; return }
            guard !session.pendingFileReceipts.values.contains(channel.id) else { status.stringValue = "Files are still being received. Wait, or choose File → Cancel Receiving Files."; return }
            guard !app.windows.contains(where: { $0.session === session && $0.channel?.id == channel.id && $0.activeComposer.hasMarkedText() }) else { status.stringValue = "Finish text composition in the other window before sending."; return }
            // A shortcut the last key completed is formatted first, so the
            // message is what the composer shows right after.
            if inlineComposer.mode == .visual { composer.flushPendingShortcut() }
            // Then the web addresses that are still plain text become links.
            if inlineComposer.mode == .visual { composer.linkAllAddresses() }
            let draft = try currentDraft()
            guard try Self.hasText(draft) || !attachments.isEmpty else { return }
            var sendSilently = false
            if editing == nil {
                switch OutgoingPolicy.decision(now: Date(), workingHours: session.workingHours, timezone: session.account.timezone, preference: session.userPreferences?.supportedQuietHoursNudge ?? .noNudge) {
                case .normal: break
                case .silent: sendSilently = true
                case .ask:
                    let alert = NSAlert(); alert.messageText = "Outside site working hours"
                    alert.informativeText = "Send without notifying your teammates? The site timezone is \(session.account.timezone)."
                    alert.addButton(withTitle: "Send Silently"); alert.addButton(withTitle: "Send Normally"); alert.addButton(withTitle: "Cancel")
                    let choice = alert.runModal()
                    guard choice != .alertThirdButtonReturn, isCurrent(session, channelID: channel.id) else { return }
                    sendSilently = choice == .alertFirstButtonReturn
                }
            }
            let editTarget = editing
            let pendingSaves = app.windows.filter { $0.session === session && $0.channel?.id == channel.id }.compactMap(\.saveTask)
            if editing == nil { session.preparingChannels.insert(channel.id) }
            let silent = sendSilently
            sendButton.isEnabled = false; isAcceptingSend = true; mentionPopover.close(); session.notify(); updateComposerAvailability()
            if editTarget == nil { ink.lift() }
            Task { [weak self] in
                // Local acceptance belongs to the captured account and draft,
                // even when its initiating window closes before this task runs.
                defer { session.preparingChannels.remove(channel.id); self?.isAcceptingSend = false; session.notify(); if let self, !self.isClosed { self.updateContext() } }
                do {
                    for pending in pendingSaves { await pending.value }
                    guard !session.stopped, !session.readOnly, !ChannelPolicy.isArchived(channel, channels: session.channels), !session.revokedChannels.contains(channel.id) else { throw AppError.message("Conversation access changed before sending. Your draft is preserved.") }
                    if let editing = editTarget {
                        _ = try await session.mutateResource("Raven Message", name: editing.id, values: ["text": .string(draft.html)])
                        if let self, self.isCurrent(session, channelID: channel.id), self.editing?.id == editing.id {
                            self.editing = nil; if let storage = session.sharedTextStorage[channel.id] { self.composer.sharedUndoManager = session.draftUndoManagers[channel.id]; self.composer.useTextStorage(storage) }; self.displayedHTML = ""; self.restoreDraft()
                        }
                        try await session.load(channelID: channel.id)
                    } else {
                        let operation = try await session.send(draft, sendSilently: silent)
                        if let self, self.isCurrent(session, channelID: channel.id) { self.sendWasAccepted(); self.ink.accepted(operation) }
                        // The window moved on while the send was accepted.
                        else { self?.ink.sendFailed() }
                    }
                    if let self, self.isCurrent(session, channelID: channel.id) { self.updateContext() }
                } catch { self?.ink.sendFailed(); if let self, self.isCurrent(session, channelID: channel.id) { self.app.showError(error) } else if !session.stopped { session.fail(error) } }
            }
        } catch { status.stringValue = error.localizedDescription }
    }
    /// The draft became a queued message. It belongs at the newest end of
    /// the conversation, so a page of history or the context of an opened
    /// message gives way to the newest messages, where it can be seen.
    func sendWasAccepted() { inlineComposer.load(inlineComposer.mode == .markdown ? DraftEditorState(mode: .markdown) : nil); composer.undoManager?.removeAllActions(); restoreDraft(); followLatest(); render() }
    @objc func loadEarlier() { loadEarlierMessages(automatic: false) }
    /// Automatic loads come from scrolling to the top; they report failures
    /// in the status row instead of interrupting with an alert.
    func loadEarlierMessages(automatic: Bool) {
        // A pane that still holds another conversation's rows has no first
        // message of this one to count back from.
        guard !isUpdatingTranscript, let session, let channel, let first = messages.first, !isLoadingEarlier else { return }
        requestedAnchor = nil; isFollowing = false
        if messages.count >= 500 { historyUpperID = messages[max(0, messages.count - 101)].id }
        isLoadingEarlier = true; earlierProgress.startAnimation(nil)
        Task { [weak self] in
            defer { self?.isLoadingEarlier = false; self?.earlierProgress.stopAnimation(nil) }
            do { try await session.load(channelID: channel.id, olderThan: first.id) }
            catch {
                guard let self, self.isCurrent(session, channelID: channel.id), !(error is CancellationError) else { return }
                if automatic { self.status.stringValue = "Earlier messages could not be loaded: \(error.localizedDescription)" } else { self.app.showError(error) }
            }
        }
    }
    func messageSummary(for id: String) -> String {
        guard let message = messages.first(where: { $0.id == id }) else { return "a message" }
        let name = session?.authorName(message) ?? message.authorID
        let preview = replyPreview(message)
        return preview.isEmpty ? name : "\(name): \(preview)"
    }
    /// One line of a message's text, spoilers masked, for reply quotes.
    func replyPreview(_ message: RavenMessage) -> String {
        let plain: String
        if let session, case .parsed(let document) = session.messageDocument(for: message) { plain = RichTextCodec.plainText(document) } else { plain = "" }
        return String(plain.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ").prefix(120))
    }
    /// A sheet on this window, like Mail's attach panel, so other windows
    /// stay usable; the composer state is checked again when it closes.
    @objc func attachFiles(_ sender: Any?) {
        guard composer.isEditable, editing == nil, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.prompt = "Attach"; panel.message = channel.map { "Attach files to \($0.title)" } ?? ""
        let channelID = channel?.id
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let self, self.channel?.id == channelID, self.composer.isEditable, self.editing == nil else { return }
                self.stage(panel.urls)
            }
        }
    }
    func stage(_ urls: [URL]) {
        guard let session, let channel, !session.stopped, composer.isEditable else { return }
        guard editing == nil else { status.stringValue = "Finish editing the message before adding files."; return }
        let ticket = UUID(), originGeneration = navigationGeneration
        session.pendingFileReceipts[ticket] = channel.id
        promisedReceives[ticket] = Task { [weak self] in
            var staged: [StagedAttachment] = []
            defer {
                for url in urls where url.deletingLastPathComponent() == FileManager.default.temporaryDirectory && url.lastPathComponent.hasPrefix("NevermorePaste-") { try? FileManager.default.removeItem(at: url) }
                session.pendingFileReceipts.removeValue(forKey: ticket); self?.promisedReceives.removeValue(forKey: ticket); session.notify()
                if let self, self.isCurrent(session, channelID: channel.id) { self.updateContext() }
            }
            do {
                for url in urls {
                    try Task.checkCancellation()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    staged.append(try await session.store.stage(file: url))
                }
                try Task.checkCancellation()
                guard let self, self.isCurrent(session, channelID: channel.id), self.navigationGeneration == originGeneration, self.editing == nil, !session.revokedChannels.contains(channel.id) else { throw CancellationError() }
                self.attachments.append(contentsOf: staged); self.updateContext()
                self.textDidChange(Notification(name: NSText.didChangeNotification, object: self.composer))
            } catch {
                await Task { try? await session.store.pruneStaging(discarding: Set(staged.map(\.id))) }.value
                if let self, self.isCurrent(session, channelID: channel.id), !(error is CancellationError) { self.app.showError(error) }
            }
        }
        session.notify(); updateContext()
    }
    @objc func clearAttachments() { guard composer.isEditable else { return }; cancelPromisedFiles(); let ids = Set(attachments.map(\.id)); attachments = []; updateContext(); textDidChange(Notification(name: NSText.didChangeNotification, object: composer)); Task { await saveTask?.value; try? await session?.store.pruneStaging(discarding: ids) } }
    func cancelContext() { guard composer.isEditable else { return }; if editing != nil { editing = nil; if let channel, let storage = session?.sharedTextStorage[channel.id] { composer.sharedUndoManager = session?.draftUndoManagers[channel.id]; composer.useTextStorage(storage) }; displayedHTML = ""; restoreDraft() } else { replyTo = nil; textDidChange(Notification(name: NSText.didChangeNotification, object: composer)) }; updateContext() }
    var selectedMessage: RavenMessage? { messageRanges.first { NSLocationInRange(transcript.selectedRange().location, $0.0) }?.1 }
    @objc func reply(_ sender: Any?) {
        // While an edit is open the context row says "Editing" and the edit
        // save ignores replyTo; refuse instead of dropping the reply silently.
        guard composer.isEditable, editing == nil, let message = selectedMessage else { return }
        replyTo = message.id; updateContext(); focusComposer(); textDidChange(Notification(name: NSText.didChangeNotification, object: composer))
    }
    @objc func editMessage(_ sender: Any?) {
        // Starting a second edit would clobber the one already in progress.
        guard composer.isEditable, editing == nil, let message = selectedMessage, message.owner == session?.account.user else { return }
        do { let doc = try RichTextCodec.parse(message.html); guard doc.canEdit else { throw AppError.message("This message contains formatting Nevermore cannot safely edit. Open Raven in the browser to preserve it.") }; inlineComposer.load(nil); replyTo = nil; editing = message; composer.sharedUndoManager = UndoManager(); composer.useTextStorage(NSTextStorage(attributedString: NativeRichText.attributedString(document: doc, revealSpoilers: true))); updateContext(); textDidChange(Notification(name: NSText.didChangeNotification, object: composer)); focusComposer() } catch { app.showError(error) }
    }
    @objc func deleteMessage(_ sender: Any?) {
        // Deleting the message being edited would orphan the edit session.
        guard let message = selectedMessage, message.id != editing?.id, let session else { return }
        action {
            guard await SheetPrompt.confirm("Delete this message?", message: "The server may delete its whole attachment batch. This cannot be undone.", confirm: "Delete", destructive: true, on: self.window) else { return }
            _ = try await session.mutate("raven.api.raven_message.delete_messages", ["message_ids": .array([.string(message.id)])]); try await session.load(channelID: message.channelID)
        }
    }
    @objc func openThread(_ sender: Any?) {
        guard let message = selectedMessage, let session else { return }
        if channel?.raw["is_thread"].bool == true {
            // Already inside a thread: reply in place instead of creating a
            // nested thread server-side.
            reply(sender); return
        }
        action {
            _ = try await session.threadChannel(for: message)
            guard self.isCurrent(session, channelID: message.channelID), !session.deletedIDs.contains(message.id),
                  !ChannelPolicy.isRevoked(channelID: message.channelID, revoked: session.revokedChannels, threadParents: session.threadParents),
                  self.channel?.raw["parent_channel_id"].string.map(session.revokedChannels.contains) != true else { return }
            self.showThreadInspector(root: message)
        }
    }
    @objc func openThreadWindow(_ sender: Any?) {
        // Inside a thread there is no new thread to open; a reply would create
        // a nested thread server-side.
        guard let message = selectedMessage, let session, channel?.raw["is_thread"].bool != true else { return }
        action { let thread = try await session.threadChannel(for: message); guard self.session === session else { return }; self.app.open(session: session, channel: thread) }
    }
    @objc func openConversationWindow(_ sender: Any?) { if let session, let channel { app.open(session: session, channel: channel) } }
    @objc func openConversationTab(_ sender: Any?) { if let session, let channel { app.openTab(beside: self, session: session, channel: channel) } }
    /// The tab bar's + button and File ▸ New Tab: same account, chooser open.
    @objc override func newWindowForTab(_ sender: Any?) { newConversationTab(sender) }
    /// File ▸ New Tab has its own action, so it validates against this
    /// window rather than any responder that inherits newWindowForTab:.
    @objc func newConversationTab(_ sender: Any?) {
        guard session?.stopped != true, let controller = app.openTab(beside: self, session: session, channel: nil) else { NSSound.beep(); return }
        controller.chooseConversation(sender)
    }
    @objc func toggleFavorite(_ sender: Any?) { if let channel { toggleFavorite(for: channel) } }
    func toggleFavorite(for channel: RavenChannel) {
        guard let session else { return }
        action {
            session.userPreferences = nil
            let result: JSONValue
            do { result = try await session.mutate("raven.api.raven_channel.toggle_pinned_channel", ["channel_id": .string(channel.id)]) }
            catch { try? await session.refresh(); throw error }
            if result["user"].string == session.account.user || result["name"].string == session.account.user { session.userPreferences = RavenUserPreferences(raw: result) }
            try await session.refresh()
        }
    }
    @objc func markUnread(_ sender: Any?) { guard let session, let channel else { return }; action { try await session.markUnread(channelID: channel.id) } }
    @objc func react(_ sender: Any?) { guard let message = selectedMessage else { return }; showQuickReactions(for: message, focus: .first) }
    /// Saving sends the desired state, so a stale mark cannot invert it.
    /// Pinning is a server-side toggle. Either way the conversation is
    /// reconciled at once, so the mark follows without waiting for the
    /// realtime event.
    @objc func saveForLater(_ sender: Any?) {
        guard let session, let message = selectedMessage else { return }
        let add = !MessageMarks.isSaved(message, by: session.account.user)
        action { _ = try await session.mutate("raven.api.raven_message.save_message", ["message_id": .string(message.id), "add": .bool(add)]); session.requestReconciliation() }
    }
    @objc func pin(_ sender: Any?) { guard let session, let message = selectedMessage else { return }; action { _ = try await session.mutate("raven.api.raven_channel.toggle_pin_message", ["channel_id": .string(message.channelID), "message_id": .string(message.id)]); session.requestReconciliation() } }
    /// Whether the message is pinned, or nil when its conversation (a
    /// thread, say) is not in the channel list that carries the pins.
    func isPinned(_ message: RavenMessage) -> Bool? {
        pinnedMessageIDs(in: message.channelID)?.contains(message.id)
    }
    private func pinnedMessageIDs(in channelID: String) -> Set<String>? {
        let source = session?.channels.first { $0.id == channelID } ?? (channel?.id == channelID ? channel : nil)
        return source.map { MessageMarks.pinnedMessageIDs(in: $0) }
    }
    static func saveTitle(saved: Bool) -> String { saved ? "Remove from Saved" : "Save for Later" }
    static func pinTitle(pinned: Bool?) -> String { pinned.map { $0 ? "Unpin Message" : "Pin Message" } ?? "Pin / Unpin Message" }
    @objc func copyTranscript(_ sender: Any?) { copyFullTranscript(to: .general) }
    var canCopyDisplayedTranscript: Bool {
        // Navigation keeps the previous text on screen until the new render arrives.
        guard !isUpdatingTranscript, let session, !session.stopped, let channel,
              messages.first?.channelID == channel.id, !session.deletedIDs.contains(channel.id),
              !session.channelIsRevoked(channel.id) else { return false }
        return channel.raw["parent_channel_id"].string.map(session.channelIsRevoked) != true
    }
    func copyFullTranscript(to pasteboard: NSPasteboard) {
        guard canCopyDisplayedTranscript, let session else { return }
        let full: String = messages.map { message -> String in
            "\(session.authorName(message)) · \(session.displayTimestamp(message.creation))\n\(Self.plainBody(of: message))"
        }.joined(separator: "\n\n")
        pasteboard.clearContents(); pasteboard.setString(full, forType: .string)
    }
    /// A message as plain text, the way Copy Transcript writes it: spoilers
    /// stay masked and a file stands in as its name.
    static func plainBody(of message: RavenMessage) -> String {
        guard !message.html.isEmpty else { return message.raw["file"].string.map { "[Attachment: \(URL(string: $0)?.lastPathComponent ?? "File")]" } ?? message.raw["content"].string ?? "[\(message.messageType)]" }
        return (try? RichTextCodec.plainText(RichTextCodec.parse(message.html))) ?? "[Unsupported content]"
    }
    /// Copies the selected message without having to select its text first.
    @objc func copyMessageText(_ sender: Any?) { copyMessageText(to: .general) }
    private var messageForCopy: RavenMessage? {
        guard canCopyDisplayedTranscript, let message = selectedMessage,
              message.channelID == channel?.id else { return nil }
        return message
    }
    func copyMessageText(to pasteboard: NSPasteboard) {
        guard let message = messageForCopy else { return }
        pasteboard.clearContents(); pasteboard.setString(Self.plainBody(of: message), forType: .string)
    }
    /// Programmatic, unanimated toggle. Menu and toolbar commands reach the
    /// split view controller first and animate.
    @objc func toggleSidebar(_ sender: Any?) { sidebarSplitItem.isCollapsed.toggle() }
    @objc func largerText(_ sender: Any?) { resizeFont(1) }
    @objc func smallerText(_ sender: Any?) { resizeFont(-1) }
    @objc func actualTextSize(_ sender: Any?) { UserDefaults.standard.set(14.0, forKey: "fontSize"); app.settings?.reloadReadingControls(); for window in app.windows { window.render(); window.threadInspector?.render() } }
    @objc func toggleCompactMessages(_ sender: Any?) {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "compactMessages"), forKey: "compactMessages")
        app.settings?.reloadReadingControls()
        for window in app.windows { window.render(); window.threadInspector?.render() }
    }
    /// Prints the loaded transcript in light appearance, without reading
    /// controls (code buttons, unread divider, attachment hints).
    @objc func printTranscript(_ sender: Any?) {
        guard let channel, let window, let storage = transcript.textStorage else { return }
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.horizontalPagination = .fit; info.isVerticallyCentered = false
        let content = NSMutableAttributedString(attributedString: storage)
        // Day dividers are reading controls; printed headers carry the date.
        TranscriptView.prepareForExport(content, for: .print)
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let page = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        page.appearance = NSAppearance(named: .aqua)
        page.textStorage?.setAttributedString(content)
        page.isVerticallyResizable = true; page.sizeToFit()
        let operation = NSPrintOperation(view: page, printInfo: info)
        operation.jobTitle = channel.title
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
    func resizeFont(_ amount: Double) { let old = UserDefaults.standard.double(forKey: "fontSize"); UserDefaults.standard.set(min(30, max(11, (old == 0 ? 14 : old) + amount)), forKey: "fontSize"); app.settings?.reloadReadingControls(); for window in app.windows { window.render(); window.threadInspector?.render() } }
    /// ⌥⌘F: focus the toolbar search, showing the toolbar if it is hidden.
    @objc func findMessages(_ sender: Any?) {
        if window?.toolbar?.isVisible == false { window?.toolbar?.isVisible = true }
        if window?.toolbar?.items.contains(where: { $0.itemIdentifier == .nevermoreSearch }) == true { focusSearchField() }
        else { searchAccount(sender) }
    }
    /// ⌘F: the native find bar over the loaded transcript, like Mail's Find.
    @objc func findInTranscript(_ sender: Any?) {
        let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
        transcript.performTextFinderAction(item)
    }
    @objc func findNext(_ sender: Any?) { let item = NSMenuItem(); item.tag = NSTextFinder.Action.nextMatch.rawValue; transcript.performTextFinderAction(item) }
    @objc func findPrevious(_ sender: Any?) { let item = NSMenuItem(); item.tag = NSTextFinder.Action.previousMatch.rawValue; transcript.performTextFinderAction(item) }
    @objc func chooseConversation(_ sender: Any?) {
        guard let session, let window else { app.addAccount(nil); return }
        conversationChooser?.cancel()
        let chooser = ConversationChooser(session: session); conversationChooser = chooser
        chooser.onClose = { [weak self] in self?.conversationChooser = nil }
        chooser.onPick = { [weak self] candidate, newWindow in
            guard let self, self.isCurrent(session) else { return }
            self.action {
                let destination: RavenChannel
                if candidate.kind == .person {
                    let response = try await session.mutate("raven.api.raven_channel.create_direct_message_channel", ["user_id": .string(candidate.serverID)])
                    try await session.refresh()
                    guard let id = response.string ?? response["name"].string, let channel = session.channels.first(where: { $0.id == id }) else { throw AppError.message("The server did not return an accessible direct message.") }
                    destination = channel
                } else {
                    guard let channel = session.channels.first(where: { $0.id == candidate.serverID }), !session.revokedChannels.contains(channel.id) else { throw AppError.message("Access to this conversation changed.") }
                    destination = channel
                }
                guard self.isCurrent(session) else { return }
                if newWindow { self.app.open(session: session, channel: destination) } else { self.select(destination) }
            }
        }
        chooser.present(on: window)
    }
    @objc func openBrowser(_ sender: Any?) { guard let session else { return }; NSWorkspace.shared.open(session.account.origin.appendingPathComponent("raven")) }
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL, url.scheme == "nevermore-code" { if let command = codeCommands[url] { executeCode(command) }; return true }
        if let url = link as? URL, url.scheme == "nevermore-attachment", let id = url.pathComponents.last, let message = messages.first(where: { $0.id == id }) { previewAttachment(for: message); return true }
        guard let raw = (link as? URL)?.relativeString ?? link as? String, let url = URL(string: raw, relativeTo: session?.account.origin)?.absoluteURL, ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else { return true }
        NSWorkspace.shared.open(url); return true
    }
    @objc func quickLook(_ sender: Any?) { previewAttachment() }
    @objc func saveAttachment(_ sender: Any?) { fetchAttachment(save: true) }
    func previewAttachment() { fetchAttachment(save: false) }
    /// A click on an attachment line or thumbnail shows that message's file
    /// in the File panel, or in Quick Look when the window is too narrow for
    /// the panel. The click does not move the caret, so the message comes
    /// along; the caret then moves to it, so Space and ⌘Y show the same file.
    func previewAttachment(for message: RavenMessage) {
        if let range = messageRanges.first(where: { $0.1.id == message.id })?.0 { transcript.setSelectedRange(NSRange(location: range.location, length: 0)) }
        guard (window?.frame.width ?? 0) >= FileInspector.minimumWindowWidth else {
            // A hidden panel with another file would come back stale.
            if let inspector = fileInspector, inspector.source.messageID != message.id { closeFileInspector() }
            fetchAttachment(save: false, message: message); return
        }
        showFileInspector(for: message)
    }
    /// While the File panel is on screen it follows the transcript's
    /// selection to the next message with a file, as Finder's preview
    /// follows its selection. Messages without a file leave it as it is.
    private func fileInspectorFollowSelection() {
        guard !restoringTranscriptSelection, let inspector = fileInspector, !fileInspectorCollapsedByWidth,
              let message = selectedMessage, Self.hasFile(message), message.id != inspector.source.messageID else { return }
        followSelectionTask?.cancel()
        followSelectionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self, self.fileInspector != nil, !self.fileInspectorCollapsedByWidth, self.selectedMessage?.id == message.id else { return }
            self.showFileInspector(for: message)
        }
    }
    /// Quick Look (`save` false) or Save As for a message's file: the given
    /// message, else the selected one, else the File panel's. A file the
    /// File panel already holds is not downloaded again.
    func fetchAttachment(save: Bool, message: RavenMessage? = nil) {
        guard let session else { return }
        let target = message ?? selectedMessage.flatMap { Self.hasFile($0) ? $0 : nil }
        if let inspector = fileInspector, let attachment = inspector.attachment, target == nil || target?.id == inspector.source.messageID {
            // A panel the window hides has no window for its save sheet.
            if save, fileInspectorCollapsedByWidth { saveWithoutPanel(attachment, channelID: inspector.source.channelID, session: session) }
            else if save { inspector.saveAs() }
            else { presentQuickLook(attachment, link: inspector.source.messageLink, channelID: inspector.source.channelID, session: session) }
            return
        }
        guard let message = target, Self.hasFile(message) else { return }
        if save, (window?.frame.width ?? 0) >= FileInspector.minimumWindowWidth { showFileInspector(for: message, thenSave: true); return }
        downloadAttachment(of: message, session: session) { [weak self] file, link in
            guard let self else { return }
            if save { self.saveWithoutPanel(file, channelID: message.channelID, session: session) }
            else { self.presentQuickLook(file, link: link, channelID: message.channelID, session: session) }
        }
    }
    private static func hasFile(_ message: RavenMessage) -> Bool {
        message.raw["file"].string.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false
    }
    /// Which of the window's two downloads a request uses.
    private enum AttachmentDownloadSlot { case quickLook, filePanel }
    /// Downloads a message's file for this window, one per slot at a time.
    /// A newer request in the same slot, another conversation or a revoked
    /// channel drops the result. `failed` replaces the error alert when given.
    private func downloadAttachment(of message: RavenMessage, session: AccountSession, in slot: AttachmentDownloadSlot = .quickLook, failed: ((Error) -> Void)? = nil, then deliver: @escaping @MainActor (DownloadedAttachment, URL?) -> Void) {
        guard Self.hasFile(message), let file = message.raw["file"].string else { return }
        let attempt = UUID()
        switch slot {
        case .quickLook: attachmentDownload?.cancel(); attachmentAttempt = attempt
        case .filePanel: fileDownload?.cancel(); fileAttempt = attempt
        }
        status.stringValue = "Downloading attachment…"
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.isLatest(attempt, in: slot) { self.endDownload(in: slot, state: session.state) } }
            do {
                let url = try RavenAttachmentURL.resolve(file, origin: session.account.origin)
                let downloaded = try await session.client.download(url, to: FileManager.default.temporaryDirectory)
                guard !Task.isCancelled, self.isLatest(attempt, in: slot), self.isCurrent(session, channelID: message.channelID), !ChannelPolicy.isRevoked(channelID: message.channelID, revoked: session.revokedChannels, threadParents: session.threadParents) else { return }
                var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/?#%")
                let link = message.id.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: "/raven/message/" + $0, relativeTo: session.account.origin)?.absoluteURL }
                deliver(downloaded, link)
            } catch {
                guard !(error is CancellationError), self.isLatest(attempt, in: slot), self.isCurrent(session) else { return }
                if let failed { failed(error) } else { self.app.showError(error) }
            }
        }
        switch slot {
        case .quickLook: attachmentDownload = task
        case .filePanel: fileDownload = task
        }
    }
    private func isLatest(_ attempt: UUID, in slot: AttachmentDownloadSlot) -> Bool {
        switch slot {
        case .quickLook: attachmentAttempt == attempt
        case .filePanel: fileAttempt == attempt
        }
    }
    /// Forgets a slot's download; the status line returns to the account's
    /// state once neither slot is downloading.
    private func endDownload(in slot: AttachmentDownloadSlot, state: String) {
        switch slot {
        case .quickLook: attachmentDownload = nil
        case .filePanel: fileDownload = nil
        }
        if attachmentDownloads.isEmpty { status.stringValue = state }
    }
    /// Whether a file from `channelID` may still be shown in this window.
    private func attachmentActivity(channelID: String, messageID: String? = nil, session: AccountSession) -> () -> Bool {
        { [weak self, weak session] in
            guard let self, let session else { return false }
            return self.isCurrent(session) && !ChannelPolicy.isRevoked(channelID: channelID, revoked: session.revokedChannels, threadParents: session.threadParents)
                && !(messageID.map(session.deletedIDs.contains) ?? false)
        }
    }
    /// Full-size Quick Look over this window.
    private func presentQuickLook(_ file: DownloadedAttachment, link: URL?, channelID: String, session: AccountSession) {
        let presentation: AttachmentPresentation = window.map { .quickLook(over: $0) } ?? .window
        let controller = AttachmentWindow(attachment: file, messageLink: link, presentation: presentation, active: attachmentActivity(channelID: channelID, session: session), reportError: { [weak self] error in self?.app.showError(error) })
        controller.didClose = { [weak self, weak controller] in self?.attachmentWindows.removeAll { $0 === controller } }
        for previous in attachmentWindows where !previous.showsOwnWindow { previous.close() }
        if attachmentWindows.count >= 4 { attachmentWindows.removeFirst().close() }
        attachmentWindows.append(controller); controller.present(save: false)
    }
    /// Save As in a window too narrow for the File panel: the save sheet alone.
    private func saveWithoutPanel(_ file: DownloadedAttachment, channelID: String, session: AccountSession) {
        guard let window else { return }
        let active = attachmentActivity(channelID: channelID, session: session)
        let panel = NSSavePanel(); attachmentSavePanel = panel
        Task { [weak self] in
            defer { if self?.attachmentSavePanel === panel { self?.attachmentSavePanel = nil } }
            do { _ = try await AttachmentExport.saveCopy(of: file, using: panel, over: window, isCurrent: active) }
            catch { if active() { self?.app.showError(error) } }
        }
    }
    /// Shows a message's file in the File panel, in the inspector pane the
    /// thread inspector otherwise uses. `thenSave` asks where to save it as
    /// soon as it has downloaded.
    func showFileInspector(for message: RavenMessage, thenSave: Bool = false) {
        guard !isClosed, let session, !session.stopped, Self.hasFile(message),
              !session.channelIsRevoked(message.channelID), !session.deletedIDs.contains(message.id) else { return }
        if let inspector = fileInspector, inspector.source.messageID == message.id, !inspector.isDetached {
            if inspector.hasFailed {
                inspector.retry(thenSave: thenSave)
            } else if thenSave {
                if inspector.attachment != nil { inspector.saveAs() }
                else { saveWhenFileArrives = true }
            }
            return
        }
        // A replaced panel passes on the width the reader gave it.
        let width = fileInspector.flatMap { $0.isViewLoaded && $0.view.window != nil ? $0.view.frame.width : nil } ?? 340
        // Not closeFileInspector: a thread under the panel stays covered.
        tearDownFileInspector()
        let filename = message.raw["file"].string.flatMap { URL(string: $0)?.lastPathComponent } ?? "Attachment"
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/?#%")
        let link = message.id.addingPercentEncoding(withAllowedCharacters: allowed).flatMap { URL(string: "/raven/message/" + $0, relativeTo: session.account.origin)?.absoluteURL }
        let conversation = channel.map { $0.isDM ? $0.title : "#\($0.title)" }
        let source = FileInspectorSource(messageID: message.id, channelID: message.channelID, filename: filename, sender: session.authorName(message), sent: session.displayTimestamp(message.creation), conversation: conversation, messageLink: link)
        let inspector = FileInspector(source: source, active: attachmentActivity(channelID: message.channelID, messageID: message.id, session: session), reportError: { [weak self] error in self?.app.showError(error) }, makeSavePanel: makeFileInspectorSavePanel)
        inspector.onQuickLook = { [weak self, weak inspector] file in
            guard let self, let inspector else { return }
            self.presentQuickLook(file, link: inspector.source.messageLink, channelID: inspector.source.channelID, session: session)
        }
        inspector.onShowMessage = { [weak self] id in self?.scrollTo(id) }
        inspector.onClose = { [weak self] in self?.closeFileInspector() }
        inspector.onRetry = { [weak self, weak inspector] thenSave in
            guard let self, let inspector, self.fileInspector === inspector else { return }
            self.startFileDownload(message, session: session, inspector: inspector, thenSave: thenSave)
        }
        fileInspector = inspector
        let item = NSSplitViewItem(inspectorWithViewController: inspector)
        item.minimumThickness = 280; item.maximumThickness = 640; item.canCollapse = false
        // Opens at 340 pt; below the divider-drag priority so it stays resizable.
        let widthConstraint = inspector.view.widthAnchor.constraint(equalToConstant: min(640, max(280, width))); widthConstraint.priority = NSLayoutConstraint.Priority(500); widthConstraint.isActive = true
        fileSplitItem = item; fileInspectorCollapsedByWidth = false
        syncInspectorItems()
        inspector.start()
        startFileDownload(message, session: session, inspector: inspector, thenSave: thenSave)
    }

    /// Both the first click and an authorized retry use the panel's single
    /// download slot. A later Save As while loading sets the same intent.
    private func startFileDownload(_ message: RavenMessage, session: AccountSession, inspector: FileInspector, thenSave: Bool) {
        saveWhenFileArrives = thenSave
        downloadAttachment(of: message, session: session, in: .filePanel, failed: { [weak self, weak inspector] error in
            if self?.fileInspector === inspector { self?.saveWhenFileArrives = false }
            inspector?.showFailure(error)
        }) { [weak self, weak inspector] file, _ in
            guard let self, let inspector, self.fileInspector === inspector else { return }
            inspector.show(file)
            guard self.saveWhenFileArrives else { return }
            self.saveWhenFileArrives = false
            if self.fileInspectorCollapsedByWidth { self.saveWithoutPanel(file, channelID: message.channelID, session: session) } else { inspector.saveAs() }
        }
    }
    /// Closes the File panel and releases its file; a thread it covered
    /// comes back. Safe to call when closed.
    func closeFileInspector() {
        tearDownFileInspector()
        syncInspectorItems()
    }
    /// Stops the panel's download, releases its file and removes its pane.
    private func tearDownFileInspector() {
        followSelectionTask?.cancel(); followSelectionTask = nil
        if fileDownload != nil { fileAttempt = UUID(); fileDownload?.cancel(); endDownload(in: .filePanel, state: session?.state ?? status.stringValue) }
        fileInspector?.detach()
        if let item = fileSplitItem, splitController.splitViewItems.contains(item) { splitController.removeSplitViewItem(item) }
        fileSplitItem = nil; fileInspector = nil; fileInspectorCollapsedByWidth = false; saveWhenFileArrives = false
    }
    func clearPreview() {
        let wasDownloading = attachmentDownload != nil
        attachmentAttempt = UUID(); attachmentDownload?.cancel(); attachmentDownload = nil
        if wasDownloading { status.stringValue = session?.state ?? "Add an account to get started" }
        attachmentSavePanel?.cancel(nil); attachmentSavePanel = nil
        closeFileInspector()
        let windows = attachmentWindows; attachmentWindows.removeAll()
        for controller in windows { controller.close() }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let enabled = validateShellCommand(menuItem) { return enabled }
        if menuItem.action == #selector(jumpToLatest(_:)) { return canJumpToLatest }
        if menuItem.action == #selector(nextMessage(_:)) { return transcriptAccessibility.canMove(forward: true) }
        if menuItem.action == #selector(previousMessage(_:)) { return transcriptAccessibility.canMove(forward: false) }
        if menuItem.action == #selector(toggleArchivedChannels(_:)) { menuItem.state = showsArchivedChannels ? .on : .off; return session != nil }
        if menuItem.action == #selector(toggleChannelMute(_:)) {
            menuItem.title = channel?.raw["muted"].bool == true ? "Unmute Conversation" : "Mute Conversation"
            return channel.map(ChannelPolicy.canMute) == true && session?.readOnly == false && session?.stopped == false
        }
        if [#selector(toggleChannelArchive(_:)), #selector(addChannelMember(_:)), #selector(removeChannelMember(_:))].contains(menuItem.action) {
            if menuItem.action == #selector(toggleChannelArchive(_:)) { menuItem.title = channel?.raw["is_archived"].bool == true ? "Unarchive Conversation…" : "Archive Conversation…" }
            guard let session, let channel, !session.readOnly, !session.stopped, ChannelPolicy.canManage(channel, user: session.account.user, roles: session.roles) else { return false }
            return menuItem.action != #selector(removeChannelMember(_:)) || channel.raw["type"].string != "Open"
        }
        if menuItem.action == #selector(joinChannel(_:)) { return channel.map(ChannelPolicy.canJoin) == true && session?.readOnly == false && session?.stopped == false }
        if isArchivedConversation, [#selector(send(_:)), #selector(editMessage(_:)), #selector(deleteMessage(_:)), #selector(react(_:)), #selector(pin(_:)), #selector(schedule(_:)), #selector(createPoll(_:))].contains(menuItem.action) { return false }
        if menuItem.action == #selector(vote(_:)) { return selectedMessage?.messageType == "Poll" && session?.stopped == false }
        if [#selector(quickLook(_:)), #selector(saveAttachment(_:))].contains(menuItem.action) { return (selectedMessage?.raw["file"].string?.isEmpty == false || fileInspector?.attachment != nil) && session?.stopped == false }

        if [#selector(code(_:)), #selector(insertLink(_:)), #selector(mention(_:)), #selector(insertCustomEmoji(_:)), #selector(reply(_:)), #selector(editMessage(_:)), #selector(attachFiles(_:)), #selector(clearAttachments)].contains(menuItem.action), !composer.isEditable { return false }
        if menuItem.action == #selector(insertCustomEmoji(_:)), composer.hasMarkedText() || !NativeRichText.canAuthorSpoiler(composer.typingAttributes) { return false }
        if menuItem.action == #selector(sendGIF(_:)) { return canSendGIF }
        // Menu validation runs on every lookup of a Message menu shortcut;
        // the session's parsed-document cache keeps that from parsing HTML.
        if menuItem.action == #selector(openCodeReader(_:)) { guard let message = selectedMessage, let session, case .parsed(let doc) = session.messageDocument(for: message) else { return false }; return !CodeBlocks.extract(from: doc).isEmpty }
        if menuItem.action == #selector(cancelPromisedFiles(_:)) { return !promisedReceives.isEmpty }
        if menuItem.action == #selector(editMessage(_:)) { return selectedMessage?.owner == session?.account.user && selectedMessage != nil && editing == nil }
        if menuItem.action == #selector(deleteMessage(_:)) { return selectedMessage?.owner == session?.account.user && selectedMessage != nil && selectedMessage?.id != editing?.id }
        if menuItem.action == #selector(copyMessageText(_:)) { return messageForCopy != nil }
        if [#selector(reply(_:)), #selector(openThread(_:)), #selector(openThreadWindow(_:)), #selector(react(_:)), #selector(saveForLater(_:)), #selector(pin(_:)), #selector(remind(_:)), #selector(vote(_:))].contains(menuItem.action) {
            // System events carry no message actions; thread commands are
            // meaningless inside a thread, where a reply stays in place.
            guard let message = selectedMessage, message.messageType != "System" else { return false }
            if [#selector(openThread(_:)), #selector(openThreadWindow(_:))].contains(menuItem.action) { return channel?.raw["is_thread"].bool != true }
            // Reply changes the draft, which an open edit would silently drop.
            if menuItem.action == #selector(reply(_:)) { return editing == nil }
            return true
        }
        // Mark-all resolves through the app delegate from any window;
        // mark-selected needs an Inbox selection, so it is disabled here.
        if menuItem.action == #selector(AppDelegate.markAllNotificationsRead(_:)) { return session.map { !$0.readOnly && !$0.stopped && !$0.demo } ?? false }
        if menuItem.action == #selector(CollectionWindow.markSelectedRead) { return false }
        return true
    }
    func isCurrent(_ expected: AccountSession, channelID: String? = nil) -> Bool { !isClosed && session === expected && !expected.stopped && (channelID == nil || channel?.id == channelID) }
    /// Whether this window still shows the account an in-flight action started
    /// for. Navigation to another conversation of the same account is current;
    /// a switch to another account is not, and must not receive its feedback.
    func isCurrentAccount(_ expected: AccountSession) -> Bool { !isClosed && session === expected && !expected.stopped }
    func action(_ work: @escaping @MainActor () async throws -> Void) {
        let source = session
        Task { guard !isClosed, session === source, source?.stopped != true else { return }; do { try await work() } catch { if !isClosed && session === source && !(error is CancellationError) { app.showError(error) } } }
    }
    func prompt(_ title: String, message: String? = nil, placeholder: String = "", value: String = "", confirm: String = "OK") async -> String? { await SheetPrompt.text(title, message: message, placeholder: placeholder, value: value, confirm: confirm, on: window) }
    func choose(_ title: String, message: String? = nil, items: [String], confirm: String = "Choose") async -> Int? { await SheetPrompt.choose(title, message: message, items: items, confirm: confirm, on: window) }
    func summary(_ json: JSONValue) -> String { switch json { case .string(let s): return s; case .number(let n): return n.isFinite ? NSNumber(value: n).stringValue : "—"; case .bool(let b): return b ? "Yes" : "No"; case .array(let a): return a.prefix(20).map(summary).joined(separator: ", "); case .object(let o): return o.keys.sorted().prefix(15).map { "\($0): \(summary(o[$0]!))" }.joined(separator: " · "); case .null: return "" } }
}
