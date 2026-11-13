import Foundation
import Testing
@testable import NevermoreCore

@Test func richTextWireIdentityAndSpoilerPrivacy() throws {
    let html = #"<p>Hello <span data-type="userMention" data-id="alex@example.com">@Alex</span> — مرحبا 日本語 👋</p><p><span data-spoiler="true">private secret</span></p>"#
    let doc = try RichTextCodec.parse(html)
    let encoded = RichTextCodec.html(doc)
    #expect(encoded.contains("userMention"))
    #expect(encoded.contains("alex@example.com"))
    #expect(RichTextCodec.plainText(doc).contains("日本語"))
    #expect(!RichTextCodec.plainText(doc).contains("private secret"))
    #expect(RichTextCodec.plainText(doc, revealSpoilers: true).contains("private secret"))
}
@Test func maliciousMarkupNeverBecomesAnExecutableNativeLink() throws {
    let doc = try RichTextCodec.parse(#"<p>Safe</p><script>evil()</script><iframe src="https://tracker.invalid"></iframe><a href="javascript:evil()" onclick="evil()">Click</a><img src="https://tracker.invalid/pixel" onerror="evil()">"#)
    let encoded = RichTextCodec.html(doc)
    #expect(!encoded.lowercased().contains("javascript:"))
    #expect(!encoded.lowercased().contains("onclick"))
    #expect(!encoded.lowercased().contains("onerror"))
    #expect(!encoded.lowercased().contains("<script"))
    #expect(!encoded.lowercased().contains("<iframe"))
    #expect(RichTextCodec.plainText(doc).contains("Safe"))
}
@Test func codeAndListBoundariesSurviveEncoding() throws {
    let html = "<blockquote><p>Quoted</p></blockquote><ul><li><p>First</p></li><li><p>Second</p></li></ul><pre><code>if x &lt; 3 {\n  print(&quot;Hello&quot;)\n}</code></pre>"
    let first = try RichTextCodec.parse(html)
    let second = try RichTextCodec.parse(RichTextCodec.html(first))
    #expect(RichTextCodec.plainText(second).contains("if x < 3"))
    #expect(RichTextCodec.plainText(second).contains("First"))
    #expect(RichTextCodec.html(second).contains("<pre"))
    #expect(RichTextCodec.html(second).contains("<blockquote"))
}
@Test func unknownFormattingCannotBeSilentlyDestroyedByEdit() throws {
    let doc = try RichTextCodec.parse("<p>Normal</p><future-raven-widget data-id=\"opaque\">Important future content</future-raven-widget>")
    #expect(!doc.canEdit)
    #expect(!doc.warnings.isEmpty)
    #expect(RichTextCodec.plainText(doc).contains("Important future content"))
}
@Test func customEmojiRetainsServerIdentity() throws {
    let doc = try RichTextCodec.parse(#"<p><img data-type="customEmoji" data-id="party-parrot" data-name="party-parrot" src="/files/parrot.png" alt=":party-parrot:"></p>"#)
    let encoded = RichTextCodec.html(doc)
    #expect(encoded.contains("customEmoji"))
    #expect(encoded.contains("party-parrot"))
}

@Test func encoderDefendsAgainstForgedSemanticAttributes() {
    let document = RichDocument(nodes: [.element("a", ["href":"javascript:evil()", "onclick":"evil()"], [.text("Click")])])
    let html = RichTextCodec.html(document)
    #expect(!html.contains("javascript:"))
    #expect(!html.contains("onclick"))
}
@Test func unknownSemanticNodesAreReadOnly() throws {
    let doc = try RichTextCodec.parse(#"<p><span data-type="futureMath" data-id="x">Formula</span></p>"#)
    #expect(!doc.canEdit)
}
