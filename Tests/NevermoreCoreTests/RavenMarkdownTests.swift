import Testing
@testable import NevermoreCore

struct RavenMarkdownTests {
    @Test func commonFormattingProducesRavenHTML() throws {
        let source = "**bold** *italic* ~~strike~~ `code` [link](https://example.com)\n\n- one\n- two\n\n> quote\n\n---\n\n```swift\nlet x = 1\n```"
        let html = RichTextCodec.html(try RavenMarkdown.document(from: source))
        for expected in ["<strong>bold</strong>", "<em>italic</em>", "<s>strike</s>", "<code>code</code>", "href=\"https://example.com\"", "<ul>", "<blockquote>", "<hr>", "class=\"language-swift\""] { #expect(html.contains(expected)) }
    }

    @Test func ordinaryMarkupExportsAsMarkdown() throws {
        for (html, expected) in [
            ("<p><strong>bold</strong></p>", "**bold**"),
            ("<ul><li>one</li><li>two</li></ul>", "- one\n- two"),
            ("<table><tr><th>A</th><th>B</th></tr><tr><td>C</td><td>D</td></tr></table>", "| A | B |")
        ] {
            #expect(try RavenMarkdown.source(from: RichTextCodec.parse(html)).contains(expected))
        }
    }

    @Test func tableSourceCreatesAnEditableGrid() throws {
        let document = try RavenMarkdown.document(from: "| A | B |\n| --- | --- |\n| **C** | D |")
        let table = try #require(document.nodes.first)
        let layout = try #require(RichTableLayout(table))
        #expect(layout.rows == 2 && layout.columns == 2)
        #expect(RichTextCodec.html(document).contains("<strong>C</strong>"))
    }

    @Test func ravenEntitiesAndSpansSurviveRepeatedSwitches() throws {
        let html = #"<p><u>under</u><mark>yellow</mark><span data-spoiler="true"><strong>secret</strong></span><span data-type="userMention" data-id="person@example.com">@Person</span><span data-type="channelMention" data-id="channel-id">#Channel</span><img data-type="customEmoji" data-name="party" src="/files/party.png" alt=":party:"></p><table><tr><td rowspan="2"><p><em>A</em></p></td><td>B</td></tr><tr><td>C</td></tr></table>"#
        var document = try RichTextCodec.parse(html)
        let original = RichTextCodec.html(document)
        for _ in 0..<5 { document = try RavenMarkdown.document(from: RavenMarkdown.source(from: document)) }
        #expect(RichTextCodec.html(document) == original)
    }

    @Test func punctuationWhitespaceAndNestedMarksAreLossless() throws {
        let samples = [
            "<p>  literal *stars* [brackets] &amp; &lt;tag&gt; #heading\n\n尾\t </p>",
            "<p><strong> one </strong><em>two</em><strong>three</strong></p>",
            "<p><strong><em>nested</em></strong><em><strong>reverse</strong></em></p>",
            "<p><code>`tick`</code><code> a </code><code>\n</code></p>",
            "<p>line<br>next<br></p>",
            "<p><a href=\"https://example.com/a_(b)?q=one&amp;x=two\" title=\"A &amp; B\">link</a></p>",
            "<p></p><p>next</p>",
            "<pre><code class=\"language-swift\">```\ntext\n</code></pre>",
            "<table><tr><th>A</th></tr><tr><td><code>x|y</code></td></tr></table>"
        ]
        for html in samples {
            let document = try RichTextCodec.parse(html)
            let roundTrip = try RavenMarkdown.document(from: RavenMarkdown.source(from: document))
            #expect(RichTextCodec.html(roundTrip) == RichTextCodec.html(document), Comment(rawValue: html))
        }
    }

    @Test func unsupportedSourceFailsInsteadOfFlattening() {
        for source in ["# Heading", "- [x] task", "![image](https://example.com/a.png)", "[bad](javascript:alert)", "<script>alert(1)</script>", "<!-- keep me -->", "<p style='color:red'>text</p>", "<table><tr><td rowspan='0'>bad</td></tr></table>"] {
            #expect(throws: (any Error).self) { try RavenMarkdown.document(from: source) }
        }
    }

    @Test func tableCellAlignmentUsesRavensTableMetadata() throws {
        let document = try RavenMarkdown.document(from: "| A | B |\n| :---: | ---: |\n| C | D |")
        let layout = try #require(document.nodes.first.flatMap(RichTableLayout.init))
        #expect(layout.cells.map(\.alignment) == [.center, .right, .center, .right])
        let restored = try RavenMarkdown.document(from: RavenMarkdown.source(from: document))
        #expect(restored.nodes == document.nodes)
    }

    @Test func byteAndDepthLimitsApplyBothWays() throws {
        #expect(throws: (any Error).self) { try RavenMarkdown.document(from: String(repeating: "x", count: RichTextCodec.maximumBytes + 1)) }
        var node = RichNode.text("x")
        for _ in 0..<66 { node = .element("strong", [:], [node]) }
        let deep = node
        #expect(throws: (any Error).self) { try RavenMarkdown.source(from: RichDocument(nodes: [deep])) }
        #expect(throws: (any Error).self) { try RavenMarkdown.source(from: RichDocument(nodes: [], canEdit: false)) }
    }

    @Test func sourceLeavesOrdinaryPunctuationReadable() throws {
        let sentence = "Hello, world! It's 3 o'clock (really): see https://example.com/a-b?x=1. 50% off; a > b, \"quoted\" $5 #general @alice R&D {x}"
        #expect(try RavenMarkdown.source(from: RichTextCodec.parse("<p>\(RichTextCodec.escape(sentence))</p>")) == sentence)
    }

    @Test func sourceStillEscapesWhatWouldBecomeMarkup() throws {
        for (text, expected) in [
            ("2 * 3 * 4", ##"2 \* 3 \* 4"##), ("snake_case_name", ##"snake\_case\_name"##), ("[not a link]", ##"\[not a link\]"##),
            ("`tick`", ##"\`tick\`"##), ("<b>", ##"\<b>"##), ("~~old~~", ##"\~\~old\~\~"##), ("back\\slash", ##"back\\slash"##),
            ("&amp; stays text", ##"\&amp; stays text"##),
            ("# not a heading", ##"\# not a heading"##), ("- not a bullet", ##"\- not a bullet"##), ("+ not a bullet", ##"\+ not a bullet"##),
            ("--- not a rule", ##"\--- not a rule"##), ("> not a quote", ##"\> not a quote"##), ("2024. A good year", ##"2024\. A good year"##),
            ("1) not a list", ##"1\) not a list"##)
        ] {
            let document = try RichTextCodec.parse("<p>\(RichTextCodec.escape(text))</p>")
            let source = try RavenMarkdown.source(from: document)
            #expect(source == expected, "\(text)")
            #expect(RichTextCodec.html(try RavenMarkdown.document(from: source)) == RichTextCodec.html(document), "\(text)")
        }
    }

    @Test func listItemsAndTableCellsUseReadableSource() throws {
        let list = try RavenMarkdown.source(from: RichTextCodec.parse("<ul><li>Ready, set: go!</li><li>- dash</li></ul>"))
        #expect(list == "- Ready, set: go!\n- \\- dash")
        let table = try RichTextCodec.parse("<table><tr><th>A|B</th><th>C</th></tr><tr><td>d, e</td><td>f</td></tr></table>")
        let source = try RavenMarkdown.source(from: table)
        #expect(source.hasPrefix("| A&#124;B | C |") && source.contains("| d, e | f |"))
        #expect(Self.unwrapped(try RavenMarkdown.document(from: source)) == Self.unwrapped(table))
    }

    /// HTML without the paragraph and row-group wrappers that Markdown adds
    /// to list items and tables, which the exporter treats as equivalent.
    private static func unwrapped(_ document: RichDocument) -> String {
        ["<p>", "</p>", "<thead>", "</thead>", "<tbody>", "</tbody>"].reduce(RichTextCodec.html(document)) { $0.replacingOccurrences(of: $1, with: "") }
    }

    /// Readable source must never change what the text says: every export,
    /// readable or not, parses back to the same document.
    @Test func everyExportRoundTrips() throws {
        let alphabet: [String] = ["a", "B", "1", "9", " ", ".", ")", "#", "-", "+", "=", "*", "_", "`", "[", "]", "(", "<", ">", "&", ";", "!", "|", "~", "\\", ":", "/", "@", "w", "\"", "'", "amp", "#1", "é", "😀"]
        var seed: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(bound)) }
        for _ in 0..<600 {
            let text = (0..<(1 + next(14))).map { _ in alphabet[next(alphabet.count)] }.joined()
            for html in ["<p>\(RichTextCodec.escape(text))</p>", "<ul><li>\(RichTextCodec.escape(text))</li></ul>", "<p><strong>x</strong>\(RichTextCodec.escape(text))</p>"] {
                let document = try RichTextCodec.parse(html)
                // Every one of these has a source form; a throw is a failure.
                let source = try RavenMarkdown.source(from: document)
                #expect(Self.unwrapped(try RavenMarkdown.document(from: source)) == Self.unwrapped(document), "\(html) -> \(source)")
            }
        }
    }
}
