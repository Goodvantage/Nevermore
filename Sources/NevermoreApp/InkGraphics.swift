import AppKit
import NevermoreCore

/// Colors and timings of the ink. One place, so the vocabulary stays small.
@MainActor enum Ink {
    /// How far wet ink leans from the text color toward the accent.
    static let wetBlend: CGFloat = 0.6
    /// Other people's messages arrive most of the way dry.
    static let freshBlend: CGFloat = 0.32
    /// WCAG AA for body text; wet ink must stay readable on every theme.
    static let minimumContrast: CGFloat = 4.5

    static let liftHeight: CGFloat = 5
    static let flightStiffness: CGFloat = 300
    static let flightDamping: CGFloat = 26
    static let flutterDegrees: CGFloat = 1.2
    static let staggerPerWord: CFTimeInterval = 0.005
    static let staggerLimit: CFTimeInterval = 0.14
    static let glintDuration: CFTimeInterval = 0.55
    static let glintWidth: CGFloat = 80
    static let dryDurationPerLine: CFTimeInterval = 0.42
    static let dryLineStagger: CFTimeInterval = 0.07
    static let dryEdge: CGFloat = 44
    static let freshDryDuration: CFTimeInterval = 0.35

    /// Reduce Motion replaces flights, glints and sweeps with cuts. The
    /// `inkStill` default does the same for this app alone.
    static var reducesMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || UserDefaults.standard.bool(forKey: "inkStill") }

    /// Stretches every ink animation, for studying one frame by frame:
    /// `defaults write ch.goodvantage.Nevermore inkTimeScale 8`.
    static let timeScale: Double = {
        let value = UserDefaults.standard.double(forKey: "inkTimeScale")
        return value >= 1 && value <= 30 ? value : 1
    }()

    /// The text color pulled toward the accent, backed off until it keeps
    /// body-text contrast against the transcript.
    static func color(blend: CGFloat, in view: NSView) -> NSColor {
        var result = NSColor.labelColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            let text = NSColor.themeText.usingColorSpace(.sRGB) ?? .black
            guard !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                  let accent = NSColor.themeAccent.usingColorSpace(.sRGB) else { result = text; return }
            // A themed transcript sits on a gradient; every stop must pass.
            let themed = ActiveThemePalette.current?.gradient.map { NSColor(theme: $0) } ?? []
            let backgrounds = (themed.isEmpty ? [NSColor.textBackgroundColor] : themed).compactMap { $0.usingColorSpace(.sRGB) }
            var fraction = blend
            result = text
            while fraction > 0.05 {
                let candidate = text.blended(withFraction: fraction, of: accent) ?? text
                if backgrounds.allSatisfy({ contrast(candidate, $0) >= minimumContrast }) { result = candidate; break }
                fraction -= 0.1
            }
        }
        return result
    }

    private static func luminance(_ color: NSColor) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(color.redComponent) + 0.7152 * channel(color.greenComponent) + 0.0722 * channel(color.blueComponent)
    }
    /// Light ink means a dark transcript.
    static func isLight(_ color: NSColor) -> Bool { (color.usingColorSpace(.sRGB).map(luminance) ?? 0) > 0.35 }
    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// Draws a glyph range exactly as its layout manager would, into a
    /// bitmap whose top row is the top of `rect` (container coordinates).
    /// Flying words and drying sweeps are cut from these, so they register
    /// with the real text to the pixel.
    static func snapshot(_ layout: NSLayoutManager, glyphs: NSRange, rect: NSRect, scale: CGFloat) -> CGImage? {
        let width = Int((rect.width * scale).rounded(.up)), height = Int((rect.height * scale).rounded(.up))
        guard width > 0, height > 0, width <= 8192, height <= 8192, glyphs.length > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        layout.drawGlyphs(forGlyphRange: glyphs, at: NSPoint(x: -rect.minX, y: -rect.minY))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }
}

/// Hosts the words while they are between the composer and the transcript.
/// It covers the conversation pane, above the composer glass, and never
/// takes a click.
@MainActor final class InkOverlayView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A glint or a drying sweep over one message. It lives inside the
/// transcript, so it scrolls with the text it belongs to.
@MainActor final class InkEffectView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The drop at the end of a message that has not been acknowledged. It
/// carries the state without color: it breathes while the outbox works
/// and holds still when the send needs attention.
@MainActor final class InkBlot: NSView {
    static let size = NSSize(width: 16, height: 18)
    let operationID: UUID
    var onClick: ((InkBlot) -> Void)?
    private let drop = CAShapeLayer()
    private(set) var wetness: InkWetness = .flowing

    init(operationID: UUID) {
        self.operationID = operationID
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        drop.frame = bounds
        drop.path = Self.dropPath(in: bounds.insetBy(dx: 4, dy: 3))
        layer?.addSublayer(drop)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A drop hanging from its point: a circle with a tangent tip.
    private static func dropPath(in rect: NSRect) -> CGPath {
        let path = CGMutablePath()
        let radius = rect.width / 2
        // Layer geometry is unflipped: the point is at the top (maxY).
        let center = CGPoint(x: rect.midX, y: rect.minY + radius)
        let tip = CGPoint(x: rect.midX, y: rect.maxY)
        path.move(to: tip)
        path.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: CGPoint(x: center.x + radius, y: center.y + radius * 0.9))
        path.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi, clockwise: true)
        path.addQuadCurve(to: tip, control: CGPoint(x: center.x - radius, y: center.y + radius * 0.9))
        path.closeSubpath()
        return path
    }

    func update(wetness: InkWetness, label: String, canTakeBack: Bool, color: NSColor, alert: NSColor) {
        self.wetness = wetness
        drop.fillColor = (wetness == .flowing ? color : alert).cgColor
        toolTip = canTakeBack ? "\(label). Click for options, or press ⌘Z to take it back." : "\(label). Click for options."
        setAccessibilityLabel("Not sent yet: \(label)")
        let breathes = wetness == .flowing && !Ink.reducesMotion
        if breathes, drop.animation(forKey: "breathe") == nil {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1; breathe.toValue = 0.4
            breathe.duration = 1.1; breathe.autoreverses = true; breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            drop.add(breathe, forKey: "breathe")
        } else if !breathes {
            drop.removeAnimation(forKey: "breathe")
        }
    }

    override func mouseDown(with event: NSEvent) { onClick?(self) }
    override func accessibilityPerformPress() -> Bool { onClick?(self); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
