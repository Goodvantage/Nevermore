import AppKit
import NevermoreCore

@MainActor enum MarkdownSourceFormatting {
    static func apply(command: ComposerFormattingBar.Command, to text: NSTextView) throws {
        guard text.isEditable, !text.hasMarkedText() else { return }
        let range = text.selectedRange(), raw = text.string as NSString
        guard NSMaxRange(range) <= raw.length else { return }
        let selected = raw.substring(with: range)
        let inline: [ComposerFormattingBar.Command] = [.bold, .italic, .underline, .strike, .highlight, .spoiler, .link]
        if inline.contains(command), selected.contains(where: \.isNewline) {
            // Raw inline HTML spanning Markdown paragraphs can protect only
            // the first paragraph, notably leaking the rest of a spoiler.
            throw AppError.message("Select text within one line for inline formatting. Use Visual mode for larger selections.")
        }
        var content = selected, prefix = "", suffix = ""
        switch command {
        case .bold: prefix = "**"; suffix = "**"
        case .italic: prefix = "*"; suffix = "*"
        case .underline: prefix = "<u>"; suffix = "</u>"
        case .strike: prefix = "~~"; suffix = "~~"
        case .highlight: prefix = "<mark>"; suffix = "</mark>"
        case .spoiler: prefix = "<span data-spoiler=\"true\">"; suffix = "</span>"
        case .inlineCode:
            if selected.contains("\n") || selected.contains("\r") {
                prefix = "<code>"; suffix = "</code>"
                content = RichTextCodec.escape(selected).replacingOccurrences(of: "\r", with: "&#13;").replacingOccurrences(of: "\n", with: "&#10;")
            } else {
                let fence = String(repeating: "`", count: (selected.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0) + 1)
                let pad = selected.first == "`" || selected.last == "`" || (selected.first == " " && selected.last == " " && selected.contains(where: { $0 != " " })) ? " " : ""
                prefix = fence + pad; suffix = pad + fence
            }
        case .codeBlock:
            let fence = String(repeating: "~", count: max(3, (selected.split(whereSeparator: { $0 != "~" }).map(\.count).max() ?? 0) + 1))
            prefix = "\n\n\(fence)\n"; suffix = "\n\(fence)\n\n"
        case .bullets: prefix = "\n\n- "
        case .numbers: prefix = "\n\n1. "
        case .quote: prefix = "\n\n> "
        case .rule: prefix = "\n\n---\n\n"
        case .link: prefix = "["; suffix = "](https://example.com)"
        case .clearFormatting: return
        case .table: prefix = "\n\n| Header | Header |\n| --- | --- |\n| Cell | Cell |\n\n"
        }
        text.breakUndoCoalescing(); text.insertText(prefix + content + suffix, replacementRange: range)
        text.undoManager?.setActionName(command.title)
        text.setSelectedRange(NSRange(location: range.location + prefix.utf16.count, length: content.utf16.count))
    }
}
