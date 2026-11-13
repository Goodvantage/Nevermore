import CoreGraphics

extension OrnamentShapes {
    /// Northern lights: three wavy curtains across the top of the pane, each
    /// brightest along its lower hem and fading upward, with faint vertical
    /// rays for the curtain texture.
    static func aurora(in bounds: CGRect, colors: [CGColor], context: CGContext) {
        guard !colors.isEmpty else { return }
        let height = bounds.height * 0.42
        let steps = 48
        for band in 0..<3 {
            let color = colors[band % colors.count]
            let phase = CGFloat(band) * 1.7
            let amplitude = height * (0.12 + 0.04 * CGFloat(band))
            let hemBase = bounds.maxY - height * (0.55 + 0.14 * CGFloat(band))
            let thickness = height * (0.5 - 0.08 * CGFloat(band))
            func hem(_ x: CGFloat) -> CGFloat {
                let t = (x - bounds.minX) / max(1, bounds.width)
                return hemBase + amplitude * sin(t * .pi * 2.2 + phase) + amplitude * 0.35 * sin(t * .pi * 5.3 + phase * 2)
            }
            let curtain = CGMutablePath()
            curtain.move(to: CGPoint(x: bounds.minX, y: hem(bounds.minX)))
            for step in 1...steps {
                let x = bounds.minX + bounds.width * CGFloat(step) / CGFloat(steps)
                curtain.addLine(to: CGPoint(x: x, y: hem(x)))
            }
            for step in stride(from: steps, through: 0, by: -1) {
                let x = bounds.minX + bounds.width * CGFloat(step) / CGFloat(steps)
                curtain.addLine(to: CGPoint(x: x, y: hem(x) + thickness))
            }
            curtain.closeSubpath()
            context.saveGState()
            context.addPath(curtain)
            context.clip()
            let clear = color.copy(alpha: 0) ?? color
            if let gradient = CGGradient(colorsSpace: color.colorSpace, colors: [color, clear] as CFArray, locations: [0, 1]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: bounds.midX, y: hemBase - amplitude * 1.4),
                                           end: CGPoint(x: bounds.midX, y: hemBase + amplitude + thickness), options: [.drawsBeforeStartLocation])
            }
            // Rays: thin vertical strokes inside the curtain.
            context.setStrokeColor(color.copy(alpha: 0.35) ?? color)
            context.setLineWidth(max(1.5, bounds.width / 400))
            var x = bounds.minX + CGFloat(band) * 7
            while x < bounds.maxX {
                context.move(to: CGPoint(x: x, y: hem(x)))
                context.addLine(to: CGPoint(x: x, y: hem(x) + thickness * 0.8))
                x += max(10, bounds.width / 60)
            }
            context.strokePath()
            context.restoreGState()
        }
    }
}
