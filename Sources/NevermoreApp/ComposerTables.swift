import AppKit
import NevermoreCore

extension NSAttributedString.Key {
    static let editableTable = Self("Nevermore.EditableTable")
}

/// Tables are atomic in a flowing text view. AppKit's ordinary typing can merge
/// text blocks or split cell terminators, so cell/geometry changes go through the
/// table editor instead. A fingerprint rejects partial copies or unmediated edits.
private struct ComposerTableMark: Codable {
    var id = UUID()
    var node: RichNode
    var signature = ""
}

@MainActor extension NativeRichText {
    static func markTable(_ node: RichNode, in value: NSMutableAttributedString, range: NSRange) {
        guard range.length > 0, let data = try? JSONEncoder().encode(ComposerTableMark(node: node)) else { return }
        value.addAttribute(.editableTable, value: data, range: range)
    }

    // Only called while rendering or renaming internal paragraph identities,
    // never after accepting user input.
    static func sealTables(in value: NSMutableAttributedString) {
        value.enumerateAttribute(.editableTable, in: NSRange(location: 0, length: value.length)) { raw, range, _ in
            guard let data = raw as? Data, var mark = try? JSONDecoder().decode(ComposerTableMark.self, from: data) else { return }
            mark.signature = signature(value.attributedSubstring(from: range))
            if let data = try? JSONEncoder().encode(mark) { value.addAttribute(.editableTable, value: data, range: range) }
        }
    }

    static func tableSelection(in value: NSAttributedString, selection: NSRange) -> (node: RichNode, range: NSRange)? {
        guard selection.location != NSNotFound, selection.location < value.length else { return nil }
        var range = NSRange()
        guard let data = value.attribute(.editableTable, at: selection.location, effectiveRange: &range) as? Data,
              let mark = try? JSONDecoder().decode(ComposerTableMark.self, from: data),
              mark.signature == signature(value.attributedSubstring(from: range)) else { return nil }
        return (mark.node, range)
    }

    static func containsTables(_ value: NSAttributedString) -> Bool {
        var found = false
        value.enumerateAttribute(.editableTable, in: NSRange(location: 0, length: value.length)) { mark, _, stop in
            if mark != nil { found = true; stop.pointee = true }
        }
        return found
    }

    static func tableAwareDocument(from value: NSAttributedString) throws -> RichDocument {
        var nodes: [RichNode] = []
        var failure: Error?
        value.enumerateAttribute(.editableTable, in: NSRange(location: 0, length: value.length)) { raw, range, stop in
            do {
                let fragment = value.attributedSubstring(from: range)
                if let raw {
                    guard let data = raw as? Data,
                          let mark = try? JSONDecoder().decode(ComposerTableMark.self, from: data),
                          mark.signature == signature(fragment), RichTableLayout(mark.node) != nil else { throw RichTextError.unsafeEdit }
                    let table = try RichTextCodec.parse(RichTextCodec.html(RichDocument(nodes: [mark.node])))
                    guard table.canEdit else { throw RichTextError.unsafeEdit }
                    nodes += table.nodes
                } else { nodes += try document(from: fragment).nodes }
            } catch { failure = error; stop.pointee = true }
        }
        if let failure { throw failure }
        return RichDocument(nodes: nodes)
    }

    static func allowsTableChange(in value: NSAttributedString, range: NSRange, replacingText: Bool) -> Bool {
        guard range.location != NSNotFound, range.location <= value.length, range.length <= value.length - range.location else { return false }
        var allowed = true
        value.enumerateAttribute(.editableTable, in: NSRange(location: 0, length: value.length)) { mark, table, stop in
            guard mark != nil else { return }
            if range.length == 0 {
                if NSLocationInRange(range.location, table) { allowed = false }
            } else if NSIntersectionRange(table, range).length > 0 {
                // A whole-table deletion/replacement is safe; a formatting
                // command or partial deletion would damage its cell geometry.
                if !replacingText || NSIntersectionRange(table, range) != table { allowed = false }
            }
            if !allowed { stop.pointee = true }
        }
        return allowed
    }
}

@MainActor extension ComposerView {
    @objc func editTable(_ sender: Any?) {
        guard isEditable, !hasMarkedText(), let window, window.attachedSheet == nil else { return }
        flushPendingShortcut()
        // NSTextView returns its mutable storage, not an immutable snapshot.
        let original = NSAttributedString(attributedString: attributedString())
        let originalStorage = textStorage
        let selected = NativeRichText.tableSelection(in: original, selection: selectedRange())
        let range = selected?.range ?? selectedRange()
        do {
            let table = try selected.map { try EditableRichTable($0.node) } ?? EditableRichTable.make(rows: 2, columns: 2)
            Task { [weak self, weak window] in
                // A pending presentation is not in the sheet registry yet.
                // Do not expose an old draft after its owner or storage changes.
                guard let self, let window, window.isVisible, self.window === window,
                      self.textStorage === originalStorage, self.isEditable,
                      !self.hasMarkedText(), self.attributedString().isEqual(to: original),
                      window.attachedSheet == nil else { return }
                _ = await TableEditorSheet.edit(table, on: window) { [weak self] result in
                    guard let self, self.window === window, self.textStorage === originalStorage,
                          self.isEditable, !self.hasMarkedText(), self.attributedString().isEqual(to: original) else {
                        throw AppError.message("The draft changed while this table editor was open. Copy your edits before closing it; the current draft has not been replaced.")
                    }
                    let fragment = NativeRichText.insertableFragment([result.node])
                    // Reuse following text or its existing paragraph break.
                    // Only a final table needs a new ordinary insertion line.
                    if range.location > 0, (original.string as NSString).character(at: range.location - 1) != 10 {
                        fragment.insert(NSAttributedString(string: "\n", attributes: NativeRichText.plainTypingAttributes), at: 0)
                    }
                    if NSMaxRange(range) == original.length {
                        fragment.append(NSAttributedString(string: "\n", attributes: NativeRichText.plainTypingAttributes))
                    }
                    let changed = NSMutableAttributedString(attributedString: original)
                    changed.replaceCharacters(in: range, with: fragment)
                    guard self.apply(ComposerEdit(text: changed, selection: NSRange(location: range.location + fragment.length, length: 0), typingAttributes: NativeRichText.plainTypingAttributes, actionName: "Edit Table")) else {
                        throw AppError.message("The draft could not accept the table. Copy your edits before closing this editor.")
                    }
                }
                if window.isVisible { window.makeFirstResponder(self) }
            }
        } catch { window.presentError(error) }
    }
}
