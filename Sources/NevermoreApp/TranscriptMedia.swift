import AppKit
import NevermoreCore
import RavenProtocol

/// How pictures, link previews and files look in the transcript.
///
/// Each is one object on its own line, one click target, with its parts
/// grouped inside it: a link preview and a file are bordered cards, as in
/// Raven's web client, and a picture is the picture itself, rounded, with a
/// hairline so a white screenshot keeps its edge on a light theme. How to
/// use them (click for details, Space for Quick Look) is in the tooltip
/// rather than written into the conversation.
///
/// Cards are text attachments whose cells lay themselves out at the column's
/// width: the text system places them with the message, selection and the
/// viewport keeper treat them as one character, and nothing is a subview.
@MainActor enum TranscriptMedia {
    nonisolated static let cornerRadius: CGFloat = 8
    /// A picture's corners: `cornerRadius`, but at most a quarter of its
    /// shorter side, so a small picture stays a rounded rectangle rather
    /// than turning into a circle.
    nonisolated static func cornerRadius(for size: NSSize) -> CGFloat { min(cornerRadius, (min(size.width, size.height) / 4).rounded(.down)) }
    /// Pictures inside a card, one step inside its corners.
    nonisolated static let innerCornerRadius: CGFloat = 6
    /// The longest side of an image message or a GIF.
    nonisolated static let pictureMaximumSide: CGFloat = 320
    /// Until a picture's size is known.
    nonisolated static let pictureFallbackSize = NSSize(width: 240, height: 180)
    nonisolated static let linkCardMaximumWidth: CGFloat = 512
    nonisolated static let linkCardPadding: CGFloat = 12
    nonisolated static let linkThumbnailHeight: CGFloat = 72
    nonisolated static let linkBannerMaximumHeight: CGFloat = 280
    nonisolated static let fileCardWidth: CGFloat = 280
    nonisolated static let fileCardPadding: CGFloat = 8
    nonisolated static let fileIconSide: CGFloat = 32
    /// Cards never get narrower than this, so a narrow pane clips one
    /// rather than squeezing its text to nothing.
    nonisolated static let minimumCardWidth: CGFloat = 160
    nonisolated static let usageHint = "Click to show details. Press Space for Quick Look."

    /// The card surface: the text background, translucent so the theme's
    /// backdrop tints it, and stronger under the pointer.
    nonisolated static func cardFill(hovered: Bool) -> NSColor { NSColor.textBackgroundColor.withAlphaComponent(hovered ? 0.85 : 0.62) }
    nonisolated static func cardStroke(hovered: Bool) -> NSColor { hovered ? NSColor.themeSecondaryText.withAlphaComponent(0.55) : .separatorColor }

    /// The paragraph a picture or card sits in: its own line, with room
    /// above it when the message's text precedes it.
    static func paragraph(afterText: Bool) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = afterText ? 6 : 2
        return style
    }

    /// The attachment character carries no text of its own; a small font
    /// keeps the line from adding a text descent under the picture.
    private static let attachmentFont = NSFont.systemFont(ofSize: 1)

    /// `attachment` on a line of its own. `newLine` when the output does not
    /// already end a line.
    static func line(_ attachment: NSTextAttachment, attributes: [NSAttributedString.Key: Any], newLine: Bool, afterText: Bool) -> NSAttributedString {
        let output = NSMutableAttributedString(string: newLine ? "\n" : "", attributes: [.font: attachmentFont])
        let character = NSMutableAttributedString(attachment: attachment)
        var all = attributes
        all[.font] = attachmentFont
        // Only the attachment's own paragraph: a leading newline ends the
        // paragraph before it, which keeps its own style.
        all[.paragraphStyle] = paragraph(afterText: afterText)
        character.addAttributes(all, range: NSRange(location: 0, length: character.length))
        output.append(character)
        return output
    }

    /// A message's file name, as its address ends.
    static func filename(of message: RavenMessage) -> String? {
        guard let file = message.raw["file"].string, !file.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return URL(string: file)?.lastPathComponent ?? "Attachment"
    }

    /// The size of a staged file on disk, for its card before it is sent.
    static func stagedByteCount(_ attachment: StagedAttachment) -> Int64? {
        ((try? FileManager.default.attributesOfItem(atPath: attachment.localPath))?[.size] as? NSNumber)?.int64Value
    }

    // MARK: Pictures

    /// An image drawn at `size` with rounded corners and a hairline: `image`
    /// filling the box, or, until it arrives, a quiet box with a photo
    /// symbol and the file name. Drawn when shown, so it follows the theme.
    static func pictureImage(_ image: NSImage?, size: NSSize, name: String?) -> NSImage {
        let radius = cornerRadius(for: size)
        let picture = NSImage(size: size, flipped: false) { rect in
            drawPicture(image, in: rect, radius: radius, placeholderName: name)
            strokeHairline(around: rect, radius: radius)
            return true
        }
        picture.accessibilityDescription = name.map { "Image, \($0)" } ?? "Image"
        return picture
    }

    /// An image message's picture on its own line: one click target whose
    /// tooltip names the file, copied as its name and printed as itself.
    static func picture(_ image: NSImage?, size: NSSize, filename: String, link: URL?, animatedKey: String?, newLine: Bool, afterText: Bool) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = pictureImage(image, size: size, name: filename)
        attachment.bounds = NSRect(origin: .zero, size: size)
        var attributes: [NSAttributedString.Key: Any] = [.toolTip: "\(filename)\n\(usageHint)", .nevermorePictureName: filename]
        if let link { attributes[.link] = link }
        if let animatedKey { attributes[.nevermoreAnimatedImage] = animatedKey }
        return line(attachment, attributes: attributes, newLine: newLine, afterText: afterText)
    }

    /// Draws `image` to fill `rect`, cropping what overflows, inside rounded
    /// corners; without an image, the placeholder.
    nonisolated static func drawPicture(_ image: NSImage?, in rect: NSRect, radius: CGFloat, placeholderName: String? = nil) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
        // A mat behind the picture: transparent logos and screenshots sit on
        // a tile rather than on whatever is behind the card.
        NSColor.themeCodeBackground.setFill(); rect.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else {
            drawPlaceholderContent(in: rect, name: placeholderName)
            return
        }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawn = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let target = NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    /// The photo symbol, and below it the file name when the box has room,
    /// so a picture that cannot load still says what it is.
    private nonisolated static func drawPlaceholderContent(in rect: NSRect, name: String?) {
        guard rect.width >= 40, rect.height >= 40,
              let symbol = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: min(28, rect.height / 3), weight: .regular)) else { return }
        let tinted = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            NSColor.themeSecondaryText.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        let label = name.flatMap { name -> NSAttributedString? in
            guard rect.height >= 90, rect.width >= 90 else { return nil }
            let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byTruncatingMiddle
            return NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.themeSecondaryText, .paragraphStyle: style])
        }
        let gap: CGFloat = 6
        let labelHeight = label.map { ceil($0.size().height) } ?? 0
        let total = tinted.size.height + (label == nil ? 0 : gap + labelHeight)
        // Pictures draw unflipped (an image's own context) and in cards in
        // the flipped text view; the symbol goes above the name in both.
        let flipped = NSGraphicsContext.current?.isFlipped ?? false
        let symbolY = flipped ? rect.midY - total / 2 : rect.midY + total / 2 - tinted.size.height
        let labelY = flipped ? symbolY + tinted.size.height + gap : rect.midY - total / 2
        // Fainter than the name: a system secondary color keeps its own
        // translucency, which the fraction scales rather than replaces.
        tinted.draw(in: NSRect(x: rect.midX - tinted.size.width / 2, y: symbolY, width: tinted.size.width, height: tinted.size.height), from: .zero, operation: .sourceOver, fraction: 0.6, respectFlipped: true, hints: nil)
        label?.draw(with: NSRect(x: rect.minX + 8, y: labelY, width: rect.width - 16, height: labelHeight), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// A one-point line just inside a rounded rect, in the separator color.
    nonisolated static func strokeHairline(around rect: NSRect, radius: CGFloat, color: NSColor = .separatorColor) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: max(0, radius - 0.5), yRadius: max(0, radius - 0.5))
        path.lineWidth = 1
        color.setStroke(); path.stroke()
    }

    // MARK: Cards

    /// A file as a card: its type icon, its name and what it is. `link` nil
    /// for a file that is not sent yet, which cannot be opened.
    static func fileCard(filename: String, detail: String, link: URL?, metrics: TranscriptMetrics, newLine: Bool, afterText: Bool) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = FileCardCell(filename: filename, detail: detail, icon: TranscriptStyle.fileIcon(for: (filename as NSString).pathExtension), metrics: metrics)
        var attributes: [NSAttributedString.Key: Any] = [.nevermoreCopyText: filename, .toolTip: link == nil ? filename : "\(filename)\n\(usageHint)"]
        if let link { attributes[.link] = link }
        return line(attachment, attributes: attributes, newLine: newLine, afterText: afterText)
    }

    /// A link preview as a card under the message. It is not part of the
    /// message, so copies and printouts leave it out; the link it opens is
    /// in the message's text.
    static func linkCard(_ preview: LinkPreview, image: NSImage?, imageFailed: Bool, metrics: TranscriptMetrics, afterText: Bool) -> NSAttributedString {
        let attachment = NSTextAttachment()
        let placement = preview.imageURL == nil || imageFailed ? nil : TranscriptMediaLayout.previewPicture(pixelWidth: preview.imagePixelWidth, pixelHeight: preview.imagePixelHeight, thumbnailHeight: linkThumbnailHeight)
        attachment.attachmentCell = LinkPreviewCardCell(title: preview.title, summary: preview.summary, siteLine: LinkPreviewCard.siteLine(for: preview), placement: placement, picture: image, metrics: metrics)
        let attributes: [NSAttributedString.Key: Any] = [.link: preview.url, .toolTip: preview.url.absoluteString, .nevermoreReadingControl: true]
        return line(attachment, attributes: attributes, newLine: true, afterText: afterText)
    }
}

extension AccountSession {
    /// The box an image message's picture takes, loaded or not: see
    /// `TranscriptMediaLayout.pictureBox`.
    func pictureBox(for message: RavenMessage) -> NSSize {
        let maximum = TranscriptMedia.pictureMaximumSide
        return TranscriptMediaLayout.pictureBox(
            loaded: thumbnails[message.id].map { TranscriptMediaLayout.fit($0.size, maximumSide: maximum) },
            stored: TranscriptMediaLayout.storedImageSize(message, maximumSide: maximum),
            remembered: pictureSizes[message.id], fallback: TranscriptMedia.pictureFallbackSize)
    }
}

/// A card laid out as one attachment character on a line of its own: as
/// wide as the column allows up to `maximumWidth`, as tall as its content
/// is at that width. The text view's link on the character opens it.
///
/// Cells are not tied to the main actor: AppKit may lay out text, and so
/// size attachments, wherever it is asked to, such as for an accessibility
/// query. They hold only what they draw, fixed at creation, and the hover
/// flag the transcript sets on the main thread before it redraws them.
class TranscriptCardCell: NSTextAttachmentCell {
    let maximumWidth: CGFloat
    let label: String
    /// The pointer is over the card: it draws a stronger edge.
    var isHovered = false

    init(maximumWidth: CGFloat, label: String) {
        self.maximumWidth = maximumWidth; self.label = label
        super.init(imageCell: nil)
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The card's height at `width`; subclasses measure their content.
    nonisolated func contentHeight(forWidth width: CGFloat) -> CGFloat { 0 }
    /// Draws the content inside the card's border.
    func drawContent(in rect: NSRect) {}

    final nonisolated func width(available: CGFloat) -> CGFloat { max(TranscriptMedia.minimumCardWidth, min(maximumWidth, available.rounded(.down))) }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let width = width(available: lineFrag.width - position.x - textContainer.lineFragmentPadding)
        return NSRect(x: 0, y: 0, width: width, height: contentHeight(forWidth: width).rounded(.up))
    }
    override func cellSize() -> NSSize { NSSize(width: maximumWidth, height: contentHeight(forWidth: maximumWidth).rounded(.up)) }
    override func cellBaselineOffset() -> NSPoint { .zero }
    // Clicks go to the text view, which follows the character's link,
    // rather than starting a drag of the cell.
    override func wantsToTrackMouse() -> Bool { false }
    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int) -> Bool { false }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) { draw(cellFrame) }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) { draw(cellFrame) }
    // Selection shows as the selection color through the card's
    // translucent surface; the default highlight would cover the card.
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView?) {}

    private func draw(_ frame: NSRect) {
        let path = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: TranscriptMedia.cornerRadius - 0.5, yRadius: TranscriptMedia.cornerRadius - 0.5)
        TranscriptMedia.cardFill(hovered: isHovered).setFill(); path.fill()
        path.lineWidth = 1
        TranscriptMedia.cardStroke(hovered: isHovered).setStroke(); path.stroke()
        drawContent(in: frame)
    }

    override func accessibilityLabel() -> String? { label }
    override func accessibilityRole() -> NSAccessibility.Role? { .link }

    /// A line or two of text measured as drawn: `maximumLines` lines at
    /// most, the last one ending in an ellipsis when the text runs over.
    /// Sendable by hand: the attributed string is immutable after `init`.
    struct TextBlock: @unchecked Sendable {
        let text: NSAttributedString
        let lineHeight: CGFloat
        let maximumLines: Int

        init(_ string: String, font: NSFont, color: NSColor, maximumLines: Int, truncation: NSLineBreakMode = .byWordWrapping) {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = maximumLines == 1 ? truncation : .byWordWrapping
            // One paragraph: page text can hold line breaks.
            let flattened = string.split(whereSeparator: \.isNewline).joined(separator: " ")
            text = NSAttributedString(string: flattened, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
            lineHeight = ceil(font.ascender - font.descender + font.leading)
            self.maximumLines = maximumLines
        }

        func height(width: CGFloat) -> CGFloat {
            guard text.length > 0, width > 0 else { return 0 }
            if maximumLines == 1 { return lineHeight }
            let full = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            let lines = min(maximumLines, max(1, Int((full / lineHeight - 0.05).rounded(.up))))
            return CGFloat(lines) * lineHeight
        }

        func draw(at origin: NSPoint, width: CGFloat) {
            let height = height(width: width)
            guard height > 0 else { return }
            text.draw(with: NSRect(x: origin.x, y: origin.y, width: width, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
        }
    }
}

/// A link preview: the site, the page's title and description, and its
/// picture beside the text or, for a landscape banner, under it.
final class LinkPreviewCardCell: TranscriptCardCell {
    let placement: TranscriptMediaLayout.PreviewPicture?
    let picture: NSImage?
    nonisolated let siteText: TextBlock, titleText: TextBlock, summaryText: TextBlock
    private nonisolated static let siteGap: CGFloat = 3, summaryGap: CGFloat = 2, pictureGap: CGFloat = 12, bannerGap: CGFloat = 10

    /// `siteLine` names the site and always the address's host.
    init(title: String, summary: String, siteLine: String, placement: TranscriptMediaLayout.PreviewPicture?, picture: NSImage?, metrics: TranscriptMetrics) {
        self.placement = placement; self.picture = picture
        siteText = TextBlock(siteLine, font: .systemFont(ofSize: metrics.detailSize), color: .themeSecondaryText, maximumLines: 1, truncation: .byTruncatingMiddle)
        titleText = TextBlock(title, font: .systemFont(ofSize: max(12, metrics.size), weight: .semibold), color: .themeText, maximumLines: 2)
        summaryText = TextBlock(summary, font: .systemFont(ofSize: max(11, metrics.size - 1)), color: .themeSecondaryText, maximumLines: 2)
        super.init(maximumWidth: TranscriptMedia.linkCardMaximumWidth, label: "Link preview: \(title), \(siteLine)")
    }

    private struct Layout {
        var textWidth: CGFloat
        var textHeight: CGFloat
        var thumbnail: CGSize?
        var banner: CGSize?
        var height: CGFloat
    }

    private nonisolated func layout(width: CGFloat) -> Layout {
        let padding = TranscriptMedia.linkCardPadding
        let content = max(1, width - padding * 2)
        var thumbnail: CGSize?, banner: CGSize?
        switch placement {
        case .thumbnail(let size): thumbnail = size
        case .banner(let ratio): banner = TranscriptMediaLayout.bannerSize(heightRatio: ratio, width: content, maximumHeight: TranscriptMedia.linkBannerMaximumHeight)
        case nil: break
        }
        let textWidth = max(1, content - (thumbnail.map { $0.width + Self.pictureGap } ?? 0))
        let summaryHeight = summaryText.height(width: textWidth)
        let textHeight = siteText.height(width: textWidth) + Self.siteGap + titleText.height(width: textWidth) + (summaryHeight > 0 ? Self.summaryGap + summaryHeight : 0)
        var height = padding * 2 + max(textHeight, thumbnail?.height ?? 0)
        if let banner, banner.height > 0 { height += Self.bannerGap + banner.height }
        return Layout(textWidth: textWidth, textHeight: textHeight, thumbnail: thumbnail, banner: banner, height: height)
    }

    nonisolated override func contentHeight(forWidth width: CGFloat) -> CGFloat { layout(width: width).height }

    override func drawContent(in rect: NSRect) {
        let layout = layout(width: rect.width)
        let padding = TranscriptMedia.linkCardPadding
        let row = max(layout.textHeight, layout.thumbnail?.height ?? 0)
        // The text view is flipped: y grows downward.
        var y = rect.minY + padding + (row - layout.textHeight) / 2
        let x = rect.minX + padding
        siteText.draw(at: NSPoint(x: x, y: y), width: layout.textWidth); y += siteText.height(width: layout.textWidth) + Self.siteGap
        titleText.draw(at: NSPoint(x: x, y: y), width: layout.textWidth); y += titleText.height(width: layout.textWidth) + Self.summaryGap
        summaryText.draw(at: NSPoint(x: x, y: y), width: layout.textWidth)
        if let thumbnail = layout.thumbnail {
            let frame = NSRect(x: rect.maxX - padding - thumbnail.width, y: rect.minY + padding + (row - thumbnail.height) / 2, width: thumbnail.width, height: thumbnail.height)
            TranscriptMedia.drawPicture(picture, in: frame, radius: TranscriptMedia.innerCornerRadius)
            TranscriptMedia.strokeHairline(around: frame, radius: TranscriptMedia.innerCornerRadius)
        }
        if let banner = layout.banner, banner.height > 0 {
            let frame = NSRect(x: x, y: rect.minY + padding + row + Self.bannerGap, width: banner.width, height: banner.height)
            TranscriptMedia.drawPicture(picture, in: frame, radius: TranscriptMedia.innerCornerRadius)
            TranscriptMedia.strokeHairline(around: frame, radius: TranscriptMedia.innerCornerRadius)
        }
    }
}

/// A file: its type icon, its name on one line, shortened in the middle so
/// the extension stays, and its kind and size under it.
final class FileCardCell: TranscriptCardCell {
    private let icon: NSImage
    nonisolated let nameText: TextBlock, detailText: TextBlock
    private nonisolated static let iconGap: CGFloat = 10, lineGap: CGFloat = 1

    init(filename: String, detail: String, icon: NSImage, metrics: TranscriptMetrics) {
        self.icon = icon
        nameText = TextBlock(filename, font: .systemFont(ofSize: max(12, metrics.size - 1), weight: .medium), color: .themeText, maximumLines: 1, truncation: .byTruncatingMiddle)
        detailText = TextBlock(detail, font: .systemFont(ofSize: metrics.detailSize), color: .themeSecondaryText, maximumLines: 1, truncation: .byTruncatingTail)
        super.init(maximumWidth: TranscriptMedia.fileCardWidth, label: "File: \(filename), \(detail)")
    }

    nonisolated override func contentHeight(forWidth width: CGFloat) -> CGFloat {
        TranscriptMedia.fileCardPadding * 2 + max(TranscriptMedia.fileIconSide, nameText.lineHeight + Self.lineGap + detailText.lineHeight)
    }

    override func drawContent(in rect: NSRect) {
        let padding = TranscriptMedia.fileCardPadding, side = TranscriptMedia.fileIconSide
        icon.draw(in: NSRect(x: rect.minX + padding, y: rect.midY - side / 2, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        let x = rect.minX + padding + side + Self.iconGap
        let width = max(1, rect.maxX - padding - x)
        let textHeight = nameText.lineHeight + Self.lineGap + detailText.lineHeight
        let top = rect.midY - textHeight / 2
        nameText.draw(at: NSPoint(x: x, y: top), width: width)
        detailText.draw(at: NSPoint(x: x, y: top + nameText.lineHeight + Self.lineGap), width: width)
    }
}
