import AppKit
import ImageIO
import NevermoreCore
import UniformTypeIdentifiers

/// A miniature conversation window in a theme's colors: the Settings
/// gallery's cards and the `--theme-art-sheet` posters.
@MainActor enum ThemePoster {
    /// The window size a poster depicts; it is scaled to the output size.
    static let virtualSize = CGSize(width: 720, height: 450)
    /// One cached poster per preset, size, Classic light or dark look and
    /// wallpaper switch: at most a few dozen.
    private struct Slot: Hashable {
        let id: ThemeID
        let width: Int
        let height: Int
        let dark: Bool
        let decorations: Bool
    }

    /// Each slot remembers the theme it drew. A customized preset replaces
    /// its own poster instead of adding one per edit, and theme switches
    /// reuse what is there.
    private static var cache: [Slot: (theme: Theme, image: NSImage)] = [:]

    static func image(for theme: Theme, size: CGSize, appearance: NSAppearance? = nil) -> NSImage {
        let resolved = appearance ?? NSApp.effectiveAppearance
        let dark = resolved.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let decorations = ThemeManager.shared.showsDecorations
        let slot = Slot(id: theme.id, width: Int(size.width), height: Int(size.height), dark: theme.isClassic && dark, decorations: decorations)
        if let cached = cache[slot], cached.theme == theme { return cached.image }
        let scale: CGFloat = 2
        guard let cgImage = render(theme, pixelSize: CGSize(width: size.width * scale, height: size.height * scale), dark: dark, decorations: decorations) else { return NSImage(size: size) }
        let image = NSImage(cgImage: cgImage, size: size)
        cache[slot] = (theme, image)
        return image
    }

    static func render(_ theme: Theme, pixelSize: CGSize, dark: Bool, decorations: Bool) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let scale = min(pixelSize.width / virtualSize.width, pixelSize.height / virtualSize.height)
        context.scaleBy(x: scale, y: scale)
        let appearance = NSAppearance(named: theme.isClassic ? (dark ? .darkAqua : .aqua) : (theme.tone == .dark ? .darkAqua : .aqua))!
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }
        appearance.performAsCurrentDrawingAppearance {
            draw(theme, in: CGRect(origin: .zero, size: virtualSize), decorations: decorations, context: context)
        }
        return context.makeImage()
    }

    private static func draw(_ theme: Theme, in bounds: CGRect, decorations: Bool, context: CGContext) {
        let sidebarWidth: CGFloat = 190
        let pane = CGRect(x: sidebarWidth, y: 0, width: bounds.width - sidebarWidth, height: bounds.height)
        let palette = theme.palette
        // Conversation backdrop.
        context.saveGState()
        context.clip(to: pane)
        if let palette {
            drawGradient(palette, in: pane, context: context)
            if decorations {
                context.saveGState()
                context.translateBy(x: pane.minX, y: pane.minY)
                OrnamentArt.draw(theme.wallpaper.ornaments, in: CGRect(origin: .zero, size: pane.size), context: context)
                context.restoreGState()
                drawMotifs(theme, in: pane, context: context)
            }
        } else {
            context.setFillColor(NSColor.textBackgroundColor.cgColor)
            context.fill(pane)
        }
        context.restoreGState()
        // Sidebar.
        context.setFillColor((theme.tone == .dark || (theme.isClassic && NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.95, alpha: 1)).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height))
        if let palette {
            context.setFillColor(NSColor(theme: palette.sidebarTint, alpha: palette.sidebarTintOpacity).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: sidebarWidth, height: bounds.height))
        }
        let rowText = (palette.map { NSColor(theme: $0.text) } ?? NSColor.labelColor).withAlphaComponent(0.55)
        for row in 0..<7 {
            let y = bounds.height - 70 - CGFloat(row) * 34
            if row == 1 {
                context.setFillColor((palette.map { NSColor(theme: $0.accent) } ?? NSColor.controlAccentColor).cgColor)
                context.addPath(CGPath(roundedRect: CGRect(x: 10, y: y - 9, width: sidebarWidth - 20, height: 28), cornerWidth: 8, cornerHeight: 8, transform: nil))
                context.fillPath()
            }
            context.setFillColor((row == 1 ? (palette.map { NSColor(theme: $0.accent.readableForeground) } ?? .white) : rowText).cgColor)
            context.fill(CGRect(x: 22, y: y, width: CGFloat([96, 120, 80, 110, 70, 100, 88][row]), height: 9))
        }
        // Messages.
        let names = ["Edgar", "Lenore", "Annabel"]
        let bodies = ["Is everything ready for tonight?", "Yes! I brought the good snacks.", "See you at the usual place 🎉"]
        let textColor = palette.map { NSColor(theme: $0.text) } ?? .labelColor
        let secondary = palette.map { NSColor(theme: $0.secondaryText) } ?? .secondaryLabelColor
        for index in 0..<3 {
            let top = bounds.height - 70 - CGFloat(index) * 92
            let nameColor = palette.map { NSColor(theme: $0.nameColors[index % $0.nameColors.count]) } ?? .labelColor
            var nameAttributes: [NSAttributedString.Key: Any] = [.font: displayFont(theme, size: 20), .foregroundColor: nameColor]
            if palette?.nameGlow == true {
                let glow = NSShadow(); glow.shadowBlurRadius = 8; glow.shadowColor = nameColor.withAlphaComponent(0.85); nameAttributes[.shadow] = glow
            }
            let name = NSAttributedString(string: names[index], attributes: nameAttributes)
            name.draw(at: CGPoint(x: pane.minX + 30, y: top))
            NSAttributedString(string: "9:4\(index) PM", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: secondary])
                .draw(at: CGPoint(x: pane.minX + 40 + name.size().width, y: top + 3))
            NSAttributedString(string: bodies[index], attributes: [.font: bodyFont(theme, size: 18), .foregroundColor: textColor])
                .draw(at: CGPoint(x: pane.minX + 30, y: top - 30))
        }
        // Composer pill.
        let pill = CGRect(x: pane.minX + 22, y: 18, width: pane.width - 44, height: 48)
        let glassTint = palette.map { NSColor(theme: $0.composerTint, alpha: 0.28) } ?? NSColor.windowBackgroundColor.withAlphaComponent(0.85)
        context.setFillColor((NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.12, alpha: 0.72) : NSColor(white: 1, alpha: 0.78)).cgColor)
        context.addPath(CGPath(roundedRect: pill, cornerWidth: 24, cornerHeight: 24, transform: nil)); context.fillPath()
        context.setFillColor(glassTint.cgColor)
        context.addPath(CGPath(roundedRect: pill, cornerWidth: 24, cornerHeight: 24, transform: nil)); context.fillPath()
        context.setFillColor((palette.map { NSColor(theme: $0.accent) } ?? NSColor.controlAccentColor).cgColor)
        context.fillEllipse(in: CGRect(x: pill.maxX - 42, y: pill.minY + 8, width: 32, height: 32))
    }

    private static func drawGradient(_ palette: ThemePalette, in rect: CGRect, context: CGContext) {
        let colors = palette.gradient.map { NSColor(theme: $0).cgColor } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) else { return }
        let radians = palette.gradientAngle * .pi / 180
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let reach = max(rect.width, rect.height) / 2
        let start = CGPoint(x: center.x - cos(radians) * reach, y: center.y + sin(radians) * reach)
        let end = CGPoint(x: center.x + cos(radians) * reach, y: center.y - sin(radians) * reach)
        context.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func drawMotifs(_ theme: Theme, in pane: CGRect, context: CGContext) {
        guard !theme.wallpaper.motifs.isEmpty else { return }
        let side = CGFloat(WallpaperLayout.tileSize)
        context.saveGState()
        context.setAlpha(CGFloat(theme.wallpaper.opacity))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        var y = pane.minY
        while y < pane.maxY {
            var x = pane.minX
            while x < pane.maxX {
                context.saveGState()
                context.translateBy(x: x, y: y)
                WallpaperRenderer.draw(theme.wallpaper, seed: WallpaperLayout.seed(for: theme.id), tileSize: side, context: context)
                context.restoreGState()
                x += side
            }
            y += side
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private static func displayFont(_ theme: Theme, size: CGFloat) -> NSFont {
        if let name = theme.typography.displayFont, let font = NSFont(name: name, size: size) { return font }
        return .systemFont(ofSize: size, weight: .semibold)
    }

    private static func bodyFont(_ theme: Theme, size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size)
        let design: NSFontDescriptor.SystemDesign? = switch theme.typography.bodyDesign {
        case .standard: nil
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        guard let design, let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// `--theme-art-sheet <directory>` writes contact sheets of every motif and
/// ornament and a poster per theme, for reviewing the art without a server.
@MainActor enum ThemeArtSheet {
    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write(motifSheet(), to: directory.appendingPathComponent("motifs.png"))
        try write(ornamentSheet(), to: directory.appendingPathComponent("ornaments.png"))
        for theme in ThemeCatalog.all {
            for dark in theme.isClassic ? [false, true] : [theme.tone == .dark] {
                guard let poster = ThemePoster.render(theme, pixelSize: CGSize(width: 1440, height: 900), dark: dark, decorations: true) else { continue }
                try write(poster, to: directory.appendingPathComponent("theme-\(theme.id.rawValue)\(theme.isClassic ? (dark ? "-dark" : "-light") : "").png"))
            }
        }
    }

    private static func motifSheet() -> CGImage? {
        let motifs = ThemeMotif.allCases, styles = MotifStyle.allCases
        let cell: CGFloat = 120, columns = 8
        let backgrounds: [(CGColor, [CGColor])] = [
            (NSColor(theme: ThemeColor(0xFEFBEC)).cgColor, [ThemeColor(0xFB04B5), ThemeColor(0x02A8F6), ThemeColor(0xFDB833)].map { NSColor(theme: $0).cgColor }),
            (NSColor(theme: ThemeColor(0x14102A)).cgColor, [ThemeColor(0xFF7A1A), ThemeColor(0x7CFC7C), ThemeColor(0xF2E9FF)].map { NSColor(theme: $0).cgColor }),
        ]
        let rowsPerBlock = (motifs.count + columns - 1) / columns
        let blocks = styles.count * backgrounds.count
        let width = cell * CGFloat(columns), height = cell * CGFloat(rowsPerBlock * blocks)
        guard let context = bitmap(width: width, height: height) else { return nil }
        var block = 0
        for (background, colors) in backgrounds {
            for style in styles {
                let blockTop = height - CGFloat(block * rowsPerBlock) * cell
                context.setFillColor(background)
                context.fill(CGRect(x: 0, y: blockTop - CGFloat(rowsPerBlock) * cell, width: width, height: CGFloat(rowsPerBlock) * cell))
                for (index, motif) in motifs.enumerated() {
                    let column = index % columns, row = index / columns
                    let origin = CGPoint(x: CGFloat(column) * cell, y: blockTop - CGFloat(row + 1) * cell)
                    MotifArt.draw(motif, in: CGRect(x: origin.x + 25, y: origin.y + 30, width: 70, height: 70), colors: colors, style: style, context: context)
                    label("\(motif.rawValue) · \(style.rawValue)", at: CGPoint(x: origin.x + 6, y: origin.y + 6), dark: block >= styles.count, context: context)
                }
                block += 1
            }
        }
        return context.makeImage()
    }

    private static func ornamentSheet() -> CGImage? {
        let kinds = OrnamentKind.allCases
        let panel = CGSize(width: 480, height: 300), columns = 3
        let rows = (kinds.count + columns - 1) / columns
        let width = panel.width * CGFloat(columns), height = panel.height * CGFloat(rows) * 2
        guard let context = bitmap(width: width, height: height) else { return nil }
        let schemes: [(ThemeColor, [ThemeColor])] = [
            (ThemeColor(0x150D33), [ThemeColor(0xFB1A91), ThemeColor(0xFF9A3D), ThemeColor(0x5CE1FF)]),
            (ThemeColor(0xF6F4E3), [ThemeColor(0x7FB069), ThemeColor(0xF4A6C0), ThemeColor(0x3AA9C4)]),
        ]
        for (schemeIndex, (background, colors)) in schemes.enumerated() {
            for (index, kind) in kinds.enumerated() {
                let column = index % columns, row = index / columns + schemeIndex * rows
                let rect = CGRect(x: CGFloat(column) * panel.width, y: height - CGFloat(row + 1) * panel.height, width: panel.width, height: panel.height).insetBy(dx: 4, dy: 4)
                context.setFillColor(NSColor(theme: background).cgColor)
                context.fill(rect)
                context.saveGState()
                context.clip(to: rect)
                context.translateBy(x: rect.minX, y: rect.minY)
                let anchor = OrnamentArt.usualAnchor(for: kind)
                OrnamentArt.draw([OrnamentSpec(kind, anchor, colors, opacity: 1)], in: CGRect(origin: .zero, size: rect.size), context: context)
                context.restoreGState()
                label("\(kind.rawValue) · \(anchor.rawValue)", at: CGPoint(x: rect.minX + 8, y: rect.minY + 8), dark: schemeIndex == 0, context: context)
            }
        }
        return context.makeImage()
    }

    private static func bitmap(width: CGFloat, height: CGFloat) -> CGContext? {
        CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    private static func label(_ text: String, at point: CGPoint, dark: Bool, context: CGContext) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dark ? NSColor.white : NSColor.black]).draw(at: point)
        NSGraphicsContext.current = previous
    }

    private static func write(_ image: CGImage?, to url: URL) throws {
        guard let image, let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AppError.message("Could not render \(url.lastPathComponent).")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppError.message("Could not write \(url.lastPathComponent).") }
    }
}
