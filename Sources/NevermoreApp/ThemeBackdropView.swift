import AppKit
import NevermoreCore

/// The themed wallpaper behind a conversation or the sidebar: a gradient,
/// the theme's anchored ornaments and a repeating tile of motifs. Everything
/// is static layer content, so scrolling the transcript over it costs no
/// redraw; only a resize redraws the ornaments. Hidden under Classic.
@MainActor final class ThemeBackdropView: NSView {
    enum Role {
        /// Full wallpaper behind the transcript.
        case conversation
        /// Only the palette's sidebar tint: list rows sit on it edge to edge.
        case sidebar
    }

    private let role: Role
    private let gradient = CAGradientLayer()
    private let ornaments = OrnamentCanvas()
    private let pattern = CAReplicatorLayer()
    private let patternRow = CAReplicatorLayer()
    private let tile = CALayer()
    private(set) var theme: Theme?
    private var drawsDecorations = false

    init(role: Role) {
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(gradient)
        ornaments.translatesAutoresizingMaskIntoConstraints = true
        ornaments.autoresizingMask = [.width, .height]
        addSubview(ornaments)
        patternRow.addSublayer(tile)
        pattern.addSublayer(patternRow)
        layer?.addSublayer(pattern)
        // Ornaments (a subview's layer at z 0) sit between the gradient and
        // the motifs: the stacking the contrast audit checks.
        gradient.zPosition = -1
        pattern.zPosition = 1
        for sublayer in [gradient, pattern, patternRow, tile] as [CALayer] { sublayer.actions = Self.noAnimations }
        setAccessibilityElement(false)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Decorative only: clicks fall through to the views above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var isShowingDecorations: Bool { !isHidden && drawsDecorations }

    func apply(_ theme: Theme, decorations: Bool) {
        self.theme = theme
        guard let palette = theme.palette else { isHidden = true; return }
        isHidden = false
        drawsDecorations = decorations && role == .conversation && !theme.wallpaper.isEmpty
        switch role {
        case .conversation:
            gradient.colors = palette.gradient.map { NSColor(theme: $0).cgColor }
            let radians = palette.gradientAngle * .pi / 180
            // Unit-square endpoints for the angle; 90° runs top to bottom in
            // a y-up layer, so the start point sits at the top.
            gradient.startPoint = CGPoint(x: 0.5 - cos(radians) / 2, y: 0.5 + sin(radians) / 2)
            gradient.endPoint = CGPoint(x: 0.5 + cos(radians) / 2, y: 0.5 - sin(radians) / 2)
        case .sidebar:
            let tint = NSColor(theme: palette.sidebarTint, alpha: palette.sidebarTintOpacity).cgColor
            gradient.colors = [tint, tint]
        }
        ornaments.ornaments = drawsDecorations ? theme.wallpaper.ornaments : []
        ornaments.isHidden = ornaments.ornaments.isEmpty
        pattern.isHidden = !drawsDecorations || theme.wallpaper.motifs.isEmpty
        pattern.opacity = Float(theme.wallpaper.opacity)
        updateTile()
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateTile()
    }

    private func updateTile() {
        guard let theme, !pattern.isHidden else { tile.contents = nil; return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        tile.contents = WallpaperRenderer.tile(for: theme, scale: scale)
        tile.contentsScale = scale
        needsLayout = true
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
        pattern.frame = bounds
        guard !pattern.isHidden else { return }
        // Two replicators tile the motif image across the pane: one copies
        // the tile along a row, the other copies the row up the pane.
        let side = CGFloat(WallpaperLayout.tileSize)
        tile.frame = CGRect(x: 0, y: 0, width: side, height: side)
        patternRow.frame = CGRect(x: 0, y: 0, width: bounds.width, height: side)
        patternRow.instanceCount = max(1, Int((bounds.width / side).rounded(.up)))
        patternRow.instanceTransform = CATransform3DMakeTranslation(side, 0, 0)
        pattern.instanceCount = max(1, Int((bounds.height / side).rounded(.up)))
        pattern.instanceTransform = CATransform3DMakeTranslation(0, side, 0)
    }

    private static let noAnimations: [String: any CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "opacity": NSNull(), "hidden": NSNull(), "instanceCount": NSNull(), "instanceTransform": NSNull()]
}

/// Draws a theme's ornaments for the current pane size.
@MainActor private final class OrnamentCanvas: NSView {
    var ornaments: [OrnamentSpec] = [] { didSet { if ornaments != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !ornaments.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        OrnamentArt.draw(ornaments, in: bounds, context: context)
    }
}
