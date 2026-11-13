import AppKit
import NevermoreCore

/// Keeps a transcript's bottom edge where the reader left it while its pane
/// changes shape.
///
/// AppKit holds on to the top of a scrolled text view. A shorter pane cuts
/// off its bottom, so the newest messages end up behind the composer, and a
/// new width keeps the first visible line while everything below it moves.
/// A chat is read from its bottom edge, so the keeper remembers the line at
/// the bottom of the readable band whenever the reader scrolls and puts
/// that line back whenever the clip view, the wrap width or the content
/// insets change. A transcript that follows its newest message stays on it.
///
///     the reader scrolls      ─▶ remember the bottom line and the shape
///     the shape changes       ─▶ lay the text out again, put the line back
///     a live resize ends      ─▶ put the line back once more
///     the owner replaces text ─▶ nothing, until the owner calls `capture()`
///
/// Putting the line back is not a scroll by the reader, so it does not
/// replace what is remembered. A drag that narrows a window and widens it
/// again ends where it began, even when an end of the document stopped the
/// text on the way.
@MainActor final class TranscriptViewportKeeper {
    private let scrollView: NSScrollView
    private let textView: LiveResizeTextView

    /// Whether the transcript follows its newest message. Asked when the
    /// shape changes: the owner can decide to follow without scrolling.
    var isFollowing: () -> Bool = { false }

    /// The text moved in the pane: the reader scrolled, or the keeper put
    /// the bottom line back.
    var onMove: () -> Void = {}

    /// Set while the pane does not show what the owner is about to place:
    /// the text is being replaced, or belongs to a conversation the window
    /// has left. Scrolls are still reported, but nothing is remembered or
    /// put back until the owner clears this and calls `capture()`.
    var isReplacingText = false

    private var viewport: TranscriptViewport?
    private var anchor: TranscriptViewportAnchor?
    private var isPlacing = false
    /// AppKit is scrolling the text view to finish a live resize.
    private var isEndingLiveResize = false
    private var observers: [NSObjectProtocol] = []

    init(scrollView: NSScrollView, textView: LiveResizeTextView) {
        self.scrollView = scrollView; self.textView = textView
        textView.liveResizeWillEnd = { [weak self] in self?.isEndingLiveResize = true }
        textView.liveResizeDidEnd = { [weak self] in self?.liveResizeDidEnd() }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true; clip.postsFrameChangedNotifications = true
        observe(NSView.boundsDidChangeNotification, of: clip) { $0.clipDidScroll() }
        // Posted once the clip view has resized the text view and the text
        // view has rewrapped and moved its first line back into place, so a
        // placement made here is not undone by AppKit.
        observe(NSView.frameDidChangeNotification, of: clip) { $0.viewportDidChange() }
    }

    /// No queue: the block runs inside the layout pass that posted the
    /// notification, so the line is back before the new shape is drawn.
    private func observe(_ name: Notification.Name, of view: NSView, _ handler: @escaping @MainActor (TranscriptViewportKeeper) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { if let self { handler(self) } }
        })
    }

    func invalidate() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        textView.liveResizeWillEnd = nil; textView.liveResizeDidEnd = nil
    }

    /// Remembers where the reader is. Every scroll does; the owner calls
    /// it after replacing the text and placing it.
    func capture() {
        guard !isPlacing, !isReplacingText else { return }
        viewport = currentViewport
        anchor = bottomLine()
    }

    /// Puts the reader's place back if the pane changed shape. The clip
    /// view reports its own frame, and with it the wrap width; the owner
    /// reports new content insets, which nothing announces.
    func viewportDidChange() {
        guard let placed = viewport, currentViewport.differs(from: placed) else { return }
        place()
    }

    /// AppKit's scroll at the end of a live resize is over. Whatever it
    /// chose, and whether or not it rewrapped the text, the line goes back.
    private func liveResizeDidEnd() {
        isEndingLiveResize = false
        if viewport != nil { place() }
    }

    private func place() {
        guard !isPlacing, !isReplacingText, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        isPlacing = true
        defer { isPlacing = false }
        // The whole document: the text above the line decides where the
        // line is, the text below it how far the pane can scroll.
        layout.ensureLayout(for: container)
        if isFollowing() { textView.scrollToEndOfDocument(nil) }
        else if let anchor, let lineBottom = lineBottom(containing: anchor.character) {
            scroll(to: anchor.origin(lineBottom: lineBottom, in: currentViewport, documentHeight: textView.frame.height))
        }
        // The shape the pane ends up with: laying out can show or hide a
        // legacy scroller, which changes the wrap width once more.
        viewport = currentViewport
        onMove()
    }

    private func clipDidScroll() {
        // The keeper's own scroll, which `place` reports, or AppKit's at
        // the end of a live resize, which `place` is about to replace.
        guard !isPlacing, !isEndingLiveResize else { return }
        guard !isReplacingText else { onMove(); return }
        // AppKit scrolls the clip view while it reshapes the pane: a text
        // view moves its first visible line back into place after a new
        // width. Those are not the reader's scrolls. The text is placed
        // when the clip view reports its frame or the owner new insets.
        if let viewport, currentViewport.differs(from: viewport) { return }
        onMove()
        capture()
    }

    private var currentViewport: TranscriptViewport {
        let insets = scrollView.contentInsets
        return TranscriptViewport(clipHeight: scrollView.contentView.bounds.height, topInset: insets.top, bottomInset: insets.bottom, wrapWidth: textView.textContainer?.size.width ?? 0)
    }

    private func bottomLine() -> TranscriptViewportAnchor? {
        guard let layout = textView.layoutManager, let container = textView.textContainer, layout.numberOfGlyphs > 0 else { return nil }
        let readableBottom = currentViewport.readableBottom(atOrigin: scrollView.contentView.bounds.minY)
        let containerTop = textView.textContainerOrigin.y
        // One point inside the band: a line that starts at its edge is not in view.
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: readableBottom - containerTop - 1), in: container)
        var line = NSRange()
        let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line)
        return TranscriptViewportAnchor(character: layout.characterIndexForGlyph(at: line.location), lineBottom: rect.maxY + containerTop, readableBottom: readableBottom)
    }

    private func lineBottom(containing character: Int) -> CGFloat? {
        guard let layout = textView.layoutManager, layout.numberOfGlyphs > 0 else { return nil }
        // A remembered character can lie past the end of text cleared since.
        let glyph = min(layout.glyphIndexForCharacter(at: max(0, character)), layout.numberOfGlyphs - 1)
        return layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).maxY + textView.textContainerOrigin.y
    }

    private func scroll(to y: CGFloat) {
        let clip = scrollView.contentView
        // A whole point, which is a whole pixel at every scale. AppKit
        // rounds a fractional origin when the document next changes size,
        // and that scroll would pass for the reader's.
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y.rounded()))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// A text view that says when a live resize ends. While a window edge or a
/// split divider is dragged, AppKit's text view puts off its own scrolling;
/// when the drag ends it scrolls the line that was first in view at the
/// start of the drag back to the top of the pane. The keeper lets it, then
/// puts the reader's bottom line back.
@MainActor class LiveResizeTextView: NSTextView {
    var liveResizeWillEnd: (() -> Void)?
    var liveResizeDidEnd: (() -> Void)?

    override func viewDidEndLiveResize() {
        liveResizeWillEnd?()
        super.viewDidEndLiveResize()
        liveResizeDidEnd?()
    }
}
