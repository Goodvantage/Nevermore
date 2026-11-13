import AppKit
import NevermoreCore

/// Template images for the menu bar item and for the icon popup in
/// Settings. The ravens are drawn here, bolder than the wallpaper motif of
/// the same name, so they stay readable at menu bar size.
enum MenuBarIconArt {
    /// The glyph box in the menu bar, in points.
    static let menuBarSize: CGFloat = 18
    /// The glyph box beside a title in the Settings popup, in points.
    static let menuItemSize: CGFloat = 16

    static func title(for icon: MenuBarIcon) -> String {
        switch icon {
        case .raven: "Raven"
        case .ravenHead: "Raven Head"
        case .feather: "Feather"
        case .bird: "Bird"
        case .speechBubbles: "Speech Bubbles"
        }
    }

    /// A template image of `icon` in a square of `size` points.
    static func image(for icon: MenuBarIcon, size: CGFloat = menuBarSize) -> NSImage {
        let image: NSImage
        switch icon {
        case .raven: image = drawn(size: size) { fill(perchedRaven(), in: $0, context: $1) }
        case .ravenHead: image = drawn(size: size) { fill(ravenHead(), in: $0, context: $1) }
        case .feather: image = drawn(size: size) { MotifArt.draw(.feather, in: $0, rotation: featherTilt, colors: [.black], style: .fill, context: $1) }
        case .bird: image = symbol("bird.fill", size: size)
        case .speechBubbles: image = symbol("bubble.left.and.bubble.right", size: size)
        }
        image.isTemplate = true
        return image
    }

    /// A quill leaning as if resting in an inkwell.
    private static let featherTilt: CGFloat = -0.6

    private static func drawn(size: CGFloat, _ draw: @escaping @Sendable (CGRect, CGContext) -> Void) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(bounds, context)
            return true
        }
    }

    /// A system symbol scaled to sit in the same box as the drawn glyphs.
    /// Both symbols ship with every supported macOS; should one ever be
    /// missing, the raven stands in so the menu bar item is never blank.
    private static func symbol(_ name: String, size: CGFloat) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: size * symbolPointFraction, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            ?? drawn(size: size) { fill(perchedRaven(), in: $0, context: $1) }
    }

    /// Symbols are wider than their point size; this keeps them as large
    /// as the drawn glyphs without outgrowing the menu bar.
    private static let symbolPointFraction: CGFloat = 0.8

    /// Fills unit-square `shape` (y up, even-odd so eyes stay open) scaled
    /// to `rect`.
    private static func fill(_ shape: CGPath, in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width, y: rect.height)
        context.addPath(shape)
        context.setFillColor(.black)
        context.fillPath(using: .evenOdd)
    }

    /// Width of the cuts that separate a wing or a beak from the body.
    /// About 0.7 pt at menu bar size: one clear pixel row on a Retina display.
    private static let cutWidth: CGFloat = 0.04

    private static func cut(_ line: CGPath, from shape: CGPath) -> CGPath {
        shape.subtracting(line.copy(strokingWithWidth: cutWidth, lineCap: .round, lineJoin: .round, miterLimit: 1), using: .evenOdd)
    }

    /// A raven perched in profile, facing right: heavy beak, round crown,
    /// a back sloping into a long wedge tail, and a folded wing.
    private static func perchedRaven() -> CGPath {
        let body = MotifShapes.path { path in
            path.move(to: CGPoint(x: 0.985, y: 0.66))
            path.addQuadCurve(to: CGPoint(x: 0.78, y: 0.835), control: CGPoint(x: 0.90, y: 0.80))
            path.addCurve(to: CGPoint(x: 0.55, y: 0.80), control1: CGPoint(x: 0.72, y: 0.93), control2: CGPoint(x: 0.59, y: 0.91))
            path.addCurve(to: CGPoint(x: 0.30, y: 0.52), control1: CGPoint(x: 0.50, y: 0.70), control2: CGPoint(x: 0.40, y: 0.62))
            path.addLine(to: CGPoint(x: 0.015, y: 0.25))
            path.addLine(to: CGPoint(x: 0.075, y: 0.165))
            path.addLine(to: CGPoint(x: 0.30, y: 0.285))
            path.addCurve(to: CGPoint(x: 0.56, y: 0.20), control1: CGPoint(x: 0.38, y: 0.22), control2: CGPoint(x: 0.47, y: 0.19))
            path.addCurve(to: CGPoint(x: 0.79, y: 0.57), control1: CGPoint(x: 0.72, y: 0.22), control2: CGPoint(x: 0.83, y: 0.40))
            path.addQuadCurve(to: CGPoint(x: 0.985, y: 0.66), control: CGPoint(x: 0.88, y: 0.60))
            path.closeSubpath()
            path.addEllipse(in: CGRect(x: 0.70, y: 0.745, width: 0.06, height: 0.06))
        }
        let wing = MotifShapes.path { path in
            path.move(to: CGPoint(x: 0.66, y: 0.56))
            path.addCurve(to: CGPoint(x: 0.20, y: 0.33), control1: CGPoint(x: 0.58, y: 0.36), control2: CGPoint(x: 0.40, y: 0.30))
        }
        let legs = MotifShapes.path { path in
            path.addLines(between: [CGPoint(x: 0.50, y: 0.22), CGPoint(x: 0.50, y: 0.06), CGPoint(x: 0.59, y: 0.06)])
            path.addLines(between: [CGPoint(x: 0.64, y: 0.24), CGPoint(x: 0.64, y: 0.06), CGPoint(x: 0.73, y: 0.06)])
        }
        return cut(wing, from: body).union(legs.copy(strokingWithWidth: 0.06, lineCap: .round, lineJoin: .round, miterLimit: 1), using: .evenOdd)
    }

    /// The app icon's raven: a head in profile with a long, slightly
    /// hooked beak and ragged throat feathers.
    private static func ravenHead() -> CGPath {
        let head = MotifShapes.path { path in
            path.move(to: CGPoint(x: 0.99, y: 0.47))
            path.addCurve(to: CGPoint(x: 0.56, y: 0.75), control1: CGPoint(x: 0.90, y: 0.68), control2: CGPoint(x: 0.72, y: 0.76))
            path.addCurve(to: CGPoint(x: 0.13, y: 0.70), control1: CGPoint(x: 0.47, y: 0.97), control2: CGPoint(x: 0.17, y: 0.96))
            path.addCurve(to: CGPoint(x: 0.03, y: 0.04), control1: CGPoint(x: 0.10, y: 0.50), control2: CGPoint(x: 0.10, y: 0.26))
            path.addLine(to: CGPoint(x: 0.66, y: 0.04))
            path.addLine(to: CGPoint(x: 0.57, y: 0.14))
            path.addLine(to: CGPoint(x: 0.67, y: 0.17))
            path.addLine(to: CGPoint(x: 0.58, y: 0.27))
            path.addLine(to: CGPoint(x: 0.67, y: 0.31))
            path.addQuadCurve(to: CGPoint(x: 0.62, y: 0.43), control: CGPoint(x: 0.62, y: 0.37))
            path.addQuadCurve(to: CGPoint(x: 0.99, y: 0.47), control: CGPoint(x: 0.84, y: 0.42))
            path.closeSubpath()
            path.addEllipse(in: CGRect(x: 0.38, y: 0.66, width: 0.10, height: 0.10))
        }
        let gape = MotifShapes.path { path in
            path.move(to: CGPoint(x: 0.60, y: 0.565))
            path.addQuadCurve(to: CGPoint(x: 0.92, y: 0.50), control: CGPoint(x: 0.80, y: 0.565))
        }
        return cut(gape, from: head)
    }
}
