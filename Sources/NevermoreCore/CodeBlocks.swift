import Foundation
import CryptoKit

public struct RichCodeBlock: Sendable, Equatable, Identifiable {
    public let index: Int
    public let text: String
    public let language: String?
    public var lineCount: Int { text.components(separatedBy: "\n").count }
    public var isLong: Bool { lineCount > 12 || text.utf16.count > 4000 }
    /// Bound to content and position. Edits cannot reuse a stale reader/link.
    public var id: String {
        SHA256.hash(data: Data("\(index)\u{0}\(language ?? "")\u{0}\(text)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public init(index: Int, text: String, language: String? = nil) { self.index = index; self.text = text; self.language = language }
}

public enum CodeBlocks {
    /// Spoiler subtrees never become a separate reader or a copy-code shortcut.
    public static func extract(from document: RichDocument) -> [RichCodeBlock] {
        var result: [RichCodeBlock] = []
        func visit(_ node: RichNode) {
            guard case .element(let tag, let attributes, let children) = node, attributes["data-spoiler"] == nil else { return }
            if tag == "pre" {
                var language: String?
                if children.count == 1, case .element("code", let metadata, _) = children[0], let value = metadata["class"], let token = value.split(whereSeparator: { $0.isWhitespace }).first(where: { $0.hasPrefix("language-") }) { language = String(token.dropFirst(9)) }
                // Unlike a preview, code must preserve its leading/trailing blank lines.
                func codeText(_ node: RichNode) -> String {
                    switch node {
                    case .text(let text): return text
                    case .element(let childTag, let attrs, let descendants):
                        if attrs["data-spoiler"] != nil { return "[Spoiler]" }
                        if childTag == "br" || childTag == "hr" { return "\n" }
                        if childTag == "img" { return attrs["alt"] ?? attrs["data-name"].map { ":\($0):" } ?? "[Image]" }
                        return descendants.map(codeText).joined()
                    }
                }
                result.append(RichCodeBlock(index: result.count, text: children.map(codeText).joined(), language: language)); return
            }
            children.forEach(visit)
        }
        document.nodes.forEach(visit)
        return result
    }
}
