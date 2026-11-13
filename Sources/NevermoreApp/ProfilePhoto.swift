import AppKit

/// Shared rendering for sidebar and transcript photos. Crop the center
/// square before drawing so a portrait keeps its proportions.
@MainActor enum ProfilePhoto {
    static func draw(_ image: NSImage, in rect: NSRect) {
        let circle = NSBezierPath(ovalIn: rect)
        NSGraphicsContext.saveGraphicsState()
        circle.addClip()
        let side = min(image.size.width, image.size.height)
        let square = NSRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
        image.draw(in: rect, from: square, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.setStroke(); circle.lineWidth = 0.5; circle.stroke()
    }
}
