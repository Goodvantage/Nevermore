import Foundation
import Markdown

public enum RavenMarkdownError: LocalizedError {
    case unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .unsupported(let detail): "This Markdown cannot be converted safely: \(detail). Your source text is unchanged."
        }
    }
}

/// CommonMark/GFM at the authoring boundary only. Raven still receives its
/// normal HTML. Every export is re-imported and compared before it is offered;
/// constructs Markdown cannot preserve travel as HTML, never as flattened text.
public enum RavenMarkdown {
    public static func document(from source: String) throws -> RichDocument {
        guard source.utf8.count <= RichTextCodec.maximumBytes else { throw RichTextError.tooLarge }
        let tree = Document(parsing: source, options: [.disableSmartOpts])
        var count = 0
        let html = try render(tree, depth: 0, count: &count)
        let document = try RichTextCodec.parse(html)
        guard document.canEdit else { throw RichTextError.unsafeEdit }
        return document
    }

    public static func source(from document: RichDocument) throws -> String {
        guard document.canEdit else { throw RichTextError.unsafeEdit }
        try validateBounds(document.nodes)
        let original = RichTextCodec.html(document)
        guard original.utf8.count <= RichTextCodec.maximumBytes,
              try RichTextCodec.parse(original).canEdit else { throw RichTextError.unsafeEdit }
        let expected = normalized(document.nodes)
        let candidate = document.nodes.map(block).joined(separator: "\n\n")
        if candidate.utf8.count <= RichTextCodec.maximumBytes,
           let roundTrip = try? Self.document(from: candidate), normalized(roundTrip.nodes) == expected { return candidate }
        // HTML block syntax preserves rich cells, adjacent emphasis and Raven
        // entities when ordinary Markdown would change their meaning.
        let preserved = document.nodes.map(island).joined(separator: "\n\n")
        guard preserved.utf8.count <= RichTextCodec.maximumBytes else { throw RichTextError.tooLarge }
        if let roundTrip = try? Self.document(from: preserved), normalized(roundTrip.nodes) == expected { return preserved }
        throw RavenMarkdownError.unsupported("the message's HTML structure has no lossless source representation")
    }

    private static func validateBounds(_ nodes: [RichNode]) throws {
        var pending = nodes.map { ($0, 0) }, count = 0, bytes = 0
        while let (node, depth) = pending.popLast() {
            count += 1
            guard count <= 20_000 else { throw RichTextError.tooLarge }
            guard depth <= 64 else { throw RichTextError.tooDeep }
            switch node {
            case .text(let text): bytes += text.utf8.count
            case .element(let tag, let attributes, let children):
                bytes += tag.utf8.count + attributes.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count }
                pending += children.map { ($0, depth + 1) }
            }
            guard bytes <= RichTextCodec.maximumBytes else { throw RichTextError.tooLarge }
        }
    }

    private static func render(_ node: any Markup, depth: Int, count: inout Int, header: Bool = false, alignments: [Table.ColumnAlignment?] = []) throws -> String {
        count += 1
        guard count <= 20_000 else { throw RichTextError.tooLarge }
        guard depth <= 64 else { throw RichTextError.tooDeep }
        func children() throws -> String {
            try node.children.map { try render($0, depth: depth + 1, count: &count, header: header, alignments: alignments) }.joined()
        }
        func wrap(_ tag: String) throws -> String { "<\(tag)>\(try children())</\(tag)>" }
        switch node {
        case is Document: return try children()
        case is Paragraph: return try wrap("p")
        case is BlockQuote: return try wrap("blockquote")
        case is UnorderedList: return try wrap("ul")
        case let list as OrderedList:
            let start = list.startIndex == 1 ? "" : " start=\"\(list.startIndex)\""
            return "<ol\(start)>\(try children())</ol>"
        case let item as ListItem:
            guard item.checkbox == nil else { throw RavenMarkdownError.unsupported("task lists are not enabled in Raven") }
            return try wrap("li")
        case is Strong: return try wrap("strong")
        case is Emphasis: return try wrap("em")
        case is Strikethrough: return try wrap("s")
        case let text as Markdown.Text: return RichTextCodec.escape(text.string)
        case is SoftBreak: return "\n"
        case is LineBreak: return "<br>"
        case is ThematicBreak: return "<hr>"
        case let code as InlineCode: return "<code>\(RichTextCodec.escape(code.code))</code>"
        case let code as CodeBlock:
            let language = code.language.flatMap { $0.isEmpty ? nil : " class=\"language-\(RichTextCodec.escape($0))\"" } ?? ""
            return "<pre><code\(language)>\(RichTextCodec.escape(code.code))</code></pre>"
        case let link as Markdown.Link:
            guard let destination = link.destination, RichTextCodec.safeURL(destination, allowRelative: true) else { throw RavenMarkdownError.unsupported("an unsafe or empty link") }
            let title = link.title.map { " title=\"\(RichTextCodec.escape($0))\"" } ?? ""
            return "<a href=\"\(RichTextCodec.escape(destination))\"\(title)>\(try children())</a>"
        case let html as HTMLBlock: return try rawHTML(html.rawHTML.trimmingCharacters(in: .newlines))
        case let html as InlineHTML: return try rawHTML(html.rawHTML)
        case let table as Table:
            let content = try table.children.map { try render($0, depth: depth + 1, count: &count, alignments: table.columnAlignments) }.joined()
            return "<table>\(content)</table>"
        case is Table.Head:
            let cells = try node.children.map { try render($0, depth: depth + 1, count: &count, header: true, alignments: alignments) }.joined()
            return "<thead><tr>\(cells)</tr></thead>"
        case is Table.Body: return try wrap("tbody")
        case is Table.Row: return try wrap("tr")
        case let cell as Table.Cell:
            if cell.colspan == 0 || cell.rowspan == 0 { return "" }
            guard cell.colspan <= 20, cell.rowspan <= 50 else { throw RichTextError.tooLarge }
            let tag = header ? "th" : "td"
            let spans = (cell.colspan > 1 ? " colspan=\"\(cell.colspan)\"" : "") + (cell.rowspan > 1 ? " rowspan=\"\(cell.rowspan)\"" : "")
            var alignment = ""
            if alignments.indices.contains(cell.indexInParent), let value = alignments[cell.indexInParent] {
                let name: String
                switch value { case .left: name = "left"; case .center: name = "center"; case .right: name = "right" }
                alignment = " style=\"text-align: \(name)\""
            }
            return "<\(tag)\(spans)\(alignment)>\(try children())</\(tag)>"
        default: throw RavenMarkdownError.unsupported(String(describing: type(of: node)))
        }
    }

    private static func rawHTML(_ html: String) throws -> String {
        guard !html.contains("<!--"), !html.hasPrefix("<!"), !html.hasPrefix("<?") else { throw RavenMarkdownError.unsupported("HTML comments and declarations") }
        return html
    }

    private static func island(_ node: RichNode) -> String {
        RichTextCodec.html(RichDocument(nodes: [node])).replacingOccurrences(of: "\r", with: "&#13;").replacingOccurrences(of: "\n", with: "&#10;")
    }

    private static func block(_ node: RichNode) -> String {
        guard case .element(let tag, let attrs, let children) = node else { return island(node) }
        switch tag {
        case "p" where attrs.isEmpty:
            let text = children.map(inline).joined()
            return text.isEmpty ? "<p></p>" : text
        case "hr" where attrs.isEmpty: return "---"
        case "blockquote" where attrs.isEmpty:
            return children.map(block).joined(separator: "\n\n").split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
        case "ul", "ol":
            guard attrs.isEmpty || (tag == "ol" && attrs.keys.allSatisfy({ $0 == "start" })), let start = Int(attrs["start"] ?? "1") else { return island(node) }
            var lines: [String] = []
            for (index, child) in children.enumerated() {
                guard case .element("li", let itemAttrs, var content) = child, itemAttrs.isEmpty else { return island(node) }
                if content.count == 1, case .element("p", let pAttrs, let pChildren) = content[0], pAttrs.isEmpty { content = pChildren }
                guard content.allSatisfy(isInline) else { return island(node) }
                lines.append((tag == "ul" ? "- " : "\(start + index). ") + content.map(inline).joined())
            }
            return lines.joined(separator: "\n")
        case "pre" where attrs.isEmpty:
            guard children.count == 1, case .element("code", let codeAttrs, let content) = children[0],
                  content.count == 1, case .text(let code) = content[0], code.hasSuffix("\n"),
                  codeAttrs.keys.allSatisfy({ $0 == "class" }) else { return island(node) }
            let language = codeAttrs["class"].map { String($0.dropFirst("language-".count)) } ?? ""
            guard !language.contains(where: { $0.isWhitespace || $0 == "`" }) else { return island(node) }
            let fence = String(repeating: "`", count: max(3, longestRun("`", in: code) + 1))
            return "\(fence)\(language)\n\(code)\(fence)"
        case "table" where attrs.isEmpty:
            guard let layout = RichTableLayout(node), layout.cells.allSatisfy({ $0.rowSpan == 1 && $0.columnSpan == 1 }) else { return island(node) }
            var lines: [String] = []
            for row in 0..<layout.rows {
                var cells: [String] = []
                for cell in layout.cells where cell.row == row {
                    guard case .element(let tag, let attributes, var content) = cell.node, tag == (row == 0 ? "th" : "td"), attributes.isEmpty else { return island(node) }
                    if content.count == 1, case .element("p", let attributes, let kids) = content[0], attributes.isEmpty { content = kids }
                    guard content.allSatisfy(isInline) else { return island(node) }
                    cells.append(content.map(inline).joined().replacingOccurrences(of: "|", with: "&#124;"))
                }
                lines.append("| " + cells.joined(separator: " | ") + " |")
                if row == 0 { lines.append("|" + String(repeating: " --- |", count: layout.columns)) }
            }
            return lines.joined(separator: "\n")
        default: return island(node)
        }
    }

    private static func isInline(_ node: RichNode) -> Bool {
        guard case .element(let tag, _, let children) = node else { return true }
        return ["strong", "em", "u", "s", "mark", "span", "code", "a", "img", "br"].contains(tag) && children.allSatisfy(isInline)
    }

    private static func inline(_ node: RichNode) -> String {
        switch node {
        case .text(let value):
            return value.map { character in
                if character == "\n" { return "&#10;" }
                if character == "\r" { return "&#13;" }
                if character == "\t" { return "&#9;" }
                if character == " " { return " " }
                let punctuation = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"
                return punctuation.contains(character) ? "\\\(character)" : String(character)
            }.joined()
        case .element(let tag, let attrs, let children):
            let inner = children.map(inline).joined()
            if attrs.isEmpty {
                if tag == "strong" { return "**\(inner)**" }
                if tag == "em" { return "*\(inner)*" }
                if tag == "s" { return "~~\(inner)~~" }
                if tag == "br" { return "<br>" }
                if tag == "code", children.count == 1, case .text(let text) = children[0], !text.isEmpty,
                   text.first?.isWhitespace == false, text.last?.isWhitespace == false, !text.contains("\n"), !text.contains("\r") {
                    let fence = String(repeating: "`", count: longestRun("`", in: text) + 1)
                    let pad = text.first == "`" || text.last == "`" ? " " : ""
                    return fence + pad + text + pad + fence
                }
            }
            if tag == "a", attrs.keys.allSatisfy({ ["href", "title"].contains($0) }), let href = attrs["href"], !href.contains("<"), !href.contains(">"), !href.contains("\\") {
                let title = attrs["title"].map { " \"\(RichTextCodec.escape($0))\"" } ?? ""
                return "[\(inner)](<\(RichTextCodec.escape(href))>\(title))"
            }
            return island(node)
        }
    }

    private static func longestRun(_ delimiter: Character, in text: String) -> Int {
        var longest = 0, current = 0
        for character in text { current = character == delimiter ? current + 1 : 0; longest = max(longest, current) }
        return longest
    }

    /// Ignore HTML grouping differences only where they have no rendering or
    /// identity meaning: empty row-group wrappers, single cell/list paragraphs,
    /// adjacent text nodes and inter-block indentation. All attributes remain.
    private static func normalized(_ nodes: [RichNode], parent: String = "") -> [RichNode] {
        var result: [RichNode] = []
        for node in nodes {
            if case .text(let text) = node {
                if ["", "table", "thead", "tbody", "tfoot", "tr"].contains(parent), text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                if case .text(let previous) = result.last { result[result.count - 1] = .text(previous + text) }
                else { result.append(node) }
                continue
            }
            guard case .element(let tag, let attributes, var children) = node else { continue }
            if ["li", "td", "th"].contains(tag), children.count == 1,
               case .element("p", let attributes, let content) = children[0], attributes.isEmpty { children = content }
            let content = normalized(children, parent: tag)
            if parent == "table", ["thead", "tbody", "tfoot"].contains(tag), attributes.isEmpty { result += content }
            else { result.append(.element(tag, attributes, content)) }
        }
        return result
    }
}
