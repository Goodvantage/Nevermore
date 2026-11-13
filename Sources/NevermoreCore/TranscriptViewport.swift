import Foundation

/// The shape of the pane a transcript scrolls in. Text is readable in the
/// band between the toolbar and the floating composer; both float over the
/// scroll view, so they count as insets rather than as a smaller pane.
///
///     scroll origin ─▶ ┌───────────────┐ ─┐ ─┐
///                      │ toolbar       │  │  │ topInset
///                      ├───────────────┤  │ ─┘
///                      │ readable band │  │ clipHeight
///                      ├───────────────┤  │ ─┐
///                      │ composer      │  │  │ bottomInset
///                      └───────────────┘ ─┘ ─┘
///
/// `clipHeight` is the whole pane, both insets included.
/// Coordinates grow downwards, as in a flipped text view: the scroll
/// origin is the document position at the pane's top edge.
public struct TranscriptViewport: Sendable, Equatable {
    public var clipHeight: CGFloat
    public var topInset: CGFloat
    public var bottomInset: CGFloat
    /// The width the text wraps to. A different width moves every line.
    public var wrapWidth: CGFloat

    public init(clipHeight: CGFloat, topInset: CGFloat = 0, bottomInset: CGFloat = 0, wrapWidth: CGFloat) {
        self.clipHeight = clipHeight; self.topInset = topInset; self.bottomInset = bottomInset; self.wrapWidth = wrapWidth
    }

    /// Layout rounds heights and insets to fractions of a point; smaller
    /// differences in them do not move text.
    public static let tolerance: CGFloat = 0.5

    /// Whether text placed for `other` has to be placed again for this
    /// shape. The wrap width has no tolerance: the smallest change can move
    /// a word to the next line, and with it every line below.
    public func differs(from other: TranscriptViewport) -> Bool {
        wrapWidth != other.wrapWidth || abs(clipHeight - other.clipHeight) > Self.tolerance
            || abs(topInset - other.topInset) > Self.tolerance || abs(bottomInset - other.bottomInset) > Self.tolerance
    }

    /// The document position at the readable band's bottom edge.
    public func readableBottom(atOrigin origin: CGFloat) -> CGFloat { origin + clipHeight - bottomInset }

    /// Scroll origins from the first line resting below the toolbar to the
    /// last line resting above the composer. A document shorter than the
    /// readable band has one position, at its top.
    public func originRange(documentHeight: CGFloat) -> ClosedRange<CGFloat> {
        let top = -topInset
        return top...max(top, documentHeight + bottomInset - clipHeight)
    }
}

/// The line at the bottom of the readable band: the newest text a reader
/// has in view. Keeping it in place while the pane changes shape keeps the
/// reader's place, because a chat grows and is read from its bottom edge.
public struct TranscriptViewportAnchor: Sendable, Equatable {
    /// A character on the line. Its index survives a reflow; the line's
    /// position and the message's height do not.
    public var character: Int
    /// How far the line's bottom edge sits above the readable band's.
    /// Negative when the band's edge cuts through the line.
    public var gap: CGFloat

    public init(character: Int, gap: CGFloat) { self.character = character; self.gap = gap }

    public init(character: Int, lineBottom: CGFloat, readableBottom: CGFloat) {
        self.init(character: character, gap: readableBottom - lineBottom)
    }

    /// The scroll origin that puts the line back at its gap, now that its
    /// bottom edge is at `lineBottom`. Limited to positions the pane can
    /// scroll to, so a document that fits never leaves its top.
    public func origin(lineBottom: CGFloat, in viewport: TranscriptViewport, documentHeight: CGFloat) -> CGFloat {
        let range = viewport.originRange(documentHeight: documentHeight)
        let wanted = lineBottom + gap - (viewport.clipHeight - viewport.bottomInset)
        return min(max(wanted, range.lowerBound), range.upperBound)
    }
}
