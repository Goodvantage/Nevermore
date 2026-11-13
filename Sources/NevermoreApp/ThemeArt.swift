import AppKit
import NevermoreCore

/// One piece of a motif, in a unit square with a bottom-left origin (Core
/// Graphics coordinates, y up). Motif shapes are pure geometry; `MotifArt`
/// decides how a style fills, outlines or lights them.
struct MotifPart {
    enum Kind {
        /// A closed region: filled in `.fill` style, outlined otherwise.
        case area
        /// An open or thin stroke, drawn as a line in every style.
        case line
    }

    let path: CGPath
    let kind: Kind
    /// 0 is the body color; 1 and 2 are a multi-part motif's other colors.
    let colorSlot: Int
    /// Even-odd filling punches holes (a pumpkin's face, a ghost's eyes).
    let evenOdd: Bool

    init(_ path: CGPath, _ kind: Kind = .area, slot: Int = 0, evenOdd: Bool = false) {
        self.path = path
        self.kind = kind
        self.colorSlot = slot
        self.evenOdd = evenOdd
    }
}

/// Draws theme motifs with Core Graphics.
enum MotifArt {
    /// Line width for `.line` parts and outlines, as a fraction of the motif size.
    static let lineFraction: CGFloat = 0.08

    /// Draws `motif` inside the square `rect`, rotated by `rotation` radians
    /// around its center. `colors` are the instance's colors, body first.
    static func draw(_ motif: ThemeMotif, in rect: CGRect, rotation: CGFloat = 0, colors: [CGColor], style: MotifStyle, context: CGContext) {
        guard let body = colors.first else { return }
        let size = min(rect.width, rect.height)
        // Shadow blur ignores the transform, so measure the context's scale
        // (a Retina tile is drawn at 2x) before scaling to the unit square.
        let ctm = context.ctm
        let baseScale = sqrt(ctm.a * ctm.a + ctm.b * ctm.b)
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: rotation)
        context.translateBy(x: -size / 2, y: -size / 2)
        context.scaleBy(x: size, y: size)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if style == .glow {
            context.setShadow(offset: .zero, blur: size * 0.3 * baseScale, color: body)
        }
        for part in MotifShapes.parts(for: motif) {
            let color = part.colorSlot < colors.count ? colors[part.colorSlot] : body
            // Outlines trace the merged silhouette: a cloud's overlapping
            // puffs would otherwise each draw their own circle.
            let outlined = part.kind == .area && style != .fill
            context.addPath(outlined ? part.path.normalized(using: part.evenOdd ? .evenOdd : .winding) : part.path)
            switch (part.kind, style) {
            case (.area, .fill):
                context.setFillColor(color)
                context.fillPath(using: part.evenOdd ? .evenOdd : .winding)
            case (.line, .fill):
                context.setStrokeColor(color)
                context.setLineWidth(lineFraction * 1.15)
                context.strokePath()
            case (_, .stroke), (_, .glow):
                context.setStrokeColor(color)
                context.setLineWidth(lineFraction)
                context.strokePath()
            }
        }
    }

    /// A motif as a standalone image, for the empty state and celebrations.
    static func image(_ motif: ThemeMotif, colors: [ThemeColor], style: MotifStyle, size: CGFloat) -> NSImage {
        let cgColors = colors.map { NSColor(theme: $0).cgColor }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let inset = style == .glow ? bounds.width * 0.18 : 0
            draw(motif, in: bounds.insetBy(dx: inset, dy: inset), colors: cgColors, style: style, context: context)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Renders a theme's wallpaper tile: the scattered motifs from
/// `WallpaperLayout`, at full color. The caller applies the wallpaper's
/// opacity to the whole layer, which is what the contrast audit assumes.
@MainActor enum WallpaperRenderer {
    /// Everything a tile's pixels depend on. The wallpaper's opacity is not
    /// part of it: the layer showing the tile applies that.
    private struct TileKey: Equatable {
        let motifs: [MotifSpec]
        let density: ThemeDensity
        let seed: UInt64
    }

    /// Tiles of one wallpaper, by backing scale. Switching themes or editing
    /// the motifs drops the previous tiles, so browsing every theme keeps
    /// one in memory.
    private static var tiles: (key: TileKey, byScale: [CGFloat: CGImage])?

    static func tile(for theme: Theme, scale: CGFloat) -> CGImage? {
        guard !theme.wallpaper.motifs.isEmpty else { return nil }
        let key = TileKey(motifs: theme.wallpaper.motifs, density: theme.wallpaper.density, seed: WallpaperLayout.seed(for: theme.id))
        if tiles?.key != key { tiles = (key, [:]) }
        if let cached = tiles?.byScale[scale] { return cached }
        let points = CGFloat(WallpaperLayout.tileSize)
        let pixels = Int((points * scale).rounded())
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        draw(theme.wallpaper, seed: key.seed, tileSize: points, context: context)
        let image = context.makeImage()
        tiles?.byScale[scale] = image
        return image
    }

    /// Draws one tile's motifs. Motifs near an edge are repeated on the
    /// opposite edge so neighboring tiles join without a seam.
    static func draw(_ wallpaper: ThemeWallpaper, seed: UInt64, tileSize: CGFloat, context: CGContext) {
        let colorSets = wallpaper.motifs.map { $0.colors.map { NSColor(theme: $0).cgColor } }
        for placement in WallpaperLayout.scatter(wallpaper, tileSize: Double(tileSize), seed: seed) {
            let spec = wallpaper.motifs[placement.specIndex]
            let palette = colorSets[placement.specIndex]
            guard !palette.isEmpty else { continue }
            let colors = spec.motif.partCount > 1 ? palette : [palette[placement.colorIndex % palette.count]]
            let size = CGFloat(placement.size)
            // Placements use a top-left origin; Core Graphics is y-up.
            let center = CGPoint(x: placement.x, y: Double(tileSize) - placement.y)
            let reach = size * (spec.style == .glow ? 1.0 : 0.6)
            for dx in [-tileSize, 0, tileSize] where center.x + dx + reach > 0 && center.x + dx - reach < tileSize {
                for dy in [-tileSize, 0, tileSize] where center.y + dy + reach > 0 && center.y + dy - reach < tileSize {
                    let rect = CGRect(x: center.x + dx - size / 2, y: center.y + dy - size / 2, width: size, height: size)
                    MotifArt.draw(spec.motif, in: rect, rotation: CGFloat(placement.rotation), colors: colors, style: spec.style, context: context)
                }
            }
        }
    }
}

/// Draws a theme's anchored ornaments over the backdrop gradient.
enum OrnamentArt {
    /// Draws every ornament of `wallpaper` into `bounds` (y-up), each at its
    /// own opacity.
    static func draw(_ ornaments: [OrnamentSpec], in bounds: CGRect, context: CGContext) {
        for ornament in ornaments where ornament.opacity > 0 && !ornament.colors.isEmpty {
            let colors = ornament.colors.map { NSColor(theme: $0).cgColor }
            context.saveGState()
            context.setAlpha(CGFloat(ornament.opacity))
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            OrnamentShapes.draw(ornament.kind, anchor: ornament.anchor, in: bounds, colors: colors, context: context)
            context.endTransparencyLayer()
            context.restoreGState()
        }
    }

    /// Where an ornament is designed to sit: the anchor a newly added one
    /// starts at, and the one the art sheet shows it at.
    static func usualAnchor(for kind: OrnamentKind) -> OrnamentAnchor {
        switch kind {
        case .moonLarge, .ringedPlanet, .cornerStripes: .topTrailing
        case .spiderWeb, .vines: .topLeading
        case .scanlines: .fill
        case .cloudBank, .aurora: .top
        case .retroSun, .perspectiveGrid, .mountains, .oceanWaves, .rollingHills, .rainbowArc, .skyline: .bottom
        }
    }

    /// The square an anchored ornament occupies: a share of the pane's
    /// shorter side, pinned to the anchor.
    static func anchoredRect(_ anchor: OrnamentAnchor, in bounds: CGRect, fraction: CGFloat) -> CGRect {
        let side = min(bounds.width, bounds.height) * fraction
        switch anchor {
        case .topLeading: return CGRect(x: bounds.minX, y: bounds.maxY - side, width: side, height: side)
        case .topTrailing: return CGRect(x: bounds.maxX - side, y: bounds.maxY - side, width: side, height: side)
        case .bottomLeading: return CGRect(x: bounds.minX, y: bounds.minY, width: side, height: side)
        case .bottomTrailing: return CGRect(x: bounds.maxX - side, y: bounds.minY, width: side, height: side)
        case .top: return CGRect(x: bounds.minX, y: bounds.maxY - side, width: bounds.width, height: side)
        case .bottom: return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: side)
        case .fill: return bounds
        }
    }
}
