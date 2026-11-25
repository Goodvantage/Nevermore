import AppKit
import NevermoreCore

/// One paragraph of composer text, read the way `NativeRichText.document(from:)`
/// reads it: its block comes from the paragraph metadata the renderer stamped,
/// and a marker such as "│ " or "1. " counts only while it is still the
/// generated prefix that metadata names.
struct ComposerParagraph {
    enum Block: Equatable {
        case plain, quote, listItem, code
        /// Rules, legacy attributes and anything else this file leaves alone.
        case other
    }

    /// The whole paragraph, including its line break.
    var range: NSRange
    /// The generated marker at the paragraph start; empty when there is none.
    var markerRange: NSRange
    /// The text between the marker and the line break.
    var contentRange: NSRange
    var block: Block
    var meta: ParaMeta?

    var terminatorRange: NSRange {
        NSRange(location: NSMaxRange(contentRange), length: NSMaxRange(range) - NSMaxRange(contentRange))
    }

    /// A paragraph of a block quote that is not also a list item or code.
    var isQuoteParagraph: Bool { block == .quote }

    /// An item of a list that is neither nested nor inside a quote. Deeper
    /// structures keep AppKit's plain editing: they only arrive from received
    /// messages, and a wrong guess there would rewrite somebody's markup.
    var isTopLevelListItem: Bool {
        guard block == .listItem, let meta, meta.q == nil, let path = meta.l, path.count == 1 else { return false }
        return ["ul", "ol"].contains(path[0].t)
    }
}

/// A rewrite of the composer's text proposed by a typing rule. `ComposerView`
/// validates it against the HTML codec before applying it.
struct ComposerEdit {
    var text: NSAttributedString
    var selection: NSRange
    /// Attributes for the next typed character; nil keeps AppKit's choice.
    var typingAttributes: [NSAttributedString.Key: Any]?
    var actionName: String
}

/// Structure-aware typing for the composer: Markdown shortcuts, line breaks
/// that continue or leave a quote or list, and Backspace that removes a block
/// instead of damaging its marker.
///
/// Every rule edits only the paragraphs it concerns. Re-rendering the whole
/// draft would be simpler, but the renderer drops empty paragraphs, so the
/// user's blank lines would vanish with the first shortcut.
///
/// Convention kept by these rules: a line break carries block metadata only
/// while the next paragraph belongs to the same block. AppKit derives the
/// typing attributes of an empty last line from the line break before it, so
/// a stale quote or list there would silently swallow the next typed text.
@MainActor extension NativeRichText {
    static let composerFontSize: CGFloat = 14

    /// Typing attributes of ordinary text: no block metadata at all, which the
    /// encoder reads as a paragraph outside every quote, list and code block.
    static var plainTypingAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: composerFontSize), .foregroundColor: NSColor.labelColor]
    }

    private static let blockKeys: [NSAttributedString.Key] = [.paragraph, .blockKind, .markerLength, .listType, .listNumber, .generated]
    private static let documentKeys: [NSAttributedString.Key] = [.richDocument, .originalSignature, .originalText]
    /// Never continued onto the next typed character.
    private static let entityKeys: [NSAttributedString.Key] = [.generated, .semantic, .link, .autoLink]

    // MARK: Reading paragraphs

    private static func decodedMeta(_ raw: Any?) -> ParaMeta? {
        guard let string = raw as? String, let data = string.data(using: .utf8),
              let meta = try? JSONDecoder().decode(ParaMeta.self, from: data), meta.v == 1 else { return nil }
        return meta
    }

    /// The metadata covering most of the paragraph, as the encoder picks it.
    private static func dominantMeta(in value: NSAttributedString, range: NSRange) -> ParaMeta? {
        var best: (meta: ParaMeta, length: Int)?
        value.enumerateAttribute(.paragraph, in: range) { raw, subrange, _ in
            guard let meta = decodedMeta(raw) else { return }
            if best == nil || subrange.length > best!.length { best = (meta, subrange.length) }
        }
        return best?.meta
    }

    /// `typing` describes the paragraph when it holds no character yet: an
    /// empty last line exists only as the attributes the next key will get.
    static func paragraph(in value: NSAttributedString, at location: Int, typing: [NSAttributedString.Key: Any] = [:]) -> ComposerParagraph {
        let text = value.string as NSString
        let range = text.paragraphRange(for: NSRange(location: min(max(location, 0), text.length), length: 0))
        var content = range
        while content.length > 0, [10, 13].contains(Int(text.character(at: NSMaxRange(content) - 1))) { content.length -= 1 }
        var marker = NSRange(location: range.location, length: 0)

        let meta = range.length == 0 ? decodedMeta(typing[.paragraph]) : dominantMeta(in: value, range: range)
        guard let meta else {
            let legacyKind = range.length > 0 ? value.attribute(.blockKind, at: range.location, effectiveRange: nil) as? String : nil
            let block: ComposerParagraph.Block = legacyKind == nil || legacyKind == "p" ? .plain : .other
            return ComposerParagraph(range: range, markerRange: marker, contentRange: content, block: block, meta: nil)
        }

        if !meta.mk.isEmpty, content.length >= meta.mk.utf16.count {
            var effective = NSRange()
            let flagged = value.attribute(.generated, at: content.location, effectiveRange: &effective) as? Bool == true
            let length = meta.mk.utf16.count
            if flagged, effective.location <= content.location, NSMaxRange(effective) - content.location >= length,
               text.substring(with: NSRange(location: content.location, length: length)) == meta.mk {
                marker.length = length
                content.location += length
                content.length -= length
            }
        }

        let block: ComposerParagraph.Block
        switch meta.b {
        case "li": block = .listItem
        case "pre": block = .code
        case "p": block = meta.q == nil ? .plain : .quote
        default: block = .other
        }
        return ComposerParagraph(range: range, markerRange: marker, contentRange: content, block: block, meta: meta)
    }

    private static func paragraphs(in value: NSAttributedString) -> [ComposerParagraph] {
        var result: [ComposerParagraph] = []
        var location = 0
        while location < value.length {
            let next = paragraph(in: value, at: location)
            result.append(next)
            location = NSMaxRange(next.range)
        }
        return result
    }

    static func isFixedPitch(_ value: NSAttributedString, in range: NSRange) -> Bool {
        var found = false
        value.enumerateAttribute(.font, in: range) { font, _, stop in
            guard let font = font as? NSFont, NSFontManager.shared.traits(of: font).contains(.fixedPitchFontMask) else { return }
            found = true
            stop.pointee = true
        }
        return found
    }

    /// Whether the range holds only characters the user typed: no generated
    /// marker, mention, emoji or read-only markup.
    static func isOrdinaryText(_ value: NSAttributedString, in range: NSRange) -> Bool {
        var ordinary = true
        value.enumerateAttributes(in: range) { attributes, _, stop in
            guard attributes[.generated] == nil, attributes[.semantic] == nil, attributes[.unsupported] == nil, attributes[.attachment] == nil, attributes[.editableTable] == nil else {
                ordinary = false
                stop.pointee = true
                return
            }
        }
        return ordinary
    }

    // MARK: Building fragments

    /// Renders nodes for insertion into existing text. The whole-document
    /// attributes that let an untouched render skip re-encoding are removed:
    /// they describe the fragment, not the draft it lands in.
    private static func fragment(_ nodes: [RichNode]) -> NSMutableAttributedString {
        let rendered = NSMutableAttributedString(attributedString: attributedString(document: RichDocument(nodes: nodes), fontSize: composerFontSize, revealSpoilers: true))
        let full = NSRange(location: 0, length: rendered.length)
        for key in documentKeys { rendered.removeAttribute(key, range: full) }
        return rendered
    }

    private static func freshIdentity() -> String { "u" + UUID().uuidString.prefix(8).lowercased() }

    /// The renderer numbers quotes, list items and code blocks from 1 in
    /// every render. Two fragments rendered apart would share those names,
    /// and the encoder joins neighbours by name, so each fragment gets names
    /// of its own. `quote` instead continues an existing quote.
    private static func renameIdentities(in rendered: NSMutableAttributedString, quote: String? = nil) {
        var renamed: [String: String] = [:]
        func fresh(_ key: String) -> String {
            if let known = renamed[key] { return known }
            let value = freshIdentity()
            renamed[key] = value
            return value
        }

        var updates: [(NSRange, String)] = []
        rendered.enumerateAttribute(.paragraph, in: NSRange(location: 0, length: rendered.length)) { raw, range, _ in
            guard var meta = decodedMeta(raw) else { return }
            if let item = meta.it { meta.it = fresh("item:" + item) }
            if let group = meta.g { meta.g = fresh("code:" + group) }
            if let name = meta.q { meta.q = quote ?? fresh("quote:" + name) }
            updates.append((range, encoded(meta)))
        }
        for (range, value) in updates { rendered.addAttribute(.paragraph, value: value, range: range) }
    }

    /// A rendered block ready to be inserted next to existing text: its
    /// quote, item and code names are its own, except that a quote joins the
    /// quoted line directly above or below, as Raven's own editor does.
    static func insertableFragment(_ nodes: [RichNode], joiningQuote quote: String? = nil) -> NSMutableAttributedString {
        let rendered = fragment(nodes)
        renameIdentities(in: rendered, quote: quote)
        sealTables(in: rendered)
        return rendered
    }

    /// The quote a new quoted paragraph at `range` would touch.
    static func adjacentQuote(to range: NSRange, in value: NSAttributedString) -> String? {
        if range.location > 0 {
            let previous = paragraph(in: value, at: range.location - 1)
            if previous.isQuoteParagraph, let name = previous.meta?.q { return name }
        }
        guard NSMaxRange(range) < value.length else { return nil }
        let next = paragraph(in: value, at: NSMaxRange(range))
        return next.isQuoteParagraph ? next.meta?.q : nil
    }

    /// Attributes for the character typed at `location`: those of the text
    /// before it, without anything that names a marker, mention or link.
    private static func continuingAttributes(in value: NSAttributedString, at location: Int, within paragraph: ComposerParagraph) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any]
        if location > paragraph.contentRange.location { attributes = value.attributes(at: location - 1, effectiveRange: nil) }
        else if paragraph.contentRange.length > 0 { attributes = value.attributes(at: paragraph.contentRange.location, effectiveRange: nil) }
        else if paragraph.markerRange.length > 0 { attributes = value.attributes(at: paragraph.markerRange.location, effectiveRange: nil) }
        else { attributes = plainTypingAttributes }
        for key in entityKeys + documentKeys { attributes.removeValue(forKey: key) }
        return attributes
    }

    // MARK: Markdown shortcuts

    /// Turns a typed `> `, `- `, `1. ` or three backticks into the block it
    /// names. Only ordinary paragraphs convert; inside a quote, list or code
    /// block the characters stay literal.
    static func blockShortcut(_ match: MarkdownShortcut.BlockMatch, in value: NSAttributedString, selection: NSRange) -> ComposerEdit? {
        let target = paragraph(in: value, at: match.markerRange.location)
        guard target.block == .plain, target.markerRange.length == 0,
              match.markerRange.location == target.range.location, NSMaxRange(match.markerRange) <= NSMaxRange(target.contentRange),
              isOrdinaryText(value, in: match.markerRange), !isFixedPitch(value, in: match.markerRange) else { return nil }
        if match.block == .codeBlock { return codeBlockShortcut(match, target: target, in: value) }

        let contentRange = NSRange(location: NSMaxRange(match.markerRange), length: NSMaxRange(target.contentRange) - NSMaxRange(match.markerRange))
        guard let parsed = try? document(from: value.attributedSubstring(from: contentRange)), parsed.canEdit else { return nil }
        let inline: [RichNode]
        switch parsed.nodes.count {
        case 0: inline = []
        case 1:
            guard case .element("p", _, let children) = parsed.nodes[0] else { return nil }
            inline = children
        default: return nil
        }

        let node: RichNode
        let actionName: String
        switch match.block {
        case .quote:
            node = .element("blockquote", [:], [.element("p", [:], inline)])
            actionName = "Block Quote"
        case .bulletedList:
            node = .element("ul", [:], [.element("li", [:], inline)])
            actionName = "Bulleted List"
        case .numberedList(let start):
            node = .element("ol", start == 1 ? [:] : ["start": String(start)], [.element("li", [:], inline)])
            actionName = "Numbered List"
        case .codeBlock: return nil
        }
        // The same grammar check as sending, before any text changes.
        guard (try? RichTextCodec.parse(RichTextCodec.html(RichDocument(nodes: [node]))))?.canEdit == true else { return nil }

        let rendered = insertableFragment([node], joiningQuote: match.block == .quote ? adjacentQuote(to: target.range, in: value) : nil)
        guard rendered.length > 0, let markerLength = rendered.attribute(.markerLength, at: 0, effectiveRange: nil) as? Int else { return nil }

        let result = NSMutableAttributedString(attributedString: value)
        result.replaceCharacters(in: NSRange(location: target.range.location, length: NSMaxRange(target.contentRange) - target.range.location), with: rendered)
        // A caret behind the typed marker keeps its place in the text.
        var caret = selection.location >= NSMaxRange(match.markerRange)
            ? selection.location - match.markerRange.length + markerLength
            : target.range.location + markerLength
        if match.block != .quote { renumberList(in: result, around: target.range.location, caret: &caret) }

        let landed = paragraph(in: result, at: caret)
        return ComposerEdit(text: result, selection: NSRange(location: caret, length: 0),
                            typingAttributes: continuingAttributes(in: result, at: caret, within: landed), actionName: actionName)
    }

    private static func codeBlockShortcut(_ match: MarkdownShortcut.BlockMatch, target: ComposerParagraph, in value: NSAttributedString) -> ComposerEdit? {
        guard target.contentRange == match.markerRange else { return nil }
        let template = insertableFragment([.element("pre", [:], [.element("code", [:], [.text("x")])])])
        let attributes = template.attributes(at: 0, effectiveRange: nil)

        let result = NSMutableAttributedString(attributedString: value)
        // An empty code line has no character of its own: in the middle of a
        // draft its line break carries the block, at the end only the typing
        // attributes do.
        result.setAttributes(attributes, range: target.terminatorRange)
        result.deleteCharacters(in: match.markerRange)
        return ComposerEdit(text: result, selection: NSRange(location: target.range.location, length: 0), typingAttributes: attributes, actionName: "Code Block")
    }

    /// Applies `**bold**`, `*italic*`, `` `code` ``, `~~strike~~` or
    /// `||spoiler||` to the text between the delimiters and removes them.
    static func inlineShortcut(_ match: MarkdownShortcut.InlineMatch, in value: NSAttributedString, selection: NSRange) -> ComposerEdit? {
        let target = paragraph(in: value, at: match.openRange.location)
        let whole = NSUnionRange(match.openRange, match.closeRange)
        guard target.block != .code, target.block != .other,
              match.openRange.location >= target.contentRange.location, NSMaxRange(match.closeRange) <= NSMaxRange(target.contentRange),
              match.contentRange.length > 0, isOrdinaryText(value, in: match.openRange), isOrdinaryText(value, in: match.closeRange),
              // Code is literal: nothing inside or around it is Markdown.
              !isFixedPitch(value, in: whole) else { return nil }

        let content = NSMutableAttributedString(attributedString: value.attributedSubstring(from: match.contentRange))
        let full = NSRange(location: 0, length: content.length)
        let actionName: String
        switch match.style {
        case .bold:
            convertFonts(in: content) { NSFontManager.shared.convert($0, toHaveTrait: .boldFontMask) }
            actionName = "Bold"
        case .italic:
            convertFonts(in: content) { NSFontManager.shared.convert($0, toHaveTrait: .italicFontMask) }
            actionName = "Italic"
        case .strikethrough:
            content.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: full)
            actionName = "Strikethrough"
        case .code:
            let template = fragment([.element("p", [:], [.element("code", [:], [.text("x")])])])
            guard template.length > 0, let codeFont = template.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else { return nil }
            convertFonts(in: content) { font in
                let traits = NSFontManager.shared.traits(of: font)
                var converted = codeFont
                if traits.contains(.boldFontMask) { converted = NSFontManager.shared.convert(converted, toHaveTrait: .boldFontMask) }
                if traits.contains(.italicFontMask) { converted = NSFontManager.shared.convert(converted, toHaveTrait: .italicFontMask) }
                return converted
            }
            if let background = template.attribute(.backgroundColor, at: 0, effectiveRange: nil) { content.addAttribute(.backgroundColor, value: background, range: full) }
            actionName = "Code"
        case .spoiler:
            guard let state = try? spoilerSelection(in: value, range: match.contentRange), state.range == match.contentRange else { return nil }
            content.setAttributedString(settingSpoiler(content, enabled: true))
            actionName = "Spoiler"
        }

        // The delimiters were typed in the surrounding style; typing goes on in it.
        var typing = value.attributes(at: NSMaxRange(match.closeRange) - 1, effectiveRange: nil)
        for key in entityKeys + documentKeys { typing.removeValue(forKey: key) }

        let result = NSMutableAttributedString(attributedString: value)
        result.replaceCharacters(in: whole, with: content)
        let removed = match.openRange.length + match.closeRange.length
        let caret = selection.location >= NSMaxRange(whole) ? selection.location - removed : whole.location + content.length
        return ComposerEdit(text: result, selection: NSRange(location: caret, length: 0), typingAttributes: typing, actionName: actionName)
    }

    private static func convertFonts(in value: NSMutableAttributedString, _ convert: (NSFont) -> NSFont) {
        let full = NSRange(location: 0, length: value.length)
        var updates: [(NSRange, NSFont)] = []
        value.enumerateAttribute(.font, in: full) { font, range, _ in
            updates.append((range, convert(font as? NSFont ?? NSFont.systemFont(ofSize: composerFontSize))))
        }
        for (range, font) in updates { value.addAttribute(.font, value: font, range: range) }
    }

    // MARK: Line breaks

    /// A line break inside a quote, list item or code block; nil where
    /// AppKit's plain line break is right.
    static func lineBreak(in value: NSAttributedString, selection: NSRange, typing: [NSAttributedString.Key: Any]) -> ComposerEdit? {
        let target = paragraph(in: value, at: selection.location, typing: typing)
        if target.block == .code { return leavingCodeBlock(target, in: value, selection: selection) }
        guard target.isQuoteParagraph || target.isTopLevelListItem else { return nil }
        // A caret in or left of the marker acts at the start of the text.
        let start = max(selection.location, target.contentRange.location)
        let end = max(NSMaxRange(selection), start)
        guard end <= NSMaxRange(target.contentRange) else { return nil }
        // An empty line is how a quote or list ends, as in Notes and Mail.
        if target.contentRange.length == 0 { return leavingBlock(target, in: value, actionName: "Typing") }

        let result = NSMutableAttributedString(attributedString: value)
        let attributes = continuingAttributes(in: value, at: start, within: target)
        let insertion = NSMutableAttributedString(string: "\n", attributes: attributes)
        if target.isQuoteParagraph {
            insertion.append(quoteMarker(for: target, in: value))
            result.replaceCharacters(in: NSRange(location: start, length: end - start), with: insertion)
            let caret = start + insertion.length
            return ComposerEdit(text: result, selection: NSRange(location: caret, length: 0), typingAttributes: attributes, actionName: "Typing")
        }

        guard let meta = target.meta, var level = meta.l?.first, target.markerRange.length > 0 else { return nil }
        level.n += 1
        var next = meta
        next.l = [level]
        next.it = freshIdentity()
        next.mk = level.t == "ol" ? "\(level.n). " : meta.mk
        insertion.append(NSAttributedString(string: next.mk, attributes: value.attributes(at: target.markerRange.location, effectiveRange: nil)))
        result.replaceCharacters(in: NSRange(location: start, length: end - start), with: insertion)

        // The text after the caret moves into the new item and must name it,
        // or the encoder would still see the old item's marker and number.
        let moved = paragraph(in: result, at: start + 1)
        let stamped = NSRange(location: moved.range.location, length: NSMaxRange(moved.contentRange) - moved.range.location)
        result.addAttributes([.paragraph: encoded(next), .listNumber: level.n, .markerLength: next.mk.utf16.count], range: stamped)
        var caret = start + insertion.length
        renumberList(in: result, around: caret, caret: &caret)
        let landed = paragraph(in: result, at: caret)
        return ComposerEdit(text: result, selection: NSRange(location: caret, length: 0),
                            typingAttributes: continuingAttributes(in: result, at: caret, within: landed), actionName: "Typing")
    }

    /// The "│ " of a new quoted line. A quoted line typed before markers
    /// were continued has none to copy, so it is rendered afresh.
    private static func quoteMarker(for target: ComposerParagraph, in value: NSAttributedString) -> NSAttributedString {
        if target.markerRange.length > 0 { return value.attributedSubstring(from: target.markerRange) }
        return insertableFragment([.element("blockquote", [:], [.element("p", [:], [])])], joiningQuote: target.meta?.q)
    }

    /// Removes the paragraph's marker and block, leaving ordinary text. The
    /// quote or list around it splits in two.
    private static func leavingBlock(_ target: ComposerParagraph, in value: NSAttributedString, actionName: String) -> ComposerEdit {
        let result = NSMutableAttributedString(attributedString: value)
        let remainder = NSRange(location: NSMaxRange(target.markerRange), length: NSMaxRange(target.range) - NSMaxRange(target.markerRange))
        for key in blockKeys { result.removeAttribute(key, range: remainder) }
        result.deleteCharacters(in: target.markerRange)
        clearBlockFromLineBreak(before: target.range.location, in: result)

        var caret = target.range.location
        let anchor = caret
        renumberList(in: result, around: anchor, caret: &caret)
        var typing = target.contentRange.length > 0 ? result.attributes(at: caret, effectiveRange: nil) : plainTypingAttributes
        for key in entityKeys + documentKeys { typing.removeValue(forKey: key) }
        return ComposerEdit(text: result, selection: NSRange(location: caret, length: 0), typingAttributes: typing, actionName: actionName)
    }

    /// See the convention in this extension's header comment.
    private static func clearBlockFromLineBreak(before location: Int, in result: NSMutableAttributedString) {
        guard location > 0 else { return }
        let previous = paragraph(in: result, at: location - 1)
        // An empty code line is nothing but its line break; leave it in its block.
        guard previous.terminatorRange.length > 0, previous.markerRange.length + previous.contentRange.length > 0 else { return }
        for key in blockKeys { result.removeAttribute(key, range: previous.terminatorRange) }
    }

    /// A third line break at the end of a code block leaves it, like Raven's
    /// own editor: the two empty lines go and ordinary text follows.
    private static func leavingCodeBlock(_ target: ComposerParagraph, in value: NSAttributedString, selection: NSRange) -> ComposerEdit? {
        guard selection.length == 0, target.contentRange.length == 0, target.markerRange.length == 0, target.range.location > 0,
              let group = target.meta?.g else { return nil }
        let previous = paragraph(in: value, at: target.range.location - 1)
        guard previous.block == .code, previous.meta?.g == group, previous.contentRange.length == 0, previous.markerRange.length == 0 else { return nil }
        if NSMaxRange(target.range) < value.length {
            let following = paragraph(in: value, at: NSMaxRange(target.range))
            guard !(following.block == .code && following.meta?.g == group) else { return nil }
        }

        let result = NSMutableAttributedString(attributedString: value)
        result.setAttributes(plainTypingAttributes, range: target.terminatorRange)
        result.deleteCharacters(in: previous.range)
        let caret = previous.range.location
        if caret > 0 {
            let last = paragraph(in: result, at: caret - 1)
            if last.terminatorRange.length > 0, last.contentRange.length > 0 { result.setAttributes(plainTypingAttributes, range: last.terminatorRange) }
        }
        return ComposerEdit(text: result, selection: NSRange(location: caret, length: 0), typingAttributes: plainTypingAttributes, actionName: "Typing")
    }

    /// Down Arrow at the very end of a draft that ends in a code block adds
    /// an ordinary line below it, like Raven's own editor. Without it there
    /// would be no way to type after a code block that already has text.
    static func lineBelowCodeBlock(in value: NSAttributedString, selection: NSRange, typing: [NSAttributedString.Key: Any]) -> ComposerEdit? {
        guard selection.length == 0, selection.location == value.length, value.length > 0 else { return nil }
        let target = paragraph(in: value, at: selection.location, typing: typing)
        guard target.block == .code, target.contentRange.length > 0 else { return nil }
        let result = NSMutableAttributedString(attributedString: value)
        result.append(NSAttributedString(string: "\n", attributes: plainTypingAttributes))
        return ComposerEdit(text: result, selection: NSRange(location: result.length, length: 0), typingAttributes: plainTypingAttributes, actionName: "Typing")
    }

    // MARK: Deleting

    /// Backspace at the start of a quoted line or list item removes the quote
    /// or list from that line. Deleting marker characters instead would leave
    /// a block that is still sent but no longer visible. At the start of a
    /// line without a marker it joins the line above.
    static func backspace(in value: NSAttributedString, selection: NSRange) -> ComposerEdit? {
        guard selection.length == 0 else { return nil }
        let target = paragraph(in: value, at: selection.location)
        if target.markerRange.length > 0, selection.location <= NSMaxRange(target.markerRange) {
            guard target.isQuoteParagraph || target.isTopLevelListItem else { return nil }
            return leavingBlock(target, in: value, actionName: target.isQuoteParagraph ? "Remove Block Quote" : "Remove List")
        }
        guard selection.location == target.range.location, target.range.location > 0 else { return nil }
        return joining(target, onto: paragraph(in: value, at: target.range.location - 1), in: value)
    }

    /// Forward Delete at the end of a line joins the next line, without
    /// leaving that line's marker behind as text. With the caret in front of
    /// or inside a marker it removes the quote or list, as Backspace does
    /// behind the marker; deleting one marker character would leave the rest
    /// behind as text.
    static func forwardDelete(in value: NSAttributedString, selection: NSRange) -> ComposerEdit? {
        guard selection.length == 0 else { return nil }
        let head = paragraph(in: value, at: selection.location)
        if head.markerRange.length > 0, selection.location < NSMaxRange(head.markerRange) { return backspace(in: value, selection: selection) }
        guard selection.location == NSMaxRange(head.contentRange), head.terminatorRange.length > 0, NSMaxRange(head.range) < value.length else { return nil }
        return joining(paragraph(in: value, at: NSMaxRange(head.range)), onto: head, in: value)
    }

    /// Command-Backspace in the first line of a quoted line or list item
    /// deletes back to the text's start and keeps the marker. `onFirstLine`
    /// is false when the caret sits in a later wrapped line and the command
    /// stops at that line's start, where AppKit's deletion never reaches the
    /// marker. Deleting to the start of the paragraph always reaches it.
    static func deleteToLineStart(in value: NSAttributedString, selection: NSRange, onFirstLine: Bool) -> ComposerEdit? {
        guard selection.length == 0 else { return nil }
        let target = paragraph(in: value, at: selection.location)
        guard target.markerRange.length > 0 else { return nil }
        if selection.location <= NSMaxRange(target.markerRange) { return backspace(in: value, selection: selection) }
        guard onFirstLine else { return nil }

        let result = NSMutableAttributedString(attributedString: value)
        result.deleteCharacters(in: NSRange(location: target.contentRange.location, length: selection.location - target.contentRange.location))
        let caret = target.contentRange.location
        let landed = paragraph(in: result, at: caret)
        return ComposerEdit(text: result, selection: NSRange(location: caret, length: 0),
                            typingAttributes: continuingAttributes(in: result, at: caret, within: landed), actionName: "Typing")
    }

    /// Joins `tail` onto the end of `head`. The joined text takes the head's
    /// block: the encoder reads a paragraph's block from whichever metadata
    /// covers most of it, so a long tail keeping its own would turn the
    /// head's marker into literal text. Two lines without any metadata, and
    /// an empty head (deleting a blank line), are left to AppKit.
    private static func joining(_ tail: ComposerParagraph, onto head: ComposerParagraph, in value: NSAttributedString) -> ComposerEdit? {
        guard head.terminatorRange.length > 0, NSMaxRange(head.range) == tail.range.location,
              head.markerRange.length + head.contentRange.length > 0,
              head.block != .other, tail.block != .other,
              head.meta != nil || tail.meta != nil || tail.markerRange.length > 0 else { return nil }

        let result = NSMutableAttributedString(attributedString: value)
        // The tail's line break ends the joined paragraph. It keeps no block
        // of its own (see the convention above); the text before it names
        // the paragraph's block.
        for key in blockKeys {
            result.removeAttribute(key, range: tail.contentRange)
            result.removeAttribute(key, range: tail.terminatorRange)
        }
        let inherited = value.attributes(at: head.range.location, effectiveRange: nil).filter { blockKeys.contains($0.key) && $0.key != .generated }
        if !inherited.isEmpty, tail.contentRange.length > 0 { result.addAttributes(inherited, range: tail.contentRange) }
        result.deleteCharacters(in: NSRange(location: head.terminatorRange.location, length: head.terminatorRange.length + tail.markerRange.length))

        var caret = head.terminatorRange.location
        if head.isTopLevelListItem || tail.isTopLevelListItem { renumberList(in: result, around: caret, caret: &caret) }
        let landed = paragraph(in: result, at: caret)
        return ComposerEdit(text: result, selection: NSRange(location: caret, length: 0),
                            typingAttributes: continuingAttributes(in: result, at: caret, within: landed), actionName: "Typing")
    }

    /// Deleting or replacing a selection that reaches into a marker or across
    /// a line break; nil where AppKit's plain deletion is right.
    ///
    /// The line the selection starts in keeps its marker, so its quote or
    /// list survives: deleting every line leaves one empty quoted line, as
    /// deleting a whole list leaves one bullet in Notes. A marker further
    /// inside the selection goes with its line, and what is left of the last
    /// line joins the first line's block. When nothing of the first line
    /// stays and the selection stops at the start of the last line, that
    /// line is kept as it is.
    ///
    ///     │ on[e          │ on[e           [abc
    ///     │ t]wo    →     • t]wo     →     ]│ two    →
    ///     │ onwo          │ onwo           │ two
    static func deletingSelection(in value: NSAttributedString, selection: NSRange, actionName: String = "Typing") -> ComposerEdit? {
        guard selection.length > 0, NSMaxRange(selection) <= value.length else { return nil }
        let head = paragraph(in: value, at: selection.location)
        let start = max(selection.location, head.contentRange.location)
        var end = max(NSMaxRange(selection), start)
        let tail = paragraph(in: value, at: end)
        guard head.block != .other, tail.block != .other else { return nil }
        // Lines that were only ever typed carry no block at all.
        guard head.meta != nil || tail.meta != nil || head.markerRange.length + tail.markerRange.length > 0 else { return nil }
        let result = NSMutableAttributedString(attributedString: value)

        guard tail.range.location != head.range.location else {
            // One line: only a selection that began in the marker differs
            // from AppKit's deletion.
            guard start != selection.location else { return nil }
            result.deleteCharacters(in: NSRange(location: start, length: end - start))
            return ComposerEdit(text: result, selection: NSRange(location: start, length: 0),
                                typingAttributes: continuingAttributes(in: result, at: start, within: paragraph(in: result, at: start)), actionName: actionName)
        }

        if start == head.range.location, end <= tail.contentRange.location {
            // Whole lines. The last line stays, marker and all, and typing
            // continues behind its marker.
            guard tail.markerRange.length > 0 else { return nil }
            result.deleteCharacters(in: NSRange(location: start, length: tail.range.location - start))
            var caret = start + tail.markerRange.length
            // Deleted whole lines may have been list items; the surviving
            // line's marker must renumber (item 3 of 3 deleted down to
            // alone becomes item 1).
            let anchor = caret
            renumberList(in: result, around: anchor, caret: &caret)
            return ComposerEdit(text: result, selection: NSRange(location: caret, length: 0),
                                typingAttributes: continuingAttributes(in: result, at: caret, within: paragraph(in: result, at: caret)), actionName: actionName)
        }

        // What is left of the last line takes the first line's block, as in
        // `joining`.
        end = max(end, tail.contentRange.location)
        let remainder = NSRange(location: end, length: NSMaxRange(tail.contentRange) - end)
        for key in blockKeys {
            if remainder.length > 0 { result.removeAttribute(key, range: remainder) }
            if tail.terminatorRange.length > 0 { result.removeAttribute(key, range: tail.terminatorRange) }
        }
        if head.range.length > 0, remainder.length > 0 {
            let inherited = value.attributes(at: head.range.location, effectiveRange: nil).filter { blockKeys.contains($0.key) && $0.key != .generated }
            if !inherited.isEmpty { result.addAttributes(inherited, range: remainder) }
        }
        result.deleteCharacters(in: NSRange(location: start, length: end - start))

        var caret = start
        if head.isTopLevelListItem || tail.isTopLevelListItem { renumberList(in: result, around: caret, caret: &caret) }
        return ComposerEdit(text: result, selection: NSRange(location: caret, length: 0),
                            typingAttributes: continuingAttributes(in: result, at: caret, within: paragraph(in: result, at: caret)), actionName: actionName)
    }

    /// Where typing lands when the caret sits inside a marker: after it.
    static func typingLocation(in value: NSAttributedString, for selection: NSRange) -> Int? {
        guard selection.length == 0 else { return nil }
        let target = paragraph(in: value, at: selection.location)
        guard target.markerRange.length > 0, selection.location < NSMaxRange(target.markerRange) else { return nil }
        return NSMaxRange(target.markerRange)
    }

    // MARK: List numbering

    /// Re-renders the list around `location` so its bullets and numbers show
    /// what will be sent, and moves `caret` along. Lists always have a marker
    /// on every paragraph that starts an item, so no blank line can be lost.
    private static func renumberList(in result: NSMutableAttributedString, around location: Int, caret: inout Int) {
        func isListParagraph(_ candidate: ComposerParagraph) -> Bool {
            candidate.block == .listItem && candidate.meta?.q == nil && candidate.range.length > 0
        }
        var here = paragraph(in: result, at: location)
        if !isListParagraph(here) {
            // The paragraph at `location` may have just left the list (e.g.
            // leavingBlock removed its marker): renumber the list run beside
            // it, so a run after a removed item restarts at 1 the way the
            // encoder's fresh <ol> would.
            if NSMaxRange(here.range) < result.length, isListParagraph(paragraph(in: result, at: NSMaxRange(here.range))) {
                here = paragraph(in: result, at: NSMaxRange(here.range))
            } else if here.range.location > 0, isListParagraph(paragraph(in: result, at: here.range.location - 1)) {
                here = paragraph(in: result, at: here.range.location - 1)
            } else { return }
        }

        var start = here.range.location
        while start > 0 {
            let previous = paragraph(in: result, at: start - 1)
            guard isListParagraph(previous) else { break }
            start = previous.range.location
        }
        var last = here
        while NSMaxRange(last.range) < result.length {
            let next = paragraph(in: result, at: NSMaxRange(last.range))
            guard isListParagraph(next) else { break }
            last = next
        }
        // The final line break stays: it belongs to whatever follows the list.
        let blockRange = NSRange(location: start, length: NSMaxRange(last.contentRange) - start)
        let block = result.attributedSubstring(from: blockRange)
        guard let parsed = try? document(from: block), parsed.canEdit else { return }
        let rendered = insertableFragment(parsed.nodes)

        let before = paragraphs(in: block), after = paragraphs(in: rendered)
        let blockText = block.string as NSString, renderedText = rendered.string as NSString
        guard before.count == after.count, zip(before, after).allSatisfy({ blockText.substring(with: $0.contentRange) == renderedText.substring(with: $1.contentRange) }) else { return }

        let relative = caret - start
        if relative >= 0, relative <= block.length, let index = before.lastIndex(where: { $0.range.location <= relative }) {
            let offset = min(max(0, relative - before[index].contentRange.location), before[index].contentRange.length)
            caret = start + after[index].contentRange.location + offset
        } else if relative > block.length {
            caret += rendered.length - block.length
        }
        result.replaceCharacters(in: blockRange, with: rendered)
    }

    // MARK: Applying

    /// The smallest replacement that turns `old` into `new`, so an edit
    /// registers one precise undo step and leaves the rest of a shared draft
    /// (and other windows' selections in it) alone.
    static func replacement(from old: NSAttributedString, to new: NSAttributedString) -> (range: NSRange, text: NSAttributedString)? {
        guard !old.isEqual(to: new) else { return nil }
        let oldText = old.string as NSString, newText = new.string as NSString
        let limit = min(old.length, new.length)

        var prefix = 0
        while prefix < limit, oldText.character(at: prefix) == newText.character(at: prefix),
              (old.attributes(at: prefix, effectiveRange: nil) as NSDictionary).isEqual(to: new.attributes(at: prefix, effectiveRange: nil)) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, oldText.character(at: old.length - suffix - 1) == newText.character(at: new.length - suffix - 1),
              (old.attributes(at: old.length - suffix - 1, effectiveRange: nil) as NSDictionary).isEqual(to: new.attributes(at: new.length - suffix - 1, effectiveRange: nil)) { suffix += 1 }

        // Never split a surrogate pair or a composed character: widen the
        // replaced range to whole sequences in both strings.
        func sequenceStart(_ text: NSString, _ index: Int) -> Int {
            index < text.length ? text.rangeOfComposedCharacterSequence(at: index).location : index
        }
        func sequenceEnd(_ text: NSString, _ index: Int) -> Int {
            guard index > 0, index < text.length else { return index }
            let sequence = text.rangeOfComposedCharacterSequence(at: index)
            return sequence.location < index ? NSMaxRange(sequence) : index
        }
        prefix = min(sequenceStart(oldText, prefix), sequenceStart(newText, prefix))
        let oldEnd = old.length - suffix, newEnd = new.length - suffix
        suffix -= max(sequenceEnd(oldText, oldEnd) - oldEnd, sequenceEnd(newText, newEnd) - newEnd)
        suffix = max(0, suffix)

        let oldRange = NSRange(location: prefix, length: old.length - prefix - suffix)
        let newRange = NSRange(location: prefix, length: new.length - prefix - suffix)
        return (oldRange, new.attributedSubstring(from: newRange))
    }
}
