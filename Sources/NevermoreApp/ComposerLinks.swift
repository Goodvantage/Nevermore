import AppKit
import NevermoreCore

extension NSAttributedString.Key {
    /// Marks a link whose text is its own address: one the composer made
    /// from a typed or pasted web address. Only these follow later edits of
    /// their text; a link behind a label keeps its address. The encoder
    /// ignores the key.
    static let autoLink = Self("Nevermore.AutoLink")
}

/// Web addresses in the composer become real links, as in Raven's web
/// editor. Raven makes an address clickable, and builds a preview for it,
/// only when the message holds it as a link; an address sent as plain text
/// stays plain text for every reader.
@MainActor extension NativeRichText {
    private static func linkAddress(_ value: Any?) -> String? {
        (value as? URL)?.absoluteString ?? value as? String
    }

    /// Whether `range` may carry an automatic link: ordinary typed text
    /// outside code, with no link behind a label inside it.
    private static func canHoldAutomaticLink(_ value: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0, NSMaxRange(range) <= value.length,
              isOrdinaryText(value, in: range), !isFixedPitch(value, in: range) else { return false }
        var labelled = false
        value.enumerateAttributes(in: range) { attributes, _, stop in
            guard attributes[.link] != nil, attributes[.autoLink] == nil else { return }
            labelled = true
            stop.pointee = true
        }
        guard !labelled else { return false }
        let block = paragraph(in: value, at: range.location).block
        return block != .code && block != .other
    }

    private static func hasLink(_ value: NSAttributedString, in range: NSRange) -> Bool {
        var linked = false
        value.enumerateAttribute(.link, in: range) { link, _, stop in
            guard link != nil else { return }
            linked = true
            stop.pointee = true
        }
        return linked
    }

    /// The text with the web address that ends at `location` linked; nil
    /// when there is none or it may not be linked.
    static func linkingAddress(endingAt location: Int, in value: NSAttributedString) -> NSAttributedString? {
        guard let match = LinkDetection.webAddress(in: value.string, endingAt: location), let url = URL(string: match.url),
              canHoldAutomaticLink(value, range: match.range), !hasLink(value, in: match.range) else { return nil }
        let result = NSMutableAttributedString(attributedString: value)
        result.addAttributes([.link: url, .autoLink: true], range: match.range)
        return result
    }

    /// The text with every unlinked web address in the words `range`
    /// touches linked; nil when nothing changes. Used for pasted text and,
    /// before sending, for the whole draft.
    static func linkingAddresses(in range: NSRange, of value: NSAttributedString) -> NSAttributedString? {
        let text = value.string as NSString
        guard NSMaxRange(range) <= text.length else { return nil }
        var start = range.location, end = NSMaxRange(range)
        while start > 0, !isWhitespace(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, !isWhitespace(text.character(at: end)) { end += 1 }
        guard end > start else { return nil }

        var result: NSMutableAttributedString?
        for match in LinkDetection.webAddresses(in: text.substring(with: NSRange(location: start, length: end - start))) {
            let found = NSRange(location: start + match.range.location, length: match.range.length)
            guard let url = URL(string: match.url), canHoldAutomaticLink(value, range: found), !hasLink(value, in: found) else { continue }
            if result == nil { result = NSMutableAttributedString(attributedString: value) }
            result?.addAttributes([.link: url, .autoLink: true], range: found)
        }
        return result
    }

    /// The text with `selection` linked to `url`, as when a web address is
    /// pasted over selected words. nil when the selection spans lines, is
    /// code, or is itself a web address (the paste then replaces it).
    static func linkingSelection(_ selected: NSRange, to url: URL, in value: NSAttributedString) -> NSAttributedString? {
        guard selected.length > 0, NSMaxRange(selected) <= value.length else { return nil }
        // Spaces at the ends of the selection stay outside the link.
        let whole = value.string as NSString
        var selection = selected
        while selection.length > 0, isWhitespace(whole.character(at: selection.location)) { selection.location += 1; selection.length -= 1 }
        while selection.length > 0, isWhitespace(whole.character(at: NSMaxRange(selection) - 1)) { selection.length -= 1 }
        guard selection.length > 0 else { return nil }
        let text = whole.substring(with: selection)
        guard text.rangeOfCharacter(from: .newlines) == nil, LinkDetection.soleWebAddress(text) == nil,
              isOrdinaryText(value, in: selection), !isFixedPitch(value, in: selection) else { return nil }
        let block = paragraph(in: value, at: selection.location).block
        guard block != .code, block != .other else { return nil }
        let result = NSMutableAttributedString(attributedString: value)
        result.removeAttribute(.autoLink, range: selection)
        result.addAttribute(.link, value: url, range: selection)
        return result
    }

    /// One change that brings an automatic link back in line with its text.
    struct LinkCorrection: Equatable {
        var range: NSRange
        /// nil removes the link.
        var url: URL?
    }

    /// Links near `range` whose text is exactly their address but which are
    /// not marked automatic yet: links from a restored draft or an edited
    /// message, and links made with Insert Link without a label.
    static func addressLinks(near range: NSRange, in value: NSAttributedString) -> [NSRange] {
        let start = max(0, range.location - 1)
        let scope = NSRange(location: start, length: min(value.length, NSMaxRange(range) + 1) - start)
        guard scope.length > 0 else { return [] }
        let text = value.string as NSString
        var found: [NSRange] = []
        value.enumerateAttribute(.link, in: scope) { link, part, _ in
            guard link != nil else { return }
            var whole = NSRange()
            let address = linkAddress(value.attribute(.link, at: part.location, longestEffectiveRange: &whole, in: NSRange(location: 0, length: value.length)))
            guard let address, text.substring(with: whole) == address, !found.contains(whole) else { return }
            var flagged = NSRange()
            let flag = value.attribute(.autoLink, at: whole.location, longestEffectiveRange: &flagged, in: whole)
            if flag == nil || flagged != whole { found.append(whole) }
        }
        return found
    }

    /// Keeps automatic links honest: the address a reader sees is the
    /// address the link opens. Each word that holds part of an automatic
    /// link is read again; the link then covers exactly the web address
    /// found there, and goes away when there is none.
    ///
    /// Example: after "https://a.example" is linked, typing "/b" at its end
    /// gives one link to "https://a.example/b"; deleting back to "https://"
    /// removes the link.
    static func automaticLinkCorrections(in value: NSAttributedString) -> [LinkCorrection] {
        var runs: [NSRange] = []
        value.enumerateAttribute(.autoLink, in: NSRange(location: 0, length: value.length)) { flag, range, _ in
            if flag != nil { runs.append(range) }
        }
        guard !runs.isEmpty else { return [] }

        let text = value.string as NSString
        var words: [NSRange] = []
        for run in runs {
            var index = run.location
            while index < NSMaxRange(run) {
                let word = wordRange(holding: index, in: text)
                guard word.length > 0 else { index += 1; continue }
                if words.last != word { words.append(word) }
                index = NSMaxRange(word)
            }
        }

        var wanted: [(range: NSRange, url: URL)] = []
        for word in words {
            guard let match = LinkDetection.webAddresses(in: text.substring(with: word)).first, let url = URL(string: match.url) else { continue }
            let range = NSRange(location: word.location + match.range.location, length: match.range.length)
            if canHoldAutomaticLink(value, range: range) { wanted.append((range, url)) }
        }

        var corrections: [LinkCorrection] = []
        for run in runs {
            var cursor = run.location
            for target in wanted {
                let overlap = NSIntersectionRange(target.range, run)
                guard overlap.length > 0 else { continue }
                if overlap.location > cursor { corrections.append(LinkCorrection(range: NSRange(location: cursor, length: overlap.location - cursor), url: nil)) }
                cursor = NSMaxRange(overlap)
            }
            if cursor < NSMaxRange(run) { corrections.append(LinkCorrection(range: NSRange(location: cursor, length: NSMaxRange(run) - cursor), url: nil)) }
        }
        for target in wanted where !isAutomaticLink(value, range: target.range, to: target.url) {
            corrections.append(LinkCorrection(range: target.range, url: target.url))
        }
        return corrections
    }

    private static func isAutomaticLink(_ value: NSAttributedString, range: NSRange, to url: URL) -> Bool {
        var linked = NSRange(), flagged = NSRange()
        let link = value.attribute(.link, at: range.location, longestEffectiveRange: &linked, in: range)
        let flag = value.attribute(.autoLink, at: range.location, longestEffectiveRange: &flagged, in: range)
        return linkAddress(link) == url.absoluteString && linked == range && flag != nil && flagged == range
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(UInt32(unit)) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// The run of non-whitespace characters that holds `index`; empty when
    /// `index` is whitespace or past the end.
    private static func wordRange(holding index: Int, in text: NSString) -> NSRange {
        guard index < text.length, !isWhitespace(text.character(at: index)) else { return NSRange(location: index, length: 0) }
        var start = index, end = index + 1
        while start > 0, !isWhitespace(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, !isWhitespace(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    /// The addresses a draft could show a preview for, in order, each once.
    static func previewableLinks(in value: NSAttributedString) -> [URL] {
        var links: [URL] = []
        value.enumerateAttribute(.link, in: NSRange(location: 0, length: value.length)) { link, _, _ in
            guard let address = linkAddress(link), let url = URL(string: address),
                  LinkPreviewPolicy.isEligible(url), !links.contains(url) else { return }
            links.append(url)
        }
        return links
    }
}

@MainActor extension ComposerView {
    /// Links the web address that ends at the caret, before a line break
    /// follows it. A typed space does the same through `completeTypedText`.
    func linkAddressBeforeCaret() {
        let selection = selectedRange()
        guard isEditable, !hasMarkedText(), selection.length == 0,
              let linked = NativeRichText.linkingAddress(endingAt: selection.location, in: attributedString()) else { return }
        apply(ComposerEdit(text: linked, selection: selection, typingAttributes: nil, actionName: "Link"))
    }

    /// Links every web address in the draft that is not a link yet, right
    /// before the draft is sent: the last address typed has no space after
    /// it. Raven's web editor does the same when it sends.
    func linkAllAddresses() {
        flushPendingShortcut()
        let value = attributedString()
        guard isEditable, !hasMarkedText(),
              let linked = NativeRichText.linkingAddresses(in: NSRange(location: 0, length: value.length), of: value) else { return }
        apply(ComposerEdit(text: linked, selection: selectedRange(), typingAttributes: nil, actionName: "Link"))
    }

    /// A web address pasted over selected words links them instead of
    /// replacing them, as in Raven's web editor, Notes and Mail. `pasted` is
    /// the pasteboard's text.
    func pasteAsLink(_ pasted: String?) -> Bool {
        let selection = selectedRange()
        guard isEditable, !hasMarkedText(), selection.length > 0, let pasted,
              let address = LinkDetection.soleWebAddress(pasted), let url = URL(string: address),
              let linked = NativeRichText.linkingSelection(selection, to: url, in: attributedString()) else { return false }
        return apply(ComposerEdit(text: linked, selection: NSRange(location: NSMaxRange(selection), length: 0), typingAttributes: nil, actionName: "Insert Link"))
    }

    /// Format ▸ Insert Link on selected text. The target is the person's
    /// choice, so the link stops following its text even when that text is
    /// an address the composer linked itself.
    func setLink(_ url: URL, on range: NSRange) {
        guard isEditable, range.length > 0, NSMaxRange(range) <= attributedString().length else { return }
        let linked = NSMutableAttributedString(attributedString: attributedString().attributedSubstring(from: range))
        let full = NSRange(location: 0, length: linked.length)
        linked.removeAttribute(.autoLink, range: full)
        linked.addAttribute(.link, value: url, range: full)
        replaceFormatting(range, with: linked)
    }

    /// Pastes text and links the web addresses in it.
    func pasteLinkingAddresses(_ paste: () -> Void) {
        let selection = selectedRange()
        let lengthBefore = textStorage?.length ?? 0
        paste()
        let inserted = (textStorage?.length ?? 0) - lengthBefore + selection.length
        let value = attributedString()
        guard inserted > 0, selection.location + inserted <= value.length, isEditable, !hasMarkedText(),
              let linked = NativeRichText.linkingAddresses(in: NSRange(location: selection.location, length: inserted), of: value) else { return }
        apply(ComposerEdit(text: linked, selection: selectedRange(), typingAttributes: nil, actionName: "Paste"))
    }

    /// Before a change lands: links it touches whose text is their own
    /// address are marked automatic, so they can follow the change.
    func adoptAddressLinks(near ranges: [NSRange]) {
        guard let textStorage, isEditable, !hasMarkedText() else { return }
        for range in ranges where NSMaxRange(range) <= textStorage.length {
            for link in NativeRichText.addressLinks(near: range, in: textStorage) {
                textStorage.addAttribute(.autoLink, value: true, range: link)
            }
        }
    }

    /// After a change landed. The link attributes are derived from the
    /// text, so they are set on the text storage directly, without an undo
    /// step of their own: Undo and Redo change the text and end up here
    /// too.
    func correctAutomaticLinks() {
        guard let textStorage, !hasMarkedText() else { return }
        let corrections = NativeRichText.automaticLinkCorrections(in: textStorage)
        if !corrections.isEmpty {
            textStorage.beginEditing()
            for correction in corrections {
                if let url = correction.url {
                    textStorage.addAttributes([.link: url, .autoLink: true], range: correction.range)
                } else {
                    textStorage.removeAttribute(.link, range: correction.range)
                    textStorage.removeAttribute(.autoLink, range: correction.range)
                }
            }
            textStorage.endEditing()
        }

        // The next character continues a link only when it follows one.
        guard typingAttributes[.link] != nil || typingAttributes[.autoLink] != nil else { return }
        let caret = selectedRange().location
        let follows = caret > 0 && caret <= textStorage.length && textStorage.attribute(.link, at: caret - 1, effectiveRange: nil) != nil
        guard !follows else { return }
        typingAttributes.removeValue(forKey: .link)
        typingAttributes.removeValue(forKey: .autoLink)
    }
}
