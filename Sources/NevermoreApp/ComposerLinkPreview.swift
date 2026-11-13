import AppKit
import ImageIO
import NevermoreCore

/// Decides which link of a draft gets a preview card, and loads it.
///
/// The card belongs to the person writing: it shows what the link leads to
/// before the message goes out. It is not part of the message; Raven builds
/// its own previews for readers.
@MainActor final class ComposerLinkPreview {
    struct Content {
        var preview: LinkPreview
        var image: NSImage?
    }

    /// Called whenever `content` changed.
    var onChange: (() -> Void)?
    private(set) var content: Content?

    /// The address the card is for, loaded or still loading.
    private var target: URL?
    private var task: Task<Void, Never>?

    /// A link whose text is being edited changes with every key; the page
    /// is fetched once the typing pauses.
    private static let settleDelay = Duration.milliseconds(400)
    private nonisolated static let thumbnailPixels = 192
    /// Decoding limits for a picture a web page chose.
    private nonisolated static let maximumImageSide = 12_000
    private nonisolated static let maximumImagePixels = 40_000_000

    /// Show the first eligible link in the current draft.
    func update(links: [URL], loader: (any LinkPreviewLoading)?, draft: String) {
        let wanted = ComposerPreferences.showsLinkPreviews && loader != nil ? links.first : nil
        guard wanted != target else { return }

        target = wanted
        task?.cancel()
        task = nil
        if content != nil {
            content = nil
            onChange?()
        }
        guard let wanted, let loader else { return }

        task = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, let preview = await loader.preview(for: wanted) else { return }
            guard !Task.isCancelled, let self, self.target == wanted else { return }
            self.content = Content(preview: preview, image: nil)
            self.onChange?()

            guard let imageURL = preview.imageURL, let data = await loader.imageData(for: imageURL),
                  let thumbnail = await Self.thumbnail(from: data), !Task.isCancelled, self.target == wanted else { return }
            self.content?.image = NSImage(cgImage: thumbnail, size: NSSize(width: thumbnail.width, height: thumbnail.height))
            self.onChange?()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// A small bitmap of the picture, made by ImageIO without decoding the
    /// full image, and only when the file declares a sane size.
    private nonisolated static func thumbnail(from data: Data) async -> CGImage? {
        await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= maximumImageSide, height <= maximumImageSide, width * height <= maximumImagePixels else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}

/// Stands in for the network in demo sessions: every link gets a card and
/// nothing is fetched.
struct DemoLinkPreviews: LinkPreviewLoading {
    func preview(for url: URL) async -> LinkPreview? {
        guard LinkPreviewPolicy.isEligible(url), let host = url.host else { return nil }
        return LinkPreview(
            url: url,
            title: "Preview of \(host)",
            summary: "Demo conversations stay off the network. With an account, the page's title, description and picture appear here.",
            siteName: host,
            imageURL: nil
        )
    }

    func imageData(for url: URL) async -> Data? { nil }
}

/// The preview of one link, shown above the composer's text.
@MainActor final class LinkPreviewCard: NSView {
    private let picture = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let site = NSTextField(labelWithString: "")

    /// How strongly the card wants its preferred width. The split view
    /// holds its panes at 250 and above, a divider drag has 490, and the
    /// thread inspector's width 500. The card stays below all of them: at a
    /// higher priority it kept the conversation wider than a narrow window.
    static let widthPriority = NSLayoutConstraint.Priority(240)
    /// Labels adapt before the card does: long text truncates, and short
    /// text fills the available column rather than shrinking the card.
    private static let textWidthPriority = NSLayoutConstraint.Priority(230)
    private static let pictureSide: CGFloat = 44
    private static let cornerRadius: CGFloat = 9
    private static let padding: CGFloat = 6

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor

        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerRadius = 6
        picture.layer?.masksToBounds = true
        picture.setAccessibilityElement(false)

        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        summary.maximumNumberOfLines = 2
        summary.cell?.truncatesLastVisibleLine = true
        summary.isSelectable = false
        site.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        site.textColor = .secondaryLabelColor
        site.lineBreakMode = .byTruncatingMiddle
        for label in [title, summary, site] {
            label.setContentCompressionResistancePriority(Self.textWidthPriority, for: .horizontal)
            label.setContentHuggingPriority(Self.textWidthPriority, for: .horizontal)
        }

        let text = NSStackView(views: [title, summary, site])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        // A short title must not squeeze a wrapping description into its
        // intrinsic width. Every line uses the available text column.
        for label in [title, summary, site] { label.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true }
        // The picture and the text; a hidden picture gives its room to the text.
        let content = NSStackView(views: [picture, text])
        content.alignment = .top
        content.spacing = 8
        for view in [content] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // The card's size is pinned to its content with required
        // constraints. A stack view's edge insets are only preferences,
        // and the composer bar would squeeze them.
        NSLayoutConstraint.activate([
            picture.widthAnchor.constraint(equalToConstant: Self.pictureSide), picture.heightAnchor.constraint(equalToConstant: Self.pictureSide),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.padding + 1),
            content.topAnchor.constraint(equalTo: topAnchor, constant: Self.padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.padding),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Everything shown is plain text taken from the page; none of it is
    /// interpreted as markup.
    func show(_ content: ComposerLinkPreview.Content) {
        let preview = content.preview
        title.stringValue = preview.title
        summary.stringValue = preview.summary
        summary.isHidden = preview.summary.isEmpty
        site.stringValue = Self.siteLine(for: preview)
        picture.image = content.image
        picture.isHidden = content.image == nil
        toolTip = preview.url.absoluteString
        setAccessibilityLabel("Link preview: \(preview.title), \(site.stringValue)")
    }

    /// The host of the address as written always shows, so a page cannot
    /// pass for another site through its own site name.
    static func siteLine(for preview: LinkPreview) -> String {
        var host = preview.url.host?.lowercased() ?? ""
        if host.hasPrefix("www.") { host.removeFirst("www.".count) }
        let name = preview.siteName
        guard !name.isEmpty, name.lowercased() != host, name.lowercased() != "www." + host else { return host }
        return host.isEmpty ? name : "\(name) · \(host)"
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = NSColor.tertiarySystemFill.cgColor }
    }
}
