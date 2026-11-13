import AppKit
import NevermoreCore

@MainActor extension ConversationWindow: MarkdownClipboardOwner {
    func validateSourceClipboard(_ command: ComposerClipboard.Command) -> Bool? {
        guard inlineComposer.mode == .markdown, let text = inlineComposer.textView, window?.firstResponder === text else { return nil }
        guard !text.hasMarkedText() else { return false }
        switch command {
        case .copy: return text.selectedRange().length > 0
        case .cut: return text.isEditable && text.selectedRange().length > 0
        case .paste, .pastePlain: return text.isEditable && (NSPasteboard.general.availableType(from: [.string]) != nil || ComposerView.hasAttachments(.general))
        }
    }

    @discardableResult
    func handleSourceClipboard(_ command: ComposerClipboard.Command, pasteboard: NSPasteboard = .general) -> Bool {
        guard inlineComposer.mode == .markdown, let text = inlineComposer.textView, window?.firstResponder === text else { return false }
        guard !text.hasMarkedText() else { return true }
        let selected = text.selectedRange()
        guard selected.location != NSNotFound, NSMaxRange(selected) <= text.string.utf16.count else { return true }
        if command == .copy || command == .cut {
            guard selected.length > 0, command == .copy || text.isEditable else { return true }
            let raw = (text.string as NSString).substring(with: selected)
            pasteboard.clearContents(); pasteboard.setString(raw, forType: .string)
            if command == .copy { return true }
            text.breakUndoCoalescing(); text.insertText("", replacementRange: selected)
            composer.undoManager?.setActionName("Cut"); text.breakUndoCoalescing()
            return true
        }
        guard text.isEditable else { return true }
        if composer.pasteAttachments(from: pasteboard) { return true }
        guard let raw = pasteboard.string(forType: .string) else {
            status.stringValue = "Paste Markdown as text, or attach a file."; return true
        }
        guard raw.utf8.count <= RichTextCodec.maximumBytes,
              (text.string as NSString).replacingCharacters(in: selected, with: raw).utf8.count <= RichTextCodec.maximumBytes else { status.stringValue = RichTextError.tooLarge.localizedDescription; return true }
        text.breakUndoCoalescing(); text.insertText(raw, replacementRange: selected)
        composer.undoManager?.setActionName("Paste"); text.breakUndoCoalescing()
        return true
    }

}
