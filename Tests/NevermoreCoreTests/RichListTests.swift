import Foundation
import Testing
@testable import NevermoreCore

private func children(_ node: RichNode, of tag: String) -> [RichNode]? {
    guard case .element(let name, _, let kids) = node, name == tag else { return nil }
    return kids
}
private func textOf(_ node: RichNode) -> String {
    switch node {
    case .text(let value): return value
    case .element(_, _, let kids): return kids.map(textOf).joined()
    }
}

@Test func nestedListsAreEditableAndRoundTripLosslessly() throws {
    let html = "<ul><li>One<ul><li>Alpha</li><li>Beta<ol start=\"3\"><li>deep</li></ol></li></ul></li><li>Two</li></ul>"
    let doc = try RichTextCodec.parse(html)
    #expect(doc.canEdit)
    #expect(doc.warnings.isEmpty)
    #expect(RichTextCodec.html(doc) == html)
    #expect(try RichTextCodec.parse(RichTextCodec.html(doc)).nodes == doc.nodes)
}
@Test func nestedListStructurePreservesOrderKindAndStarts() throws {
    let doc = try RichTextCodec.parse("<ul><li>One<ol start=\"4\"><li>a</li><li>b</li></ol></li><li>Two</li></ul>")
    let list = try #require(doc.nodes.first)
    let items = try #require(children(list, of: "ul"))
    #expect(items.count == 2)
    let first = try #require(children(items[0], of: "li"))
    #expect(textOf(first[0]) == "One")
    guard case .element("ol", let attrs, let ordered) = first[1] else { Issue.record("nested list is not an ordered list"); return }
    #expect(attrs["start"] == "4")
    #expect(ordered.count == 2)
    #expect(RichTextCodec.html(doc).contains("<ol start=\"4\"><li>a</li><li>b</li></ol>"))
}
@Test func multilineListItemsStayInsideOneItem() throws {
    let doc = try RichTextCodec.parse("<ul><li><p>first</p><p>second</p></li><li>other</li></ul>")
    #expect(doc.canEdit)
    let list = try #require(doc.nodes.first)
    let items = try #require(children(list, of: "ul"))
    #expect(items.count == 2)
    let first = try #require(children(items[0], of: "li"))
    #expect(first.count == 2)
    #expect(textOf(items[0]).contains("first"))
    #expect(textOf(items[0]).contains("second"))
    #expect(RichTextCodec.plainText(doc).contains("first\nsecond"))
}
@Test func semanticChildrenSurviveInsideNestedItems() throws {
    let html = #"<ul><li><span data-type="userMention" data-id="alex@example.com">@Alex</span><ul><li><img data-type="customEmoji" data-id="parrot" data-name="parrot" src="/files/parrot.png" alt=":parrot:"><span data-spoiler="true">secret</span></li></ul></li></ul>"#
    let doc = try RichTextCodec.parse(html)
    #expect(doc.canEdit)
    let encoded = RichTextCodec.html(doc)
    #expect(encoded.contains("alex@example.com"))
    #expect(encoded.contains("customEmoji"))
    #expect(encoded.contains("parrot"))
    #expect(!RichTextCodec.plainText(doc).contains("secret"))
    #expect(RichTextCodec.plainText(doc, revealSpoilers: true).contains("secret"))
}
@Test func multilineCodeKeepsOneBlockAndItsLanguage() throws {
    let html = "<pre><code class=\"language-swift\">first\nsecond\nthird</code></pre>"
    let doc = try RichTextCodec.parse(html)
    #expect(doc.canEdit)
    let encoded = RichTextCodec.html(doc)
    #expect(encoded == html)
    #expect(encoded.components(separatedBy: "<pre").count == 2)
    #expect(RichTextCodec.plainText(doc).contains("first\nsecond\nthird"))
}
@Test func barePreTextStaysEditable() throws {
    let doc = try RichTextCodec.parse("<pre>plain\ntext</pre>")
    #expect(doc.canEdit)
    #expect(RichTextCodec.html(doc) == "<pre>plain\ntext</pre>")
}
@Test func complexListBlocksRemainReadOnly() throws {
    for html in [
        "<ul><li><pre>x</pre></li></ul>",
        "<ul><li><blockquote><p>x</p></blockquote></li></ul>",
        "<ul><li>a</li><p>stray</p></ul>",
        "<ol><li><hr></li></ol>",
        "<ul><li><table><tr><td>x</td></tr></table></li></ul>",
    ] {
        let doc = try RichTextCodec.parse(html)
        #expect(!doc.canEdit, "\(html)")
        #expect(!doc.warnings.isEmpty, "\(html)")
        #expect(!RichTextCodec.html(doc).isEmpty)
    }
}
@Test func complexCodeBlocksRemainReadOnly() throws {
    for html in [
        "<pre><code>a</code><code>b</code></pre>",
        "<pre><code><strong>x</strong></code></pre>",
        "<pre><em>x</em></pre>",
    ] {
        let doc = try RichTextCodec.parse(html)
        #expect(!doc.canEdit, "\(html)")
    }
}
@Test func nestedTablesAndUnknownMarkupRemainReadOnly() throws {
    #expect(!(try RichTextCodec.parse("<blockquote><table><tr><td>x</td></tr></table></blockquote>")).canEdit)
    #expect(!(try RichTextCodec.parse("<ul><li><span style=\"color:red\">styled</span></li></ul>")).canEdit)
    #expect(!(try RichTextCodec.parse("<ul><li><future-widget>x</future-widget></li></ul>")).canEdit)
}
@Test func listEncodingNeverEmitsForgedAttributes() throws {
    let forged = RichDocument(nodes: [
        .element("ul", ["onclick": "evil()", "start": "3"], [.element("li", [:], [.text("safe")])]),
        .element("ol", ["start": "bogus"], [.element("li", [:], [.text("kept")])]),
        .element("ol", ["start": "7"], [.element("li", [:], [.text("numbered")])]),
    ])
    let html = RichTextCodec.html(forged)
    #expect(!html.contains("onclick"))
    #expect(html.contains("<ul><li>safe</li></ul>"))
    #expect(html.contains("<ol><li>kept</li></ol>"))
    #expect(html.contains("<ol start=\"7\"><li>numbered</li></ol>"))
}
