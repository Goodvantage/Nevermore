import CoreGraphics
import Foundation
import RavenProtocol

/// Sizes for pictures and link preview images in the transcript, decided
/// from the dimensions Raven stores before any image arrives, so a picture
/// that loads, or leaves the cache, moves nothing around it.
///
/// The rules follow Raven's web client (`LinkPreviewCard.tsx`,
/// `ReservedImage.tsx`), so a conversation reads the same in both: a link
/// preview's picture is a banner under its text only when it is a real
/// landscape banner, and a thumbnail beside the text otherwise.
public enum TranscriptMediaLayout {
    /// A preview picture at least this many pixels wide and this much wider
    /// than tall fills the card under its text; Raven's web client draws the
    /// same line.
    public static let bannerMinimumPixelWidth = 400
    public static let bannerMinimumAspectRatio: CGFloat = 1.4
    /// Thumbnails keep their shape within these width-to-height ratios and
    /// are cropped beyond them, so a sliver of an image cannot squeeze the
    /// card's text or leave a thin stripe beside it.
    public static let thumbnailAspectRange: ClosedRange<CGFloat> = 0.75...1.6

    public enum PreviewPicture: Equatable, Sendable {
        /// Beside the text, at the given size.
        case thumbnail(CGSize)
        /// Under the text, as wide as the card allows; height over width.
        case banner(heightRatio: CGFloat)
    }

    /// Where a link preview's picture goes and how big it is. Unknown
    /// dimensions (previews stored before Raven measured them) get a square
    /// thumbnail that crops, rather than a box that changes shape later.
    public static func previewPicture(pixelWidth: Int?, pixelHeight: Int?, thumbnailHeight: CGFloat) -> PreviewPicture {
        guard let width = pixelWidth, let height = pixelHeight, width > 0, height > 0 else {
            return .thumbnail(CGSize(width: thumbnailHeight, height: thumbnailHeight))
        }
        let ratio = CGFloat(width) / CGFloat(height)
        if ratio >= bannerMinimumAspectRatio, width >= bannerMinimumPixelWidth { return .banner(heightRatio: CGFloat(height) / CGFloat(width)) }
        let shape = min(thumbnailAspectRange.upperBound, max(thumbnailAspectRange.lowerBound, ratio))
        return .thumbnail(CGSize(width: (thumbnailHeight * shape).rounded(), height: thumbnailHeight))
    }

    /// A banner's size in a card whose content is `width` wide: the full
    /// width, unless that would make it taller than `maximumHeight`.
    public static func bannerSize(heightRatio: CGFloat, width: CGFloat, maximumHeight: CGFloat) -> CGSize {
        guard heightRatio > 0, width > 0 else { return .zero }
        let height = width * heightRatio
        guard height > maximumHeight else { return CGSize(width: width.rounded(.down), height: height.rounded()) }
        return CGSize(width: (maximumHeight / heightRatio).rounded(.down), height: maximumHeight.rounded())
    }

    /// `size` scaled down to fit a square of `maximumSide`, never enlarged,
    /// in whole points of at least one point per side.
    public static func fit(_ size: CGSize, maximumSide: CGFloat) -> CGSize {
        guard size.width > 0, size.height > 0, maximumSide > 0 else { return .zero }
        let scale = min(1, maximumSide / max(size.width, size.height))
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    /// The longer side, in pixels, to decode a `pixelWidth` by `pixelHeight`
    /// picture at so that, cropped to fill `box` points at `scale` pixels per
    /// point, it stays sharp; never more than the picture has. Zero when
    /// any size is unusable.
    public static func coveringPixels(pixelWidth: Int, pixelHeight: Int, box: CGSize, scale: CGFloat) -> Int {
        guard pixelWidth > 0, pixelHeight > 0, box.width > 0, box.height > 0, scale > 0 else { return 0 }
        let width = CGFloat(pixelWidth), height = CGFloat(pixelHeight), longer = max(width, height)
        // Multiplied before dividing, so a box that matches the picture's
        // shape gives a whole number rather than one a rounding error over.
        let byWidth = box.width * scale * longer / width, byHeight = box.height * scale * longer / height
        return Int(min(longer, max(byWidth, byHeight)).rounded(.up))
    }

    /// The box an image message's picture takes. Before the picture loads:
    /// the box it had when it last loaded, else the size Raven stored for it,
    /// else `fallback`. Once loaded: its own size, unless the stored size has
    /// the same shape, which then stays, so loading moves nothing.
    public static func pictureBox(loaded: CGSize?, stored: CGSize?, remembered: CGSize?, fallback: CGSize) -> CGSize {
        guard let loaded, loaded.width > 0, loaded.height > 0 else { return remembered ?? stored ?? fallback }
        if let stored, stored.width > 0, stored.height > 0 {
            let shape = stored.width / stored.height
            if abs(loaded.width / loaded.height - shape) <= shape * 0.02 { return stored }
        }
        return loaded
    }

    /// The box an image message keeps for its picture, from the size Raven
    /// stores for the image's server thumbnail (`thumbnail_width`,
    /// `thumbnail_height`). Those fields are Data fields, so they arrive as
    /// numbers or as text. Nil when the message has no usable size.
    public static func storedImageSize(_ message: RavenMessage, maximumSide: CGFloat) -> CGSize? {
        guard let width = dimension(message.raw["thumbnail_width"]), let height = dimension(message.raw["thumbnail_height"]) else { return nil }
        return fit(CGSize(width: width, height: height), maximumSide: maximumSide)
    }

    /// A positive pixel count below a sanity bound; anything else is unusable.
    public static func dimension(_ value: JSONValue) -> Int? {
        guard let count = value.nonnegativeCount, count > 0, count <= 100_000 else { return nil }
        return Int(count)
    }
}
