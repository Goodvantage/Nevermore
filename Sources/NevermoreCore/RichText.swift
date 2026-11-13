import Foundation
import SwiftSoup

public indirect enum RichNode: Codable, Sendable, Equatable {
    case text(String)
    case element(String, [String: String], [RichNode])
    public var children: [RichNode] { if case .element(_, _, let nodes) = self { return nodes }; return [] }
}
public struct RichDocument: Codable, Sendable, Equatable {
    public var nodes: [RichNode]
    public var canEdit: Bool
    public var warnings: [String]
    public var rawHTML: String
    public init(nodes: [RichNode], canEdit: Bool = true, warnings: [String] = [], rawHTML: String = "") {
        self.nodes = nodes; self.canEdit = canEdit; self.warnings = warnings; self.rawHTML = rawHTML
    }
}
public enum RichTextError: LocalizedError {
    case tooLarge, tooDeep, unsafeEdit
    public var errorDescription: String? {
        switch self {
        case .tooLarge: return StatusLocalization.text(.richTooLarge)
        case .tooDeep: return StatusLocalization.text(.richTooDeep)
        case .unsafeEdit: return StatusLocalization.text(.richUnsafeEdit)
        }
    }
}
public enum RichTextCodec {
    public static let maximumBytes = 1_048_576
    private static let allowed: Set<String> = ["p","br","strong","em","u","s","code","pre","a","ul","ol","li","blockquote","hr","table","colgroup","col","thead","tbody","tfoot","tr","td","th","mark","span","img"]
    private static let dropped: Set<String> = ["script","style","iframe","object","embed","form","input","button","video","audio","svg","math","link","meta","base"]
    public static func parse(_ html: String) throws -> RichDocument {
        guard html.utf8.count <= maximumBytes else { throw RichTextError.tooLarge }
        let document = try SwiftSoup.parseBodyFragment(html)
        var warnings: [String] = []; var count = 0
        func visit(_ node: SwiftSoup.Node, depth: Int, parentTag: String) throws -> [RichNode] {
            guard depth <= 64 else { throw RichTextError.tooDeep }
            count += 1; guard count <= 20_000 else { throw RichTextError.tooLarge }
            if let text = node as? TextNode { return [.text(text.getWholeText())] }
            guard let element = node as? Element else { return [] }
            var tag = element.tagName().lowercased()
            tag = ["b":"strong", "i":"em", "strike":"s", "del":"s"][tag] ?? tag
            if dropped.contains(tag) { warnings.append("Unsafe embedded content was omitted."); return [] }
            let children = try element.getChildNodes().flatMap { try visit($0, depth: depth + 1, parentTag: tag) }
            guard allowed.contains(tag) else {
                warnings.append("Unsupported \(tag) formatting is read only.")
                var attrs = ["data-nevermore-unsupported": tag]
                // Raven masks a spoiler by the attribute's presence on any
                // element, so the mark must outlive a tag that is not shown.
                if element.hasAttr("data-spoiler") { attrs["data-spoiler"] = String(try element.attr("data-spoiler").prefix(4096)) }
                return [.element("span", attrs, children)]
            }
            var attrs: [String: String] = [:]
            for key in ["data-type","data-id","data-name","data-label","data-spoiler","alt","title"] {
                let value = try element.attr(key)
                if !value.isEmpty || (key == "data-spoiler" && element.hasAttr(key)) { attrs[key] = String(value.prefix(4096)) }
            }
            if let type = attrs["data-type"], !["userMention", "channelMention", "customEmoji"].contains(type) { warnings.append("Unsupported rich-text semantics are read only.") }
            if attrs["data-spoiler"] != nil {
                func hasUnsupportedSpoilerContent(_ node: RichNode) -> Bool {
                    guard case .element(let childTag, let metadata, let descendants) = node else { return false }
                    guard metadata["data-spoiler"] == nil else { return true }
                    if childTag == "img" { return metadata["data-type"] != "customEmoji" || !descendants.isEmpty }
                    guard ["span", "strong", "em", "u", "s", "mark", "a", "code", "br"].contains(childTag) else { return true }
                    if let type = metadata["data-type"], childTag != "span" || !["userMention", "channelMention"].contains(type) { return true }
                    return descendants.contains(where: hasUnsupportedSpoilerContent)
                }
                if !["span", "strong", "em", "u", "s", "mark", "a", "code"].contains(tag) || children.contains(where: hasUnsupportedSpoilerContent) {
                    warnings.append("Complex spoilers are read only to preserve nested formatting and identities.")
                }
            }
            if ["ul", "ol"].contains(tag), !["", "li", "blockquote", "td", "th"].contains(parentTag) { warnings.append("Complex list markup is read only.") }
            if tag == "li" && !["ul", "ol"].contains(parentTag) { warnings.append("Complex list markup is read only.") }
            if tag == "blockquote" && parentTag == "blockquote" { warnings.append("Nested quotes are read only.") }
            if ["ul", "ol"].contains(tag), element.children().contains(where: { $0.tagName().lowercased() != "li" }) { warnings.append("Complex list markup is read only.") }
            if ["ul", "ol"].contains(tag), element.getChildNodes().contains(where: { ($0 as? TextNode)?.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) { warnings.append("Complex list markup is read only.") }
            if tag == "li", element.children().contains(where: { ["pre", "blockquote", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "li", "hr"].contains($0.tagName().lowercased()) }) { warnings.append("List items with complex blocks are read only.") }
            if tag == "pre" {
                let elements = element.children()
                if elements.count > 1 || elements.contains(where: { $0.tagName().lowercased() != "code" || !$0.children().isEmpty }) { warnings.append("Complex code block markup is read only.") }
                if children.contains(where: { if case .element("code", let attrs, _) = $0 { return attrs.keys.contains { $0 != "class" } }; return false }) { warnings.append("Code blocks with semantic wrapper attributes are read only.") }
            }
            if tag == "a" {
                let href = try element.attr("href")
                if safeURL(href, allowRelative: true) { attrs["href"] = href }
                else if !href.isEmpty { warnings.append("An unsafe link was removed.") }
            }
            if tag == "img" {
                let src = try element.attr("src")
                if safeURL(src, allowRelative: true), !src.lowercased().hasPrefix("mailto:") { attrs["src"] = src }
                else if !src.isEmpty { warnings.append("An unsafe image source was omitted; editing is read only.") }
                if attrs["data-type"] != "customEmoji" { warnings.append("Inline media uses a safe native fallback.") }
            }
            if tag == "td" || tag == "th" {
                for key in ["colspan", "rowspan"] where element.hasAttr(key) {
                    if let n = Int(try element.attr(key)), n > 0, n <= 100 { attrs[key] = String(n) }
                    else { warnings.append("Invalid table spans are read only.") }
                }
                if element.hasAttr("colwidth") {
                    let width = try element.attr("colwidth")
                    if RichTableStyle.validCellWidths(width, span: Int(attrs["colspan"] ?? "1") ?? 1) { attrs["colwidth"] = width }
                    else { warnings.append("Invalid table column widths are read only.") }
                }
                if element.hasAttr("align") {
                    let alignment = try element.attr("align")
                    if RichTableAlignment(rawValue: alignment) != nil { attrs["align"] = alignment }
                    else { warnings.append("Unsupported table alignment is read only.") }
                }
            }
            if tag == "ol", element.hasAttr("start") {
                if let start = Int(try element.attr("start")), start >= 0, start < 100_000 { attrs["start"] = String(start) }
                else { warnings.append("Unsupported list numbering is read only.") }
            }
            let classes = try element.attr("class")
            if !classes.isEmpty {
                let tokens = classes.split(whereSeparator: { $0.isWhitespace })
                let languages = tokens.filter { $0.hasPrefix("language-") }
                let validLanguage = languages.count == 1 && languages[0].count < 100 && languages[0].count > 9 && languages[0].allSatisfy { $0.isLetter || $0.isNumber || "-_+#.".contains($0) }
                if tag == "code", parentTag == "pre", validLanguage, tokens.allSatisfy({ $0 == "hljs" || $0 == languages[0] }) { attrs["class"] = classes }
                else { warnings.append("Custom class formatting is read only.") }
            }
            // Preserve only the bounded sizing and alignment emitted by Raven's
            // table editor. Other CSS remains protected from lossy editing.
            let style = try element.attr("style")
            if !style.isEmpty {
                if RichTableStyle.declaration(style, tag: tag) != nil { attrs["style"] = style }
                else { warnings.append("Custom styling is read only.") }
            }
            if (tag == "colgroup" && parentTag != "table") || (tag == "col" && parentTag != "colgroup") {
                warnings.append("Malformed table columns are read only.")
            }
            if tag == "table", parentTag != "" || RichTableLayout(.element(tag, attrs, children)) == nil {
                warnings.append("Nested, malformed or oversized tables are read only to preserve their layout.")
            }
            return [.element(tag, attrs, children)]
        }
        let nodes = try document.body()?.getChildNodes().flatMap { try visit($0, depth: 0, parentTag: "") } ?? []
        return RichDocument(nodes: nodes, canEdit: warnings.isEmpty, warnings: Array(Set(warnings)).sorted(), rawHTML: html)
    }
    public static func html(_ document: RichDocument) -> String {
        func output(_ node: RichNode) -> String {
            switch node {
            case .text(let value): return escape(value)
            case .element(let tag, let attrs, let children):
                guard allowed.contains(tag) else { return children.map(output).joined() }
                let permitted: Set<String> = ["data-type","data-id","data-name","data-label","data-spoiler","alt","title","href","src","colspan","rowspan","colwidth","align","style","start","class"]
                let attributes = attrs.keys.sorted().filter { key in
                    guard permitted.contains(key) else { return false }
                    if key == "href" { return tag == "a" && safeURL(attrs[key]!, allowRelative: true) }
                    if key == "src" { return tag == "img" && safeURL(attrs[key]!, allowRelative: true) && !attrs[key]!.lowercased().hasPrefix("mailto:") }
                    if key == "class" { return tag == "code" }
                    if key == "style" { return RichTableStyle.declaration(attrs[key]!, tag: tag) != nil }
                    if key == "align" { return ["td", "th"].contains(tag) && RichTableAlignment(rawValue: attrs[key]!) != nil }
                    if key == "colwidth" { return ["td", "th"].contains(tag) && RichTableStyle.validCellWidths(attrs[key]!, span: Int(attrs["colspan"] ?? "1") ?? 1) }
                    if key == "colspan" || key == "rowspan" { guard tag == "td" || tag == "th", let number = Int(attrs[key]!), (1...100).contains(number) else { return false }; return true }
                    if key == "start" { guard tag == "ol", let number = Int(attrs[key]!), number >= 0, number < 100_000 else { return false }; return true }
                    return true
                }.map { " \($0)=\"\(escape(attrs[$0]!))\"" }.joined()
                if ["br","hr","img","col"].contains(tag) { return "<\(tag)\(attributes)>" }
                return "<\(tag)\(attributes)>\(children.map(output).joined())</\(tag)>"
            }
        }
        return document.nodes.map(output).joined()
    }
    public static func plainText(_ document: RichDocument, revealSpoilers: Bool = false) -> String {
        func text(_ node: RichNode) -> String {
            switch node {
            case .text(let value): return value
            case .element(let tag, let attrs, let children):
                if attrs["data-spoiler"] != nil && !revealSpoilers { return "[Spoiler]" }
                if tag == "img" { return attrs["alt"] ?? attrs["data-name"].map { ":\($0):" } ?? "[Image]" }
                if tag == "br" || tag == "hr" { return "\n" }
                let body = children.map(text).joined()
                return body + (["p","pre","li","blockquote","tr"].contains(tag) ? "\n" : tag == "td" || tag == "th" ? "\t" : "")
            }
        }
        return document.nodes.map(text).joined().trimmingCharacters(in: .newlines)
    }
    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
    public static func safeURL(_ text: String, allowRelative: Bool = false) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 8192, !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), !text.contains("\\") else { return false }
        if allowRelative && text.hasPrefix("/") && !text.hasPrefix("//") { return true }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["https","http","mailto"].contains(scheme), url.user == nil, url.password == nil else { return false }
        return scheme == "mailto" || url.host != nil
    }
}
