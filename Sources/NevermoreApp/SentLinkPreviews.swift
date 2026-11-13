import AppKit
import ImageIO
import NevermoreCore
import RavenProtocol

/// Server-owned previews are transient and never stored with message history.
@MainActor final class SentLinkPreviews {
    private var previews: [String: LinkPreview] = [:]
    private var insertionOrder: [String] = []
    private var images: [String: NSImage] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var attempted: [String: Date] = [:]
    private let loader: any LinkPreviewLoading = LinkPreviewLoader()

    func reset() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll(); previews.removeAll(); insertionOrder.removeAll(); images.removeAll(); attempted.removeAll()
    }

    func preview(for raw: String) -> LinkPreview? { previews[raw] }
    func image(for raw: String) -> NSImage? { images[raw] }

    func ingest(_ sidecar: JSONValue) {
        for (raw, row) in sidecar.object.prefix(100) {
            guard raw.utf8.count <= 8192 else { continue }
            if let parsed = Self.decode(raw: raw, row: row) {
                if previews[raw] != parsed, tasks[raw] == nil { attempted.removeValue(forKey: raw) }
                store(parsed, for: raw)
            } else {
                previews.removeValue(forKey: raw); images.removeValue(forKey: raw)
                insertionOrder.removeAll { $0 == raw }
            }
        }
    }

    private func store(_ preview: LinkPreview, for raw: String) {
        if previews[raw] != preview { images.removeValue(forKey: raw) }
        if previews[raw] == nil {
            if previews.count >= 500, let oldest = insertionOrder.first {
                previews.removeValue(forKey: oldest); images.removeValue(forKey: oldest)
                insertionOrder.removeFirst()
            }
            insertionOrder.append(raw)
        }
        previews[raw] = preview
    }

    // History refreshes can be frequent. Retain misses for five minutes so
    // unpreviewable links do not start a new polling cycle on every refresh.
    func claimLookup(_ raw: String, at now: Date = Date()) -> Bool {
        if let last = attempted[raw], now.timeIntervalSince(last) < 300 { return false }
        if attempted.count >= 500 {
            attempted = attempted.filter { now.timeIntervalSince($0.value) < 300 }
        }
        guard attempted[raw] != nil || attempted.count < 500 else { return false }
        attempted[raw] = now
        return true
    }

    static func decode(raw: String, row: JSONValue) -> LinkPreview? {
        guard raw.utf8.count <= 8192, RichTextCodec.safeURL(raw), let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil,
              let title = row["title"].string, !title.isEmpty else { return nil }
        let image = row["image"].string.flatMap(URL.init(string:)).flatMap { LinkPreviewPolicy.isEligible($0) ? $0 : nil }
        return LinkPreview(url: url, title: String(title.prefix(300)), summary: String((row["description"].string ?? "").prefix(600)), siteName: String((row["site_name"].string ?? "").prefix(200)), imageURL: image)
    }

    func request(_ raw: String, session: AccountSession) {
        if let preview = previews[raw], preview.imageURL == nil || images[raw] != nil { return }
        guard !session.demo, !session.stopped, raw.utf8.count <= 8192, RichTextCodec.safeURL(raw), let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil,
              tasks[raw] == nil, tasks.count < 20, claimLookup(raw) else { return }
        let generation = session.generation
        tasks[raw] = Task { [weak self, weak session] in
            guard let self, let session else { return }
            defer { if !Task.isCancelled { self.tasks[raw] = nil }; if !session.stopped { session.notify() } }
            for delay in [0, 2, 5, 10, 20] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled, !session.stopped, session.generation == generation else { return }
                if self.previews[raw] == nil {
                    if let response = try? await session.client.rpc("raven.api.preview_links.get_previews", arguments: ["urls": .array([.string(raw)])], mutation: true),
                       let preview = Self.decode(raw: raw, row: response[raw]) {
                        guard !Task.isCancelled, !session.stopped, session.generation == generation else { return }
                        self.store(preview, for: raw)
                        session.notify()
                    }
                }
                if let preview = self.previews[raw] {
                    if let imageURL = preview.imageURL, let data = await self.loader.imageData(for: imageURL),
                       let thumbnail = await Self.thumbnail(data), !Task.isCancelled, !session.stopped, session.generation == generation {
                        self.images[raw] = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
                        session.notify()
                    }
                    return
                }
            }
        }
    }

    private nonisolated static func thumbnail(_ data: Data) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 12_000, height <= 12_000, width * height <= 40_000_000 else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 192, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        }.value
    }
}

@MainActor enum SentLinkPreviewPresentation {
    static func links(in document: RichDocument) -> [String] {
        var result: [String] = []
        func visit(_ node: RichNode) {
            guard case .element(let tag, let attrs, let children) = node, attrs["data-spoiler"] == nil, tag != "pre", tag != "code" else { return }
            if tag == "a", let url = attrs["href"], !result.contains(url) { result.append(url) }
            for child in children { visit(child) }
        }
        for node in document.nodes { visit(node) }
        return Array(result.prefix(10))
    }

    static func card(_ preview: LinkPreview, image: NSImage?, size: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "\n")
        if let image {
            let attachment = NSTextAttachment(); attachment.image = image
            let scale = min(1, 80 / max(image.size.width, image.size.height))
            attachment.bounds = NSRect(x: 0, y: 0, width: image.size.width * scale, height: image.size.height * scale)
            result.append(NSAttributedString(attachment: attachment)); result.append(NSAttributedString(string: "\n"))
        }
        let background = NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
        result.append(NSAttributedString(string: "  \(preview.title)  ", attributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.linkColor, .backgroundColor: background, .link: preview.url]))
        if !preview.summary.isEmpty { result.append(NSAttributedString(string: "\n  \(preview.summary)  ", attributes: [.font: NSFont.systemFont(ofSize: max(11, size - 1)), .foregroundColor: NSColor.themeText, .backgroundColor: background])) }
        result.append(NSAttributedString(string: "\n  \(LinkPreviewCard.siteLine(for: preview))  ", attributes: [.font: NSFont.systemFont(ofSize: max(10, size - 2)), .foregroundColor: NSColor.themeSecondaryText, .backgroundColor: background]))
        return result
    }
}
