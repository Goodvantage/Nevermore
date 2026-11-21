import Foundation

/// A GIF sent as its own message, in the form Raven's GIF picker used:
/// `<p><img src="…" alt="…"></p>`, the image hotlinked from the GIF service.
///
/// Both GIF services forbid storing copies of their media, so the GIF is
/// not uploaded to the Raven site; every reader's client loads it from the
/// service. The body has no text, which Raven's idempotent send refuses
/// ("Cannot send an empty message"); `Session` therefore sends these
/// through Raven's plain send, which has no client idempotency key. An
/// uncertain attempt waits for explicit review instead of replaying itself,
/// and a deliberate retry posts the GIF again.
public enum GIFMessage {
    /// The message body for `item`.
    public static func html(for item: GIFItem) -> String {
        let alt = item.title.isEmpty ? "GIF" : item.title
        let image = RichNode.element("img", ["src": item.message.url.absoluteString, "alt": alt], [])
        return RichTextCodec.html(RichDocument(nodes: [.element("p", [:], [image])]))
    }

    /// The GIF's address when `html` is exactly one paragraph holding one
    /// image from a GIF service, else nil.
    public static func source(in html: String) -> URL? {
        document(html).flatMap(source(in:))
    }

    /// A GIF body is one short paragraph; anything longer is not one.
    private static func document(_ html: String) -> RichDocument? {
        guard html.utf8.count <= 16_384 else { return nil }
        return try? RichTextCodec.parse(html)
    }

    /// The GIF's address when `document` is exactly one paragraph holding
    /// one image from a GIF service, else nil.
    public static func source(in document: RichDocument) -> URL? {
        let blocks = document.nodes.filter { !isBlank($0) }
        guard blocks.count == 1, case .element("p", let paragraph, let children) = blocks[0], paragraph.isEmpty else { return nil }
        let inline = children.filter { !isBlank($0) }
        guard inline.count == 1, case .element("img", let attributes, _) = inline[0], attributes["data-type"] == nil, let src = attributes["src"] else { return nil }
        return GIFMediaPolicy.mediaURL(src)
    }

    /// The body as it is stored and sent, or `RichTextError.unsafeEdit`
    /// when it is not a lone GIF.
    public static func validatedHTML(_ html: String) throws -> String {
        guard let document = document(html), source(in: document) != nil else { throw RichTextError.unsafeEdit }
        return RichTextCodec.html(document)
    }

    private static func isBlank(_ node: RichNode) -> Bool {
        if case .text(let text) = node { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return false
    }
}

extension SendOperation {
    /// A GIF picked in the conversation rather than a composed message.
    public var isGIF: Bool { attachments.isEmpty && GIFMessage.source(in: html) != nil }
}
