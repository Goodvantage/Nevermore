import Foundation

/// Markdown-style typing shortcuts for the composer.
///
/// Every matcher runs right after the user typed one character, with `caret`
/// at the insertion point after it. All ranges are UTF-16 offsets into the
/// inspected text, matching `NSTextView`'s coordinates.
public enum MarkdownShortcut {
    /// A block-level shortcut: the typed marker becomes block formatting.
    public enum Block: Sendable, Equatable {
        case quote
        case bulletedList
        case numberedList(start: Int)
        case codeBlock
    }

    /// A completed block shortcut: the block to apply and the typed marker
    /// (including its trailing space) to delete.
    public struct BlockMatch: Sendable, Equatable {
        public var block: Block
        /// The typed marker to delete, including its trailing space.
        public var markerRange: NSRange
    }

    /// An inline style wrapping the text between two delimiters.
    public enum Inline: String, Sendable, Equatable, CaseIterable {
        case bold, italic, code, strikethrough, spoiler
    }

    /// A completed inline shortcut: the style plus the delimiter and content
    /// ranges, all inside the caret's paragraph.
    public struct InlineMatch: Sendable, Equatable {
        public var style: Inline
        public var openRange: NSRange
        public var contentRange: NSRange
        public var closeRange: NSRange
    }

    private static let maxListDigits = 5
    private static let asciiDigits: ClosedRange<Character> = "0"..."9"
    /// What may sit directly before an inline opening delimiter.
    private static let openerBoundaries: Set<String> = ["(", "[", "{", "\"", "'", "\u{201C}", "\u{2018}"]

    /// The characters `NSString.paragraphRange` ends a paragraph at: line
    /// feed, carriage return and the paragraph separator. A line separator
    /// (U+2028) or form feed stays inside its paragraph.
    private static let paragraphTerminators: Set<unichar> = [0x0A, 0x0D, 0x2029]

    /// The caret's paragraph without its line terminator.
    private static func paragraphContentRange(for caret: Int, in text: NSString) -> NSRange {
        let paragraph = text.paragraphRange(for: NSRange(location: caret, length: 0))
        var end = paragraph.location + paragraph.length
        while end > paragraph.location, paragraphTerminators.contains(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: paragraph.location, length: end - paragraph.location)
    }

    /// Matches a block marker typed at the start of the caret's paragraph.
    public static func block(in text: String, caret: Int) -> BlockMatch? {
        let value = text as NSString
        guard caret > 0, caret <= value.length else { return nil }
        let paragraph = paragraphContentRange(for: caret, in: value)
        let prefix = value.substring(with: NSRange(location: paragraph.location, length: caret - paragraph.location)) as String
        if prefix == "> " {
            return BlockMatch(block: .quote, markerRange: NSRange(location: paragraph.location, length: 2))
        }
        if prefix == "- " || prefix == "* " || prefix == "+ " {
            return BlockMatch(block: .bulletedList, markerRange: NSRange(location: paragraph.location, length: 2))
        }
        if prefix == "```", caret == paragraph.location + paragraph.length {
            return BlockMatch(block: .codeBlock, markerRange: NSRange(location: paragraph.location, length: 3))
        }
        return numberedListMatch(paragraph: paragraph, prefix: prefix)
    }

    /// "1. ", "007) ": one to five ASCII digits, "." or ")", one plain space.
    private static func numberedListMatch(paragraph: NSRange, prefix: String) -> BlockMatch? {
        let digits = prefix.dropLast(2)
        guard digits.count >= 1, digits.count <= maxListDigits else { return nil }
        guard prefix.hasSuffix(" ") else { return nil }
        let punctuation = prefix[prefix.index(prefix.endIndex, offsetBy: -2)]
        guard punctuation == "." || punctuation == ")" else { return nil }
        guard digits.allSatisfy({ asciiDigits.contains($0) }) else { return nil }
        guard let start = Int(digits) else { return nil }
        return BlockMatch(block: .numberedList(start: start), markerRange: NSRange(location: paragraph.location, length: prefix.utf16.count))
    }

    /// Matches an inline delimiter pair completed right before the caret.
    public static func inline(in text: String, caret: Int) -> InlineMatch? {
        let value = text as NSString
        guard caret > 0, caret <= value.length else { return nil }
        let paragraph = paragraphContentRange(for: caret, in: value)
        // Two-character closers first, then the one-character ones.
        if caret - 2 >= paragraph.location {
            let pair = value.substring(with: NSRange(location: caret - 2, length: 2))
            if let match = matchInline(closer: pair, style: style(forTwoCharacterCloser: pair), closeRange: NSRange(location: caret - 2, length: 2), paragraph: paragraph, in: value) {
                return match
            }
        }
        let single = value.substring(with: NSRange(location: caret - 1, length: 1))
        return matchInline(closer: single, style: style(forOneCharacterCloser: single), closeRange: NSRange(location: caret - 1, length: 1), paragraph: paragraph, in: value)
    }

    private static func style(forTwoCharacterCloser closer: String) -> Inline? {
        switch closer {
        case "**", "__": return .bold
        case "~~": return .strikethrough
        case "||": return .spoiler
        default: return nil
        }
    }

    private static func style(forOneCharacterCloser closer: String) -> Inline? {
        switch closer {
        case "*", "_": return .italic
        case "`": return .code
        default: return nil
        }
    }

    /// Finds the nearest opening delimiter before the closer and validates
    /// the completed `<open><content><close>`.
    private static func matchInline(closer: String, style: Inline?, closeRange: NSRange, paragraph: NSRange, in text: NSString) -> InlineMatch? {
        guard let style else { return nil }
        let searchRange = NSRange(location: paragraph.location, length: closeRange.location - paragraph.location)
        let openRange = text.range(of: closer, options: .backwards, range: searchRange)
        guard openRange.location != NSNotFound else { return nil }
        let contentRange = NSRange(location: openRange.location + openRange.length, length: closeRange.location - openRange.location - openRange.length)
        guard contentRange.length > 0 else { return nil }
        let content = text.substring(with: contentRange)
        let delimiterCharacter = closer.first!
        guard !content.contains(delimiterCharacter) else { return nil }
        // A style never spans lines, including the soft line breaks that
        // do not end a paragraph.
        guard content.rangeOfCharacter(from: .newlines) == nil else { return nil }
        if style == .code {
            // Code spans may start or end with whitespace, but not be only whitespace.
            guard !content.allSatisfy({ $0.isWhitespace }) else { return nil }
        } else {
            guard let first = content.first, let last = content.last, !first.isWhitespace, !last.isWhitespace else { return nil }
        }
        guard openRange.location == paragraph.location || hasOpenerBoundary(openRange.location, style: style, delimiterCharacter: delimiterCharacter, text: text) else { return nil }
        return InlineMatch(style: style, openRange: openRange, contentRange: contentRange, closeRange: closeRange)
    }

    /// Rule 4 (with its `.code` exception) and rule 5, for an opener that is
    /// not at the paragraph start.
    private static func hasOpenerBoundary(_ location: Int, style: Inline, delimiterCharacter: Character, text: NSString) -> Bool {
        let before = text.substring(with: NSRange(location: location - 1, length: 1))
        if style == .code {
            return before != "`"
        }
        if before == String(delimiterCharacter) { return false }
        return before.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || openerBoundaries.contains(before)
    }
}
