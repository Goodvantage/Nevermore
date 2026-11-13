import AppKit
import NevermoreCore

@MainActor extension ComposerView {
    @objc func toggleHighlight(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), NativeRichText.allowsTableChange(in: attributedString(), range: selectedRange(), replacingText: false) else { return }
        let selection = selectedRange()
        let current = attributedString()
        let range = (try? NativeRichText.spoilerSelection(in: current, range: selection))?.range ?? selection
        let attributes = range.length == 0 ? typingAttributes : current.attributes(at: range.location, effectiveRange: nil)
        let enabled = attributes[.highlight] as? Bool != true
        func changed(_ original: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var result = original
            if enabled {
                result[.highlight] = true
                result[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.25)
            } else {
                result.removeValue(forKey: .highlight)
                if (result[.backgroundColor] as? NSColor)?.isEqual(NSColor.systemYellow.withAlphaComponent(0.25)) == true {
                    result.removeValue(forKey: .backgroundColor)
                    if let font = result[.font] as? NSFont, NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask) {
                        result[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
                    }
                    if NativeRichText.isSpoiler(result) { result = NativeRichText.settingSpoiler(result, enabled: true) }
                }
            }
            return result
        }
        if range.length == 0 { typingAttributes = changed(attributes); return }
        let value = NSMutableAttributedString(attributedString: current.attributedSubstring(from: range))
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attrs, run, _ in value.setAttributes(changed(attrs), range: run) }
        replaceFormatting(range, with: value); undoManager?.setActionName("Highlight")
    }

    @objc func toggleInlineCode(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), NativeRichText.allowsTableChange(in: attributedString(), range: selectedRange(), replacingText: false) else { return }
        let range = selectedRange(), manager = NSFontManager.shared
        let font = (range.length == 0 ? typingAttributes[.font] : attributedString().attribute(.font, at: range.location, effectiveRange: nil)) as? NSFont ?? .systemFont(ofSize: 14)
        let remove = manager.traits(of: font).contains(.fixedPitchFontMask)
        let replacement: NSFont = remove ? .systemFont(ofSize: font.pointSize) : .monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        if range.length == 0 { typingAttributes[.font] = replacement; return }
        let value = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: range))
        value.enumerateAttribute(.font, in: NSRange(location: 0, length: value.length)) { old, run, _ in
            let traits = manager.traits(of: old as? NSFont ?? font).intersection([.boldFontMask, .italicFontMask])
            value.addAttribute(.font, value: manager.convert(replacement, toHaveTrait: traits), range: run)
        }
        replaceFormatting(range, with: value); undoManager?.setActionName("Inline Code")
    }

    @objc func formatCodeBlock(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return }
        let range = (string as NSString).paragraphRange(for: selectedRange())
        guard NativeRichText.allowsTableChange(in: attributedString(), range: range, replacingText: false) else { return }
        let source = attributedString().attributedSubstring(from: range)
        guard let document = try? NativeRichText.document(from: source), document.canEdit else { return }
        // Code blocks cannot carry semantic entities or other block metadata.
        // Do not use reading text here: it unmasks spoilers and trims code.
        func literal(_ nodes: [RichNode]) -> String? {
            var text = ""
            for node in nodes {
                switch node {
                case .text(let value): text += value
                case .element(let tag, let attributes, let children):
                    guard attributes.isEmpty else { return nil }
                    if tag == "br" { text += "\n"; continue }
                    guard ["strong", "em", "u", "s", "mark", "code", "span"].contains(tag), let value = literal(children) else { return nil }
                    text += value
                }
            }
            return text
        }
        let paragraphs = document.nodes.compactMap { node -> [RichNode]? in
            if case .element("p", let attributes, let children) = node, attributes.isEmpty { return children }
            return nil
        }
        let groups: [[RichNode]]
        if paragraphs.count == document.nodes.count { groups = paragraphs }
        else if paragraphs.isEmpty { groups = [document.nodes] }
        else { NSSound.beep(); return }
        var pieces: [String] = []
        for group in groups {
            guard let value = literal(group) else { NSSound.beep(); return }
            pieces.append(value)
        }
        let plain = pieces.joined(separator: "\n")
        let template = NativeRichText.insertableFragment([.element("pre", [:], [.element("code", [:], [.text(plain.isEmpty ? "x" : plain)])])])
        let attributes = template.attributes(at: 0, effectiveRange: nil)
        let changed = NSMutableAttributedString(attributedString: attributedString())
        if plain.isEmpty {
            // Like the existing triple-backtick shortcut: an empty final code
            // line lives in typing attributes, not a placeholder to send.
            if range.length > 0 { changed.setAttributes(attributes, range: range) }
            _ = apply(ComposerEdit(text: changed, selection: NSRange(location: range.location, length: 0), typingAttributes: attributes, actionName: "Code Block"))
            return
        }
        // The renderer removes its final paragraph terminator. A literal
        // trailing code newline needs an additional empty code paragraph so
        // re-encoding does not mistake that newline for the terminator.
        if plain.hasSuffix("\n") { template.append(NSAttributedString(string: "\n", attributes: attributes)) }
        if source.string.hasSuffix("\n") { template.append(NSAttributedString(string: "\n", attributes: attributes)) }
        changed.replaceCharacters(in: range, with: template)
        _ = apply(ComposerEdit(text: changed, selection: NSRange(location: range.location + plain.utf16.count, length: 0), typingAttributes: attributes, actionName: "Code Block"))
    }

    @objc func insertRule(_ sender: Any?) {
        guard isEditable, !hasMarkedText() else { return }
        replaceWithBlock(.element("hr", [:], []), range: selectedRange())
    }

    private func replaceWithBlock(_ node: RichNode, range: NSRange) {
        guard NativeRichText.allowsTableChange(in: attributedString(), range: range, replacingText: false) else { return }
        let fragment = NativeRichText.insertableFragment([node, .element("p", [:], [.text("\n")])])
        if range.location > 0, (string as NSString).character(at: range.location - 1) != 10 { fragment.insert(NSAttributedString(string: "\n", attributes: NativeRichText.plainTypingAttributes), at: 0) }
        let changed = NSMutableAttributedString(attributedString: attributedString()); changed.replaceCharacters(in: range, with: fragment)
        _ = apply(ComposerEdit(text: changed, selection: NSRange(location: range.location + fragment.length, length: 0), typingAttributes: NativeRichText.plainTypingAttributes, actionName: "Format Block"))
    }

    @objc func formatLink(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let window, window.attachedSheet == nil else { return }
        let original = NSAttributedString(attributedString: attributedString()), range = selectedRange()
        let originalStorage = textStorage
        guard NativeRichText.allowsTableChange(in: original, range: range, replacingText: false) else { return }
        let alert = NSAlert(); alert.messageText = "Insert Link"; alert.informativeText = "Enter an http, https or mailto link."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); field.placeholderString = "https://…"
        alert.accessoryView = field; alert.addButton(withTitle: "Insert"); alert.addButton(withTitle: "Cancel")
        let sheet = alert.window
        var cancelled = false
        // The URL being authored is private editor state too, even when this
        // dialog belongs directly to the inline composer.
        ComposerEditorLifetime.register(sheet) { [weak sheet] in
            cancelled = true
            guard let sheet else { return }
            ComposerEditorLifetime.unregister(sheet)
            sheet.sheetParent?.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil)
        }
        alert.beginSheetModal(for: window) { [weak self, weak sheet] response in
            if let sheet { ComposerEditorLifetime.unregister(sheet) }
            guard !cancelled, response == .alertFirstButtonReturn, let self,
                  self.window === window, self.textStorage === originalStorage,
                  self.isEditable, self.attributedString().isEqual(to: original) else { return }
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard RichTextCodec.safeURL(text), let url = URL(string: text) else { NSSound.beep(); return }
            if range.length == 0 { self.insertText(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14), .link: url]), replacementRange: range) }
            else { self.setLink(url, on: range) }
            self.undoManager?.setActionName("Insert Link"); self.window?.makeFirstResponder(self)
        }
    }
}
