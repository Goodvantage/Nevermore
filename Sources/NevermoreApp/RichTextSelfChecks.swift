import AppKit
import NevermoreCore
import RavenProtocol

@MainActor enum RichTextSelfChecks {
    static func run() throws -> [(String, Bool)] {
        var results: [(String, Bool)] = []
        func check(_ label: String, _ body: () throws -> Bool) {
            do { results.append((label, try body())) }
            catch { results.append(("\(label) [\(error.localizedDescription)]", false)) }
        }
        func location(of needle: String, in text: NSMutableAttributedString) throws -> Int {
            guard let range = text.string.range(of: needle) else { throw RichTextError.unsafeEdit }
            return NSRange(range, in: text.string).location
        }
        check("reading preserves visible editor formatting without retaining edit metadata") {
            let corpus = [
                "<p><strong>Bold</strong> <em>italic</em> <u>underlined</u> <s>struck</s> <mark>marked</mark> <a href=\"https://example.invalid\">link</a></p>",
                "<blockquote><p>Quote</p><ul><li>One<ul><li>Nested</li></ul></li></ul></blockquote>",
                "<p>Before</p><pre><code>let value = 1\nprint(value)</code></pre><hr><p>After<br>line</p>",
                "<p><img data-type=\"customEmoji\" src=\"/files/fixture.png\" alt=\":fixture:\"> 👩🏽‍💻</p>"
            ]
            for html in corpus {
                let document = try RichTextCodec.parse(html)
                let expected = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: document))
                let full = NSRange(location: 0, length: expected.length)
                var keys = Set<NSAttributedString.Key>()
                expected.enumerateAttributes(in: full) { attributes, _, _ in
                    keys.formUnion(attributes.keys.filter { $0.rawValue.hasPrefix("Nevermore.") })
                }
                for key in keys { expected.removeAttribute(key, range: full) }
                let reading = NativeRichText.readingString(document: document)
                guard reading.isEqual(to: expected) else { return false }
                var privateMetadata = false
                reading.enumerateAttributes(in: NSRange(location: 0, length: reading.length)) { attributes, _, _ in
                    if attributes.keys.contains(where: { $0.rawValue.hasPrefix("Nevermore.") }) { privateMetadata = true }
                }
                if privateMetadata { return false }
            }
            return true
        }
        check("unedited nested list round-trips exactly") {
            let doc = try RichTextCodec.parse("<ul><li>One<ul><li>Alpha</li><li>Beta</li></ul></li><li>Two</li></ul>")
            let round = try NativeRichText.document(from: NativeRichText.attributedString(document: doc))
            return RichTextCodec.html(round) == RichTextCodec.html(doc)
        }
        check("nested lists keep depth and order after text edits") {
            let doc = try RichTextCodec.parse("<ul><li>One<ul><li>Alpha</li><li>Beta</li></ul></li><li>Two</li></ul>")
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            text.insert(NSAttributedString(string: "X"), at: try location(of: "Beta", in: text) + 1)
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html.contains("<ul><li>Alpha</li><li>BXeta</li></ul>") && html.contains("<li>Two</li>") && html.contains("<li>One")
        }
        check("nested ordered lists keep their start after edits") {
            let doc = try RichTextCodec.parse("<ul><li>head<ol start=\"4\"><li>x</li><li>y</li></ol></li><li>tail</li></ul>")
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            text.insert(NSAttributedString(string: "!"), at: try location(of: "y", in: text) + 1)
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html.contains("<ol start=\"4\"><li>x</li><li>y!</li></ol>") && html.contains("<li>tail</li>")
        }
        check("multiline code stays one block with its language after edits") {
            let doc = try RichTextCodec.parse("<pre><code class=\"language-swift\">first\nsecond\nthird</code></pre>")
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            text.insert(NSAttributedString(string: "!"), at: try location(of: "second", in: text))
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html.components(separatedBy: "<pre").count == 2 && html.contains("first\n!second\nthird") && html.contains("language-swift")
        }
        check("Return inside a list item starts a sibling without eating text") {
            let doc = try RichTextCodec.parse("<ul><li>alphabeta</li></ul>")
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            text.insert(NSAttributedString(string: "\n"), at: try location(of: "beta", in: text))
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html.contains("<ul><li>alpha</li><li>beta</li></ul>")
        }
        check("Return inside a nested item preserves its depth") {
            let doc = try RichTextCodec.parse("<ul><li>outer<ul><li>deep</li></ul></li></ul>")
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            text.insert(NSAttributedString(string: "\n"), at: try location(of: "eep", in: text))
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html.contains("<ul><li>d</li><li>eep</li></ul>") && !html.contains("<ol")
        }
        check("typed ordered markers stay literal after the bullet") {
            let doc = try RichTextCodec.parse("<ol><li>item</li></ol>")
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            text.insert(NSAttributedString(string: "9. ", attributes: text.attributes(at: 2, effectiveRange: nil)), at: 3)
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html.contains("<li>9. item</li>") && !html.contains("start=")
        }
        check("typed markers before the bullet are never stripped") {
            let doc = try RichTextCodec.parse("<ol><li>item</li></ol>")
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            text.insert(NSAttributedString(string: "9. ", attributes: text.attributes(at: 0, effectiveRange: nil)), at: 0)
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html.contains("<li>9. 1. item</li>")
        }
        check("plain-text marker look-alikes stay literal paragraphs") {
            let doc = try RichTextCodec.parse("<p>plain</p>")
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            text.append(NSAttributedString(string: "\n• pasted", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]))
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html.contains("• pasted") && !html.contains("<li")
        }
        check("a copied list line reimports as a list item") {
            let doc = try RichTextCodec.parse("<ul><li>item</li></ul>")
            let rendered = NativeRichText.attributedString(document: doc)
            let text = NSMutableAttributedString(attributedString: rendered)
            text.insert(NSAttributedString(string: "\n"), at: text.length)
            text.append(rendered.attributedSubstring(from: NSRange(location: 0, length: rendered.length)))
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html == "<ul><li>item</li><li>item</li></ul>"
        }
        check("mentions emoji and spoilers survive inside nested items") {
            let doc = try RichTextCodec.parse(#"<ul><li><span data-type="userMention" data-id="u@example.com">@U</span><ul><li><img data-type="customEmoji" data-id="parrot" data-name="parrot" src="/f/parrot.png" alt=":parrot:"><span data-spoiler="true">secret</span></li></ul></li></ul>"#)
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc, revealSpoilers: true))
            text.insert(NSAttributedString(string: "!"), at: 0)
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html.contains("u@example.com") && html.contains("customEmoji") && html.contains("parrot") && html.contains("data-spoiler")
        }
        check("formatting changes cannot resurrect stale structure") {
            let doc = try RichTextCodec.parse("<ul><li>One<ul><li>deep</li></ul></li></ul>")
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: try location(of: "deep", in: text), length: 4))
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html.contains("<strong>deep</strong>") && html.contains("<ul><li>") && !html.contains("<p>")
        }
        check("multiline list items keep their lines in one item") {
            let doc = try RichTextCodec.parse("<ul><li><p>first</p><p>second</p></li><li>other</li></ul>")
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            text.insert(NSAttributedString(string: "!"), at: try location(of: "second", in: text))
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html.contains("<li>first<p>!second</p></li>") && html.contains("<li>other</li>")
        }
        check("a blockquote stays one block after edits") {
            let doc = try RichTextCodec.parse("<blockquote><p>one</p><p>two</p></blockquote>")
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            text.insert(NSAttributedString(string: "!"), at: try location(of: "two", in: text))
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html == "<blockquote><p>one</p><p>!two</p></blockquote>"
        }
        check("lists and code blocks nest inside blockquotes") {
            let doc = try RichTextCodec.parse("<blockquote><ul><li>q</li></ul><pre><code>x\ny</code></pre></blockquote>")
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            text.insert(NSAttributedString(string: "!"), at: try location(of: "y", in: text) + 1)
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html.components(separatedBy: "<blockquote").count == 2 && html.contains("<ul><li>q</li></ul>") && html.contains("x\ny!") && html.components(separatedBy: "<pre").count == 2
        }
        check("table metadata rejects direct partial cell edits") {
            let doc = try RichTextCodec.parse("<p>a</p><table><tr><td>cell</td></tr></table>")
            guard doc.canEdit else { return false }
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: doc))
            guard try NativeRichText.document(from: text).nodes == doc.nodes else { return false }
            text.insert(NSAttributedString(string: "x"), at: try location(of: "cell", in: text) + 1)
            do { _ = try NativeRichText.document(from: text); return false } catch { return true }
        }
        check("complex list blocks stay read only") {
            let doc = try RichTextCodec.parse("<ul><li><pre>x</pre></li></ul>")
            guard !doc.canEdit else { return false }
            do { _ = try NativeRichText.document(from: NativeRichText.attributedString(document: doc)); return false } catch { return true }
        }
        check("authored spoilers retain formatting and hide text from reading and copying") {
            let source = try RichTextCodec.parse("<p>visible <strong>secret</strong> end</p>")
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: source, revealSpoilers: true))
            let range = (text.string as NSString).range(of: "secret")
            text.replaceCharacters(in: range, with: NativeRichText.settingSpoiler(text.attributedSubstring(from: range), enabled: true))
            let document = try NativeRichText.document(from: text)
            let html = RichTextCodec.html(document)
            let reading = NativeRichText.readingString(document: document)
            return document.canEdit && html.contains("data-spoiler") && html.contains("<strong>secret</strong>") && !reading.string.contains("secret") && !RichTextCodec.plainText(document).contains("secret") && reading.string.contains("[Spoiler]")
        }
        check("spoiler formatting keeps emoji and mention identities atomic") {
            let source = try RichTextCodec.parse(#"<p><img data-type="customEmoji" src="/files/party.png" alt=":party:"> <span data-type="userMention" data-id="fixture-user">Fixture</span></p>"#)
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: source, revealSpoilers: true))
            let entity = try NativeRichText.spoilerSelection(in: text, range: NSRange(location: 2, length: 1)).range
            text.replaceCharacters(in: entity, with: NativeRichText.settingSpoiler(text.attributedSubstring(from: entity), enabled: true))
            let mention = try NativeRichText.spoilerSelection(in: text, range: (text.string as NSString).range(of: "ixt")).range
            text.replaceCharacters(in: mention, with: NativeRichText.settingSpoiler(text.attributedSubstring(from: mention), enabled: true))
            let document = try NativeRichText.document(from: text)
            let html = RichTextCodec.html(document)
            let reloaded = try RichTextCodec.parse(html)
            let restored = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: reloaded, revealSpoilers: true))
            restored.append(NSAttributedString(string: "!"))
            let edited = try NativeRichText.document(from: restored)
            let editedHTML = RichTextCodec.html(edited)
            let editableAfterReload = try RichTextCodec.parse(editedHTML).canEdit
            let plain = NativeRichText.readingString(document: edited).string
            let unspoiled = try NativeRichText.document(from: NativeRichText.settingSpoiler(restored, enabled: false))
            let unspoiledHTML = RichTextCodec.html(unspoiled)
            return entity.length == ":party:".utf16.count && mention.length == "Fixture".utf16.count && reloaded.canEdit && editableAfterReload && editedHTML.components(separatedBy: "customEmoji").count == 2 && editedHTML.components(separatedBy: "fixture-user").count == 2 && !plain.contains("Fixture") && !plain.contains(":party:") && plain.hasSuffix("!") && !unspoiledHTML.contains("data-spoiler") && unspoiledHTML.components(separatedBy: "customEmoji").count == 2 && unspoiledHTML.components(separatedBy: "fixture-user").count == 2
        }
        check("removing spoiler formatting cannot resurrect the original wrapper") {
            let original = try RichTextCodec.parse(#"<p><span data-spoiler="true"><strong>secret</strong></span> visible</p>"#)
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: original, revealSpoilers: true))
            let range = (text.string as NSString).range(of: "secret")
            text.replaceCharacters(in: range, with: NativeRichText.settingSpoiler(text.attributedSubstring(from: range), enabled: false))
            let document = try NativeRichText.document(from: text)
            return !RichTextCodec.html(document).contains("data-spoiler") && RichTextCodec.html(document).contains("<strong>secret</strong>") && NativeRichText.readingString(document: document).string.contains("secret")
        }
        for (name, source, expected) in [("list", "<ul><li>x</li></ul>", "<ul><li>"), ("quote", "<blockquote><p>x</p></blockquote>", "<blockquote><p>")] {
            check("custom emoji insertion preserves its surrounding \(name) after reload") {
                let emoji = try RavenCustomEmoji(raw: .object(["name": .string("long-emoji"), "emoji_name": .string("a-long-custom-emoji-name"), "image": .string("/files/emoji.png")]), origin: URL(string: "https://fixture.invalid")!)
                let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: try RichTextCodec.parse(source), revealSpoilers: true))
                let location = (text.string as NSString).range(of: "x").location
                let context = EmojiInsertion.context(text.attributes(at: location, effectiveRange: nil))
                text.insert(try EmojiInsertion.value(emoji, context: context), at: location)
                let html = RichTextCodec.html(try NativeRichText.document(from: text))
                let reloaded = try RichTextCodec.parse(html)
                return reloaded.canEdit && html.hasPrefix(expected) && html.components(separatedBy: "customEmoji").count == 2 && !html.contains("•") && !html.contains("❯")
            }
        }
        check("custom emoji insertion refuses code blocks") {
            let emoji = try RavenCustomEmoji(raw: .object(["name": .string("emoji"), "emoji_name": .string("emoji"), "image": .string("/files/emoji.png")]), origin: URL(string: "https://fixture.invalid")!)
            let text = NativeRichText.attributedString(document: try RichTextCodec.parse("<pre><code>x</code></pre>"), revealSpoilers: true)
            do { _ = try EmojiInsertion.value(emoji, context: EmojiInsertion.context(text.attributes(at: 0, effectiveRange: nil))); return false }
            catch { return true }
        }
        check("adjacent identical emoji keep separate entities after editing") {
            let text = NSMutableAttributedString(attributedString: NativeRichText.attributedString(document: try RichTextCodec.parse(#"<p><img data-type="customEmoji" src="/files/emoji.png" alt=":emoji:"><img data-type="customEmoji" src="/files/emoji.png" alt=":emoji:"></p>"#), revealSpoilers: true))
            text.append(NSAttributedString(string: "!"))
            let html = RichTextCodec.html(try NativeRichText.document(from: text))
            return html.components(separatedBy: "customEmoji").count == 3 && html.hasSuffix("!</p>")
        }
        check("native tables place selectable cells in separate columns") {
            let doc = try RichTextCodec.parse("<table><tr><th>Header A</th><th>Header B</th></tr><tr><td>Value A</td><td>Value B</td></tr></table>")
            let text = NativeRichText.readingString(document: doc)
            let storage = NSTextStorage(attributedString: text), layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 400, height: 10_000))
            storage.addLayoutManager(layout); layout.addTextContainer(container); layout.ensureLayout(for: container)
            func rect(_ needle: String) -> NSRect {
                let characters = (text.string as NSString).range(of: needle)
                return layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: characters, actualCharacterRange: nil), in: container)
            }
            return rect("Header B").minX > rect("Header A").maxX && rect("Value A").minY > rect("Header A").minY && layout.usedRect(for: container).maxX <= 401
        }
        check("native table spans retain their row and column geometry") {
            let doc = try RichTextCodec.parse("<table><tr><td rowspan=2>A</td><td colspan=2>B</td></tr><tr><td>C</td><td>D</td></tr></table>")
            let text = NativeRichText.readingString(document: doc)
            func block(_ needle: String) -> NSTextTableBlock? {
                let location = (text.string as NSString).range(of: needle).location
                return (text.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock
            }
            return block("A")?.rowSpan == 2 && block("B")?.columnSpan == 2 && block("C")?.startingRow == 1 && block("C")?.startingColumn == 1 && block("D")?.startingColumn == 2
        }
        check("native table copying keeps tab-separated columns and RTF structure") {
            let doc = try RichTextCodec.parse("<table><tr><td>A</td><td>B</td></tr><tr><td>C</td><td>D</td></tr></table>")
            let text = NativeRichText.readingString(document: doc)
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let imported = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            return NativeTables.plainText(text) == "A\tB\nC\tD\n" && (imported.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.isEmpty == false
        }
        check("native table layout keeps hidden cell contents out of reading and RTF") {
            let doc = try RichTextCodec.parse(#"<table><tr><td><span data-spoiler="true">HIDDEN_TABLE_VALUE</span></td><td>public</td></tr></table>"#)
            let text = NativeRichText.readingString(document: doc)
            let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            let imported = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            return !text.string.contains("HIDDEN_TABLE_VALUE") && !imported.string.contains("HIDDEN_TABLE_VALUE") && imported.string.contains("[Spoiler]") && imported.string.contains("public")
        }
        return results
    }
}
