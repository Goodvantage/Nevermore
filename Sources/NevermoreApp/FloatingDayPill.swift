import AppKit

/// The day of the topmost message, floating under the toolbar while the
/// reader scrolls through history, so a long scroll never loses track of
/// when it is (Messages and WhatsApp do the same). It looks like the
/// transcript's own day pill, ignores the pointer, and fades out shortly
/// after scrolling stops. VoiceOver reads the day dividers in the text, so
/// the pill is not an accessibility element.
@MainActor final class FloatingDayPill: NSView {
    /// Room the pill needs under the top of the readable band; a day
    /// divider inside it hides the pill so one day never shows twice.
    static let clearance: CGFloat = 40
    /// How long the pill stays after the last scroll. Checks shorten it.
    static var lingering: Duration = .milliseconds(1200)

    private let label = NSTextField(labelWithString: "")
    private(set) var day: String?
    var isShown: Bool { !isHidden && day != nil }

    init() {
        super.init(frame: .zero)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .themeSecondaryText
        label.alignment = .center
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        setAccessibilityElement(false)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let pill = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        NSColor.textBackgroundColor.setFill(); path.fill()
        NSColor.separatorColor.setStroke(); path.lineWidth = 1; path.stroke()
    }

    func show(_ day: String, font: NSFont) {
        if self.day != day || label.font != font { label.font = font; label.stringValue = day; self.day = day }
        guard isHidden || alphaValue < 1 else { return }
        isHidden = false
        animate(to: 1)
    }

    func hide(animated: Bool) {
        guard !isHidden else { return }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { alphaValue = 0; isHidden = true; day = nil; return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { guard let self, self.alphaValue == 0 else { return }; self.isHidden = true; self.day = nil }
        })
    }

    private func animate(to alpha: CGFloat) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { alphaValue = alpha; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = alpha
        }
    }
}

/// Scope wheel and momentum input to this transcript. A programmatic
/// placement can follow the last wheel event while it is still NSApp.currentEvent.
@MainActor final class TranscriptScrollView: NSScrollView {
    var onWheelMove: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        // AppKit can apply momentum displacement after this method returns.
        if event.scrollingDeltaY != 0 || !event.momentumPhase.isEmpty { onWheelMove?() }
    }
}

extension ConversationWindow {
    /// The label of the day divider above the top of the readable band, or
    /// nil when that divider is itself in view or another one is about to
    /// reach the pill's place.
    func floatingDayLabel() -> (day: String, centerX: CGFloat)? {
        guard channel != nil, !isUpdatingTranscript, let layout = transcript.layoutManager, let container = transcript.textContainer,
              let storage = transcript.textStorage, storage.length > 0 else { return nil }
        let origin = transcript.textContainerOrigin
        let readable = readableTranscriptRect
        let text = storage.string as NSString
        func labelRange(_ range: NSRange) -> NSRange {
            var label = range
            if label.length > 0, text.character(at: NSMaxRange(label) - 1) == 10 { label.length -= 1 }
            return label
        }
        func rect(_ range: NSRange) -> NSRect {
            layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container).offsetBy(dx: origin.x, dy: origin.y)
        }
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: readable.minY - origin.y), in: container)
        let index = min(storage.length - 1, layout.characterIndexForGlyph(at: glyph))
        var above: (day: String, rect: NSRect)?
        storage.enumerateAttribute(.nevermoreDayDivider, in: NSRange(location: 0, length: index + 1), options: .reverse) { value, range, stop in
            let label = labelRange(range)
            guard value as? Bool == true, label.length > 0 else { return }
            above = (text.substring(with: label), rect(label)); stop.pointee = true
        }
        guard let above, above.rect.maxY < readable.minY else { return nil }
        var collides = false
        let rest = NSRange(location: index + 1, length: storage.length - index - 1)
        storage.enumerateAttribute(.nevermoreDayDivider, in: rest) { value, range, stop in
            let label = labelRange(range)
            guard value as? Bool == true, label.length > 0 else { return }
            collides = rect(label).minY < readable.minY + FloatingDayPill.clearance; stop.pointee = true
        }
        return collides ? nil : (above.day, above.rect.midX)
    }

    /// Called whenever the transcript moves. Only the reader's own scrolling
    /// (a wheel, trackpad or scroller drag) shows the pill; new messages and
    /// placements after a render do not.
    func updateFloatingDayPill(readerWheel: Bool = false) {
        let readerScrolls = isTranscriptLiveScrolling || readerWheel
        guard readerScrolls || dayPill.isShown else { return }
        // The earlier-messages spinner takes the same place while it loads.
        guard !isLoadingEarlier, let found = floatingDayLabel() else { hideFloatingDayPill(animated: false); return }
        guard readerScrolls else { return }
        let center = transcript.convert(NSPoint(x: found.centerX, y: 0), to: dayPill.superview).x
        dayPillCenter?.constant = center
        dayPill.show(found.day, font: .systemFont(ofSize: max(11, transcript.metrics.size - 2), weight: .semibold))
        dayPillFade?.cancel()
        guard !isTranscriptLiveScrolling else { return }
        scheduleFloatingDayPillFade()
    }

    func scheduleFloatingDayPillFade() {
        dayPillFade?.cancel()
        dayPillFade = Task { [weak self] in
            try? await Task.sleep(for: FloatingDayPill.lingering)
            guard !Task.isCancelled else { return }
            self?.hideFloatingDayPill(animated: true)
        }
    }

    func hideFloatingDayPill(animated: Bool) {
        dayPillFade?.cancel(); dayPillFade = nil
        dayPill.hide(animated: animated)
    }
}
