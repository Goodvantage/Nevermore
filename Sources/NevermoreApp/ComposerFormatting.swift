import AppKit
import NevermoreCore

@MainActor extension ComposerView {
    func canClearFormatting() -> Bool {
        let value = attributedString(), range = selectedRange()
        guard isEditable, !hasMarkedText(), range.length > 0, range.location != NSNotFound,
              range.location <= value.length, range.length <= value.length - range.location,
              NativeRichText.allowsTableChange(in: value, range: range, replacingText: false),
              let safeRange = try? NativeRichText.spoilerSelection(in: value, range: range), safeRange.range == range,
              let document = try? NativeRichText.document(from: value), document.canEdit else { return false }
        return true
    }
    @objc func clearFormatting(_ sender: Any?) {
        guard canClearFormatting() else { return }
        let range = selectedRange()
        let value = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: range))
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { original, run, _ in
            var attrs = NativeRichText.settingSpoiler(original, enabled: false)
            attrs.removeValue(forKey: .underlineStyle)
            attrs.removeValue(forKey: .strikethroughStyle)
            if attrs.removeValue(forKey: .highlight) != nil { attrs.removeValue(forKey: .backgroundColor) }
            if let font = attrs[.font] as? NSFont, attrs[.blockKind] as? String != "pre" {
                attrs[.font] = NSFont.systemFont(ofSize: font.pointSize)
            }
            value.setAttributes(attrs, range: run)
        }
        breakUndoCoalescing()
        replaceFormatting(range, with: value)
        undoManager?.setActionName("Clear Formatting")
        breakUndoCoalescing()
    }

    @objc func toggleStrikethrough(_ sender: Any?) {
        guard isEditable else { return }
        let range = selectedRange()
        let old = range.length > 0 ? attributedString().attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int ?? 0 : typingAttributes[.strikethroughStyle] as? Int ?? 0
        if range.length == 0 { typingAttributes[.strikethroughStyle] = old == 0 ? 1 : 0; return }
        let updated = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: range))
        updated.addAttribute(.strikethroughStyle, value: old == 0 ? 1 : 0, range: NSRange(location: 0, length: updated.length))
        replaceFormatting(range, with: updated)
    }
    @objc func toggleSpoiler(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return }
        let selection = selectedRange()
        if selection.length == 0 {
            guard NativeRichText.canAuthorSpoiler(typingAttributes) else { return }
            typingAttributes = NativeRichText.settingSpoiler(typingAttributes, enabled: !NativeRichText.isSpoiler(typingAttributes))
            return
        }
        do {
            let current = attributedString()
            let formatting = try NativeRichText.spoilerSelection(in: current, range: selection)
            let value = NativeRichText.settingSpoiler(current.attributedSubstring(from: formatting.range), enabled: !formatting.enabled)
            let proposed = NSMutableAttributedString(attributedString: current)
            proposed.replaceCharacters(in: formatting.range, with: value)
            guard try NativeRichText.document(from: proposed).canEdit else { throw RichTextError.unsafeEdit }
            breakUndoCoalescing()
            let undo = undoManager; undo?.beginUndoGrouping()
            replaceFormatting(formatting.range, with: value)
            undo?.setActionName("Spoiler"); undo?.endUndoGrouping()
            breakUndoCoalescing(); setSelectedRange(formatting.range)
        } catch { NSSound.beep() }
    }
    @objc func bulletedList(_ sender: Any?) { wrapParagraphs(in: "ul") }
    @objc func numberedList(_ sender: Any?) { wrapParagraphs(in: "ol") }
    @objc func blockquote(_ sender: Any?) { wrapParagraphs(in: "blockquote") }

    private func wrapParagraphs(in tag: String) {
        guard isEditable, !hasMarkedText() else { return }
        do {
            let range = (string as NSString).paragraphRange(for: selectedRange())
            let original = attributedString().attributedSubstring(from: range)
            let parsed = try NativeRichText.document(from: original)
            guard parsed.canEdit else { throw RichTextError.unsafeEdit }
            let children: [RichNode]
            if parsed.nodes.isEmpty {
                children = [.element(tag == "blockquote" ? "p" : "li", [:], [])]
            } else if tag == "blockquote" { children = parsed.nodes }
            else {
                children = parsed.nodes.map { node in
                    if case .element("p", _, let inline) = node { return .element("li", [:], inline) }
                    return .element("li", [:], [node])
                }
            }
            let wrapped = RichDocument(nodes: [.element(tag, [:], children)])
            // Revalidate the same grammar as sending/editing before changing any text.
            guard try RichTextCodec.parse(RichTextCodec.html(wrapped)).canEdit else { throw RichTextError.unsafeEdit }
            // Not a bare render: its item and quote names would repeat
            // those already in the draft, and the encoder joins by name.
            let rendered = NativeRichText.insertableFragment(wrapped.nodes, joiningQuote: tag == "blockquote" ? NativeRichText.adjacentQuote(to: range, in: attributedString()) : nil)
            if original.string.hasSuffix("\n") { rendered.append(NSAttributedString(string: "\n")) }
            breakUndoCoalescing(); let undo = undoManager; undo?.beginUndoGrouping()
            insertText(rendered, replacementRange: range)
            undo?.setActionName(tag == "blockquote" ? "Block Quote" : "Format List"); undo?.endUndoGrouping(); breakUndoCoalescing()
        } catch { NSSound.beep() }
    }
}
