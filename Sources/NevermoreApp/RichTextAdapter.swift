import AppKit
import NevermoreCore

// Internal rather than private: ComposerStructure.swift edits paragraphs
// through the same metadata the renderer stamps and the encoder reads.
extension NSAttributedString.Key {
    static let richDocument = Self("Nevermore.RichDocument")
    static let originalSignature = Self("Nevermore.OriginalSignature")
    static let originalText = Self("Nevermore.OriginalText")
    static let semantic = Self("Nevermore.SemanticNode")
    static let spoiler = Self("Nevermore.Spoiler")
    static let spoilerTint = Self("Nevermore.SpoilerTint")
    static let highlight = Self("Nevermore.Highlight")
    static let listType = Self("Nevermore.ListType")
    static let listNumber = Self("Nevermore.ListNumber")
    static let blockKind = Self("Nevermore.BlockKind")
    static let markerLength = Self("Nevermore.MarkerLength")
    static let unsupported = Self("Nevermore.Unsupported")
    static let paragraph = Self("Nevermore.Paragraph")
    static let generated = Self("Nevermore.Generated")
    static let paraContext = Self("Nevermore.ParaContext")
}
// Versioned per-paragraph edit metadata (v1). The renderer stamps every
// paragraph with this context; reconstruction trusts it only while the
// paragraph's generated marker prefix still matches, so typed or pasted
// look-alike text stays literal. Unknown or missing versions fall back to the
// legacy attributes.
struct ParaMeta: Codable {
    struct Level: Codable { var t: String; var n: Int }
    var v = 1
    var b = "p"          // p | li | pre
    var q: String?       // enclosing blockquote group
    var l: [Level]?      // list path, outermost first (li)
    var g: String?       // code block group joining wrapped lines (pre)
    var it: String?      // list item identity (li)
    var code: Bool?      // pre children wrapped in <code>
    var lang: String?    // code language-* class
    var mk = ""          // generated marker prefix ("│ ", indent, bullet)
    var pid = 0          // rendered paragraph index
}
private final class RenderState {
    var lists: [(tag: String, n: Int, item: String)] = []
    var quote: String?
    /// Reading mode: the characters of each rendered quote, its trailing
    /// newline included, for spacing quotes apart from their answers.
    var quoteSpans: [NSRange] = []
    var container = ""
    var pre = false
    var unsupported = false
    var counter = 0
    func nextID(_ prefix: String) -> String { counter += 1; return "\(prefix)\(counter)" }
}
/// AppKit coalesces equal adjacent attribute values. Keep separate semantic
/// instances even when two emoji/mentions carry identical server metadata.
private struct SemanticMark: Codable {
    let instance: UUID
    let node: RichNode
    init(node: RichNode) { instance = UUID(); self.node = node }
}
@MainActor enum NativeRichText {
    private static let spoilerColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12)

    static func settingSpoiler(_ source: [NSAttributedString.Key: Any], enabled: Bool) -> [NSAttributedString.Key: Any] {
        var result = source
        if enabled {
            result[.spoiler] = true
            if result[.backgroundColor] == nil { result[.backgroundColor] = spoilerColor; result[.spoilerTint] = true }
        } else {
            result.removeValue(forKey: .spoiler)
            if result[.spoilerTint] as? Bool == true, (result[.backgroundColor] as? NSColor)?.isEqual(spoilerColor) == true { result.removeValue(forKey: .backgroundColor) }
            result.removeValue(forKey: .spoilerTint)
        }
        return result
    }
    static func isSpoiler(_ attributes: [NSAttributedString.Key: Any]) -> Bool { attributes[.spoiler] as? Bool == true }
    static func canAuthorSpoiler(_ attributes: [NSAttributedString.Key: Any]) -> Bool { attributes[.blockKind] as? String != "pre" && attributes[.unsupported] as? Bool != true }

    /// Semantic mentions and emoji remain atomic when a formatting selection
    /// begins inside their displayed label. Also retain whole emoji graphemes.
    static func spoilerSelection(in value: NSAttributedString, range: NSRange) throws -> (range: NSRange, enabled: Bool) {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0, range.location <= value.length, range.length <= value.length - range.location else { throw RichTextError.unsafeEdit }
        guard range.length > 0 else { return (range, false) }
        var expanded = (value.string as NSString).rangeOfComposedCharacterSequences(for: range)
        value.enumerateAttribute(.semantic, in: NSRange(location: 0, length: value.length)) { marker, entity, _ in
            if marker != nil, NSIntersectionRange(expanded, entity).length > 0 { expanded = NSUnionRange(expanded, entity) }
        }
        var supported = true
        value.enumerateAttributes(in: expanded) { attributes, _, _ in if !canAuthorSpoiler(attributes) { supported = false } }
        guard supported else { throw RichTextError.unsafeEdit }
        var enabled = true
        value.enumerateAttribute(.spoiler, in: expanded) { flag, _, _ in if flag as? Bool != true { enabled = false } }
        return (expanded, enabled)
    }
    static func settingSpoiler(_ value: NSAttributedString, enabled: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: value)
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in
            result.setAttributes(settingSpoiler(attributes, enabled: enabled), range: range)
        }
        return result
    }

    static func signature(_ value: NSAttributedString) -> String {
        var parts = [value.string]
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attrs, range, _ in
            let keys: [NSAttributedString.Key] = [.font, .underlineStyle, .strikethroughStyle, .link, .semantic, .spoiler, .blockKind, .markerLength, .backgroundColor, .highlight, .listType, .listNumber, .paragraph, .generated, .paragraphStyle, .attachment]
            parts.append("\(range.location):\(range.length):" + keys.map { String(describing: attrs[$0] ?? "") }.joined(separator: "|"))
        }
        return parts.joined(separator: "\u{001E}")
    }
    static func encoded(_ meta: ParaMeta) -> String { String(decoding: (try? JSONEncoder().encode(meta)) ?? Data(), as: UTF8.self) }
    private static func stampParagraphs(_ output: NSMutableAttributedString) {
        let text = output.string as NSString
        var location = 0, pid = 0
        while location < output.length {
            let range = text.paragraphRange(for: NSRange(location: location, length: 0))
            if let raw = output.attribute(.paraContext, at: range.location, effectiveRange: nil) as? String,
               let data = raw.data(using: .utf8), var meta = try? JSONDecoder().decode(ParaMeta.self, from: data) {
                pid += 1; meta.v = 1; meta.pid = pid
                if let stamped = try? JSONEncoder().encode(meta), let string = String(data: stamped, encoding: .utf8) {
                    output.addAttribute(.paragraph, value: string, range: range)
                }
            }
            output.removeAttribute(.paraContext, range: range)
            location = NSMaxRange(range)
        }
    }
    /// Reading/copying does not need the editor's original HTML or semantic payloads.
    static func readingString(document: RichDocument, fontSize: CGFloat = 14) -> NSAttributedString {
        func mask(_ node: RichNode) -> RichNode {
            guard case .element(let tag, let attrs, let children) = node else { return node }
            if attrs["data-spoiler"] != nil { return .text("[Spoiler]") }
            return .element(tag, attrs, children.map(mask))
        }
        let visible = RichDocument(nodes: document.nodes.map(mask), canEdit: false)
        let output = NSMutableAttributedString(attributedString: renderDocument(document: visible, fontSize: fontSize, revealSpoilers: false, purpose: .reading))
        let full = NSRange(location: 0, length: output.length)
        var privateKeys = Set<NSAttributedString.Key>()
        output.enumerateAttributes(in: full) { attrs, _, _ in
            privateKeys.formUnion(attrs.keys.filter { $0.rawValue.hasPrefix("Nevermore.") })
        }
        for key in privateKeys where key != .nevermoreBodyQuote && key != .nevermoreInlineImage { output.removeAttribute(key, range: full) }
        return output
    }

    static func attributedString(document: RichDocument, fontSize: CGFloat = 14, revealSpoilers: Bool = false) -> NSAttributedString {
        renderDocument(document: document, fontSize: fontSize, revealSpoilers: revealSpoilers, purpose: .editing)
    }

    private enum RenderPurpose { case reading, editing }

    private static func renderDocument(document: RichDocument, fontSize: CGFloat, revealSpoilers: Bool, purpose: RenderPurpose) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        // Reading text follows the theme. Editing keeps system fonts and
        // colors: the HTML encoder reads a fixed-pitch font as inline code.
        let reading = purpose == .reading
        let font = reading ? ThemeFonts.readingBody(ofSize: fontSize) : NSFont.systemFont(ofSize: fontSize)
        let textColor: NSColor = reading ? .themeText : .labelColor
        let quietColor: NSColor = reading ? .themeSecondaryText : .secondaryLabelColor
        let mentionColor: NSColor = reading ? .themeLink : .linkColor
        let codeBackground: NSColor = reading ? .themeCodeBackground : NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        let state = RenderState()
        func append(_ string: String, _ attrs: [NSAttributedString.Key: Any]) { output.append(NSAttributedString(string: string, attributes: attrs)) }
        func encoded(_ node: RichNode) -> String {
            guard purpose == .editing else { return "" }
            return String(decoding: (try? JSONEncoder().encode(SemanticMark(node: node))) ?? Data(), as: UTF8.self)
        }
        func paragraphContext(_ meta: ParaMeta) -> String {
            purpose == .editing ? NativeRichText.encoded(meta) : ""
        }
        func lineStart(_ attrs: [NSAttributedString.Key: Any]) { if output.length > 0 && !output.string.hasSuffix("\n") { append("\n", attrs) } }
        func beginPara(_ attributes: [NSAttributedString.Key: Any], meta input: ParaMeta) -> [NSAttributedString.Key: Any] {
            var meta = input
            meta.mk = (meta.q != nil && !reading ? "│ " : "") + meta.mk
            var attrs = attributes
            attrs[.paraContext] = paragraphContext(meta)
            attrs[.blockKind] = meta.b
            if let inner = meta.l?.last { attrs[.listType] = inner.t; attrs[.listNumber] = inner.n }
            attrs[.markerLength] = meta.mk.utf16.count
            lineStart(attrs)
            if !meta.mk.isEmpty { var marker = attrs; marker[.generated] = true; append(meta.mk, marker) }
            return attrs
        }
        func render(_ node: RichNode, attributes: [NSAttributedString.Key: Any], depth: Int = 0) {
            switch node {
            case .text(let string): append(string, attributes)
            case .element(let tag, let metadata, let children):
                var attrs = attributes
                let start = output.length
                let currentFont = attrs[.font] as? NSFont ?? font
                switch tag {
                case "strong": attrs[.font] = NSFontManager.shared.convert(currentFont, toHaveTrait: .boldFontMask)
                case "em": attrs[.font] = NSFontManager.shared.convert(currentFont, toHaveTrait: .italicFontMask)
                case "u": attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                case "s": attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                case "code", "pre": attrs[.font] = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular); attrs[.backgroundColor] = codeBackground
                case "mark": attrs[.highlight] = true; attrs[.backgroundColor] = NSColor.systemYellow.withAlphaComponent(0.25)
                case "a": if let href = metadata["href"], RichTextCodec.safeURL(href, allowRelative: true), let url = URL(string: href) { attrs[.link] = url }
                default: break
                }
                if metadata["data-nevermore-unsupported"] != nil { attrs[.unsupported] = true }
                if metadata["data-spoiler"] != nil {
                    if revealSpoilers {
                        attrs = settingSpoiler(attrs, enabled: true)
                        for child in children { render(child, attributes: attrs, depth: depth + 1) }
                    } else {
                        attrs[.semantic] = encoded(node)
                        attrs[.foregroundColor] = quietColor
                        append("[Spoiler]", attrs)
                    }
                    return
                }
                switch tag {
                case "ul", "ol":
                    if state.pre || state.container == "ul" || state.container == "ol" {
                        state.unsupported = true
                        for child in children { render(child, attributes: attrs, depth: depth + 1) }
                        break
                    }
                    let parent = state.container; state.container = tag
                    let level = state.lists.count + 1
                    let base = tag == "ol" ? (Int(metadata["start"] ?? "1") ?? 1) : 1
                    var index = 0
                    for child in children {
                        if case .element("li", _, _) = child {
                            index += 1
                            if state.lists.count >= level { state.lists.removeSubrange((level - 1)...) }
                            state.lists.append((tag, tag == "ol" ? base + index - 1 : index, state.nextID("i")))
                            render(child, attributes: attributes, depth: depth + 1)
                        } else if case .text(let space) = child, space.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            continue
                        } else { state.unsupported = true; render(child, attributes: attrs, depth: depth + 1) }
                    }
                    if state.lists.count >= level { state.lists.removeSubrange((level - 1)...) }
                    state.container = parent
                case "li":
                    guard let frame = state.lists.last, ["ul", "ol"].contains(state.container) else {
                        state.unsupported = true
                        for child in children { render(child, attributes: attrs, depth: depth + 1) }
                        break
                    }
                    var meta = ParaMeta(b: "li", q: state.quote, l: state.lists.map { .init(t: $0.tag, n: $0.n) }, it: frame.item)
                    let indent = String(repeating: "  ", count: state.lists.count - 1)
                    let bullet = frame.tag == "ol" ? "\(frame.n). " : ["•", "◦", "▪"][min(state.lists.count, 3) - 1] + " "
                    meta.mk = indent + bullet
                    let para = beginPara(attrs, meta: meta)
                    let parent = state.container; state.container = "li"
                    var sawContent = false
                    for child in children {
                        if case .element(let childTag, _, let grandchildren) = child {
                            if ["ul", "ol"].contains(childTag) {
                                if !output.string.hasSuffix("\n") { append("\n", para) }
                                render(child, attributes: attributes, depth: depth + 1)
                                sawContent = false
                                continue
                            }
                            if childTag == "p" {
                                if sawContent && !output.string.hasSuffix("\n") { append("\n", para) }
                                for grandchild in grandchildren { render(grandchild, attributes: para, depth: depth + 1) }
                                sawContent = true
                                continue
                            }
                            if ["pre", "blockquote", "li", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "hr"].contains(childTag) {
                                state.unsupported = true
                                render(child, attributes: attrs, depth: depth + 1)
                                continue
                            }
                        }
                        render(child, attributes: para, depth: depth + 1)
                        sawContent = true
                    }
                    if !output.string.hasSuffix("\n") { append("\n", para) }
                    state.container = parent
                case "pre":
                    if state.pre || state.container == "li" {
                        state.unsupported = true
                        for child in children { render(child, attributes: attrs, depth: depth + 1) }
                        break
                    }
                    var wrapped = false, language: String? = nil, textChildren = children
                    if children.count == 1, case .element("code", let codeAttrs, let codeChildren) = children[0], codeAttrs.keys.allSatisfy({ $0 == "class" }) {
                        wrapped = true; language = codeAttrs["class"]; textChildren = codeChildren
                    }
                    let clean = textChildren.allSatisfy { if case .text = $0 { return true }; return false }
                    if !clean { state.unsupported = true }
                    let meta = ParaMeta(b: "pre", q: state.quote, g: state.nextID("b"), code: wrapped, lang: language)
                    let para = beginPara(attrs, meta: meta)
                    state.pre = true
                    for child in clean ? textChildren : children { render(child, attributes: para, depth: depth + 1) }
                    if !output.string.hasSuffix("\n") { append("\n", para) }
                    state.pre = false
                case "blockquote":
                    if state.quote != nil || state.pre || state.container == "ul" || state.container == "ol" {
                        state.unsupported = true
                        for child in children { render(child, attributes: attrs, depth: depth + 1) }
                        break
                    }
                    let parent = state.quote; let qid = state.nextID("q"); state.quote = qid
                    var quoted = attrs
                    if reading {
                        let style = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                        style.firstLineHeadIndent += 12
                        style.headIndent += 12
                        quoted[.paragraphStyle] = style
                        quoted[.nevermoreBodyQuote] = UUID().uuidString
                    }
                    var markerContext = ParaMeta(b: "p", q: qid); markerContext.mk = "│ "
                    quoted[.paraContext] = paragraphContext(ParaMeta(b: "p", q: qid))
                    quoted[.blockKind] = "p"
                    lineStart(quoted)
                    let quoteStart = output.length
                    for child in children {
                        if case .element(let childTag, _, _) = child, ["p", "ul", "ol", "pre", "blockquote"].contains(childTag) {
                            render(child, attributes: quoted, depth: depth + 1)
                        } else {
                            if !reading && output.length > 0 && output.string.hasSuffix("\n") {
                                var marker = quoted; marker[.generated] = true
                                if case .element(let childTag, _, _) = child, childTag == "hr" || childTag == "br" {
                                    marker[.paraContext] = paragraphContext(ParaMeta(b: childTag, q: qid, mk: "│ "))
                                } else {
                                    marker[.paraContext] = paragraphContext(markerContext)
                                }
                                append("│ ", marker)
                            }
                            render(child, attributes: quoted, depth: depth + 1)
                        }
                    }
                    if !output.string.hasSuffix("\n") { append("\n", quoted) }
                    state.quote = parent
                    if reading { state.quoteSpans.append(NSRange(location: quoteStart, length: output.length - quoteStart)) }
                case "p":
                    let para = beginPara(attrs, meta: ParaMeta(b: "p", q: state.quote))
                    for child in children { render(child, attributes: para, depth: depth + 1) }
                    if !output.string.hasSuffix("\n") { append("\n", para) }
                case "table":
                    if let layout = RichTableLayout(node) {
                        lineStart(attrs)
                        let table = NativeTables.table(columns: layout.columns)
                        for cell in layout.cells {
                            let block = NativeTables.block(for: cell, in: table, fontSize: fontSize)
                            let style = (attrs[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
                            style.textBlocks = [block]
                            switch cell.alignment {
                            case .left: style.alignment = .left
                            case .center: style.alignment = .center
                            case .right: style.alignment = .right
                            case nil: break
                            }
                            var cellAttributes = attrs; cellAttributes[.paragraphStyle] = style
                            if case .element("th", _, _) = cell.node { cellAttributes[.font] = NSFontManager.shared.convert(currentFont, toHaveTrait: .boldFontMask) }
                            let cellStart = output.length
                            render(cell.node, attributes: cellAttributes, depth: depth + 1)
                            if output.length == cellStart || !output.string.hasSuffix("\n") { append("\n", cellAttributes) }
                        }
                    } else {
                        state.unsupported = true
                        for child in children { render(child, attributes: attrs, depth: depth + 1) }
                    }
                case "tr":
                    lineStart(attrs)
                    for child in children { render(child, attributes: attrs, depth: depth + 1) }
                    if !output.string.hasSuffix("\n") { append("\n", attrs) }
                case "td", "th":
                    for child in children { render(child, attributes: attrs, depth: depth + 1) }
                    if (attrs[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.last is NSTextTableBlock == false { append("\t", attrs) }
                default:
                    if tag == "img" {
                        attrs[.semantic] = encoded(node)
                        // The transcript may show a GIF in place of the text.
                        if reading, metadata["data-type"] != "customEmoji", let src = metadata["src"] { attrs[.nevermoreInlineImage] = InlineImageSource(src) }
                        append(metadata["alt"] ?? metadata["data-name"].map { ":\($0):" } ?? "[Image]", attrs)
                    } else if tag == "br" || tag == "hr" {
                        if tag == "hr" || attrs[.paraContext] == nil {
                            attrs[.paraContext] = paragraphContext(ParaMeta(b: tag, q: state.quote))
                            attrs[.blockKind] = tag
                        }
                        append("\n", attrs)
                    }
                    else if metadata["data-spoiler"] != nil {
                        attrs[.semantic] = encoded(node)
                        if revealSpoilers { for child in children { render(child, attributes: attrs, depth: depth + 1) } }
                        else { attrs[.foregroundColor] = quietColor; append("[Spoiler]", attrs) }
                    } else {
                        if metadata["data-type"] == "userMention" || metadata["data-type"] == "channelMention" {
                            attrs[.semantic] = encoded(node); attrs[.foregroundColor] = mentionColor
                        }
                        for child in children { render(child, attributes: attrs, depth: depth + 1) }
                    }
                }
                if tag == "table", purpose == .editing, document.canEdit {
                    markTable(node, in: output, range: NSRange(location: start, length: output.length - start))
                }
            }
        }
        for node in document.nodes { render(node, attributes: [.font: font, .foregroundColor: textColor]) }
        if reading { spaceQuotes(state.quoteSpans, in: output, fontSize: fontSize) }
        if (state.unsupported || !document.canEdit) && output.length > 0 { output.addAttribute(.unsupported, value: true, range: NSRange(location: 0, length: output.length)) }
        // Transcript renders discard edit metadata. Avoid computing paragraph
        // round trips and full attributed signatures that only editors consume.
        if purpose == .editing { stampParagraphs(output) }
        if output.string.hasSuffix("\n"), (output.attribute(.paragraphStyle, at: output.length - 1, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty != false {
            output.deleteCharacters(in: NSRange(location: output.length - 1, length: 1))
        }
        if purpose == .editing, output.length > 0 {
            sealTables(in: output)
            let fingerprint = signature(output)
            if let data = try? JSONEncoder().encode(document) {
                output.addAttribute(.originalSignature, value: fingerprint, range: NSRange(location: 0, length: output.length))
                output.addAttribute(.richDocument, value: data, range: NSRange(location: 0, length: output.length))
                output.addAttribute(.originalText, value: output.string, range: NSRange(location: 0, length: output.length))
            }
        }
        return output
    }
    /// Reading quotes pair with the text that answers them: a small gap
    /// separates a quote from its answer and a larger one separates an
    /// answer from the next quote. A quote that opens the message adds
    /// nothing above it, so it sits under the sender line like any first
    /// paragraph. The gaps are paragraph spacing, which stays outside the
    /// used line rects the quote bar is drawn from.
    private static func spaceQuotes(_ quotes: [NSRange], in output: NSMutableAttributedString, fontSize: CGFloat) {
        let answerGap = (fontSize * 0.3).rounded(), nextQuoteGap = (fontSize * 0.75).rounded()
        let string = output.string as NSString
        func space(paragraphAt location: Int, by gap: CGFloat) {
            guard location < output.length else { return }
            let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
            var updates: [(NSRange, NSParagraphStyle)] = []
            output.enumerateAttribute(.paragraphStyle, in: paragraph) { value, run, _ in
                let current = value as? NSParagraphStyle ?? .default
                // Table cells lay out in their own blocks.
                guard current.textBlocks.isEmpty, current.paragraphSpacingBefore < gap else { return }
                let style = current.mutableCopy() as! NSMutableParagraphStyle
                style.paragraphSpacingBefore = gap
                updates.append((run, style))
            }
            for (run, style) in updates { output.addAttribute(.paragraphStyle, value: style, range: run) }
        }
        for quote in quotes where quote.length > 0 {
            space(paragraphAt: NSMaxRange(quote), by: answerGap)
            if quote.location > 0 { space(paragraphAt: quote.location, by: nextQuoteGap) }
        }
    }
    static func document(from value: NSAttributedString) throws -> RichDocument {
        guard value.string.utf8.count <= RichTextCodec.maximumBytes else { throw RichTextError.tooLarge }
        if value.length == 0 { return RichDocument(nodes: []) }
        if containsTables(value) { return try tableAwareDocument(from: value) }
        if let original = value.attribute(.originalText, at: 0, effectiveRange: nil) as? String,
           original == value.string,
           value.attribute(.originalSignature, at: 0, effectiveRange: nil) as? String == signature(value),
           let data = value.attribute(.richDocument, at: 0, effectiveRange: nil) as? Data,
           let document = try? JSONDecoder().decode(RichDocument.self, from: data) {
            guard document.canEdit else { throw RichTextError.unsafeEdit }
            return document
        }
        var unsafe = false
        value.enumerateAttribute(.unsupported, in: NSRange(location: 0, length: value.length)) { marker, _, stop in
            if marker as? Bool == true { unsafe = true; stop.pointee = true }
        }
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attrs, _, stop in
            if attrs[.attachment] != nil || (attrs[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.isEmpty == false { unsafe = true; stop.pointee = true }
        }
        guard !unsafe else { throw RichTextError.unsafeEdit }
        let text = value.string as NSString
        var root: [RichNode] = []
        var quoteID: String? = nil
        var quoteChildren: [RichNode] = []
        var stack: [(tag: String, start: Int, items: [RichNode], lastItemID: String?, lastN: Int)] = []
        var preGroup: (id: String?, code: Bool, lang: String?, lines: [[RichNode]])? = nil
        var lastPID = -1
        func appendNode(_ node: RichNode) { if quoteID != nil { quoteChildren.append(node) } else { root.append(node) } }
        func appendToLastItem(_ node: RichNode) {
            guard let index = stack.indices.last, let last = stack[index].items.popLast(), case .element("li", let attrs, var kids) = last else { return }
            kids.append(node); stack[index].items.append(.element("li", attrs, kids))
        }
        func popList() {
            let frame = stack.removeLast()
            var attrs: [String: String] = [:]
            if frame.tag == "ol", frame.start != 1 { attrs["start"] = String(frame.start) }
            let node = RichNode.element(frame.tag, attrs, frame.items)
            if stack.isEmpty { appendNode(node) } else { appendToLastItem(node) }
        }
        func closeLists() { while !stack.isEmpty { popList() } }
        func closePre() {
            guard let group = preGroup else { return }
            var joined: [RichNode] = []
            for (index, line) in group.lines.enumerated() { if index > 0 { joined.append(.text("\n")) }; joined += line }
            var codeAttrs: [String: String] = [:]
            if let lang = group.lang { codeAttrs["class"] = lang }
            appendNode(.element("pre", [:], group.code ? [.element("code", codeAttrs, joined)] : joined))
            preGroup = nil
        }
        func closeQuote() { if quoteID != nil { root.append(.element("blockquote", [:], quoteChildren)); quoteChildren = []; quoteID = nil } }
        func inlineNodes(_ range: NSRange, kind: String, semantic: Bool = true, spoiler: Bool = true) -> [RichNode] {
            var nodes: [RichNode] = []
            if spoiler {
                value.enumerateAttribute(.spoiler, in: range) { flag, subrange, _ in
                    let children = inlineNodes(subrange, kind: kind, semantic: semantic, spoiler: false)
                    if flag as? Bool == true { nodes.append(.element("span", ["data-spoiler": "true"], children)) }
                    else { nodes += children }
                }
                return nodes
            }
            if semantic {
                value.enumerateAttribute(.semantic, in: range) { marker, subrange, _ in
                    if let json = marker as? String, let data = json.data(using: .utf8), let mark = try? JSONDecoder().decode(SemanticMark.self, from: data), case .element(let tag, let metadata, let originalChildren) = mark.node {
                        let node = mark.node
                        if tag == "img" { nodes.append(node) }
                        else if metadata["data-spoiler"] != nil && text.substring(with: subrange) == "[Spoiler]" { nodes.append(.element(tag, metadata, originalChildren)) }
                        else { nodes.append(.element(tag, metadata, inlineNodes(subrange, kind: kind, semantic: false, spoiler: false))) }
                    } else { nodes += inlineNodes(subrange, kind: kind, semantic: false, spoiler: false) }
                }
                return nodes
            }
            value.enumerateAttributes(in: range) { attrs, subrange, _ in
                var node = RichNode.text(text.substring(with: subrange))
                if let font = attrs[.font] as? NSFont {
                    let traits = NSFontManager.shared.traits(of: font)
                    if traits.contains(.boldFontMask) { node = .element("strong", [:], [node]) }
                    if traits.contains(.italicFontMask) { node = .element("em", [:], [node]) }
                    if traits.contains(.fixedPitchFontMask) && kind != "pre" { node = .element("code", [:], [node]) }
                }
                if (attrs[.underlineStyle] as? Int ?? 0) != 0 { node = .element("u", [:], [node]) }
                if (attrs[.strikethroughStyle] as? Int ?? 0) != 0 { node = .element("s", [:], [node]) }
                if attrs[.highlight] as? Bool == true { node = .element("mark", [:], [node]) }
                if let url = (attrs[.link] as? URL)?.relativeString ?? attrs[.link] as? String, RichTextCodec.safeURL(url, allowRelative: true) { node = .element("a", ["href":url], [node]) }
                nodes.append(node)
            }
            return nodes
        }
        func dominantMeta(in range: NSRange) -> ParaMeta? {
            var best: (meta: ParaMeta, length: Int)? = nil
            value.enumerateAttribute(.paragraph, in: range) { raw, subrange, _ in
                guard let s = raw as? String, let data = s.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(ParaMeta.self, from: data), decoded.v == 1 else { return }
                if best == nil || subrange.length > best!.length { best = (decoded, subrange.length) }
            }
            return best?.meta
        }
        var location = 0
        while location < value.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            var content = paragraph
            let meta = dominantMeta(in: paragraph)
            if let meta, !meta.mk.isEmpty {
                var effective = NSRange()
                let flagged = value.attribute(.generated, at: content.location, effectiveRange: &effective) as? Bool == true
                let limit = min(meta.mk.utf16.count, content.length)
                if flagged, effective.location <= content.location, NSMaxRange(effective) - content.location >= limit,
                   limit > 0, text.substring(with: NSRange(location: content.location, length: limit)) == meta.mk {
                    content.location += limit; content.length -= limit
                }
            } else if meta == nil {
                let kind = value.attribute(.blockKind, at: paragraph.location, effectiveRange: nil) as? String ?? "p"
                let marker = value.attribute(.markerLength, at: paragraph.location, effectiveRange: nil) as? Int ?? 0
                let expected = kind == "blockquote" ? "│ " : kind == "li" ? (value.attribute(.listType, at: paragraph.location, effectiveRange: nil) as? String == "ol" ? "\(value.attribute(.listNumber, at: paragraph.location, effectiveRange: nil) as? Int ?? 1). " : "• ") : ""
                if marker > 0 && !expected.isEmpty && text.substring(with: paragraph).hasPrefix(expected) {
                    content.location += min(marker, content.length); content.length -= min(marker, content.length)
                }
            }
            while content.length > 0 && [10,13].contains(Int(text.character(at: NSMaxRange(content) - 1))) { content.length -= 1 }
            if let meta {
                let children = inlineNodes(content, kind: meta.b)
                if meta.q != quoteID { closePre(); closeLists(); closeQuote(); quoteID = meta.q }
                if meta.b == "li", let path = meta.l?.filter({ ["ul", "ol"].contains($0.t) }), !path.isEmpty {
                    closePre()
                    var common = 0
                    while common < stack.count && common < path.count && stack[common].tag == path[common].t
                        && (path[common].t == "ul" || path[common].n == stack[common].lastN || path[common].n == stack[common].lastN + 1) { common += 1 }
                    while stack.count > common { popList() }
                    while stack.count < path.count {
                        let level = path[stack.count]
                        if !stack.isEmpty, stack[stack.count - 1].items.isEmpty { stack[stack.count - 1].items.append(.element("li", [:], [])) }
                        stack.append((level.t, level.n >= 0 && level.n < 100_000 ? level.n : 1, [], nil, level.n))
                    }
                    let continuation = meta.it != nil && meta.it == stack.last?.lastItemID && meta.pid != lastPID
                    if continuation, stack.last?.items.isEmpty == false { appendToLastItem(.element("p", [:], children)) }
                    else {
                        stack[stack.count - 1].items.append(.element("li", [:], children))
                        stack[stack.count - 1].lastItemID = meta.it
                        stack[stack.count - 1].lastN = path.last?.n ?? stack[stack.count - 1].lastN
                    }
                } else {
                    closeLists()
                    if meta.b == "hr" || meta.b == "br" {
                        closePre()
                        appendNode(.element(meta.b, [:], []))
                        if !children.isEmpty { appendNode(.element("p", [:], children)) }
                    } else if meta.b == "pre" {
                        if let group = preGroup, group.id != nil, group.id == meta.g { preGroup?.lines.append(children) }
                        else {
                            closePre()
                            preGroup = (meta.g, meta.code ?? true, meta.lang, [children])
                            if meta.g == nil { closePre() }
                        }
                    } else { closePre(); appendNode(.element("p", [:], children)) }
                }
                lastPID = meta.pid
            } else {
                // Text without paragraph metadata was typed or pasted outside
                // any rendered block, so it ends an open quote instead of
                // being exported inside it.
                if quoteID != nil { closePre(); closeLists(); closeQuote() }
                let kind = value.attribute(.blockKind, at: paragraph.location, effectiveRange: nil) as? String ?? "p"
                let children = inlineNodes(content, kind: kind)
                if kind == "li" {
                    closePre()
                    let raw = value.attribute(.listType, at: paragraph.location, effectiveRange: nil) as? String ?? "ul"
                    let tag = ["ul", "ol"].contains(raw) ? raw : "ul"
                    let number = value.attribute(.listNumber, at: paragraph.location, effectiveRange: nil) as? Int ?? 1
                    while stack.count > 1 { popList() }
                    if let top = stack.first, top.tag != tag { popList() }
                    if stack.isEmpty { stack.append((tag, number >= 0 && number < 100_000 ? number : 1, [], nil, number)) }
                    stack[stack.count - 1].items.append(.element("li", [:], children))
                } else {
                    closeLists()
                    if kind == "pre" { closePre(); appendNode(.element("pre", [:], [.element("code", [:], children)])) }
                    else if kind == "blockquote" { closePre(); appendNode(.element("blockquote", [:], [.element("p", [:], children)])) }
                    else { closePre(); appendNode(.element("p", [:], children)) }
                }
                lastPID = -1
            }
            location = NSMaxRange(paragraph)
        }
        closePre(); closeLists(); closeQuote()
        return RichDocument(nodes: root)
    }
}
