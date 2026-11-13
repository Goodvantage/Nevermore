import CoreGraphics
import Foundation
import NevermoreCore

/// Large anchored decorations. Each draws into `bounds` (the whole pane,
/// y up) at full opacity; `OrnamentArt` applies the ornament's opacity.
enum OrnamentShapes {
    static func draw(_ kind: OrnamentKind, anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        guard !colors.isEmpty else { return }
        context.saveGState()
        context.clip(to: bounds)
        switch kind {
        case .moonLarge: moon(anchor: anchor, in: bounds, colors: colors, context: context)
        case .spiderWeb: spiderWeb(anchor: anchor, in: bounds, colors: colors, context: context)
        case .retroSun: retroSun(anchor: anchor, in: bounds, colors: colors, context: context)
        case .perspectiveGrid: perspectiveGrid(anchor: anchor, in: bounds, colors: colors, context: context)
        case .cornerStripes: cornerStripes(anchor: anchor, in: bounds, colors: colors, context: context)
        case .mountains: mountains(anchor: anchor, in: bounds, colors: colors, context: context)
        case .oceanWaves: oceanWaves(anchor: anchor, in: bounds, colors: colors, context: context)
        case .rollingHills: rollingHills(anchor: anchor, in: bounds, colors: colors, context: context)
        case .ringedPlanet: ringedPlanet(anchor: anchor, in: bounds, colors: colors, context: context)
        case .scanlines: scanlines(in: bounds, colors: colors, context: context)
        case .rainbowArc: rainbowArc(anchor: anchor, in: bounds, colors: colors, context: context)
        case .skyline: skyline(anchor: anchor, in: bounds, colors: colors, context: context)
        case .cloudBank: cloudBank(anchor: anchor, in: bounds, colors: colors, context: context)
        case .vines: vines(anchor: anchor, in: bounds, colors: colors, context: context)
        case .aurora: aurora(in: bounds, colors: colors, context: context)
        }
        context.restoreGState()
    }

    /// Frame for corner-anchored art: the bounds corner plus the unit axes
    /// that point into the pane along each adjacent edge, so `point(u, v)`
    /// measures `u` along the horizontal edge and `v` along the vertical.
    private struct CornerFrame {
        var origin: CGPoint
        var x: CGFloat
        var y: CGFloat

        func point(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + u * x, y: origin.y + v * y)
        }
    }

    private static func cornerFrame(_ anchor: OrnamentAnchor, in bounds: CGRect) -> CornerFrame {
        switch anchor {
        case .topLeading, .top:
            return CornerFrame(origin: CGPoint(x: bounds.minX, y: bounds.maxY), x: 1, y: -1)
        case .topTrailing:
            return CornerFrame(origin: CGPoint(x: bounds.maxX, y: bounds.maxY), x: -1, y: -1)
        case .bottomTrailing:
            return CornerFrame(origin: CGPoint(x: bounds.maxX, y: bounds.minY), x: -1, y: 1)
        case .bottomLeading, .bottom, .fill:
            return CornerFrame(origin: CGPoint(x: bounds.minX, y: bounds.minY), x: 1, y: 1)
        }
    }

    /// +1 when the ornament grows up from the bottom edge, -1 when it
    /// hangs down from the top.
    private static func edgeDirection(_ anchor: OrnamentAnchor) -> CGFloat {
        switch anchor {
        case .top, .topLeading, .topTrailing: return -1
        case .bottom, .bottomLeading, .bottomTrailing, .fill: return 1
        }
    }

    private static func color(_ colors: [CGColor], _ index: Int) -> CGColor {
        colors[index % colors.count]
    }

    private static func soft(_ color: CGColor, _ alpha: CGFloat) -> CGColor {
        color.copy(alpha: alpha) ?? color
    }

    /// A big full moon with a soft glow and translucent craters, inset in
    /// the anchor corner.
    private static func moon(anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        let rect = OrnamentArt.anchoredRect(anchor, in: bounds, fraction: 0.42)
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = side * 0.34
        let body = color(colors, 0)
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [soft(body, 0.45), soft(body, 0)] as CFArray, locations: [0, 1]) {
            context.drawRadialGradient(gradient, startCenter: center, startRadius: radius * 0.9,
                                       endCenter: center, endRadius: side * 0.75, options: [])
        }
        context.setFillColor(body)
        context.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.15))
        for (dx, dy, dr) in [(-0.3, 0.28, 0.2), (0.34, 0.1, 0.15), (0.05, -0.34, 0.12), (-0.42, -0.18, 0.09)] as [(CGFloat, CGFloat, CGFloat)] {
            let r = dr * radius
            context.fillEllipse(in: CGRect(x: center.x + dx * radius - r, y: center.y + dy * radius - r, width: r * 2, height: r * 2))
        }
    }

    /// A web strung across the anchor corner: radial threads, sagging ring
    /// arcs, and a small spider hanging from the middle thread.
    private static func spiderWeb(anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        let side = min(bounds.width, bounds.height) * 0.45
        let frame = cornerFrame(anchor, in: bounds)
        let web = color(colors, 0)
        let spokes = 7
        func spoke(_ index: Int, _ radius: CGFloat) -> CGPoint {
            let angle = CGFloat(index) / CGFloat(spokes - 1) * .pi / 2
            return frame.point(radius * cos(angle), radius * sin(angle))
        }
        context.setStrokeColor(web)
        context.setLineCap(.round)
        context.setLineWidth(1.8)
        for index in 0..<spokes {
            context.move(to: frame.origin)
            context.addLine(to: spoke(index, side))
        }
        context.strokePath()
        for ring in [0.22, 0.38, 0.54, 0.7, 0.86] as [CGFloat] {
            let radius = ring * side
            for index in 0..<(spokes - 1) {
                let midAngle = (CGFloat(index) + 0.5) / CGFloat(spokes - 1) * .pi / 2
                let control = frame.point(radius * 0.72 * cos(midAngle), radius * 0.72 * sin(midAngle))
                context.move(to: spoke(index, radius))
                context.addQuadCurve(to: spoke(index + 1, radius), control: control)
            }
        }
        context.strokePath()
        // The spider drops toward the pane interior on its own thread.
        let hang = spoke(3, side * 0.55)
        let drop = CGPoint(x: hang.x, y: hang.y + side * 0.1 * frame.y)
        let bodyR = side * 0.05
        let body = CGPoint(x: drop.x, y: drop.y + bodyR * 0.7 * frame.y)
        context.setLineWidth(1.5)
        context.move(to: hang)
        context.addLine(to: drop)
        context.strokePath()
        context.setFillColor(web)
        context.fillEllipse(in: CGRect(x: body.x - bodyR, y: body.y - bodyR, width: bodyR * 2, height: bodyR * 2))
        let headR = bodyR * 0.55
        let head = CGPoint(x: body.x, y: body.y + (bodyR + headR * 0.6) * frame.y)
        context.fillEllipse(in: CGRect(x: head.x - headR, y: head.y - headR, width: headR * 2, height: headR * 2))
        context.setLineWidth(1.5)
        for s in [-1.0, 1.0] as [CGFloat] {
            for leg in 0..<3 {
                let fan = (CGFloat(leg) - 1) * 0.5
                context.move(to: CGPoint(x: body.x + s * bodyR * 0.55, y: body.y - fan * bodyR * 0.5 * frame.y))
                context.addLine(to: CGPoint(x: body.x + s * bodyR * 1.5, y: body.y - (fan + 0.55) * bodyR * frame.y))
            }
        }
        context.strokePath()
    }

    /// An outrun sun: a gradient disc sliced by horizontal gaps that
    /// thicken downward. Bottom/top anchors sink it behind the edge so
    /// about 60 percent shows; corner anchors get the whole disc.
    private static func retroSun(anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        let radius = min(bounds.width, bounds.height) * 0.32
        let sunk = anchor == .bottom || anchor == .top || anchor == .fill
        let center: CGPoint
        switch anchor {
        case .bottom, .fill:
            center = CGPoint(x: bounds.midX, y: bounds.minY + radius * 0.2)
        case .top:
            center = CGPoint(x: bounds.midX, y: bounds.maxY - radius * 0.2)
        default:
            center = cornerFrame(anchor, in: bounds).point(radius * 1.02, radius * 1.02)
        }
        context.saveGState()
        context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                     colors: [color(colors, 0), color(colors, 1)] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: center.x, y: center.y + radius),
                                       end: CGPoint(x: center.x, y: center.y - radius), options: [])
        }
        // A sunk sun's lower half is clipped away, so its gaps start higher.
        context.setBlendMode(.clear)
        var gapTop = center.y + radius * (sunk ? 0.42 : 0.05)
        var gap = radius * 0.028
        while gapTop - gap > center.y - radius {
            context.fill(CGRect(x: center.x - radius, y: gapTop - gap, width: radius * 2, height: gap))
            gapTop -= gap + radius * 0.062
            gap *= 1.42
        }
        context.restoreGState()
    }

    /// A floor grid filling the pane's bottom (or top) 35 percent:
    /// horizontal lines bunching toward the horizon, spokes converging on
    /// a central vanishing point, everything fading out near the horizon.
    private static func perspectiveGrid(anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        let dir = edgeDirection(anchor)
        let height = bounds.height * 0.35
        let baseY = dir > 0 ? bounds.minY : bounds.maxY
        let horizonY = baseY + dir * height
        let floorRect = CGRect(x: bounds.minX, y: min(baseY, horizonY), width: bounds.width, height: height)
        let vanishing = CGPoint(x: bounds.midX, y: horizonY)
        context.saveGState()
        context.clip(to: floorRect)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setStrokeColor(color(colors, 0))
        context.setLineWidth(1.5)
        for index in 1...9 {
            let t = CGFloat(index) / 9
            let y = horizonY - dir * height * t * t
            context.move(to: CGPoint(x: floorRect.minX, y: y))
            context.addLine(to: CGPoint(x: floorRect.maxX, y: y))
        }
        for index in -8...8 {
            context.move(to: vanishing)
            context.addLine(to: CGPoint(x: bounds.midX + CGFloat(index) * bounds.width / 5.5, y: baseY))
        }
        context.strokePath()
        context.setBlendMode(.destinationIn)
        let opaque = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let clear = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)
        if let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [opaque, clear] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(fade, start: CGPoint(x: bounds.midX, y: baseY), end: CGPoint(x: bounds.midX, y: horizonY), options: [])
        }
        context.endTransparencyLayer()
        context.restoreGState()
        context.setStrokeColor(color(colors, 1))
        context.setLineWidth(2)
        context.move(to: CGPoint(x: bounds.minX, y: horizonY))
        context.addLine(to: CGPoint(x: bounds.maxX, y: horizonY))
        context.strokePath()
    }

    /// Parallel 45-degree stripes, one per color, tiling a triangle that
    /// fills the anchor corner.
    private static func cornerStripes(anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        let frame = cornerFrame(anchor, in: bounds)
        // Bands sit perpendicular to the corner bisector; a band `w` points
        // deep spans `w * sqrt(2)` along each edge.
        let width = max(18, min(bounds.width, bounds.height) * 0.3 / CGFloat(colors.count))
        let leg = width * sqrt(2)
        for index in 0..<colors.count {
            let inner = CGFloat(index) * leg, outer = inner + leg
            let path = CGMutablePath()
            path.move(to: frame.point(inner, 0))
            path.addLine(to: frame.point(outer, 0))
            path.addLine(to: frame.point(0, outer))
            path.addLine(to: frame.point(0, inner))
            path.closeSubpath()
            context.setFillColor(color(colors, index))
            context.addPath(path)
            context.fillPath()
        }
    }

    /// Two jagged mountain silhouettes along the anchor edge, the taller
    /// range behind.
    private static func mountains(anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        let dir = edgeDirection(anchor)
        let edge = dir > 0 ? bounds.minY : bounds.maxY
        func ridge(_ points: [(CGFloat, CGFloat)], _ fill: CGColor) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: bounds.minX, y: edge))
            for (fx, fy) in points {
                path.addLine(to: CGPoint(x: bounds.minX + fx * bounds.width, y: edge + dir * fy * bounds.height))
            }
            path.addLine(to: CGPoint(x: bounds.maxX, y: edge))
            path.closeSubpath()
            context.setFillColor(fill)
            context.addPath(path)
            context.fillPath()
        }
        ridge([(0, 0.1), (0.08, 0.21), (0.16, 0.12), (0.27, 0.25), (0.37, 0.12), (0.47, 0.2),
               (0.58, 0.1), (0.69, 0.235), (0.8, 0.13), (0.9, 0.18), (1, 0.09)], color(colors, 0))
        ridge([(0, 0.05), (0.11, 0.15), (0.21, 0.07), (0.33, 0.17), (0.44, 0.06), (0.55, 0.135),
               (0.66, 0.05), (0.77, 0.16), (0.88, 0.08), (1, 0.12)], color(colors, 1))
    }

    /// Three sine-wave bands stacked along the anchor edge, each with its
    /// own phase, wavelength and amplitude.
    private static func oceanWaves(anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        let dir = edgeDirection(anchor)
        let edge = dir > 0 ? bounds.minY : bounds.maxY
        let layers: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (0.175, 0.045, 0.95, 0.4),
            (0.115, 0.04, 0.7, 2.4),
            (0.062, 0.035, 0.5, 4.6),
        ]
        for (index, layer) in layers.enumerated() {
            let (level, amplitude, wavelength, phase) = layer
            let path = CGMutablePath()
            path.move(to: CGPoint(x: bounds.minX, y: edge))
            for step in 0...120 {
                let fx = CGFloat(step) / 120
                let y = edge + dir * (level + amplitude * sin(fx * .pi * 2 / wavelength + phase)) * bounds.height
                path.addLine(to: CGPoint(x: bounds.minX + fx * bounds.width, y: y))
            }
            path.addLine(to: CGPoint(x: bounds.maxX, y: edge))
            path.closeSubpath()
            context.setFillColor(color(colors, index))
            context.addPath(path)
            context.fillPath()
        }
    }

    /// Three overlapping wide-ellipse hill domes along the anchor edge.
    private static func rollingHills(anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        let dir = edgeDirection(anchor)
        let edge = dir > 0 ? bounds.minY : bounds.maxY
        let hills: [(CGFloat, CGFloat, CGFloat)] = [(0.3, 0.6, 0.24), (0.74, 0.5, 0.165), (0.45, 0.65, 0.1)]
        let lift = bounds.height * 0.02
        for (index, hill) in hills.enumerated() {
            let rx = hill.1 * bounds.width, ry = hill.2 * bounds.height + lift
            let cx = bounds.minX + hill.0 * bounds.width, cy = edge - dir * lift
            context.setFillColor(color(colors, index))
            context.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
        }
    }

    /// A banded planet in the anchor corner with a tilted ring drawn in
    /// two passes so its far half hides behind the disc.
    private static func ringedPlanet(anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        let rect = OrnamentArt.anchoredRect(anchor, in: bounds, fraction: 0.4)
        let side = min(rect.width, rect.height)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = side * 0.28
        let ringRX = side * 0.44, ringRY = side * 0.14, tilt = -18 * CGFloat.pi / 180
        var transform = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: tilt)
        let ring = CGPath(ellipseIn: CGRect(x: -ringRX, y: -ringRY, width: ringRX * 2, height: ringRY * 2), transform: &transform)
        let axis = CGPoint(x: cos(tilt), y: sin(tilt)), normal = CGPoint(x: -sin(tilt), y: cos(tilt))
        let reach = side * 2
        func halfPlane(_ sign: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: center.x + axis.x * reach, y: center.y + axis.y * reach))
            path.addLine(to: CGPoint(x: center.x - axis.x * reach, y: center.y - axis.y * reach))
            path.addLine(to: CGPoint(x: center.x - axis.x * reach + normal.x * reach * sign, y: center.y - axis.y * reach + normal.y * reach * sign))
            path.addLine(to: CGPoint(x: center.x + axis.x * reach + normal.x * reach * sign, y: center.y + axis.y * reach + normal.y * reach * sign))
            path.closeSubpath()
            return path
        }
        context.setStrokeColor(color(colors, 1))
        context.setLineWidth(max(1.5, side * 0.05))
        context.saveGState()
        context.addPath(halfPlane(1))
        context.clip()
        context.addPath(ring)
        context.strokePath()
        context.restoreGState()
        context.saveGState()
        context.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.clip()
        context.setFillColor(color(colors, 0))
        context.fill(CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.1))
        for offset in [-0.5, -0.02, 0.45] as [CGFloat] {
            context.fillEllipse(in: CGRect(x: center.x - radius * 1.6, y: center.y + offset * radius - radius * 0.16,
                                           width: radius * 3.2, height: radius * 0.32))
        }
        context.restoreGState()
        context.saveGState()
        context.addPath(halfPlane(-1))
        context.clip()
        context.addPath(ring)
        context.strokePath()
        context.restoreGState()
    }

    /// One-point horizontal rules every three points across the pane.
    private static func scanlines(in bounds: CGRect, colors: [CGColor], context: CGContext) {
        context.setFillColor(color(colors, 0))
        var rects: [CGRect] = []
        var y = bounds.minY + 0.5
        while y < bounds.maxY {
            rects.append(CGRect(x: bounds.minX, y: y, width: bounds.width, height: 1))
            y += 3
        }
        context.fill(rects)
    }

    /// A concentric-band rainbow rising from the anchor edge with a puffy
    /// cloud at each foot.
    private static func rainbowArc(anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        let band: CGFloat = 14
        let outer = min(bounds.width, bounds.height) * 0.58
        let dir = edgeDirection(anchor)
        let edge = dir > 0 ? bounds.minY : bounds.maxY
        let cx: CGFloat
        switch anchor {
        case .bottomTrailing, .topTrailing: cx = bounds.maxX - outer * 1.1
        case .bottomLeading, .topLeading: cx = bounds.minX + outer * 1.1
        default: cx = bounds.midX
        }
        let center = CGPoint(x: cx, y: edge)
        for index in 0..<colors.count {
            let radius = outer - CGFloat(index) * band - band / 2
            guard radius > band / 2 else { break }
            context.setStrokeColor(color(colors, index))
            context.setLineWidth(band)
            context.addArc(center: center, radius: radius, startAngle: dir > 0 ? 0 : .pi, endAngle: dir > 0 ? .pi : 2 * .pi, clockwise: false)
            context.strokePath()
        }
        context.setFillColor(lightest(colors))
        for foot in [cx - outer + 4, cx + outer - 4] {
            context.addPath(cloudPath(center: CGPoint(x: foot, y: edge + dir * 10), radius: 17, out: dir))
            context.fillPath()
        }
    }

    /// A row of puffy cloud blobs hugging the anchor edge.
    private static func cloudBank(anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        let dir = edgeDirection(anchor)
        let edge = dir > 0 ? bounds.minY : bounds.maxY
        let positions: [CGFloat] = [0.05, 0.21, 0.38, 0.55, 0.71, 0.88]
        let scales: [CGFloat] = [1.0, 1.25, 0.9, 1.15, 0.95, 1.3]
        context.setFillColor(color(colors, 0))
        for (index, fx) in positions.enumerated() {
            let r = bounds.height * 0.075 * scales[index % scales.count]
            let center = CGPoint(x: bounds.minX + fx * bounds.width, y: edge + dir * (r * 0.5 + CGFloat(index % 2) * 4))
            context.addPath(cloudPath(center: center, radius: r, out: dir))
            context.fillPath()
        }
    }

    /// A silhouette of buildings along the anchor edge. Windows are cut out
    /// of the first color and, given a second color, lit with it.
    private static func skyline(anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        let dir = edgeDirection(anchor)
        let edge = dir > 0 ? bounds.minY : bounds.maxY
        let specs: [(CGFloat, CGFloat)] = [(0.075, 0.55), (0.06, 0.9), (0.09, 0.42), (0.07, 0.78), (0.05, 0.6),
                                           (0.085, 1.0), (0.06, 0.5), (0.08, 0.68), (0.055, 0.85), (0.1, 0.45), (0.07, 0.72), (0.06, 0.95)]
        let path = CGMutablePath()
        let windows = CGMutablePath()
        var x = bounds.minX, index = 0
        while x < bounds.maxX {
            let (fw, fh) = specs[index % specs.count]
            let width = fw * bounds.width, height = fh * bounds.height * 0.2
            let base = CGRect(x: x, y: min(edge, edge + dir * height), width: width, height: height)
            path.addRect(base)
            if fh > 0.85 {
                path.addRect(CGRect(x: x + width / 2 - 1.5, y: min(edge + dir * height, edge + dir * (height + 7)),
                                    width: 3, height: 7))
            }
            let window = max(2.5, width * 0.15), margin = width * 0.14
            var wy = base.minY + 4
            while wy + window < base.maxY - margin {
                var wx = base.minX + margin
                while wx + window < base.maxX - margin {
                    path.addRect(CGRect(x: wx, y: wy, width: window, height: window))
                    windows.addRect(CGRect(x: wx, y: wy, width: window, height: window))
                    wx += window * 1.9
                }
                wy += window * 1.6
            }
            x += width
            index += 1
        }
        context.setFillColor(color(colors, 0))
        context.addPath(path)
        context.fillPath(using: .evenOdd)
        guard colors.count > 1 else { return }
        context.setFillColor(color(colors, 1))
        context.addPath(windows)
        context.fillPath()
    }

    /// Wavy vines growing from the anchor corner along both edges, each
    /// ending in a curl and sprouting leaves and five-petal flowers.
    private static func vines(anchor: OrnamentAnchor, in bounds: CGRect, colors: [CGColor], context: CGContext) {
        let frame = cornerFrame(anchor, in: bounds)
        let shortSide = min(bounds.width, bounds.height)
        let length = shortSide * 0.5
        let amplitude = shortSide * 0.03
        let stem = color(colors, 0), petal = color(colors, 1)
        context.setLineCap(.round)
        for vine in 0..<2 {
            let phase = CGFloat(vine) * 1.7
            // The baseline is one amplitude inside the pane so the wobble
            // never clips the edge.
            func point(at t: CGFloat) -> CGPoint {
                let wobble = amplitude * (1 + sin(t / length * .pi * 5 + phase))
                return vine == 0 ? frame.point(t, wobble) : frame.point(wobble, t)
            }
            let path = CGMutablePath()
            path.move(to: frame.origin)
            for step in 1...48 {
                path.addLine(to: point(at: CGFloat(step) / 48 * length))
            }
            // Tendril curl at the tip: a shrinking spiral that starts
            // exactly where the stem ends. The stem tip sits `curlR` from
            // the curl center along the frame's axis, so aim the spiral's
            // first point back at it instead of assuming a fixed direction.
            let curlR: CGFloat = 9
            let tipWobble = amplitude * (1 + sin(.pi * 5 + phase))
            let tip = point(at: length)
            let curlCenter = vine == 0 ? frame.point(length, tipWobble + curlR) : frame.point(tipWobble + curlR, length)
            let startAngle = atan2(tip.y - curlCenter.y, tip.x - curlCenter.x)
            for step in 1...30 {
                let angle = startAngle + CGFloat(step) / 30 * .pi * 3
                let r = curlR * (1 - CGFloat(step) / 40)
                path.addLine(to: CGPoint(x: curlCenter.x + r * cos(angle), y: curlCenter.y + r * sin(angle)))
            }
            context.setStrokeColor(stem)
            context.setLineWidth(2)
            context.addPath(path)
            context.strokePath()
            context.setFillColor(stem)
            for leaf in 0..<8 {
                let base = point(at: (CGFloat(leaf) + 0.7) * length / 9)
                let lean: CGFloat = leaf % 2 == 0 ? 0.55 : -0.15
                let size: CGFloat = 10 + CGFloat(leaf % 3)
                // Leaves always grow toward the pane interior, alternating
                // their tilt along the stem.
                let tip = vine == 0
                    ? CGPoint(x: base.x + lean * size * frame.x, y: base.y + size * frame.y)
                    : CGPoint(x: base.x + size * frame.x, y: base.y + lean * size * frame.y)
                context.addPath(leafPath(from: base, to: tip))
                context.fillPath()
            }
            for t in (vine == 0 ? [0.3, 0.72] : [0.5]) as [CGFloat] {
                flower(at: point(at: t * length), petal: petal, center: stem, context: context)
            }
        }
    }

    /// A pointed-oval leaf: two quadratic curves between base and tip.
    private static func leafPath(from base: CGPoint, to tip: CGPoint) -> CGPath {
        let mid = CGPoint(x: (base.x + tip.x) / 2, y: (base.y + tip.y) / 2)
        let dx = tip.x - base.x, dy = tip.y - base.y
        let length = max(1, hypot(dx, dy))
        let px = -dy / length, py = dx / length, bulge = length * 0.33
        let path = CGMutablePath()
        path.move(to: base)
        path.addQuadCurve(to: tip, control: CGPoint(x: mid.x + px * bulge, y: mid.y + py * bulge))
        path.addQuadCurve(to: base, control: CGPoint(x: mid.x - px * bulge, y: mid.y - py * bulge))
        path.closeSubpath()
        return path
    }

    /// A five-petal flower: five small circles around a contrasting dot.
    private static func flower(at center: CGPoint, petal: CGColor, center dot: CGColor, context: CGContext) {
        let petalR: CGFloat = 4, spread: CGFloat = 5.6
        context.setFillColor(petal)
        for index in 0..<5 {
            let angle = CGFloat(index) * .pi * 2 / 5 - .pi / 2
            context.fillEllipse(in: CGRect(x: center.x + cos(angle) * spread - petalR, y: center.y + sin(angle) * spread - petalR,
                                           width: petalR * 2, height: petalR * 2))
        }
        context.setFillColor(dot)
        context.fillEllipse(in: CGRect(x: center.x - 2.6, y: center.y - 2.6, width: 5.2, height: 5.2))
    }

    /// A puffy cloud made of four overlapping circles; `out` points away
    /// from the edge the cloud sits on (+1 up, -1 down).
    private static func cloudPath(center: CGPoint, radius: CGFloat, out: CGFloat) -> CGPath {
        let path = CGMutablePath()
        for (dx, dy, dr) in [(0, 0, 1.0), (-0.95, -0.18, 0.72), (0.92, -0.14, 0.65), (-0.08, 0.52, 0.55)] as [(CGFloat, CGFloat, CGFloat)] {
            let r = dr * radius
            path.addEllipse(in: CGRect(x: center.x + dx * radius - r, y: center.y + dy * radius * out - r, width: r * 2, height: r * 2))
        }
        return path
    }

    /// The palette's brightest color, for rainbow clouds.
    private static func lightest(_ colors: [CGColor]) -> CGColor {
        func luminance(_ color: CGColor) -> CGFloat {
            guard let components = color.components else { return 0 }
            if components.count >= 3 { return 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2] }
            return components.first ?? 0
        }
        return colors.max(by: { luminance($0) < luminance($1) }) ?? colors[0]
    }
}
