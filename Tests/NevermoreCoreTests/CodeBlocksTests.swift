import Foundation
import Testing
@testable import NevermoreCore

@Test func codeExtractionPreservesWhitespaceLanguageAndIndependentIdentities() throws {
    let document = try RichTextCodec.parse("<p>before</p><pre><code class=\"language-swift\">\n  let x = &lt;value&gt;\n\n</code></pre><pre>same</pre><pre>same</pre>")
    let blocks = CodeBlocks.extract(from: document)
    #expect(blocks.count == 3)
    #expect(blocks[0].text == "\n  let x = <value>\n\n")
    #expect(blocks[0].language == "swift")
    #expect(blocks[0].lineCount == 3)
    #expect(blocks[1].id != blocks[2].id)
    #expect(blocks[0].id != RichCodeBlock(index: 0, text: blocks[0].text + "!").id)
}

@Test func codeReaderNeverExtractsHiddenSpoilerSubtrees() throws {
    let document = try RichTextCodec.parse("<span data-spoiler=\"true\"><pre>hidden</pre></span><pre>visible<span data-spoiler=\"true\">secret</span></pre>")
    let blocks = CodeBlocks.extract(from: document)
    #expect(blocks.count == 1)
    #expect(blocks[0].text == "visible[Spoiler]")
    #expect(!blocks[0].text.contains("secret"))
    #expect(!document.canEdit)
}

@Test func inlineSpoilersKeepNestedMentionIdentityDuringEdit() throws {
    let document = try RichTextCodec.parse("<p><span data-spoiler=\"true\">hidden <span data-type=\"userMention\" data-id=\"u\">@User</span></span></p>")
    #expect(document.canEdit)
    #expect(RichTextCodec.plainText(document) == "[Spoiler]")
    #expect(RichTextCodec.html(document).contains("data-id=\"u\""))
    #expect(try RichTextCodec.parse(RichTextCodec.html(document)).canEdit)
    #expect(try RichTextCodec.parse("<p><span data-spoiler=\"true\"><strong>safe simple</strong></span></p>").canEdit)
}

@Test func codeBlockLineCountIgnoresOnlyTheTrailingNewline() {
    #expect(RichCodeBlock(index: 0, text: "a\nb\n").lineCount == 2)
    #expect(RichCodeBlock(index: 0, text: "a\nb").lineCount == 2)
    #expect(RichCodeBlock(index: 0, text: "a\n\n").lineCount == 2)
    #expect(RichCodeBlock(index: 0, text: "a\nb\n\n").lineCount == 3)
    #expect(RichCodeBlock(index: 0, text: "\n").lineCount == 1)
    #expect(RichCodeBlock(index: 0, text: "").lineCount == 1)
    #expect(RichCodeBlock(index: 0, text: "one line").lineCount == 1)
}
