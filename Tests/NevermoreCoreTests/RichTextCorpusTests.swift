import Foundation
import Testing
@testable import NevermoreCore

// Offline rich-text interoperability corpus for RichTextCodec (NevermoreCore only;
// the AppKit adapter in NevermoreApp is not importable from this test target).
//
// Provenance legend (see docs/implementation/RICH-TEXT-CORPUS.md for the full table):
// - [server]  pinned Raven develop 9b01029a92f790e999aab8973e428601261615d1, cached primary
//             files (/tmp/nevermore-contracts): message_model.py, raven_message.py.
// - [editor]  pinned editor feature set per docs/RAVEN-RESEARCH.md §2/§5, which cites
//             useRavenEditor.ts at the same commit (bold/italic/underline/strike, inline and
//             fenced code, lists, blockquotes, links, highlights, tables, mentions, custom
//             emoji, spoilers; headings/task lists/details are NOT enabled there).
// - [out]     Nevermore's own outgoing markup: Sources/NevermoreCore/MentionCompletion.swift.
// All fixtures are synthetic and offline. They are modeled on the contracts above and are
// NOT cross-client verified against a running Raven web/mobile client.

private func corpusFirstElement(_ nodes: [RichNode], _ tag: String) -> RichNode? {
    for node in nodes {
        if case .element(let name, _, _) = node, name == tag { return node }
    }
    return nil
}
private func corpusElements(_ node: RichNode, _ tag: String) -> [RichNode] {
    guard case .element(_, _, let kids) = node else { return [] }
    return kids.filter { if case .element(let name, _, _) = $0, name == tag { return true }; return false }
}
private func corpusAttrs(_ node: RichNode) -> [String: String] {
    if case .element(_, let attrs, _) = node { return attrs }
    return [:]
}
private func corpusText(_ node: RichNode) -> String {
    switch node {
    case .text(let value): return value
    case .element(_, _, let kids): return kids.map(corpusText).joined()
    }
}
/// Parses, re-encodes, re-parses and asserts the model is a fixed point, and that the
/// original wire HTML is retained untouched for the read-only fallback.
private func corpusRoundTrip(_ html: String) throws -> RichDocument {
    let doc = try RichTextCodec.parse(html)
    #expect(doc.rawHTML == html, "raw wire HTML must be preserved verbatim for the fallback")
    let reencoded = RichTextCodec.html(doc)
    let reparsed = try RichTextCodec.parse(reencoded)
    #expect(reparsed.nodes == doc.nodes, "parse(html(parse(x))) must be a model fixed point")
    return doc
}

// MARK: - Mentions

// Corpus id: mention-user. Provenance: [server] message_model.py extract_mentions reads
// span[data-type="userMention"][data-id]; [out] MentionCompletion.swift also emits data-label.
@Test func richTextCorpusUserMentionPreservesIdentity() throws {
    let html = #"<p>Hi <span data-type="userMention" data-id="alex@example.com" data-label="@Alex">@Alex</span>!</p>"#
    let doc = try corpusRoundTrip(html)
    #expect(doc.canEdit && doc.warnings.isEmpty)
    guard let paragraph = corpusFirstElement(doc.nodes, "p"),
          let mention = corpusElements(paragraph, "span").first else {
        Issue.record("mention span missing"); return
    }
    let attrs = corpusAttrs(mention)
    #expect(attrs["data-type"] == "userMention")
    #expect(attrs["data-id"] == "alex@example.com", "server derives mention recipients from data-id; it must not be lost")
    #expect(attrs["data-label"] == "@Alex")
    #expect(corpusText(mention) == "@Alex")
    let encoded = RichTextCodec.html(doc)
    #expect(encoded.contains("data-type=\"userMention\"") && encoded.contains("data-id=\"alex@example.com\""))
    #expect(RichTextCodec.plainText(doc) == "Hi @Alex!")
}

// Corpus id: mention-channel. Provenance: [out] MentionCompletion.swift emits
// span[data-type="channelMention"][data-id][data-label="#name"]; the parser allowlist accepts
// channelMention. The cached server files do not cover channel mentions, so this fixture is
// modeled, not server-verified.
@Test func richTextCorpusChannelMentionPreservesIdentity() throws {
    let html = ##"<p>see <span data-type="channelMention" data-id="CH-0001" data-label="#general">#general</span></p>"##
    let doc = try corpusRoundTrip(html)
    #expect(doc.canEdit && doc.warnings.isEmpty)
    guard let paragraph = corpusFirstElement(doc.nodes, "p"),
          let mention = corpusElements(paragraph, "span").first else {
        Issue.record("channel mention span missing"); return
    }
    let attrs = corpusAttrs(mention)
    #expect(attrs["data-type"] == "channelMention")
    #expect(attrs["data-id"] == "CH-0001")
    #expect(attrs["data-label"] == "#general")
    #expect(RichTextCodec.plainText(doc) == "see #general")
    #expect(RichTextCodec.html(doc).contains("channelMention"))
}

// MARK: - Custom emoji

// Corpus id: emoji-inline. Provenance: [server] message_model.py replaces
// img[data-type="customEmoji"] with its alt (:name:) for plain text; raven_message.py treats
// an emoji-only message as non-empty. [editor] custom emoji are enabled.
@Test func richTextCorpusCustomEmojiPreservesIdentityAndPlainTextName() throws {
    let html = #"<p>party <img data-type="customEmoji" data-id="parrot" data-name="parrot" src="/files/parrot.png" alt=":parrot:"> time</p>"#
    let doc = try corpusRoundTrip(html)
    #expect(doc.canEdit && doc.warnings.isEmpty)
    guard let paragraph = corpusFirstElement(doc.nodes, "p"),
          let emoji = corpusElements(paragraph, "img").first else {
        Issue.record("emoji img missing"); return
    }
    let attrs = corpusAttrs(emoji)
    #expect(attrs["data-type"] == "customEmoji")
    #expect(attrs["data-id"] == "parrot")
    #expect(attrs["data-name"] == "parrot")
    #expect(attrs["src"] == "/files/parrot.png", "relative /files media URL is part of the emoji contract")
    #expect(attrs["alt"] == ":parrot:")
    let encoded = RichTextCodec.html(doc)
    for fragment in ["customEmoji", "parrot", "/files/parrot.png", ":parrot:"] {
        #expect(encoded.contains(fragment))
    }
    #expect(RichTextCodec.plainText(doc) == "party :parrot: time")
}

// Corpus id: emoji-only-message. Provenance: [server] raven_message.py: a message that is only
// a custom emoji is NOT empty; its preview carries the :name:.
@Test func richTextCorpusEmojiOnlyMessageHasNonEmptyPlainText() throws {
    let doc = try corpusRoundTrip(#"<p><img data-type="customEmoji" data-id="blob" data-name="blob" src="https://cdn.example.com/blob.gif" alt=":blob:"></p>"#)
    #expect(RichTextCodec.plainText(doc) == ":blob:")
    guard let paragraph = corpusFirstElement(doc.nodes, "p"),
          let emoji = corpusElements(paragraph, "img").first else { Issue.record("emoji missing"); return }
    #expect(corpusAttrs(emoji)["src"] == "https://cdn.example.com/blob.gif")
}

// MARK: - Spoilers

// Corpus id: spoiler-inline. Provenance: [server] message_model.py masks every element carrying
// data-spoiler in derived previews; [editor] spoilers (||text||) are enabled.
@Test func richTextCorpusSpoilerIsMaskedInPlainTextButKeptOnTheWire() throws {
    let html = #"<p>the ending is <span data-spoiler="true">the butler did it</span></p>"#
    let doc = try corpusRoundTrip(html)
    #expect(doc.canEdit && doc.warnings.isEmpty, "a plain inline spoiler stays editable")
    let plain = RichTextCodec.plainText(doc)
    #expect(plain == "the ending is [Spoiler]")
    #expect(!plain.contains("butler"))
    #expect(RichTextCodec.plainText(doc, revealSpoilers: true) == "the ending is the butler did it")
    let encoded = RichTextCodec.html(doc)
    #expect(encoded.contains("data-spoiler=\"true\""), "the wire format keeps the spoiler mark and body; masking is a preview concern")
    #expect(encoded.contains("the butler did it"))
}

// Corpus id: spoiler-complex. Provenance: current parser policy (RichText.swift "Complex
// spoilers") — spoilers on block tags or with nested spoiler marks are read-only but must still be
// masked in plain text.
@Test func richTextCorpusComplexSpoilersStayMaskedAndReadOnly() throws {
    for html in [
        #"<p><span data-spoiler="true"><span data-spoiler="true">nested secret</span></span></p>"#,
        #"<span data-spoiler="true"><ul><li>block secret</li></ul></span>"#,
        #"<p><span data-spoiler="true"><strong data-type="userMention" data-id="fixture-user">Fixture</strong></span></p>"#,
        #"<p data-spoiler="true">whole para secret</p>"#,
        #"<p><img data-type="customEmoji" data-id="e" data-name="e" data-spoiler="true" src="/files/e.png" alt=":e:"></p>"#,
    ] {
        let doc = try corpusRoundTrip(html)
        #expect(!doc.canEdit, "complex spoiler must be read-only: \(html)")
        #expect(doc.warnings.contains("Complex spoilers are read only to preserve nested formatting and identities."), "\(html)")
        let plain = RichTextCodec.plainText(doc)
        #expect(plain == "[Spoiler]", "spoiler body must never leak: \(html)")
        #expect(!plain.contains("secret") && !plain.contains("@A") && !plain.contains(":e:"))
        #expect(!RichTextCodec.plainText(doc, revealSpoilers: true).isEmpty)
        #expect(RichTextCodec.html(doc).contains("data-spoiler=\"true\""))
    }
}

// Corpus id: spoiler-unsupported-tag. Provenance: [server] message_model.py:143 masks by
// attribute presence on any element, not only on the span Raven's editor writes. A tag
// outside the supported set degrades to a read-only span, and used to lose the mark on the
// way, so its body showed in the transcript, reply quotes and copies (first filtered run:
// this test failed for every case).
@Test func richTextCorpusSpoilerOnAnUnsupportedTagIsMasked() throws {
    for html in [
        #"<div data-spoiler="true">secret-div</div>"#,
        #"<h2 data-spoiler>secret-heading</h2>"#,
        #"<p>seen <sup data-spoiler="">secret-sup</sup></p>"#,
        #"<details data-spoiler="true"><summary>secret-summary</summary>secret-body</details>"#,
    ] {
        let doc = try RichTextCodec.parse(html)
        let plain = RichTextCodec.plainText(doc)
        #expect(!plain.contains("secret"), "a spoiler on an unsupported tag must not leak: \(html)")
        #expect(plain.contains("[Spoiler]"), "no [Spoiler] placeholder for \(html)")
        #expect(!doc.canEdit, "an unsupported tag stays read-only: \(html)")
        #expect(RichTextCodec.plainText(doc, revealSpoilers: true).contains("secret"), "revealing still shows the body: \(html)")
        #expect(RichTextCodec.html(doc).contains("data-spoiler"), "spoiler mark stripped on re-encode for \(html)")
    }
    // An unsupported tag without the mark still shows its text.
    #expect(RichTextCodec.plainText(try RichTextCodec.parse("<div>plain-div</div>")).contains("plain-div"))
}

@Test func authoredSemanticSpoilersRemainEditableAfterDraftReload() throws {
    for content in [
        #"<span data-type="userMention" data-id="fixture-user" data-label="Fixture">Fixture</span>"#,
        #"<img data-type="customEmoji" src="/files/party.png" alt=":party:">"#,
    ] {
        let html = "<p><span data-spoiler=\"true\">\(content)</span> visible</p>"
        let document = try corpusRoundTrip(html)
        #expect(document.canEdit)
        #expect(document.warnings.isEmpty)
        #expect(RichTextCodec.plainText(document) == "[Spoiler] visible")
        #expect(try RichTextCodec.parse(RichTextCodec.html(document)).canEdit)
    }
}

// Corpus id: spoiler-empty-attribute. Provenance: [server] message_model.py:143 masks by
// attribute PRESENCE (find_all(attrs={"data-spoiler": True}) matches empty/bare values);
// Nevermore's own search index does the same (Store.swift select("[data-spoiler]")).
//
// This corpus case exposed a real production bug: parse used to drop empty-valued attributes
// (`if !value.isEmpty { attrs[key] = ... }`), so data-spoiler="" or a bare data-spoiler leaked
// the spoiler body in plainText and lost the mark on re-encode while canEdit stayed true
// (first filtered run: this test failed with 6 issues). Root fix observed in
// RichText.swift:52 — data-spoiler is now recorded by presence (`element.hasAttr(key)`).
// The test is kept as a guard for the presence-based contract.
@Test func richTextCorpusSpoilerWithEmptyOrBareAttributeIsMasked() throws {
    for html in [
        #"<p>x <span data-spoiler="">secret-empty</span></p>"#,
        #"<p>y <span data-spoiler>secret-bare</span></p>"#,
    ] {
        let doc = try RichTextCodec.parse(html)
        let plain = RichTextCodec.plainText(doc)
        #expect(!plain.contains("secret-empty") && !plain.contains("secret-bare"), "empty/bare data-spoiler must not leak in plainText (server masks by presence) — \(html)")
        #expect(plain.contains("[Spoiler]"), "no [Spoiler] placeholder for \(html)")
        #expect(RichTextCodec.html(doc).contains("data-spoiler"), "spoiler mark stripped on re-encode for \(html)")
        #expect(try RichTextCodec.parse(RichTextCodec.html(doc)).nodes == doc.nodes, "spoiler mark lost across parse(html(parse(x))) for \(html)")
    }
}

// MARK: - Links

// Corpus id: link-safe. Provenance: [server] message_model.py extracts a[href] for link
// previews; [editor] links are enabled. Relative /files URLs and mailto: are part of the
// safe set used by the codec.
@Test func richTextCorpusSafeLinksKeepHrefAndText() throws {
    let html = #"<p><a href="https://example.com/docs?a=1&amp;b=2" title="Docs">docs</a> and <a href="/files/report.pdf">report</a> or <a href="mailto:alex@example.com">mail</a></p>"#
    let doc = try corpusRoundTrip(html)
    #expect(doc.canEdit && doc.warnings.isEmpty)
    guard let paragraph = corpusFirstElement(doc.nodes, "p") else { Issue.record("p missing"); return }
    let anchors = corpusElements(paragraph, "a")
    #expect(anchors.count == 3)
    #expect(corpusAttrs(anchors[0])["href"] == "https://example.com/docs?a=1&b=2")
    #expect(corpusAttrs(anchors[0])["title"] == "Docs")
    #expect(corpusAttrs(anchors[1])["href"] == "/files/report.pdf")
    #expect(corpusAttrs(anchors[2])["href"] == "mailto:alex@example.com")
    #expect(RichTextCodec.html(doc).contains("href=\"/files/report.pdf\""))
    #expect(RichTextCodec.plainText(doc) == "docs and report or mail")
}

// Corpus id: link-unsafe. Provenance: codec safeURL contract (https/http/mailto with host,
// no userinfo, no control chars, no backslash, no protocol-relative); [server] previews must
// never carry executable URLs.
@Test func richTextCorpusUnsafeLinksAreRemovedWithWarning() throws {
    let unsafe = [
        "javascript:alert(1)",
        "JaVaScRiPt:alert(1)",
        "data:text/html,<script>evil()</script>",
        "vbscript:x",
        "//evil.example/x",
        "https://user:pass@example.com",
        "https://example.com\\@evil",
        " https://example.com",
        "https://exa\tmple.com",
    ]
    for href in unsafe {
        let html = #"<p><a href="\#(href)" onclick="evil()">click</a></p>"#
        let doc = try RichTextCodec.parse(html)
        guard let paragraph = corpusFirstElement(doc.nodes, "p"),
              let anchor = corpusElements(paragraph, "a").first else {
            Issue.record("anchor missing for \(href)"); continue
        }
        #expect(corpusAttrs(anchor)["href"] == nil, "unsafe href must be dropped: \(href)")
        #expect(corpusAttrs(anchor)["onclick"] == nil, "event handlers must never survive: \(href)")
        #expect(!doc.canEdit)
        #expect(doc.warnings.contains("An unsafe link was removed."), "\(href)")
        #expect(RichTextCodec.plainText(doc) == "click", "link text is preserved even when the URL is removed")
        let encoded = RichTextCodec.html(doc)
        #expect(!encoded.contains("href"), "\(href)")
        #expect(!encoded.lowercased().contains("onclick"))
    }
}

// Corpus id: url-matrix. Provenance: codec safeURL contract directly.
@Test func richTextCorpusSafeURLSchemeMatrix() {
    let allowed = ["https://example.com", "http://example.com/path?q=1", "mailto:a@b.c", "/files/x.png", "/", "HTTPS://EXAMPLE.COM"]
    for url in allowed { #expect(RichTextCodec.safeURL(url, allowRelative: true), "should be safe: \(url)") }
    let rejected = ["//evil.com", "javascript:x", "data:x", "ftp://h", "https://user@h", "https://h\\x", " https://h", "https://h\tx", "", "relative/path", "./x", "../x", "#anchor", "?q=1"]
    for url in rejected { #expect(!RichTextCodec.safeURL(url, allowRelative: true), "should be rejected: \(url.debugDescription)") }
}

// MARK: - Lists

// Corpus id: lists-nested-ordered. Provenance: [editor] lists are enabled; ordered start and
// nesting must survive identity-preserving round trips.
@Test func richTextCorpusOrderedAndNestedListsRoundTrip() throws {
    let html = #"<ul><li>One<ul><li>Alpha</li><li>Beta<ol start="3"><li>deep</li></ol></li></ul></li><li>Two</li></ul>"#
    let doc = try corpusRoundTrip(html)
    #expect(doc.canEdit && doc.warnings.isEmpty)
    guard let list = corpusFirstElement(doc.nodes, "ul") else { Issue.record("ul missing"); return }
    let items = corpusElements(list, "li")
    #expect(items.count == 2)
    let firstKids = items[0].children
    guard case .element("ul", _, _) = firstKids[1] else { Issue.record("nested ul missing"); return }
    let nestedItems = firstKids[1].children.filter { if case .element("li", _, _) = $0 { return true }; return false }
    #expect(nestedItems.count == 2)
    guard case .element("ol", let attrs, _) = nestedItems[1].children[1] else { Issue.record("nested ol missing"); return }
    #expect(attrs["start"] == "3", "ordered-list start must survive")
    #expect(RichTextCodec.html(doc).contains("<ol start=\"3\">"))
    let plain = RichTextCodec.plainText(doc)
    for item in ["One", "Alpha", "Beta", "deep", "Two"] { #expect(plain.contains(item)) }
    // Standalone ordered start.
    let started = try corpusRoundTrip(#"<ol start="4"><li>a</li><li>b</li></ol>"#)
    #expect(corpusAttrs(try #require(corpusFirstElement(started.nodes, "ol")))["start"] == "4")
}

// MARK: - Code blocks

// Corpus id: code-language-whitespace. Provenance: [editor] fenced code is enabled with a
// language-* class; code bodies must preserve whitespace, newlines, entities and brackets.
@Test func richTextCorpusCodeBlockPreservesLanguageAndWhitespace() throws {
    let code = "func f() {\n    return 1 < 2 && \"q\"\n\n\n}\n"
    let html = "<pre><code class=\"language-swift\">func f() {\n    return 1 &lt; 2 &amp;&amp; &quot;q&quot;\n\n\n}\n</code></pre>"
    let doc = try corpusRoundTrip(html)
    #expect(doc.canEdit && doc.warnings.isEmpty)
    guard let pre = corpusFirstElement(doc.nodes, "pre"),
          case .element("code", let codeAttrs, let codeKids) = pre.children[0] else {
        Issue.record("pre>code missing"); return
    }
    #expect(codeAttrs["class"] == "language-swift", "code language must survive")
    #expect(codeKids.count == 1)
    #expect(corpusText(pre) == code, "code text must be byte-exact, including indentation, blank lines and trailing newline")
    let encoded = RichTextCodec.html(doc)
    #expect(encoded.contains("class=\"language-swift\""))
    #expect(encoded.contains("1 &lt; 2 &amp;&amp; &quot;q&quot;"), "code is re-escaped, never raw")
    #expect(RichTextCodec.plainText(doc) == code.trimmingCharacters(in: .newlines))
    // Bare <pre> without <code> stays editable too.
    let bare = try corpusRoundTrip("<pre>plain\ntext</pre>")
    #expect(RichTextCodec.plainText(bare) == "plain\ntext")
}

// MARK: - Blockquotes

// Corpus id: quote. Provenance: [editor] blockquotes are enabled; nested quotes are read-only.
@Test func richTextCorpusBlockquoteRoundTripsAndNestedQuoteIsReadOnly() throws {
    let simple = try corpusRoundTrip(#"<blockquote><p>quoted <strong>bold</strong> <a href="https://example.com/x">link</a></p></blockquote>"#)
    #expect(simple.canEdit && simple.warnings.isEmpty)
    #expect(RichTextCodec.plainText(simple) == "quoted bold link")
    let listInQuote = try corpusRoundTrip("<blockquote><ul><li>a</li><li>b</li></ul></blockquote>")
    #expect(listInQuote.canEdit && listInQuote.warnings.isEmpty)
    let nested = try RichTextCodec.parse("<blockquote><blockquote><p>deep</p></blockquote></blockquote>")
    #expect(!nested.canEdit)
    #expect(nested.warnings.contains("Nested quotes are read only."))
    #expect(RichTextCodec.plainText(nested).contains("deep"))
    #expect(nested.rawHTML == "<blockquote><blockquote><p>deep</p></blockquote></blockquote>")
}

// MARK: - Tables

// Corpus id: table. Provenance: [editor] tables are enabled in Raven.
// Bounded complete tables support cell editing while preserving their spans.
@Test func richTextCorpusTableIsReadableCopyableEditable() throws {
    let html = #"<table><thead><tr><th colspan="2">H</th></tr></thead><tbody><tr><td>a</td><td rowspan="2">b</td></tr><tr><td>c</td></tr></tbody></table>"#
    let doc = try corpusRoundTrip(html)
    #expect(doc.canEdit, "bounded complete tables support safe cell editing")
    #expect(doc.warnings.isEmpty)
    let table = try #require(corpusFirstElement(doc.nodes, "table"))
    let th = try #require(corpusElements(corpusElements(corpusElements(table, "thead")[0], "tr")[0], "th").first)
    #expect(corpusAttrs(th)["colspan"] == "2")
    let tds = corpusElements(corpusElements(corpusElements(table, "tbody")[0], "tr")[0], "td")
    #expect(corpusAttrs(tds[1])["rowspan"] == "2")
    let encoded = RichTextCodec.html(doc)
    #expect(encoded.contains("colspan=\"2\"") && encoded.contains("rowspan=\"2\""))
    let plain = RichTextCodec.plainText(doc)
    #expect(plain.contains("H\t") && plain.contains("a\tb\t") && plain.contains("c\t"), "cells stay copyable as tab/newline-separated text")
    #expect(doc.rawHTML == html)
}

// MARK: - Unsupported markup (safe read-only fallback)

// Corpus id: unsupported-tags. Provenance: [editor] headings/details are NOT enabled in the
// pinned editor, but other clients can still send them; the fallback must keep the text
// readable, mark the document read-only, retain rawHTML, and never emit the unknown tag.
@Test func richTextCorpusUnsupportedMarkupFallsBackSafely() throws {
    let cases: [(html: String, warning: String, forbidden: String, visible: String)] = [
        (#"<h1>Title</h1><p>body</p>"#, "Unsupported h1 formatting is read only.", "<h1", "Title"),
        (#"<details><summary>S</summary><p>body</p></details>"#, "Unsupported details formatting is read only.", "<details", "S"),
        (#"<p><span style="color:red">styled</span></p>"#, "Custom styling is read only.", "style=", "styled"),
        // Unknown data-type semantics stay on the wire (forward compatibility) but are read-only.
        (#"<p><span data-type="futureMath" data-id="x">F</span></p>"#, "Unsupported rich-text semantics are read only.", "<futureMath", "F"),
    ]
    for c in cases {
        let doc = try RichTextCodec.parse(c.html)
        #expect(!doc.canEdit, "\(c.html)")
        #expect(doc.warnings.contains(c.warning), "\(c.html)")
        #expect(doc.rawHTML == c.html, "original markup is retained for the browser fallback")
        #expect(RichTextCodec.plainText(doc).contains(c.visible), "visible text must survive: \(c.html)")
        let encoded = RichTextCodec.html(doc)
        #expect(!encoded.contains(c.forbidden), "sanitized output must not contain \(c.forbidden)")
        // The sanitized output must re-parse to something still safe.
        let reparsed = try RichTextCodec.parse(encoded)
        #expect(!RichTextCodec.html(reparsed).contains(c.forbidden))
    }
}

// MARK: - Malicious markup

// Corpus id: malicious. Provenance: dropped/allowlist design in RichText.swift; [server] only
// the documented semantic attributes are meaningful. Event handlers, executable schemes and
// embedded-content tags must never reach the encoder output.
@Test func richTextCorpusMaliciousMarkupIsNeutralized() throws {
    let html = #"<p>ok</p><script>evil()</script><style>p{color:red}</style><iframe src="https://t.example"></iframe><object data="x"></object><embed src="x"><form><input value="v"><button>b</button></form><svg><path d="M0 0"/></svg><math><mi>x</mi></math><a href="javascript:evil()" onclick="evil()">click</a><img src="https://t.example/p.png" onerror="evil()" alt="pic">"#
    let doc = try RichTextCodec.parse(html)
    #expect(!doc.canEdit)
    #expect(doc.warnings.contains("Unsafe embedded content was omitted."))
    #expect(doc.warnings.contains("An unsafe link was removed."))
    #expect(doc.warnings.contains("Inline media uses a safe native fallback."))
    #expect(RichTextCodec.plainText(doc).contains("ok"))
    #expect(RichTextCodec.plainText(doc).contains("click"))
    #expect(RichTextCodec.plainText(doc).contains("pic"))
    let encoded = RichTextCodec.html(doc)
    let lower = encoded.lowercased()
    for bad in ["<script", "<style", "<iframe", "<object", "<embed", "<form", "<input", "<button", "<svg", "<math", "onclick", "onerror", "javascript:"] {
        #expect(!lower.contains(bad), "encoder output must not contain \(bad)")
    }
    // Sanitization is idempotent.
    let reparsed = try RichTextCodec.parse(encoded)
    let again = RichTextCodec.html(reparsed).lowercased()
    for bad in ["<script", "onclick", "onerror", "javascript:"] {
        #expect(!again.contains(bad))
    }
}

// Corpus id: image-sources. Provenance: codec img rules — safe src kept, mailto:/data: src
// dropped, non-emoji images get the fallback warning, emoji identity attributes always kept.
@Test func richTextCorpusUnsafeImageSourcesAreNeutralized() throws {
    // data: URI on a custom emoji: src dropped, identity kept, no "data:" in output.
    let emoji = try RichTextCodec.parse(#"<p><img data-type="customEmoji" data-id="e" data-name="e" src="data:image/svg+xml;base64,PHN2Zz4=" alt=":e:"></p>"#)
    guard let paragraph = corpusFirstElement(emoji.nodes, "p"),
          let img = corpusElements(paragraph, "img").first else { Issue.record("img missing"); return }
    let attrs = corpusAttrs(img)
    #expect(attrs["src"] == nil)
    #expect(attrs["data-type"] == "customEmoji" && attrs["data-id"] == "e" && attrs["alt"] == ":e:")
    #expect(!emoji.canEdit, "an omitted unsafe image source must make the message read-only, not silently editable")
    #expect(emoji.warnings.contains("An unsafe image source was omitted; editing is read only."))
    #expect(!RichTextCodec.html(emoji).contains("data:"))
    #expect(RichTextCodec.plainText(emoji) == ":e:")
    // mailto: src dropped with the fallback warning.
    let mailto = try RichTextCodec.parse(#"<p><img src="mailto:x@y.z" alt="x"></p>"#)
    #expect(!mailto.canEdit)
    #expect(mailto.warnings.contains("Inline media uses a safe native fallback."))
    guard let mailtoP = corpusFirstElement(mailto.nodes, "p"), let mailtoImg = corpusElements(mailtoP, "img").first else { Issue.record("img missing"); return }
    #expect(corpusAttrs(mailtoImg)["src"] == nil)
    // Safe https image keeps src (read-only fallback for non-emoji media).
    let remote = try RichTextCodec.parse(#"<p><img src="https://cdn.example.com/p.png" onerror="evil()" alt="pic"></p>"#)
    guard let remoteP = corpusFirstElement(remote.nodes, "p"), let remoteImg = corpusElements(remoteP, "img").first else { Issue.record("img missing"); return }
    #expect(corpusAttrs(remoteImg)["src"] == "https://cdn.example.com/p.png")
    #expect(!RichTextCodec.html(remote).lowercased().contains("onerror"))
}

// Corpus id: forged-document. Provenance: encoder must defend against hand-built (not parsed)
// documents: only the permitted attribute set is emitted, with per-tag checks for href/src/start.
@Test func richTextCorpusForgedDocumentEncodingStaysSafe() throws {
    let forged = RichDocument(nodes: [
        .element("a", ["href": "javascript:evil()", "onclick": "evil()", "target": "_blank"], [.text("click")]),
        .element("img", ["src": "data:text/html,x", "srcset": "https://evil/x 2x", "onerror": "evil()", "alt": "a"], []),
        .element("ul", ["onclick": "evil()", "start": "3"], [.element("li", [:], [.text("safe")])]),
        .element("ol", ["start": "bogus"], [.element("li", [:], [.text("kept")])]),
        .element("p", ["class": "language-x"], [.text("pc")]),
        .element("span", ["data-spoiler": "true", "style": "color:red"], [.text("hidden")]),
    ])
    let html = RichTextCodec.html(forged)
    let lower = html.lowercased()
    for bad in ["javascript:", "onclick", "onerror", "srcset", "target=", "style="] {
        #expect(!lower.contains(bad), "forged attribute \(bad) must not be emitted")
    }
    #expect(!lower.contains("data:"))
    #expect(html.contains("<ul><li>safe</li></ul>"))
    #expect(html.contains("<ol><li>kept</li></ol>"), "invalid start is dropped, not emitted")
    #expect(html.contains("data-spoiler=\"true\""))
    #expect(!html.contains("class="), "class is only emitted on code elements")
    let plain = RichTextCodec.plainText(forged)
    for expected in ["click", "safe", "kept", "pc", "[Spoiler]"] { #expect(plain.contains(expected)) }
    #expect(!plain.contains("hidden"), "spoiler stays masked even in a forged document")
}

// Corpus id: edge-attribute-guards. Provenance: codec policy for attributes that must never be
// silently normalized while the document claims to be editable: multi-token code classes,
// invalid ol start, stray text in lists, class outside pre>code. These cases originally exposed
// silent drops (see RICH-TEXT-CORPUS.md findings F2-F5); root now warns and marks read-only or
// preserves the value, and this test guards that behavior.
@Test func richTextCorpusEdgeAttributeGuards() throws {
    // Multi-token code class with an optional hljs token, and c++ style languages, are preserved.
    for html in [
        #"<pre><code class="language-swift hljs">x</code></pre>"#,
        #"<pre><code class="language-c++">x</code></pre>"#,
    ] {
        let doc = try corpusRoundTrip(html)
        #expect(doc.canEdit && doc.warnings.isEmpty, "\(html)")
        #expect(RichTextCodec.html(doc).contains("class=\""), "language class lost for \(html)")
    }
    // A class that is not a single valid language token on pre>code is read-only, not silent.
    let badClass = try RichTextCodec.parse(#"<pre><code class="language-swift language-python">x</code></pre>"#)
    #expect(!badClass.canEdit)
    #expect(badClass.warnings.contains("Custom class formatting is read only."))
    #expect(!RichTextCodec.html(badClass).contains("class="))
    // class on inline code (not pre>code) is read-only.
    let inlineClass = try RichTextCodec.parse(#"<p><code class="language-swift">x</code></p>"#)
    #expect(!inlineClass.canEdit && !RichTextCodec.html(inlineClass).contains("class="))
    // Invalid / out-of-range ol start warns instead of silently resetting numbering.
    for html in [#"<ol start="abc"><li>a</li></ol>"#, #"<ol start="-2"><li>a</li></ol>"#, #"<ol start="100000"><li>a</li></ol>"#] {
        let doc = try RichTextCodec.parse(html)
        #expect(!doc.canEdit, "\(html)")
        #expect(doc.warnings.contains("Unsupported list numbering is read only."), "\(html)")
        #expect(!RichTextCodec.html(doc).contains("start="))
    }
    // Stray non-whitespace text directly inside a list is read-only; formatting whitespace is fine.
    let stray = try RichTextCodec.parse("<ul>hello<li>a</li></ul>")
    #expect(!stray.canEdit)
    #expect(stray.warnings.contains("Complex list markup is read only."))
    let tidy = try RichTextCodec.parse("<ul>\n  <li>a</li>\n</ul>")
    #expect(tidy.canEdit && tidy.warnings.isEmpty)
}

// MARK: - Boundaries

// Corpus id: boundaries. Provenance: codec limits (1 MiB, depth 64, 20 000 nodes).
@Test func richTextCorpusSizeAndDepthBoundaries() throws {
    let atLimit = "<p>" + String(repeating: "a", count: RichTextCodec.maximumBytes - 7) + "</p>"
    #expect(atLimit.utf8.count == RichTextCodec.maximumBytes)
    _ = try RichTextCodec.parse(atLimit)
    #expect(throws: RichTextError.tooLarge) { try RichTextCodec.parse(atLimit + "a") }
    #expect(throws: RichTextError.tooDeep) { try RichTextCodec.parse(String(repeating: "<span>", count: 70) + "x" + String(repeating: "</span>", count: 70)) }
    _ = try RichTextCodec.parse(String(repeating: "<span>", count: 60) + "x" + String(repeating: "</span>", count: 60))
    #expect(throws: RichTextError.tooLarge) { try RichTextCodec.parse("<p>" + String(repeating: "<em>x</em>", count: 15_000) + "</p>") }
    // 9 999 <em> + 9 999 text nodes + the wrapping <p> = 19 999 visited nodes, just under the cap.
    _ = try RichTextCodec.parse("<p>" + String(repeating: "<em>x</em>", count: 9_999) + "</p>")
}

// MARK: - Composite message

// Corpus id: composite. Provenance: mix of [server]/[editor]/[out] constructs above in one
// message; asserts identity, text preservation and spoiler privacy together.
@Test func richTextCorpusCompositeMessage() throws {
    let html = """
    <p>Hey <span data-type="userMention" data-id="alex@example.com" data-label="@Alex">@Alex</span>, see <span data-type="channelMention" data-id="CH-9" data-label="#dev">#dev</span> <img data-type="customEmoji" data-id="parrot" data-name="parrot" src="/files/parrot.png" alt=":parrot:"></p>
    <blockquote><p>quoted <a href="https://example.com/x">link</a></p></blockquote>
    <ol start="2"><li>first</li><li>second<ul><li>nested</li></ul></li></ol>
    <pre><code class="language-python">def f():\n    return 1 &lt; 2\n</code></pre>
    <p>secret: <span data-spoiler="true">the twist</span></p>
    """
    let doc = try corpusRoundTrip(html)
    #expect(doc.canEdit && doc.warnings.isEmpty)
    let encoded = RichTextCodec.html(doc)
    for fragment in ["userMention", "alex@example.com", "channelMention", "CH-9", "#dev", "customEmoji", "parrot", "/files/parrot.png", "language-python", "start=\"2\"", "data-spoiler=\"true\"", "https://example.com/x"] {
        #expect(encoded.contains(fragment), "identity fragment lost: \(fragment)")
    }
    let plain = RichTextCodec.plainText(doc)
    for expected in ["@Alex", "#dev", ":parrot:", "quoted link", "first", "second", "nested", "def f():", "return 1 < 2"] {
        #expect(plain.contains(expected), "plain text lost: \(expected)")
    }
    #expect(!plain.contains("the twist"), "spoiler body must not leak")
    #expect(plain.contains("[Spoiler]"))
    #expect(RichTextCodec.plainText(doc, revealSpoilers: true).contains("the twist"))
}
