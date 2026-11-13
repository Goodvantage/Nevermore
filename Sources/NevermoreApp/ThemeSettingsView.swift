import AppKit
import NevermoreCore

/// Settings ▸ Appearance: a gallery of preset cards, the way into the theme
/// editor, the backdrop opacity and the wallpaper and effects switches.
/// Choosing a card applies that preset, with your changes to it, at once.
@MainActor final class ThemeSettingsView: NSView {
    /// What the pane asks the app to do.
    struct Actions {
        var select: (ThemeID) -> Void
        var customize: () -> Void
        var setBackdropOpacity: (Double) -> Void
        var preferencesChanged: () -> Void
    }

    private static let columns = 4
    private static let backdropSliderWidth: CGFloat = 200
    private let decorations = NSButton(checkboxWithTitle: "Show theme wallpaper and ornaments", target: nil, action: nil)
    private let effects = NSButton(checkboxWithTitle: "Celebrate when you switch themes", target: nil, action: nil)
    let customize = NSButton(title: "Customize Theme…", target: nil, action: nil)
    private let customizeStatus = NSTextField(labelWithString: "")
    let backdropOpacity = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let backdropOpacityValue = NSTextField(labelWithString: "100%")
    private(set) var cards: [ThemeCard] = []
    private let actions: Actions

    init(actions: Actions) {
        self.actions = actions
        super.init(frame: .zero)
        cards = ThemeCatalog.all.map { theme in
            let card = ThemeCard(theme: theme)
            card.target = self
            card.action = #selector(choose(_:))
            return card
        }
        var rows: [[NSView]] = []
        for start in stride(from: 0, to: cards.count, by: Self.columns) {
            var row: [NSView] = Array(cards[start..<min(start + Self.columns, cards.count)])
            while row.count < Self.columns { row.append(NSGridCell.emptyContentView) }
            rows.append(row)
        }
        let gallery = NSGridView(views: rows)
        gallery.rowSpacing = 12
        gallery.columnSpacing = 12
        gallery.setAccessibilityElement(true)
        gallery.setAccessibilityRole(.radioGroup)
        gallery.setAccessibilityLabel("Theme")
        customize.target = self
        customize.action = #selector(openEditor(_:))
        customizeStatus.textColor = .secondaryLabelColor
        customizeStatus.font = .systemFont(ofSize: 11)
        let customizeRow = NSStackView(views: [customize, customizeStatus])
        customizeRow.spacing = 8
        backdropOpacity.isContinuous = true
        backdropOpacity.target = self
        backdropOpacity.action = #selector(changeBackdropOpacity(_:))
        backdropOpacity.widthAnchor.constraint(equalToConstant: Self.backdropSliderWidth).isActive = true
        backdropOpacity.setAccessibilityLabel("Backdrop opacity")
        backdropOpacity.toolTip = "How strongly a theme's backdrop, wallpaper and sidebar tint show. Applies to every theme except Classic, which has none."
        backdropOpacityValue.textColor = .secondaryLabelColor
        backdropOpacityValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let backdropRow = NSStackView(views: [NSTextField(labelWithString: "Backdrop opacity:"), backdropOpacity, backdropOpacityValue])
        backdropRow.spacing = 8
        decorations.target = self
        decorations.action = #selector(togglePreference(_:))
        effects.target = self
        effects.action = #selector(togglePreference(_:))
        let note = NSTextField(wrappingLabelWithString: "Themes are presets: Customize Theme changes the chosen one's colors, backdrop, wallpaper and fonts, and you can reset it at any time. Increase Contrast hides the wallpaper and Reduce Motion skips celebrations, whatever these switches say.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.preferredMaxLayoutWidth = 420
        let stack = NSStackView(views: [gallery, customizeRow, backdropRow, decorations, effects, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: gallery)
        stack.setCustomSpacing(12, after: customizeRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reload()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Matches the controls to the stored preferences and current theme.
    func reload() {
        let manager = ThemeManager.shared
        for card in cards {
            card.show(manager.drawn(card.theme.id), customized: manager.isCustomized(card.theme.id))
            card.isChosen = card.theme.id == manager.current.id
        }
        // Drawing a poster scatters and draws its wallpaper. The backdrop
        // slider changes every card's theme on each step of a drag, so the
        // posters follow once the changes pause, in mid-drag too.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(refreshPreviews), object: nil)
        perform(#selector(refreshPreviews), with: nil, afterDelay: ThemeTranscriptRefresh.coalescingDelay, inModes: [.common])
        // Classic is the system look: it has no settings and no backdrop.
        let themed = !manager.current.isClassic
        customize.isEnabled = themed
        customizeStatus.stringValue = !themed ? "Classic keeps the system look. Choose another theme to customize it."
            : manager.isCustomized(manager.current.id) ? "\(manager.current.name) has your changes." : ""
        backdropOpacity.isEnabled = themed
        // A drag in progress already shows its own value, which is stored
        // rounded: leave the knob under the pointer.
        if ThemeEditorController.hundredths(backdropOpacity.doubleValue) != manager.backdropOpacity { backdropOpacity.doubleValue = manager.backdropOpacity }
        backdropOpacityValue.stringValue = ThemeEditorController.percent(manager.backdropOpacity)
        decorations.state = manager.decorationsEnabled ? .on : .off
        effects.state = manager.effectsEnabled ? .on : .off
    }

    @objc private func refreshPreviews() {
        for card in cards { card.refreshPreview() }
    }

    @objc private func choose(_ sender: ThemeCard) {
        actions.select(sender.theme.id)
        reload()
    }

    @objc private func openEditor(_ sender: Any?) {
        actions.customize()
    }

    @objc private func changeBackdropOpacity(_ sender: Any?) {
        actions.setBackdropOpacity(ThemeEditorController.hundredths(backdropOpacity.doubleValue))
    }

    @objc private func togglePreference(_ sender: NSButton) {
        ThemeManager.shared.decorationsEnabled = decorations.state == .on
        ThemeManager.shared.effectsEnabled = effects.state == .on
        actions.preferencesChanged()
    }
}

/// One preset in the gallery: a miniature window as the theme would draw
/// now and the theme's name, with a badge when you have changed it. Exposed
/// to accessibility as a radio button.
@MainActor final class ThemeCard: NSButton {
    static let previewSize = CGSize(width: 136, height: 85)
    private(set) var theme: Theme
    private(set) var isCustomized = false
    var isChosen = false {
        didSet {
            guard isChosen != oldValue else { return }
            needsDisplay = true
            setAccessibilityValue(isChosen ? 1 : 0)
        }
    }
    private var preview: NSImage?

    init(theme: Theme) {
        self.theme = theme
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        toolTip = "\(theme.name): \(theme.tagline)"
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(theme.name)
        setAccessibilityHelp(theme.tagline)
        setAccessibilityValue(0)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: Self.previewSize.width + 8).isActive = true
        heightAnchor.constraint(equalToConstant: Self.previewSize.height + 30).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the preset as it draws now: with the user's changes and at the
    /// user's backdrop opacity. The gallery refreshes the preview itself,
    /// except for a card that has none yet.
    func show(_ theme: Theme, customized: Bool) {
        self.theme = theme
        if customized != isCustomized { needsDisplay = true }
        isCustomized = customized
        toolTip = "\(theme.name): \(theme.tagline)" + (customized ? " (customized)" : "")
        setAccessibilityHelp(customized ? "\(theme.tagline). Customized." : theme.tagline)
        if preview == nil { refreshPreview() }
    }

    func refreshPreview() {
        preview = ThemePoster.image(for: theme, size: Self.previewSize, appearance: effectiveAppearance)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Classic's card follows light and dark.
        if theme.isClassic { refreshPreview() }
    }

    /// Buttons are flipped; the card lays out bottom-up like a plain view so
    /// the preview sits above its name.
    override var isFlipped: Bool { false }

    private var previewRect: NSRect {
        NSRect(x: 4, y: bounds.height - 4 - Self.previewSize.height, width: Self.previewSize.width, height: Self.previewSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = previewRect
        let rounded = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        rounded.addClip()
        preview?.draw(in: frame)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke()
        rounded.lineWidth = 1
        rounded.stroke()
        if isChosen {
            let ring = NSBezierPath(roundedRect: frame.insetBy(dx: -2.5, dy: -2.5), xRadius: 10, yRadius: 10)
            ring.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            ring.stroke()
            drawBadge("checkmark", in: NSRect(x: frame.maxX - 22, y: frame.maxY - 22, width: 18, height: 18), fill: .controlAccentColor)
        }
        if isCustomized { drawBadge("paintbrush.pointed.fill", in: NSRect(x: frame.minX + 4, y: frame.maxY - 22, width: 18, height: 18), fill: NSColor.black.withAlphaComponent(0.55)) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(string: theme.name, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: isChosen ? .semibold : .regular), .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
            .draw(in: NSRect(x: 0, y: 2, width: bounds.width, height: 18))
    }

    /// A white symbol on a filled circle, over the preview's corner.
    private func drawBadge(_ symbol: String, in badge: NSRect, fill: NSColor) {
        fill.setFill()
        NSBezierPath(ovalIn: badge).fill()
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) else { return }
        let tinted = glyph.tinted(.white)
        tinted.draw(in: NSRect(x: badge.midX - tinted.size.width / 2, y: badge.midY - tinted.size.height / 2, width: tinted.size.width, height: tinted.size.height))
    }

    override var focusRingMaskBounds: NSRect { previewRect }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: previewRect, xRadius: 8, yRadius: 8).fill() }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}
