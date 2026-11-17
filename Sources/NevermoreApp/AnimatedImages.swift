import AppKit
import NevermoreCore
import QuartzCore

extension NSAttributedString.Key {
    /// Marks a transcript image attachment that has animated frames. The
    /// value is the frames' key in `AnimatedImageCache`.
    static let nevermoreAnimatedImage = NSAttributedString.Key("Nevermore.AnimatedImage")
    /// Marks the fallback text of an `<img>` in a message body that is not
    /// a custom emoji. The value is an `InlineImageSource`.
    static let nevermoreInlineImage = NSAttributedString.Key("Nevermore.InlineImage")
}

/// The `src` of one `<img>`, unvalidated. Equal only to itself, so the
/// same GIF twice side by side stays two runs of text, not one.
final class InlineImageSource: NSObject, Sendable {
    let src: String
    init(_ src: String) { self.src = src }
}

/// Names animated images in `AnimatedImageCache`.
enum AnimatedImageKey {
    /// The file of an Image message.
    static func message(_ id: String) -> String { "message:\(id)" }
    /// A GIF embedded in a message body by its address.
    static func remote(_ url: URL) -> String { "url:\(url.absoluteString)" }
}

/// Decoded animated images of one account, shared by its windows.
///
/// Decoded frames are large, so the cache holds a byte budget rather than a
/// count and forgets the images least recently shown first. A forgotten
/// image still has its first frame in the transcript's attachment; it plays
/// again once it is decoded again.
@MainActor final class AnimatedImageCache {
    private var images: [String: AnimatedImage] = [:]
    private var order: [String] = []
    private var bytes = 0
    /// Source sizes of the images held so far, kept after their frames go,
    /// so a GIF waiting to be decoded again keeps its place in the layout.
    private var sizes: [String: CGSize] = [:]
    private static let maximumSizes = 4096
    let budget: Int

    init(budget: Int = 160 * 1024 * 1024) { self.budget = budget }

    subscript(key: String) -> AnimatedImage? {
        guard let image = images[key] else { return nil }
        touch(key)
        return image
    }

    func contains(_ key: String) -> Bool { images[key] != nil }

    func sourceSize(_ key: String) -> CGSize? { sizes[key] }

    func insert(_ image: AnimatedImage, for key: String) {
        if let old = images[key] { bytes -= old.decodedBytes }
        images[key] = image
        if sizes.count >= Self.maximumSizes { sizes.removeAll() }
        sizes[key] = image.sourcePixelSize
        bytes += image.decodedBytes
        touch(key)
        while bytes > budget, order.count > 1, let oldest = order.first {
            order.removeFirst()
            if let removed = images.removeValue(forKey: oldest) { bytes -= removed.decodedBytes }
        }
    }

    func removeAll() { images.removeAll(); order.removeAll(); sizes.removeAll(); bytes = 0 }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// The still shown in the text attachment: the first frame, at the size
    /// the attachment would have for a still image of the source's size.
    static func still(_ image: AnimatedImage, maxSide: CGFloat) -> NSImage? {
        guard let first = image.frames.first else { return nil }
        return NSImage(cgImage: first, size: displaySize(image.sourcePixelSize, maxSide: maxSide))
    }

    static func displaySize(_ source: CGSize, maxSide: CGFloat) -> NSSize {
        let scale = min(1, maxSide / max(source.width, source.height, 1))
        return NSSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
    }
}

/// Plays one animated image through Core Animation, so no frame is decoded
/// or drawn on the main thread while it runs.
///
/// It takes no clicks and is hidden from accessibility: the text
/// attachment below it, which shows the first frame, stays the target for
/// clicks, selection, drags and VoiceOver.
@MainActor final class AnimatedImageView: NSView {
    static let animationKey = "Nevermore.AnimatedFrames"
    let key: String
    private(set) var image: AnimatedImage

    init(key: String, image: AnimatedImage, frame: NSRect) {
        self.key = key; self.image = image
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.contents = image.frames.first
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isPlaying: Bool { layer?.animation(forKey: Self.animationKey) != nil }

    func show(_ image: AnimatedImage, animates: Bool) {
        self.image = image
        layer?.contents = image.frames.first
        // A running animation would go on showing the old frames.
        layer?.removeAnimation(forKey: Self.animationKey)
        setPlaying(animates)
    }

    func setPlaying(_ playing: Bool) {
        guard let layer else { return }
        guard playing, image.isAnimated, image.duration > 0 else {
            layer.removeAnimation(forKey: Self.animationKey)
            return
        }
        guard !isPlaying else { return }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = image.frames
        // Discrete mode wants one key time more than values, ending at 1.
        animation.keyTimes = (image.keyTimes + [1]).map { NSNumber(value: $0) }
        animation.calculationMode = .discrete
        animation.duration = image.duration
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: Self.animationKey)
    }
}

/// Keeps an `AnimatedImageView` over each animated attachment in the
/// visible part of a TextKit 1 text view.
///
/// Views are subviews of the text view, so scrolling moves them with the
/// text; they are placed again only when the text, the wrap width or the
/// visible band changes. Attachments scrolled out of view lose their view,
/// so offscreen GIFs cost nothing.
@MainActor final class AnimatedImageOverlay {
    private unowned let textView: NSTextView
    private let images: (String) -> AnimatedImage?
    /// Whether images play. Off under Reduce Motion, where the first
    /// frame stays.
    var animates: () -> Bool = { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Placed views by attachment character location.
    private(set) var views: [Int: AnimatedImageView] = [:]
    private var observers: [NSObjectProtocol] = []
    /// Extra height above and below the visible rect where views are kept,
    /// so a short scroll does not rebuild them.
    private let margin: CGFloat = 400
    private var layoutScheduled = false
    private var invalidated = false

    init(textView: NSTextView, scrollView: NSScrollView, images: @escaping (String) -> AnimatedImage?) {
        self.textView = textView; self.images = images
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        observe(NSView.boundsDidChangeNotification, of: clip)
        observe(NSView.frameDidChangeNotification, of: textView)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPlayback() }
        })
    }

    private func observe(_ name: Notification.Name, of view: NSView) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: view, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
    }

    func invalidate() {
        invalidated = true
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
        removeAll()
    }

    func removeAll() {
        for view in views.values { view.removeFromSuperview() }
        views.removeAll()
    }

    func refreshPlayback() {
        let playing = animates()
        for view in views.values { view.setPlaying(playing) }
    }

    /// Places views for the animated attachments near the visible rect and
    /// removes the others.
    func update() { update(layingOut: false) }

    private func update(layingOut: Bool) {
        guard !invalidated, let layout = textView.layoutManager, let container = textView.textContainer, let storage = textView.textStorage, storage.length > 0, textView.window != nil else {
            removeAll(); return
        }
        let origin = textView.textContainerOrigin
        let band = textView.visibleRect.insetBy(dx: 0, dy: -margin).offsetBy(dx: -origin.x, dy: -origin.y)
        if layingOut {
            layout.ensureLayout(forBoundingRect: band, in: container)
        } else if layout.firstUnlaidCharacterIndex() < storage.length, layout.usedRect(for: container).maxY < band.maxY {
            // A width change, as when a legacy scroller comes or goes,
            // posts its frame change before the text is laid out again.
            // The views in view stay meanwhile: a GIF the cache let go
            // could not come back. Forcing layout here could reenter it.
            scheduleLayout(); return
        }
        let glyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: band, in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var placed: [Int: AnimatedImageView] = [:]
        let playing = animates()
        func place(_ key: String?, at location: Int) {
            let existing = views.removeValue(forKey: location)
            guard let key, let frame = Self.attachmentFrame(at: location, layout: layout, origin: origin) else {
                existing?.removeFromSuperview(); return
            }
            let view: AnimatedImageView
            // A placed view keeps its frames after the cache lets them go,
            // so GIFs in view cannot push each other out and load in turn.
            if let existing, existing.key == key {
                view = existing
                if view.frame != frame { view.frame = frame }
            } else {
                existing?.removeFromSuperview()
                guard let image = images(key) else { return }
                view = AnimatedImageView(key: key, image: image, frame: frame)
                textView.addSubview(view)
            }
            view.setPlaying(playing)
            placed[location] = view
        }
        // The same GIF side by side is one run with one attachment per character.
        storage.enumerateAttribute(.nevermoreAnimatedImage, in: characters) { value, range, _ in
            for location in range.location..<NSMaxRange(range) { place(value as? String, at: location) }
        }
        for view in views.values { view.removeFromSuperview() }
        views = placed
    }

    private func scheduleLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.layoutScheduled = false
            self.update(layingOut: true)
        }
    }

    /// Where the attachment glyph for `location` is drawn, in text view
    /// coordinates; nil when it is not an attachment or not laid out.
    static func attachmentFrame(at location: Int, layout: NSLayoutManager, origin: NSPoint) -> NSRect? {
        guard let storage = layout.textStorage, location < storage.length,
              let attachment = storage.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment else { return nil }
        let glyph = layout.glyphIndexForCharacter(at: location)
        // Not `notShownAttribute`: AppKit reports attachment glyphs as not shown, since their cell draws them.
        guard glyph < layout.numberOfGlyphs else { return nil }
        let size = layout.attachmentSize(forGlyphAt: glyph)
        guard size.width > 0, size.height > 0 else { return nil }
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
        guard line.height > 0 else { return nil }
        let baseline = layout.location(forGlyphAt: glyph)
        // The attachment sits on the baseline, raised by its bounds' origin.
        return NSRect(x: origin.x + line.minX + baseline.x,
                      y: origin.y + line.minY + baseline.y - size.height - attachment.bounds.minY,
                      width: size.width, height: size.height)
    }
}

/// Shows GIFs embedded in message bodies (`<p><img src="…gif"></p>`, as
/// Raven's GIF picker sends them) as images in the transcript.
///
/// The rich-text renderer keeps an image as its text fallback, marked with
/// `.nevermoreInlineImage`. Here a GIF from a GIF service replaces that
/// text with an attachment: its first frame once loaded, a quiet box
/// before then. A GIF loads once it comes into view, as attached images
/// do. Other images, and GIFs while the reader has turned them off, keep
/// the text.
@MainActor enum InlineImagePresentation {
    /// The same bound as image messages.
    static let maxSide: CGFloat = 320
    /// Shown until the GIF arrives; most GIFs are about 4:3.
    static let placeholderSize = NSSize(width: 200, height: 150)
    /// GIFs shown per message; any more keep their text, so one message
    /// cannot make the reader fetch thousands.
    static let maximumPerMessage = 20

    static var showsGIFs: Bool { GIFPreferences.showsInMessages(storedValue: UserDefaults.standard.object(forKey: GIFPreferences.showsInMessagesKey)) }

    static func embed(_ text: NSAttributedString, session: AccountSession, enabled: Bool = showsGIFs) -> NSAttributedString {
        guard enabled, text.length > 0 else { return text }
        var runs: [(NSRange, URL)] = []
        text.enumerateAttribute(.nevermoreInlineImage, in: NSRange(location: 0, length: text.length)) { value, range, stop in
            if let src = (value as? InlineImageSource)?.src, let url = GIFMediaPolicy.mediaURL(src), !session.inlineImageFailed(url) { runs.append((range, url)) }
            if runs.count == maximumPerMessage { stop.pointee = true }
        }
        guard !runs.isEmpty else { return text }
        let output = NSMutableAttributedString(attributedString: text)
        // Back to front, so earlier ranges stay valid.
        for (range, url) in runs.reversed() {
            let key = AnimatedImageKey.remote(url)
            var attributes = output.attributes(at: range.location, effectiveRange: nil)
            attributes.removeValue(forKey: .nevermoreInlineImage)
            // The fallback text names the GIF for VoiceOver and the pointer.
            attributes[.toolTip] = output.attributedSubstring(from: range).string
            let attachment = NSTextAttachment()
            if let image = session.animatedImages[key], let still = AnimatedImageCache.still(image, maxSide: maxSide) {
                attachment.image = still
                attachment.bounds = NSRect(origin: .zero, size: still.size)
                if image.isAnimated { attributes[.nevermoreAnimatedImage] = key }
            } else {
                // Loaded once it comes into view: the overlay asks for it.
                let size = session.animatedImages.sourceSize(key).map { AnimatedImageCache.displaySize($0, maxSide: maxSide) } ?? placeholderSize
                attachment.image = placeholder(size)
                attachment.bounds = NSRect(origin: .zero, size: size)
                attributes[.nevermoreAnimatedImage] = key
                session.noteInlineImage(url)
            }
            let replacement = NSMutableAttributedString(attachment: attachment)
            replacement.addAttributes(attributes, range: NSRange(location: 0, length: replacement.length))
            output.replaceCharacters(in: range, with: replacement)
        }
        return output
    }

    /// A rounded box in the code background color, drawn when shown so it
    /// follows the theme.
    static func placeholder(_ size: NSSize) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSColor.themeCodeBackground.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).fill()
            let label = NSAttributedString(string: "GIF", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.themeSecondaryText])
            let labelSize = label.size()
            label.draw(at: NSPoint(x: rect.midX - labelSize.width / 2, y: rect.midY - labelSize.height / 2))
            return true
        }
    }
}
