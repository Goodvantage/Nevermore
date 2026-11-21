import AppKit
import NevermoreCore

/// The short particle burst that greets a newly chosen theme: confetti for
/// Memphis, bats for Halloween, bubbles under the sea. It runs once for
/// about four seconds on Core Animation and then removes itself, so it costs
/// nothing afterwards. Callers check Reduce Motion and the Effects setting
/// (`ThemeManager.playsEffects`).
@MainActor enum ThemeCelebrationPlayer {
    private enum Flow {
        /// Falls from the top edge.
        case fall
        /// Rises from the bottom edge.
        case rise
        /// Bursts from the middle.
        case burst
    }

    /// How long particles are emitted, and how long the overlay stays.
    static let emissionDuration: TimeInterval = 0.7
    static let overlayDuration: TimeInterval = 4.5

    static func play(_ theme: Theme, over host: NSView?) {
        guard let host, host.bounds.width > 0 else { return }
        // Arrowing through the Theme menu can start a new celebration before
        // the previous one's timer removes it. Replace it so the window never
        // stacks several emitters and bursts. Selecting a theme without a
        // celebration retires a lingering overlay too.
        for old in host.subviews where old is CelebrationOverlay { old.removeFromSuperview() }
        guard let palette = theme.palette, theme.celebration != .none else { return }
        let (motifs, flow) = recipe(for: theme.celebration)
        let colors = celebrationColors(theme, palette: palette)
        let overlay = CelebrationOverlay(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        let emitter = CAEmitterLayer()
        emitter.renderMode = .unordered
        overlay.layoutEmitter = { bounds in aim(emitter, flow: flow, in: bounds) }
        overlay.layoutEmitter?(overlay.bounds)
        emitter.emitterCells = motifs.enumerated().flatMap { motifIndex, motif in
            colors.prefix(3).enumerated().compactMap { colorIndex, color in
                cell(motif, colors: theme.wallpaper.motifs.first { $0.motif == motif }?.colors ?? [color], tint: color, flow: flow, variant: motifIndex * 3 + colorIndex, scale: host.window?.backingScaleFactor ?? 2)
            }
        }
        overlay.layer?.addSublayer(emitter)
        DispatchQueue.main.asyncAfter(deadline: .now() + emissionDuration) { emitter.birthRate = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + overlayDuration) { overlay.removeFromSuperview() }
    }

    /// Fits the emitter to the overlay, with its source on the edge the
    /// particles enter from. Runs again whenever the window resizes.
    private static func aim(_ emitter: CAEmitterLayer, flow: Flow, in bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        emitter.frame = bounds
        switch flow {
        case .fall:
            emitter.emitterShape = .line
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.maxY + 20)
            emitter.emitterSize = CGSize(width: bounds.width, height: 1)
        case .rise:
            emitter.emitterShape = .line
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.minY - 20)
            emitter.emitterSize = CGSize(width: bounds.width, height: 1)
        case .burst:
            emitter.emitterShape = .point
            emitter.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    private static func recipe(for celebration: ThemeCelebration) -> ([ThemeMotif], Flow) {
        switch celebration {
        case .none: ([], .burst)
        case .confetti: ([.triangle, .squiggle, .dot, .halfCircle], .fall)
        case .bats: ([.bat], .rise)
        case .ravens: ([.raven, .feather], .rise)
        case .sparkles: ([.sparkle, .star], .burst)
        case .bubbles: ([.bubble], .rise)
        case .leaves: ([.leaf, .flower], .fall)
        case .snow: ([.snowflake, .dot], .fall)
        case .stars: ([.star, .sparkle], .burst)
        case .hearts: ([.heart, .sparkle], .rise)
        case .notes: ([.musicNote], .rise)
        }
    }

    private static func celebrationColors(_ theme: Theme, palette: ThemePalette) -> [ThemeColor] {
        var colors = [palette.accent] + palette.nameColors
        var seen = Set<ThemeColor>()
        colors = colors.filter { seen.insert($0).inserted }
        return colors
    }

    private static func cell(_ motif: ThemeMotif, colors: [ThemeColor], tint: ThemeColor, flow: Flow, variant: Int, scale: CGFloat) -> CAEmitterCell? {
        // Multi-part motifs keep their own colors; single-color motifs take
        // one palette color per cell so the burst is varied.
        let partColors = motif.partCount > 1 ? colors : [tint]
        let style: MotifStyle = motif == .bubble || motif == .snowflake ? .stroke : .fill
        guard let image = particleImage(motif, colors: partColors, style: style, scale: scale) else { return nil }
        let cell = CAEmitterCell()
        cell.contents = image
        cell.contentsScale = scale
        cell.lifetime = 3.4
        cell.lifetimeRange = 0.6
        cell.scale = 0.9
        cell.scaleRange = 0.35
        cell.alphaSpeed = -0.22
        let jitter = CGFloat(variant % 5) / 5
        switch flow {
        case .fall:
            cell.birthRate = 14
            cell.velocity = 150 + 40 * jitter
            cell.velocityRange = 60
            cell.emissionLongitude = -.pi / 2
            cell.emissionRange = .pi / 5
            cell.yAcceleration = -90
            cell.spin = 2.5
            cell.spinRange = 5
        case .rise:
            cell.birthRate = 9
            cell.velocity = 210 + 40 * jitter
            cell.velocityRange = 70
            cell.emissionLongitude = .pi / 2
            cell.emissionRange = .pi / 6
            cell.yAcceleration = -25
            cell.xAcceleration = variant.isMultiple(of: 2) ? 18 : -18
            cell.spinRange = 0.8
        case .burst:
            cell.birthRate = 22
            cell.velocity = 260 + 40 * jitter
            cell.velocityRange = 120
            cell.emissionRange = .pi * 2
            cell.yAcceleration = -160
            cell.spinRange = 3
        }
        return cell
    }

    private static func particleImage(_ motif: ThemeMotif, colors: [ThemeColor], style: MotifStyle, scale: CGFloat) -> CGImage? {
        let points: CGFloat = 26
        let pixels = Int(points * scale)
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        MotifArt.draw(motif, in: CGRect(x: 0, y: 0, width: points, height: points), colors: colors.map { NSColor(theme: $0).cgColor }, style: style, context: context)
        return context.makeImage()
    }
}

/// Hosts a celebration above the conversation without taking clicks or
/// accessibility focus.
@MainActor private final class CelebrationOverlay: NSView {
    /// Re-fits the emitter; the overlay follows its host's size.
    var layoutEmitter: ((CGRect) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutEmitter?(bounds)
    }
}
