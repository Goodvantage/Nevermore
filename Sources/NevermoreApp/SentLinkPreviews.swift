import AppKit
import ImageIO
import NevermoreCore
import RavenProtocol

/// Server-owned previews are transient and never stored with message history.
@MainActor final class SentLinkPreviews {
    private var previews: [String: LinkPreview] = [:]
    private var insertionOrder: [String] = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var attempted: [String: Date] = [:]
    private let loader: any LinkPreviewLoading = LinkPreviewLoader()

    /// Pictures load only for cards in view (`loadImage`), like an image
    /// message's picture, and are kept under `imageBudget` bytes, the least
    /// recently shown let go first. A card keeps its picture's box from the
    /// size Raven measured, so one scrolled back into view loads again in
    /// place.
    private var images: [String: NSImage] = [:]
    private var imageCosts: [String: Int] = [:]
    private var imageOrder: [String] = []
    private var imageBytes = 0
    private var imageTasks: [String: Task<Void, Never>] = [:]
    /// When a picture could not be fetched or decoded. Its card drops the
    /// picture rather than keep an empty box, and the next try waits for
    /// `imageRetryInterval`.
    private var failedImages: [String: Date] = [:]
    private let imageBudget: Int
    private static let imageRetryInterval: TimeInterval = 300
    private static let maximumImageTasks = 4

    init(imageBudget: Int = 48 * 1024 * 1024) { self.imageBudget = imageBudget }

    func reset() {
        for task in tasks.values { task.cancel() }
        for task in imageTasks.values { task.cancel() }
        tasks.removeAll(); previews.removeAll(); insertionOrder.removeAll(); attempted.removeAll()
        imageTasks.removeAll(); images.removeAll(); imageCosts.removeAll(); imageOrder.removeAll(); imageBytes = 0; failedImages.removeAll()
    }

    func preview(for raw: String) -> LinkPreview? { previews[raw] }
    func image(for raw: String) -> NSImage? { images[raw] }
    func imageFailed(_ raw: String) -> Bool { failedImages[raw] != nil }

    func ingest(_ sidecar: JSONValue) {
        for (raw, row) in sidecar.object.prefix(100) {
            guard raw.utf8.count <= 8192 else { continue }
            if let parsed = Self.decode(raw: raw, row: row) {
                if previews[raw] != parsed, tasks[raw] == nil { attempted.removeValue(forKey: raw) }
                store(parsed, for: raw)
            } else {
                previews.removeValue(forKey: raw); removeImage(for: raw)
                insertionOrder.removeAll { $0 == raw }
            }
        }
    }

    private func store(_ preview: LinkPreview, for raw: String) {
        if previews[raw] != preview { removeImage(for: raw) }
        if let index = insertionOrder.firstIndex(of: raw) {
            // Seen again (history refresh or updated preview): keep it from being evicted first.
            insertionOrder.remove(at: index)
        } else if previews.count >= 500, let oldest = insertionOrder.first {
            previews.removeValue(forKey: oldest); removeImage(for: oldest)
            insertionOrder.removeFirst()
        }
        insertionOrder.append(raw)
        previews[raw] = preview
    }

    /// Keeps a decoded picture for `raw`'s card, within the byte budget.
    func storeImage(_ image: CGImage, for raw: String) {
        removeImage(for: raw)
        let cost = image.bytesPerRow * image.height
        images[raw] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        imageCosts[raw] = cost; imageOrder.append(raw); imageBytes += cost
        while imageBytes > imageBudget, imageOrder.count > 1, let oldest = imageOrder.first {
            removeImage(for: oldest)
        }
    }

    /// Forgets a picture and any failure to fetch it.
    private func removeImage(for raw: String) {
        failedImages.removeValue(forKey: raw)
        guard images.removeValue(forKey: raw) != nil else { return }
        imageBytes -= imageCosts.removeValue(forKey: raw) ?? 0
        imageOrder.removeAll { $0 == raw }
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
        // Raven measures the picture when it stores the preview; the size
        // places it in the card before it arrives.
        let width = image == nil ? nil : TranscriptMediaLayout.dimension(row["image_width"])
        let height = image == nil ? nil : TranscriptMediaLayout.dimension(row["image_height"])
        return LinkPreview(url: url, title: String(title.prefix(300)), summary: String((row["description"].string ?? "").prefix(600)), siteName: String((row["site_name"].string ?? "").prefix(200)), imageURL: image, imagePixelWidth: width, imagePixelHeight: height)
    }

    /// Looks up `raw`'s preview: its title, description and picture's
    /// address. The picture itself loads when its card is in view.
    func request(_ raw: String, session: AccountSession) {
        guard previews[raw] == nil, !session.demo, !session.stopped, raw.utf8.count <= 8192, RichTextCodec.safeURL(raw), let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil,
              tasks[raw] == nil, tasks.count < 20, claimLookup(raw) else { return }
        let generation = session.generation
        tasks[raw] = Task { [weak self, weak session] in
            guard let self, let session else { return }
            defer { if !Task.isCancelled { self.tasks[raw] = nil }; if !session.stopped { session.notify() } }
            for delay in [0, 2, 5, 10, 20] {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                // A history refresh can bring the preview in the meantime.
                guard !Task.isCancelled, !session.stopped, session.generation == generation, self.previews[raw] == nil else { return }
                if let response = try? await session.client.rpc("raven.api.preview_links.get_previews", arguments: ["urls": .array([.string(raw)])], mutation: true),
                   let preview = Self.decode(raw: raw, row: response[raw]) {
                    guard !Task.isCancelled, !session.stopped, session.generation == generation else { return }
                    self.store(preview, for: raw)
                    return
                }
            }
        }
    }

    /// Loads the picture of `message`'s preview card, which is in view.
    func loadImage(for message: RavenMessage, session: AccountSession) {
        guard !message.html.isEmpty, case .parsed(let document) = session.messageDocument(for: message),
              let raw = SentLinkPreviewPresentation.previewedLink(of: message, in: document) else { return }
        loadImage(raw, session: session)
    }

    /// Fetches the picture of `raw`'s preview unless it is here, on its way,
    /// or failed less than `imageRetryInterval` ago. A picture here counts
    /// as shown, so the budget lets it go last.
    ///
    /// The budget holds several screens of cards (a banner card at its
    /// largest costs about 6 KB per point of its height), so the pictures in
    /// view never push each other out and load again in a loop.
    func loadImage(_ raw: String, session: AccountSession, now: Date = Date()) {
        guard let preview = previews[raw], let imageURL = preview.imageURL else { return }
        if images[raw] != nil {
            imageOrder.removeAll { $0 == raw }; imageOrder.append(raw)
            return
        }
        if let failed = failedImages[raw], now.timeIntervalSince(failed) < Self.imageRetryInterval { return }
        guard !session.demo, !session.stopped, imageTasks[raw] == nil, imageTasks.count < Self.maximumImageTasks else { return }
        let generation = session.generation
        let box = Self.pictureBox(for: preview)
        imageTasks[raw] = Task { [weak self, weak session] in
            guard let self, let session else { return }
            defer { if !Task.isCancelled { self.imageTasks[raw] = nil } }
            var picture: CGImage?
            if let data = await self.loader.imageData(for: imageURL) { picture = await Self.decodePicture(data, covering: box) }
            guard !Task.isCancelled, !session.stopped, session.generation == generation, self.previews[raw] == preview else { return }
            if let picture { self.storeImage(picture, for: raw) } else { self.failedImages[raw] = Date() }
            session.notify()
        }
    }

    /// The largest box a preview's picture is drawn in: its thumbnail, or a
    /// banner across a card as wide as cards get.
    static func pictureBox(for preview: LinkPreview) -> CGSize {
        switch TranscriptMediaLayout.previewPicture(pixelWidth: preview.imagePixelWidth, pixelHeight: preview.imagePixelHeight, thumbnailHeight: TranscriptMedia.linkThumbnailHeight) {
        case .thumbnail(let size): size
        case .banner(let ratio):
            TranscriptMediaLayout.bannerSize(heightRatio: ratio, width: TranscriptMedia.linkCardMaximumWidth - TranscriptMedia.linkCardPadding * 2, maximumHeight: TranscriptMedia.linkBannerMaximumHeight)
        }
    }

    /// Decodes a picture just large enough to fill `box` sharply on a
    /// Retina display, from its own size: Raven's measurement may be
    /// missing or out of date.
    private nonisolated static func decodePicture(_ data: Data, covering box: CGSize) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 12_000, height <= 12_000, width * height <= 40_000_000 else { return nil }
            // EXIF orientations 5 to 8 turn the picture a quarter turn.
            let turned = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue).map { (5...8).contains($0) } ?? false
            let pixels = TranscriptMediaLayout.coveringPixels(pixelWidth: turned ? height : width, pixelHeight: turned ? width : height, box: box, scale: 2)
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: max(1, pixels), kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        }.value
    }
}

@MainActor enum SentLinkPreviewPresentation {
    /// The link a message's preview is for: its first web link, as in
    /// Raven's web client, which previews one link per message. None when
    /// the sender hid the preview (`hide_link_preview`).
    static func previewedLink(of message: RavenMessage, in document: RichDocument) -> String? {
        guard !message.raw["hide_link_preview"].bool else { return nil }
        return links(in: document).first { raw in URL(string: raw)?.scheme.map { ["http", "https"].contains($0.lowercased()) } == true }
    }

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
}
