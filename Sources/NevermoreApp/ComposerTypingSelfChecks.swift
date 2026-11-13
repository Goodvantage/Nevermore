import AppKit
import NevermoreCore

/// Drives a real `ComposerView` through the same entry points the keyboard
/// uses (`insertText`, `insertNewlineIgnoringFieldEditor`, `deleteBackward`,
/// `moveDown`) and compares both what the user sees and the HTML that would
/// be sent.
@MainActor enum ComposerTypingSelfChecks {
    static func run() async throws -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        let composer = ComposerView(frame: NSRect(x: 0, y: 0, width: 480, height: 200))
        composer.isRichText = true
        composer.allowsUndo = true
        composer.font = .systemFont(ofSize: NativeRichText.composerFontSize)
        composer.textColor = .labelColor
        composer.alwaysInsertNewline = true
        composer.sharedUndoManager = UndoManager()

        let defaults = UserDefaults.standard
        let savedPreference = defaults.object(forKey: ComposerPreferences.markdownShortcutsKey)
        defaults.removeObject(forKey: ComposerPreferences.markdownShortcutsKey)
        defer {
            if let savedPreference { defaults.set(savedPreference, forKey: ComposerPreferences.markdownShortcutsKey) }
            else { defaults.removeObject(forKey: ComposerPreferences.markdownShortcutsKey) }
        }

        func type(_ text: String) {
            for character in text {
                if character == "\n" { composer.insertNewlineIgnoringFieldEditor(nil) }
                else { composer.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
            }
        }
        /// Ends the current key event the way AppKit does for a real one:
        /// its undo group closes, the shortcut it completed is formatted in
        /// a group of its own, and that group closes too. Synthetic input
        /// does not pass through NSApplication, so events are posted until
        /// nothing is left open.
        func settle() async throws {
            composer.breakUndoCoalescing()
            for _ in 0..<200 {
                if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                    NSApp.postEvent(event, atStart: false)
                }
                try await Task.sleep(for: .milliseconds(5))
                if composer.pendingShortcut == nil, (composer.undoManager?.groupingLevel ?? 0) == 0 { return }
            }
            throw AppError.message("The composer did not settle after a synthetic key.")
        }
        /// One key per event, as the keyboard delivers them, so undo groups
        /// form the way they do for a person typing.
        func press(_ text: String) async throws {
            for character in text {
                type(String(character))
                try await settle()
            }
        }
        func html() -> String {
            composer.flushPendingShortcut()
            return (try? RichTextCodec.html(NativeRichText.document(from: composer.attributedString()))) ?? "<unsendable>"
        }
        func load(_ source: String) throws {
            let text = source.isEmpty ? NSAttributedString() : NativeRichText.attributedString(document: try RichTextCodec.parse(source), revealSpoilers: true)
            composer.textStorage?.setAttributedString(text)
            composer.setSelectedRange(NSRange(location: composer.string.utf16.count, length: 0))
            if source.isEmpty { composer.typingAttributes = NativeRichText.plainTypingAttributes }
            composer.undoManager?.removeAllActions()
        }
        /// A person can only move the caret after the last key's event has
        /// ended, which is when a completed shortcut is formatted.
        func caret(_ location: Int) {
            composer.flushPendingShortcut()
            composer.setSelectedRange(NSRange(location: location, length: 0))
        }
        func expect(_ label: String, shows text: String, sends markup: String) {
            composer.flushPendingShortcut()
            let passed = composer.string == text && html() == markup
            if !passed { print("DIAGNOSTIC \(label): shows=\(composer.string.debugDescription) sends=\(html())") }
            results.append((label, passed))
        }

        // Block shortcuts.
        try load("")
        type("> hello")
        expect("typing \"> \" starts a block quote", shows: "│ hello", sends: "<blockquote><p>hello</p></blockquote>")

        try load("")
        try await press("> ")
        composer.undoManager?.undo()
        expect("Undo after a block shortcut restores the typed characters", shows: "> ", sends: "<p>&gt; </p>")
        try await settle()
        type("x")
        expect("typing after that Undo does not convert again", shows: "> x", sends: "<p>&gt; x</p>")

        try load("")
        type("- one\ntwo")
        expect("typing \"- \" starts a bulleted list and a line break adds an item", shows: "• one\n• two", sends: "<ul><li>one</li><li>two</li></ul>")

        try load("")
        type("* star")
        expect("typing \"* \" starts a bulleted list", shows: "• star", sends: "<ul><li>star</li></ul>")

        try load("")
        type("1. one\ntwo\n\nafter")
        expect("a numbered list counts on and an empty item ends it", shows: "1. one\n2. two\nafter", sends: "<ol><li>one</li><li>two</li></ol><p>after</p>")

        try load("")
        type("3. three")
        expect("a numbered list starts at the typed number", shows: "3. three", sends: "<ol start=\"3\"><li>three</li></ol>")

        try load("<p>existing</p>")
        caret(0)
        type("> ")
        expect("a marker typed in front of a line converts that line", shows: "│ existing", sends: "<blockquote><p>existing</p></blockquote>")

        // Quotes: continuing, leaving and joining.
        try load("")
        type("> one\ntwo")
        expect("a line break inside a quote continues it with its own bar", shows: "│ one\n│ two", sends: "<blockquote><p>one</p><p>two</p></blockquote>")

        try load("")
        type("> one\n\nafter")
        expect("an empty quoted line ends the quote", shows: "│ one\nafter", sends: "<blockquote><p>one</p></blockquote><p>after</p>")

        try load("")
        type("> one\n\n")
        caret(0)
        caret(composer.string.utf16.count)
        type("later")
        expect("text typed after leaving a quote stays outside it when the caret returns", shows: "│ one\nlater", sends: "<blockquote><p>one</p></blockquote><p>later</p>")

        try load("")
        type("> one\n\n> two")
        expect("a quote typed right under a quote joins it", shows: "│ one\n│ two", sends: "<blockquote><p>one</p><p>two</p></blockquote>")

        try load("<blockquote><p>onetwo</p></blockquote>")
        caret(5)
        type("\n")
        expect("a line break in the middle of a quoted line splits it", shows: "│ one\n│ two", sends: "<blockquote><p>one</p><p>two</p></blockquote>")

        // Lists: splitting and renumbering.
        try load("<ol><li>onetwo</li><li>three</li></ol>")
        caret(6)
        type("\n")
        expect("splitting a numbered item renumbers the items after it", shows: "1. one\n2. two\n3. three", sends: "<ol><li>one</li><li>two</li><li>three</li></ol>")

        try load("<ol><li>one</li></ol>")
        caret(composer.string.utf16.count)
        composer.insertNewlineIgnoringFieldEditor(nil)
        composer.insertNewlineIgnoringFieldEditor(nil)
        type("1. again")
        expect("a list typed under a list shows the number that is sent", shows: "1. one\n2. again", sends: "<ol><li>one</li><li>again</li></ol>")

        // Backspace.
        try load("<blockquote><p>one</p></blockquote>")
        caret(2)
        composer.deleteBackward(nil)
        expect("Backspace at the start of a quoted line removes the quote", shows: "one", sends: "<p>one</p>")

        try load("<ul><li>one</li><li>two</li><li>three</li></ul>")
        caret(8)
        composer.deleteBackward(nil)
        expect("Backspace at the start of a list item takes it out of the list", shows: "• one\ntwo\n• three", sends: "<ul><li>one</li></ul><p>two</p><ul><li>three</li></ul>")

        try load("<blockquote><p>one</p></blockquote>")
        caret(0)
        type("x")
        expect("typing with the caret inside a marker lands after it", shows: "│ xone", sends: "<blockquote><p>xone</p></blockquote>")

        // Inline shortcuts.
        let inline: [(String, String, String, String)] = [
            ("**bold** x", "bold x", "<p><strong>bold</strong> x</p>", "two asterisks make bold text"),
            ("__bold__ x", "bold x", "<p><strong>bold</strong> x</p>", "two underscores make bold text"),
            ("*soft* x", "soft x", "<p><em>soft</em> x</p>", "one asterisk makes italic text"),
            ("_soft_ x", "soft x", "<p><em>soft</em> x</p>", "one underscore makes italic text"),
            ("`code` x", "code x", "<p><code>code</code> x</p>", "backticks make inline code"),
            ("~~gone~~ x", "gone x", "<p><s>gone</s> x</p>", "two tildes strike text through"),
            ("||hush|| x", "hush x", "<p><span data-spoiler=\"true\">hush</span> x</p>", "two pipes make a spoiler"),
            ("snake_case_name and 2 * 3 * 4", "snake_case_name and 2 * 3 * 4", "<p>snake_case_name and 2 * 3 * 4</p>", "identifiers and arithmetic stay literal"),
        ]
        for (typed, shown, sent, label) in inline {
            try load("")
            type(typed)
            expect(label, shows: shown, sends: sent)
        }

        try load("")
        try await press("**bold**")
        composer.undoManager?.undo()
        expect("Undo after an inline shortcut restores the delimiters", shows: "**bold**", sends: "<p>**bold**</p>")

        let redoneInline: [(String, String, String, String)] = [
            ("**bold**", "bold", "<strong>bold</strong>", "bold"),
            ("*soft*", "soft", "<em>soft</em>", "italic"),
            ("`code`", "code", "<code>code</code>", "code"),
            ("~~gone~~", "gone", "<s>gone</s>", "strike-through"),
            ("||hush||", "hush", "<span data-spoiler=\"true\">hush</span>", "spoiler"),
        ]
        for (typed, shown, markup, label) in redoneInline {
            try load("")
            try await press(typed)
            composer.undoManager?.undo()
            try await settle()
            composer.undoManager?.redo()
            try await settle()
            type(" x")
            expect("typing after Redo of the \(label) shortcut stays outside its formatting", shows: shown + " x", sends: "<p>\(markup) x</p>")
        }

        try load("")
        type("> **loud**")
        expect("inline shortcuts work inside a quote", shows: "│ loud", sends: "<blockquote><p><strong>loud</strong></p></blockquote>")

        // Code blocks.
        try load("")
        type("```")
        type("let a = **b**\n> c")
        expect("three backticks start a code block where Markdown stays literal", shows: "let a = **b**\n> c", sends: "<pre><code>let a = **b**\n&gt; c</code></pre>")
        type("\n\n\nafter")
        expect("a third line break at the end of a code block leaves it", shows: "let a = **b**\n> c\nafter", sends: "<pre><code>let a = **b**\n&gt; c</code></pre><p>after</p>")

        try load("<pre><code>code</code></pre>")
        caret(composer.string.utf16.count)
        composer.moveDown(nil)
        type("after")
        expect("Down Arrow at the end of a final code block adds a line below it", shows: "code\nafter", sends: "<pre><code>code</code></pre><p>after</p>")

        // Things that must stay untouched.
        try load("")
        type("one\n\n> two")
        expect("a shortcut keeps blank lines elsewhere in the draft", shows: "one\n\n│ two", sends: "<p>one</p><p></p><blockquote><p>two</p></blockquote>")

        try load("")
        composer.setMarkedText("> ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedText = composer.string
        composer.unmarkText()
        results.append(("text still being composed by an input method is not converted", markedText == "> " && composer.string == "> "))

        // With the caret at the start of a quoted line, Backspace and a line
        // break would both rewrite the line. Not while text is being composed.
        try load("<blockquote><p>one</p></blockquote>")
        caret(2)
        composer.setMarkedText("に", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let heldBack = composer.hasMarkedText() && !composer.deleteStructuredBackward() && !composer.insertStructuredLineBreak() && composer.string == "│ にone"
        composer.unmarkText()
        results.append(("the structure rules wait while an input method is composing", heldBack))

        try load("")
        defaults.set(false, forKey: ComposerPreferences.markdownShortcutsKey)
        type("> **plain**")
        expect("turning Markdown shortcuts off keeps typed characters literal", shows: "> **plain**", sends: "<p>&gt; **plain**</p>")
        defaults.removeObject(forKey: ComposerPreferences.markdownShortcutsKey)

        // The Format menu's Block Quote on one of two typed lines.
        try load("")
        type("one\ntwo")
        caret(0)
        composer.blockquote(nil)
        expect("a line under a quoted line is sent outside the quote, as shown", shows: "│ one\ntwo", sends: "<blockquote><p>one</p></blockquote><p>two</p>")

        // Joining lines. The restored draft carries paragraph metadata on
        // every line, as after a relaunch.
        try load("<blockquote><p>one</p></blockquote><p>a much longer plain line</p>")
        caret(6)
        composer.deleteBackward(nil)
        expect("Backspace at the start of a line joins it to the quoted line above", shows: "│ onea much longer plain line", sends: "<blockquote><p>onea much longer plain line</p></blockquote>")

        try load("<ul><li>one</li><li>two and more text</li><li>three</li></ul>")
        caret(5)
        composer.deleteForward(nil)
        expect("Forward Delete at the end of a list item joins the next item without its marker", shows: "• onetwo and more text\n• three", sends: "<ul><li>onetwo and more text</li><li>three</li></ul>")

        try load("<blockquote><p>one two</p></blockquote>")
        caret(2)
        composer.deleteWordBackward(nil)
        expect("Option-Backspace at the start of a quoted line removes the quote, not the marker", shows: "one two", sends: "<p>one two</p>")

        try load("<blockquote><p>one two</p></blockquote>")
        caret(6)
        composer.deleteToBeginningOfLine(nil)
        expect("Command-Backspace in a quoted line keeps its marker", shows: "│ two", sends: "<blockquote><p>two</p></blockquote>")

        // Format ▸ Bulleted List on the line under a list.
        try load("<p>intro</p><ul><li>only</li></ul><p>new</p>")
        caret(composer.string.utf16.count)
        composer.bulletedList(nil)
        expect("a line made a list item under a list is sent as its own item, as shown", shows: "intro\n• only\n• new", sends: "<p>intro</p><ul><li>only</li><li>new</li></ul>")

        // Markers under the caret.
        try load("<blockquote><p>one</p></blockquote>")
        caret(0)
        type("\n")
        expect("a line break with the caret in front of a quote's marker adds a quoted line above", shows: "│ \n│ one", sends: "<blockquote><p></p><p>one</p></blockquote>")

        try load("<ol><li>one</li></ol>")
        caret(1)
        type("\n")
        expect("a line break with the caret inside a list marker adds an item above", shows: "1. \n2. one", sends: "<ol><li></li><li>one</li></ol>")

        try load("<ul><li>one</li></ul>")
        caret(1)
        composer.deleteForward(nil)
        expect("Forward Delete inside a marker removes the list, not half the marker", shows: "one", sends: "<p>one</p>")

        try load("<blockquote><p>\(String(repeating: "wrapping words ", count: 20))end</p></blockquote>")
        caret(composer.string.utf16.count)
        composer.deleteToBeginningOfParagraph(nil)
        expect("deleting to the start of a wrapped quoted paragraph keeps its marker", shows: "│ ", sends: "<blockquote><p></p></blockquote>")

        // Markers inside a selection.
        try load("<blockquote><p>one</p></blockquote>")
        composer.selectAll(nil)
        type("x")
        expect("typing over a selected quote keeps the quote that is shown", shows: "│ x", sends: "<blockquote><p>x</p></blockquote>")

        try load("<blockquote><p>one</p></blockquote>")
        composer.selectAll(nil)
        composer.deleteBackward(nil)
        expect("deleting everything leaves the quote's first line, as lists do in Notes", shows: "│ ", sends: "<blockquote><p></p></blockquote>")
        composer.deleteBackward(nil)
        results.append(("one more Backspace removes that quote", composer.string.isEmpty && !html().contains("blockquote")))

        try load("<ul><li>one</li><li>two</li></ul>")
        composer.setSelectedRange(NSRange(location: 4, length: 5))
        composer.deleteBackward(nil)
        expect("a selection across two list items joins them without a stray marker", shows: "• onwo", sends: "<ul><li>onwo</li></ul>")

        try load("<p>abc</p><blockquote><p>two</p></blockquote>")
        composer.setSelectedRange(NSRange(location: 0, length: 4))
        type("X")
        expect("typing over a whole line above a quote lands inside the quote", shows: "│ Xtwo", sends: "<blockquote><p>Xtwo</p></blockquote>")

        try load("<p>abc</p><blockquote><p>two</p></blockquote>")
        composer.setSelectedRange(NSRange(location: 0, length: 4))
        composer.delete(nil)
        expect("deleting a whole line above a quote leaves the quote as it is", shows: "│ two", sends: "<blockquote><p>two</p></blockquote>")

        try load("<blockquote><p>ab</p></blockquote><ul><li>a much longer item</li></ul>")
        composer.setSelectedRange(NSRange(location: 3, length: 5))
        composer.deleteForward(nil)
        expect("text left over from a list item joins the quote it is pulled into", shows: "│ a much longer item", sends: "<blockquote><p>a much longer item</p></blockquote>")

        try load("<blockquote><p>one</p><p>two</p></blockquote>")
        composer.setSelectedRange(NSRange(location: 3, length: 6))
        type("\n")
        expect("a line break typed over a selection across quoted lines keeps one bar per line", shows: "│ o\n│ wo", sends: "<blockquote><p>o</p><p>wo</p></blockquote>")

        // Web addresses become links.
        let address = "https://example.com"
        func anchor(_ href: String, _ text: String? = nil) -> String { "<a href=\"\(href)\">\(text ?? href)</a>" }

        try load("")
        try await press("see \(address)/a ")
        expect("a space after a web address makes it a link", shows: "see \(address)/a ", sends: "<p>see \(anchor(address + "/a")) </p>")
        composer.undoManager?.undo()
        expect("Undo after that removes the link and keeps what was typed", shows: "see \(address)/a ", sends: "<p>see \(address)/a </p>")
        try await settle()
        type("x ")
        expect("typing on after that Undo does not link the address again", shows: "see \(address)/a x ", sends: "<p>see \(address)/a x </p>")

        try load("")
        type("(see \(address)/a_(b)). ")
        expect("punctuation around a web address stays outside the link", shows: "(see \(address)/a_(b)). ", sends: "<p>(see \(anchor(address + "/a_(b)"))). </p>")

        try load("")
        type("\(address)\nnext")
        expect("a line break after a web address links it", shows: "\(address)\nnext", sends: "<p>\(anchor(address))</p><p>next</p>")

        try load("")
        type("> \(address) done")
        expect("a web address inside a quote is linked there", shows: "│ \(address) done", sends: "<blockquote><p>\(anchor(address)) done</p></blockquote>")

        try load("")
        type("\(address) ")
        caret(address.utf16.count)
        type("/docs")
        expect("typing at the end of a linked address extends the link", shows: "\(address)/docs ", sends: "<p>\(anchor(address + "/docs")) </p>")

        // One key per event, so Undo takes back one key.
        try load("")
        try await press("\(address) ")
        caret(address.utf16.count)
        try await press("/docs")
        composer.undoManager?.undo()
        expect("Undo of a key typed into a link shortens the link with its text", shows: "\(address)/doc ", sends: "<p>\(anchor(address + "/doc")) </p>")
        composer.undoManager?.redo()
        expect("Redo extends the link again", shows: "\(address)/docs ", sends: "<p>\(anchor(address + "/docs")) </p>")

        // A run of typing is one Undo step; the link must follow it back.
        try load("")
        try await press("see \(address) ")
        composer.deleteBackward(nil)
        try await settle()
        type("/x")
        try await settle()
        composer.undoManager?.undo()
        expect("Undo of typing appended to a link restores the link's address", shows: "see \(address)", sends: "<p>see \(anchor(address))</p>")
        composer.undoManager?.redo()
        expect("Redo of that typing extends the link again", shows: "see \(address)/x", sends: "<p>see \(anchor(address + "/x"))</p>")

        try load("")
        try await press("\(address) ")
        caret("https://exam".utf16.count)
        composer.deleteBackward(nil)
        composer.deleteBackward(nil)
        try await settle()
        expect("deleting inside a linked address changes the link with it", shows: "https://exple.com ", sends: "<p>\(anchor("https://exple.com")) </p>")
        composer.undoManager?.undo()
        expect("Undo of that deletion restores one link to the whole address", shows: "\(address) ", sends: "<p>\(anchor(address)) </p>")

        try load("")
        type("\(address) ")
        caret(address.utf16.count)
        type(".")
        expect("a full stop typed after a link stays outside it", shows: "\(address). ", sends: "<p>\(anchor(address)). </p>")
        type("x")
        expect("text typed after that full stop is not linked", shows: "\(address).x ", sends: "<p>\(anchor(address + ".x")) </p>")

        try load("")
        type("\(address) ")
        caret(address.utf16.count)
        for _ in 0..<"example.com".count { composer.deleteBackward(nil) }
        expect("an address deleted down to its scheme is no link any more", shows: "https:// ", sends: "<p>https:// </p>")

        try load("")
        type("\(address) ")
        caret("https://ex".utf16.count)
        composer.insertNewlineIgnoringFieldEditor(nil)
        expect("a line break inside a linked address leaves no stale link", shows: "https://ex\nample.com ", sends: "<p>\(anchor("https://ex"))</p><p>ample.com </p>")

        try load("<p>\(anchor(address))</p>")
        type("/x")
        expect("a restored link that shows its own address follows edits to it", shows: "\(address)/x", sends: "<p>\(anchor(address + "/x"))</p>")

        try load("<p>\(anchor(address, "the docs"))</p>")
        caret(3)
        type("se")
        expect("a link behind a label keeps its address when the label changes", shows: "these docs", sends: "<p>\(anchor(address, "these docs"))</p>")

        try load("")
        type("`\(address)` and ```")
        expect("an address inside inline code is not linked", shows: "\(address) and ```", sends: "<p><code>\(address)</code> and ```</p>")

        try load("")
        type("```")
        type("\(address) x")
        composer.linkAllAddresses()
        expect("an address inside a code block is not linked", shows: "\(address) x", sends: "<pre><code>\(address) x</code></pre>")

        try load("")
        type("go to \(address)/path?q=1")
        let unlinked = html()
        composer.linkAllAddresses()
        expect("an address at the very end is linked when the message is sent", shows: "go to \(address)/path?q=1", sends: "<p>go to \(anchor(address + "/path?q=1"))</p>")
        results.append(("until then the last address is plain text", unlinked == "<p>go to \(address)/path?q=1</p>"))

        try load("<p>read the docs today</p>")
        composer.setSelectedRange(NSRange(location: 5, length: 8))
        let pastedOver = composer.pasteAsLink(" \(address)/docs\n")
        expect("a web address pasted over selected words links them", shows: "read the docs today", sends: "<p>read \(anchor(address + "/docs", "the docs")) today</p>")
        composer.setSelectedRange(NSRange(location: 0, length: 4))
        results.append(("pasting other text over a selection is an ordinary paste", pastedOver && !composer.pasteAsLink("not an address") && !composer.pasteAsLink(nil)))

        try load("<p>read the docs today</p>")
        composer.setSelectedRange(NSRange(location: 4, length: 10))
        _ = composer.pasteAsLink("\(address)/docs")
        expect("spaces at the ends of the selection stay outside the pasted link", shows: "read the docs today", sends: "<p>read \(anchor(address + "/docs", "the docs")) today</p>")

        // Format ▸ Insert Link on an address the composer linked itself.
        try load("")
        type("\(address) and more")
        composer.setLink(URL(string: "https://other.example/page")!, on: NSRange(location: 0, length: address.utf16.count))
        type("!")
        expect("a link target chosen with Insert Link is kept for an address that was linked automatically", shows: "\(address) and more!", sends: "<p>\(anchor("https://other.example/page", address)) and more!</p>")

        try load("<p>before after</p>")
        caret(7)
        composer.pasteLinkingAddresses { composer.insertText("https://a.example/one and https://b.example/two ", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        expect("web addresses in pasted text become links", shows: "before https://a.example/one and https://b.example/two after", sends: "<p>before \(anchor("https://a.example/one")) and \(anchor("https://b.example/two")) after</p>")

        try load("")
        defaults.set(false, forKey: ComposerPreferences.markdownShortcutsKey)
        type("> \(address) x")
        expect("addresses are linked with Markdown shortcuts turned off", shows: "> \(address) x", sends: "<p>&gt; \(anchor(address)) x</p>")
        defaults.removeObject(forKey: ComposerPreferences.markdownShortcutsKey)

        try load("<p>\(anchor("http://plain.example", "a")) \(anchor("https://one.example/x", "b")) \(anchor("https://one.example/x", "c")) \(anchor("https://192.168.1.1/", "d")) \(anchor("https://two.example", "e"))</p>")
        results.append(("only public https links are offered for a preview, each once", NativeRichText.previewableLinks(in: composer.attributedString()).map(\.absoluteString) == ["https://one.example/x", "https://two.example"]))

        // Whether a draft says anything is read from the message, not from
        // what the composer shows.
        func saysSomething(_ html: String) throws -> Bool { try ConversationWindow.hasText(Draft(channelID: "fixture", html: html)) }
        // Returning from an edit can attach an already-correct shared draft,
        // so restoreDraft need not rewrite its text or reset its selection.
        try load("<p><strong>edited message</strong></p>")
        composer.setSelectedRange(NSRange(location: composer.string.utf16.count, length: 0))
        composer.typingAttributes = composer.attributedString().attributes(at: 0, effectiveRange: nil)
        composer.useTextStorage(NSTextStorage())
        let emptySelection = composer.selectedRange()
        if emptySelection == NSRange(location: 0, length: 0) { type("new") }
        expect("returning from an edit to an empty draft accepts plain typing", shows: "new", sends: "<p>new</p>")

        try load("<p>edited message</p>")
        composer.setSelectedRange(NSRange(location: 3, length: 11))
        let sharedDraft = NativeRichText.attributedString(document: try RichTextCodec.parse("<p>draft</p>"))
        composer.useTextStorage(NSTextStorage(attributedString: sharedDraft))
        let restoredSelection = composer.selectedRange()
        if restoredSelection == NSRange(location: 3, length: 0) { type("!") }
        expect("switching to a shorter shared draft does not carry an edited selection", shows: "dra!ft", sends: "<p>dra!ft</p>")

        let emptyDrafts = ["", "<blockquote><p></p></blockquote>", "<ul><li></li></ul>"]
        results.append(("a draft of only a quote or list marker is not a message", try emptyDrafts.allSatisfy { try !saysSomething($0) }))
        // Both real text and whitespace can exceed the grammar's node cap.
        // Neither may silently pass the guard or look like an empty draft.
        for (name, paragraph) in [("text", "<p>line</p>"), ("whitespace", "<p> </p>")] {
            let manyLines = String(repeating: paragraph, count: 10_001)
            var reported = false
            do { _ = try saysSomething(manyLines) }
            catch { reported = true }
            results.append(("an oversized \(name) draft reports an error before sending", reported))
        }

        return results
    }

    /// Answers link previews without the network. The picture is a small
    /// PNG made here, so the thumbnail path runs too.
    private struct FixtureLinkPreviews: LinkPreviewLoading {
        static let picture = URL(string: "https://fixture.example/picture.png")!
        let pictureData: Data?

        func preview(for url: URL) async -> LinkPreview? {
            guard url.host == "fixture.example" else { return nil }
            return LinkPreview(url: url, title: "Fixture \(url.lastPathComponent)", summary: "Fixture summary.", siteName: "Fixture Site", imageURL: url.lastPathComponent == "pictured" ? Self.picture : nil)
        }

        func imageData(for url: URL) async -> Data? { url == Self.picture ? pictureData : nil }
    }

    /// The preview card in a real window: it follows the draft's first
    /// link and respects the preference.
    static func runLinkPreview(window controller: ConversationWindow) async throws -> [(String, Bool)] {
        let composer = controller.composer
        let saved = NSAttributedString(attributedString: composer.attributedString())
        let defaults = UserDefaults.standard
        let savedPreference = defaults.object(forKey: ComposerPreferences.linkPreviewsKey)
        defaults.removeObject(forKey: ComposerPreferences.linkPreviewsKey)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        controller.linkPreviewLoaderOverride = FixtureLinkPreviews(pictureData: bitmap?.representation(using: .png, properties: [:]))
        defer {
            controller.linkPreviewLoaderOverride = nil
            if let savedPreference { defaults.set(savedPreference, forKey: ComposerPreferences.linkPreviewsKey) }
            else { defaults.removeObject(forKey: ComposerPreferences.linkPreviewsKey) }
            composer.textStorage?.setAttributedString(saved)
            composer.undoManager?.removeAllActions()
            controller.textDidChange(Notification(name: NSText.didChangeNotification, object: composer))
        }

        func clear() {
            composer.textStorage?.setAttributedString(NSAttributedString())
            composer.typingAttributes = NativeRichText.plainTypingAttributes
            composer.undoManager?.removeAllActions()
            controller.textDidChange(Notification(name: NSText.didChangeNotification, object: composer))
        }
        func type(_ text: String) {
            composer.setSelectedRange(NSRange(location: composer.string.utf16.count, length: 0))
            for character in text { composer.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0)) }
        }
        func until(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
            return condition()
        }
        var shownTitle: String? { controller.linkPreviewRow.isHidden ? nil : controller.linkPreview.content?.preview.title }
        var results: [(String, Bool)] = []

        clear()
        type("look at https://fixture.example/first ")
        let appeared = try await until { shownTitle == "Fixture first" }
        results.append(("a link in the draft gets a preview card above the text", appeared && controller.linkPreviewCard.accessibilityLabel() == "Link preview: Fixture first, Fixture Site · fixture.example"))
        type("and https://fixture.example/second ")
        try await Task.sleep(for: .milliseconds(700))
        results.append(("the card stays with the first link when another is added", shownTitle == "Fixture first"))

        clear()
        type("https://fixture.example/pictured ")
        let pictured = try await until { controller.linkPreview.content?.image != nil }
        results.append(("the page's picture is shown as a thumbnail", pictured && shownTitle == "Fixture pictured"))
        composer.setSelectedRange(NSRange(location: 0, length: composer.string.utf16.count))
        composer.deleteBackward(nil)
        results.append(("the card goes away with its link", shownTitle == nil))

        type("https://unknown.example/page ")
        try await Task.sleep(for: .milliseconds(700))
        results.append(("a page without a preview shows no card", shownTitle == nil))

        clear()
        defaults.set(false, forKey: ComposerPreferences.linkPreviewsKey)
        type("https://fixture.example/first ")
        let linked = try await until { (try? RichTextCodec.html(NativeRichText.document(from: composer.attributedString()))) == "<p><a href=\"https://fixture.example/first\">https://fixture.example/first</a> </p>" }
        try await Task.sleep(for: .milliseconds(700))
        results.append(("with previews turned off the address is still linked, without a card", shownTitle == nil && linked))
        defaults.removeObject(forKey: ComposerPreferences.linkPreviewsKey)
        controller.updateLinkPreview()
        results.append(("turning previews back on brings the card back", try await until { shownTitle == "Fixture first" }))

        // The card fills room that is there and must not decide how wide
        // the conversation is. At the window's smallest width the
        // conversation still ends at the window's edge, and the card
        // narrows with it; a hidden card has no say either.
        if let window = controller.window, let sidebar = controller.sidebarSplitItem?.viewController.view {
            let home = window.frame
            func resize(width: CGFloat) {
                var frame = home
                frame.size.width = width
                window.setFrame(frame, display: true); window.contentView?.layoutSubtreeIfNeeded()
            }
            var conversationFits: Bool { sidebar.frame.width + controller.transcriptScroll.frame.width <= window.frame.width + 1 }
            resize(width: 1080)
            let roomy = controller.linkPreviewCard.frame.width
            let shortTitle = LinkPreview(url: URL(string: "https://fixture.example/first")!, title: "T", summary: "The preview description should use the available width, rather than the title's intrinsic width.", siteName: "Fixture Site", imageURL: nil)
            for pictured in [false, true] {
                let image = pictured ? NSImage(size: NSSize(width: 8, height: 8)) : nil
                var noDescription = shortTitle
                noDescription.summary = ""
                controller.linkPreviewCard.show(ComposerLinkPreview.Content(preview: noDescription, image: image))
                window.contentView?.layoutSubtreeIfNeeded()
                controller.linkPreviewCard.show(ComposerLinkPreview.Content(preview: shortTitle, image: image))
                window.contentView?.layoutSubtreeIfNeeded()
                let description = InteractionSelfChecks.descendants(controller.linkPreviewCard, of: NSTextField.self).first { $0.stringValue == shortTitle.summary }
                let descriptionEdge = description.map { $0.convert($0.bounds, to: controller.linkPreviewCard).maxX } ?? 0
                let closeEdge = controller.linkPreviewCard.bounds.maxX
                let gap = closeEdge - descriptionEdge
                let fillsColumn = description != nil && gap >= 0 && gap <= 12 && (description?.frame.width ?? 0) > 200
                if !fillsColumn { print("DIAGNOSTIC preview column: picture=\(pictured) card=\(controller.linkPreviewCard.frame) description=\(String(describing: description?.frame)) gap=\(gap)") }
                results.append(("a short preview title leaves the description a full column \(pictured ? "with" : "without") a picture", fillsColumn))
            }
            let wordy = LinkPreview(url: URL(string: "https://fixture.example/first")!, title: String(repeating: "A long title ", count: 40), summary: String(repeating: "A long description ", count: 60), siteName: "Fixture Site", imageURL: nil)
            controller.linkPreviewCard.show(ComposerLinkPreview.Content(preview: wordy, image: nil)); window.contentView?.layoutSubtreeIfNeeded()
            results.append(("long text is cut off and leaves the card its width", controller.linkPreviewCard.frame.width == ComposerMetrics.linkPreviewWidth))
            controller.showLinkPreview(); window.contentView?.layoutSubtreeIfNeeded()
            resize(width: window.minSize.width)
            let card = controller.linkPreviewCard.frame
            let narrowed = card.width < roomy && card.maxX <= controller.linkPreviewRow.bounds.maxX - 11
            results.append(("the card narrows with the conversation in a narrow window", roomy == ComposerMetrics.linkPreviewWidth && narrowed && conversationFits))
            resize(width: 1080)
            clear()
            resize(width: window.minSize.width)
            results.append(("a hidden card does not hold the conversation wider than its window", shownTitle == nil && conversationFits))
            window.setFrame(home, display: true); window.contentView?.layoutSubtreeIfNeeded()
        }

        let named = LinkPreview(url: URL(string: "https://www.example.com/a")!, title: "T", summary: "", siteName: "Example", imageURL: nil)
        var bare = named
        bare.siteName = "example.com"
        results.append(("the card names the site and always shows the address's host", LinkPreviewCard.siteLine(for: named) == "Example · example.com" && LinkPreviewCard.siteLine(for: bare) == "example.com"))
        return results
    }

    /// Real key events through NSApplication's event loop, where AppKit
    /// closes each key's undo group by itself: the first Undo after a
    /// shortcut must restore exactly the typed characters, and the second
    /// must remove them.
    static func runKeyEvents(window controller: ConversationWindow) async throws -> [(String, Bool)] {
        guard let window = controller.window else { return [("composer key-event fixture has a window", false)] }
        let composer = controller.composer
        let saved = NSAttributedString(attributedString: composer.attributedString())
        // These checks are about events and Undo, whatever the person
        // running them chose in Settings.
        let defaults = UserDefaults.standard
        let savedPreference = defaults.object(forKey: ComposerPreferences.markdownShortcutsKey)
        defaults.removeObject(forKey: ComposerPreferences.markdownShortcutsKey)
        defer {
            if let savedPreference { defaults.set(savedPreference, forKey: ComposerPreferences.markdownShortcutsKey) }
            composer.textStorage?.setAttributedString(saved)
            composer.undoManager?.removeAllActions()
            controller.textDidChange(Notification(name: NSText.didChangeNotification, object: composer))
        }
        composer.textStorage?.setAttributedString(NSAttributedString())
        composer.typingAttributes = NativeRichText.plainTypingAttributes
        composer.undoManager?.removeAllActions()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(composer)
        for _ in 0..<100 where !window.isKeyWindow { try await Task.sleep(for: .milliseconds(10)) }

        func post(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) async throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(60))
        }
        func html() -> String { (try? RichTextCodec.html(NativeRichText.document(from: composer.attributedString()))) ?? "<unsendable>" }

        try await post(">", code: 47, modifiers: .shift)
        try await post(" ", code: 49)
        try await post("h", code: 4)
        try await post("i", code: 34)
        let typed = composer.string == "│ hi" && html() == "<blockquote><p>hi</p></blockquote>"
        if !typed { print("DIAGNOSTIC key events typed: key=\(window.isKeyWindow) shows=\(composer.string.debugDescription) sends=\(html())") }
        try await post("z", code: 6, modifiers: .command)
        let afterTyping = composer.string
        try await post("z", code: 6, modifiers: .command)
        let afterFormat = composer.string
        try await post("z", code: 6, modifiers: .command)
        let afterAll = composer.string
        let undone = afterTyping == "│ " && afterFormat == "> " && afterAll.isEmpty
        if !undone { print("DIAGNOSTIC key events undo: \(afterTyping.debugDescription) \(afterFormat.debugDescription) \(afterAll.debugDescription)") }
        // An empty quote is all marker; it must not count as a message.
        try await post(">", code: 47, modifiers: .shift)
        try await post(" ", code: 49)
        let emptyQuote = composer.string
        controller.send(nil)
        let refused = emptyQuote == "│ " && !controller.isAcceptingSend && composer.string == "│ "
        if !refused { print("DIAGNOSTIC empty quote send: shows=\(emptyQuote.debugDescription) accepting=\(controller.isAcceptingSend)") }
        // Send right after the key that completed a shortcut, before its
        // deferred formatting ran: the draft must be read as it will show.
        composer.textStorage?.setAttributedString(NSAttributedString())
        composer.typingAttributes = NativeRichText.plainTypingAttributes
        composer.insertText(">", replacementRange: NSRange(location: NSNotFound, length: 0))
        composer.insertText(" ", replacementRange: NSRange(location: NSNotFound, length: 0))
        controller.send(nil)
        let flushed = composer.string == "│ " && !controller.isAcceptingSend
        if !flushed { print("DIAGNOSTIC send after shortcut: shows=\(composer.string.debugDescription) accepting=\(controller.isAcceptingSend)") }

        // Saving an edit disables typing while the server answers, then
        // reattaches the shared draft before enabling the composer again.
        let sharedStorage = composer.textStorage!
        sharedStorage.setAttributedString(NSAttributedString())
        composer.setSelectedRange(NSRange(location: 0, length: 0))
        composer.useTextStorage(NSTextStorage(string: "edited message"))
        composer.setSelectedRange(NSRange(location: 14, length: 0))
        window.makeFirstResponder(composer)
        controller.isAcceptingSend = true
        controller.updateComposerAvailability()
        try await Task.sleep(for: .milliseconds(80))
        composer.useTextStorage(sharedStorage)
        controller.isAcceptingSend = false
        controller.updateComposerAvailability()
        try await post("x", code: 7)
        let resumesTyping = composer.string == "x"
        if !resumesTyping { print("DIAGNOSTIC after edit: editable=\(composer.isEditable) focused=\(window.firstResponder === composer) responder=\(String(describing: window.firstResponder?.className)) selection=\(composer.selectedRange()) shows=\(composer.string.debugDescription)") }
        return [
            ("a shortcut typed on the keyboard formats the line", typed),
            ("sending right after a shortcut key sends what the composer then shows", flushed),
            ("Undo steps back through the text, then the formatting, then the typed marker", undone),
            ("a quote or list with no text is not sent as a message", refused),
            ("typing resumes after saving an edit restores the shared draft", resumesTyping),
        ]
    }
}
