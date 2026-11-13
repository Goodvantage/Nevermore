import CoreGraphics
import NevermoreCore

/// Motif geometry. Every shape is built in a unit square with a bottom-left
/// origin (y up) and keeps roughly 5% padding inside it; `MotifArt` scales,
/// rotates and styles it. The shapes themselves live in the
/// `MotifShapes+*.swift` files, one family per file.
enum MotifShapes {
    static func parts(for motif: ThemeMotif) -> [MotifPart] {
        switch motif {
        case .dot: dot()
        case .ring: ring()
        case .triangle: triangle()
        case .squiggle: squiggle()
        case .zigzag: zigzag()
        case .halfCircle: halfCircle()
        case .cross: cross()
        case .star: star()
        case .sparkle: sparkle()
        case .heart: heart()
        case .bolt: bolt()
        case .diamond: diamond()
        case .spiral: spiral()
        case .musicNote: musicNote()
        case .pixelHeart: pixelHeart()
        case .pixelStar: pixelStar()
        case .bat: bat()
        case .pumpkin: pumpkin()
        case .ghost: ghost()
        case .candyCorn: candyCorn()
        case .moon: moon()
        case .raven: raven()
        case .feather: feather()
        case .planet: planet()
        case .rocket: rocket()
        case .comet: comet()
        case .bubble: bubble()
        case .fish: fish()
        case .starfish: starfish()
        case .shell: shell()
        case .seaweed: seaweed()
        case .flower: flower()
        case .leaf: leaf()
        case .mushroom: mushroom()
        case .cloud: cloud()
        case .lemon: lemon()
        case .cherry: cherry()
        case .sun: sun()
        case .snowflake: snowflake()
        }
    }

    // MARK: Building blocks shared by the shape files

    static func path(_ build: (CGMutablePath) -> Void) -> CGPath {
        let path = CGMutablePath()
        build(path)
        return path.copy() ?? path
    }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    static func polygon(_ points: [CGPoint]) -> CGPath {
        path { $0.addLines(between: points); $0.closeSubpath() }
    }

    /// A regular star with `points` tips around `center`.
    static func starPolygon(points: Int, center: CGPoint = CGPoint(x: 0.5, y: 0.5), outer: CGFloat, inner: CGFloat, rotation: CGFloat = 0) -> CGPath {
        let vertices = (0..<(points * 2)).map { index -> CGPoint in
            let radius = index.isMultiple(of: 2) ? outer : inner
            let angle = rotation + .pi / 2 + CGFloat(index) * .pi / CGFloat(points)
            return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        return polygon(vertices)
    }

    /// Unit-square pixel art: `rows` top first, `#` marks a filled cell.
    static func pixels(_ rows: [String]) -> CGPath {
        let height = rows.count, width = rows.map(\.count).max() ?? 0
        guard height > 0, width > 0 else { return CGMutablePath() }
        let cell = 0.9 / CGFloat(max(width, height))
        let originX = (1 - cell * CGFloat(width)) / 2, originY = (1 - cell * CGFloat(height)) / 2
        // Merge the cells into one outline: separate squares would show
        // anti-aliased seams when filled and a grid when outlined.
        var merged: CGPath = CGMutablePath()
        for (row, line) in rows.enumerated() {
            for (column, character) in line.enumerated() where character == "#" {
                // A hair of overlap lets the union close shared edges.
                let square = CGPath(rect: CGRect(x: originX + CGFloat(column) * cell, y: originY + CGFloat(height - 1 - row) * cell, width: cell, height: cell).insetBy(dx: -0.001, dy: -0.001), transform: nil)
                merged = merged.isEmpty ? square : merged.union(square)
            }
        }
        return merged
    }
}
