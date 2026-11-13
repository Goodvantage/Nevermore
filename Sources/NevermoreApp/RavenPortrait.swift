import AppKit
import NevermoreCore

/// Static, local vector artwork: circular raven portraits for people and
/// geometric channel tiles. Bold silhouettes remain legible at 18 points.
enum RavenPortrait {
    enum ChannelAccess: String { case standard, privateChannel }

    static func image(named name: String) -> NSImage {
        image(design: RavenAvatarDesign(name: name), channelAccess: nil)
    }

    static func channelImage(named name: String, workspace: String, access: ChannelAccess) -> NSImage {
        image(design: RavenAvatarDesign(channelName: name, workspace: workspace), channelAccess: access)
    }

    private static func image(design: RavenAvatarDesign, channelAccess: ChannelAccess?) -> NSImage {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: bounds.minX, y: bounds.minY)
            context.scaleBy(x: bounds.width / 100, y: bounds.height / 100)
            if let channelAccess {
                drawChannel(design, access: channelAccess, context: context)
            } else {
                drawPerson(design, context: context)
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawChannel(_ design: RavenAvatarDesign, access: ChannelAccess, context: CGContext) {
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                               cornerWidth: 18, cornerHeight: 18, transform: nil))
        context.clip()
        context.setFillColor(color(hue: design.backgroundHue, saturation: 0.24, brightness: 0.94))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(color(hue: design.backgroundHue, saturation: 0.38, brightness: 0.84))
        // A quiet edge pattern adds identity without competing with the symbol.
        switch design.motif {
        case .plain: context.fill(CGRect(x: 0, y: 86, width: 100, height: 14))
        case .dots:
            for x in [14.0, 50, 86] { context.fillEllipse(in: CGRect(x: x - 3, y: 86, width: 6, height: 6)) }
        case .rays: fill([(58, 100), (100, 58), (100, 100)], context)
        case .halo:
            context.setStrokeColor(color(hue: design.backgroundHue, saturation: 0.38, brightness: 0.84))
            context.setLineWidth(5)
            context.strokeEllipse(in: CGRect(x: 62, y: 62, width: 48, height: 48))
        }
        let ink = color(hue: design.backgroundHue, saturation: 0.65, brightness: 0.32)
        context.setFillColor(ink)
        context.setStrokeColor(ink)
        context.setLineWidth(8)
        context.setLineCap(.round)
        switch access {
        case .standard:
            for x in [39.0, 65] {
                context.move(to: CGPoint(x: x + 4, y: 26)); context.addLine(to: CGPoint(x: x - 4, y: 74))
            }
            for y in [40.0, 60] {
                context.move(to: CGPoint(x: 26, y: y)); context.addLine(to: CGPoint(x: 76, y: y))
            }
            context.strokePath()
        case .privateChannel:
            context.strokeEllipse(in: CGRect(x: 33, y: 23, width: 34, height: 42))
            context.addPath(CGPath(roundedRect: CGRect(x: 25, y: 44, width: 50, height: 34),
                                   cornerWidth: 7, cornerHeight: 7, transform: nil))
            context.fillPath()
            context.setFillColor(color(hue: design.backgroundHue, saturation: 0.24, brightness: 0.94))
            context.fillEllipse(in: CGRect(x: 46, y: 55, width: 8, height: 8))
            context.fill(CGRect(x: 48, y: 60, width: 4, height: 8))
        }
    }

    private static func drawPerson(_ design: RavenAvatarDesign, context: CGContext) {
        context.addEllipse(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        context.clip()
        context.setFillColor(color(hue: design.backgroundHue, saturation: 0.30, brightness: 0.96))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(CGColor(gray: 1, alpha: 0.30))
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.40))
        context.setLineWidth(4)
        switch design.motif {
        case .plain: break
        case .dots:
            for (x, y) in [(16.0, 37.0), (76, 19), (80, 77)] {
                context.fillEllipse(in: CGRect(x: x, y: y, width: 8, height: 8))
            }
        case .rays:
            for x in stride(from: -20.0, through: 100, by: 25) {
                context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x + 70, y: 100))
            }
            context.strokePath()
        case .halo: context.strokeEllipse(in: CGRect(x: 12, y: 10, width: 76, height: 76))
        }

        if design.facing == .left { context.translateBy(x: 100, y: 0); context.scaleBy(x: -1, y: 1) }
        let palette: (hue: Double, saturation: Double, brightness: Double) = switch design.palette {
        case .ink: (0.61, 0.32, 0.22)
        case .slate: (0.58, 0.20, 0.50)
        case .cobalt: (0.63, 0.62, 0.46)
        case .teal: (0.48, 0.60, 0.37)
        case .plum: (0.79, 0.45, 0.42)
        case .rust: (0.06, 0.48, 0.44)
        }
        let plumage = color(hue: palette.hue, saturation: palette.saturation, brightness: palette.brightness)
        let sheen = color(hue: palette.hue, saturation: palette.saturation * 0.65, brightness: palette.brightness + 0.25)
        context.setFillColor(plumage)
        switch design.silhouette {
        case .slender: fill([(36, 48), (28, 80), (22, 103), (77, 103), (64, 75), (68, 78), (59, 48)], context)
        case .broad: fill([(26, 46), (12, 76), (5, 103), (96, 103), (83, 75), (87, 77), (67, 46)], context)
        case .round, .angular: fill([(28, 44), (20, 75), (13, 103), (86, 103), (71, 77), (78, 79), (63, 46)], context)
        }
        context.setFillColor(sheen)
        if design.marking == .bib {
            fill([(29, 65), (69, 65), (63, 92), (50, 84), (39, 94)], context)
        } else {
            context.setStrokeColor(sheen)
            context.setLineCap(.round)
            context.setLineWidth(3)
            for index in 0..<design.featherCount {
                let x = 30.0 + Double(index) * 8
                context.move(to: CGPoint(x: x, y: 80)); context.addLine(to: CGPoint(x: x + 4, y: 88))
            }
            context.strokePath()
        }

        // Proportions alter the whole face, so eyes and bill stay attached to
        // the silhouette. The shoulders retain their own distinct outline.
        context.translateBy(x: 48, y: 43)
        switch design.silhouette {
        case .round: context.scaleBy(x: 1.03, y: 1.02)
        case .slender: context.scaleBy(x: 0.80, y: 1.17)
        case .broad: context.scaleBy(x: 1.13, y: 0.87)
        case .angular: break
        }
        context.translateBy(x: -48, y: -43)
        context.setFillColor(plumage)
        if design.silhouette == .angular {
            fill([(20, 35), (30, 19), (58, 17), (72, 30), (70, 55), (54, 67), (30, 59)], context)
        } else {
            context.fillEllipse(in: CGRect(x: 47 - design.headWidth / 2, y: 42 - design.headHeight / 2,
                                          width: design.headWidth, height: design.headHeight))
        }
        switch design.crest {
        case .smooth: break
        case .swept: fill([(22, 32), (16, 9), (31, 17), (40, 5), (46, 23), (58, 27)], context)
        case .tousled: fill([(23, 30), (20, 11), (35, 20), (42, 5), (49, 22), (65, 12), (59, 32)], context)
        case .spiky: fill([(21, 30), (26, 8), (33, 22), (40, 2), (47, 22), (58, 7), (67, 32)], context)
        case .tufted:
            context.move(to: CGPoint(x: 34, y: 26))
            context.addCurve(to: CGPoint(x: 30, y: 4), control1: CGPoint(x: 41, y: 17), control2: CGPoint(x: 31, y: 17))
            context.addCurve(to: CGPoint(x: 53, y: 26), control1: CGPoint(x: 53, y: 0), control2: CGPoint(x: 58, y: 18))
            context.closePath(); context.fillPath()
        }
        context.setFillColor(sheen)
        switch design.marking {
        case .plain, .bib: break
        case .brow: fill([(26, 26), (64, 24), (68, 32), (28, 35)], context)
        case .cheek:
            context.fillEllipse(in: CGRect(x: 27, y: 43, width: 21, height: 17))
            if design.pose == .front { context.fillEllipse(in: CGRect(x: 51, y: 43, width: 21, height: 17)) }
        case .mask: context.fillEllipse(in: CGRect(x: 25, y: 26, width: 46, height: 28))
        }
        let bill = CGColor(srgbRed: 0.43, green: 0.49, blue: 0.53, alpha: 1)
        context.setFillColor(bill)
        if design.pose == .front {
            let tip: Double = design.beak == .long || design.beak == .hooked ? 70 : 62
            let width: Double = design.beak == .stout ? 14 : 10
            fill([(49 - width, 43), (49, 37), (49 + width, 43), (54, tip - 3), (49, tip), (44, tip - 3)], context)
            context.setFillColor(CGColor(gray: 0.14, alpha: 1))
            fill([(49, 42), (49 + width, 43), (54, tip - 3), (49, tip)], context)
            drawEye(design.eye, x: 30, y: 32, context: context)
            drawEye(design.eye, x: 57, y: 32, context: context)
        } else {
            switch design.beak {
            case .compact: fill([(62, 39), (77, 42), (85, 51), (67, 54), (61, 49)], context)
            case .long: fill([(62, 38), (82, 42), (95, 51), (68, 54), (61, 49)], context)
            case .hooked:
                context.move(to: CGPoint(x: 62, y: 38))
                context.addCurve(to: CGPoint(x: 88, y: 61), control1: CGPoint(x: 85, y: 38), control2: CGPoint(x: 95, y: 48))
                context.addLine(to: CGPoint(x: 84, y: 53)); context.addLine(to: CGPoint(x: 65, y: 54))
                context.closePath(); context.fillPath()
            case .stout: fill([(62, 37), (81, 41), (90, 53), (75, 59), (62, 54)], context)
            }
            context.setStrokeColor(plumage); context.setLineWidth(2)
            context.move(to: CGPoint(x: 66, y: 49)); context.addLine(to: CGPoint(x: 81, y: 51)); context.strokePath()
            drawEye(design.eye, x: 47, y: 29, context: context)
        }
    }

    private static func drawEye(_ eye: RavenAvatarDesign.Eye, x: Double, y: Double, context: CGContext) {
        context.setFillColor(CGColor(srgbRed: 0.98, green: 0.97, blue: 0.89, alpha: 1))
        let height: Double = eye == .almond ? 9 : eye == .curious ? 15 : 12
        context.fillEllipse(in: CGRect(x: x, y: y, width: 13, height: height))
        context.setFillColor(CGColor(gray: 0.06, alpha: 1))
        context.fillEllipse(in: CGRect(x: x + 5, y: y + (height - 6) / 2, width: 6, height: 6))
    }

    private static func fill(_ points: [(Double, Double)], _ context: CGContext) {
        context.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
        context.closePath(); context.fillPath()
    }

    /// Fixed sRGB colors, independent of appearance, selection or theme palette.
    private static func color(hue: Double, saturation: Double, brightness: Double) -> CGColor {
        let sector = hue * 6, fraction = sector - floor(sector)
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - saturation * fraction)
        let rising = brightness * (1 - saturation * (1 - fraction))
        let rgb: (Double, Double, Double)
        switch Int(sector) % 6 {
        case 0: rgb = (brightness, rising, low)
        case 1: rgb = (falling, brightness, low)
        case 2: rgb = (low, brightness, rising)
        case 3: rgb = (low, falling, brightness)
        case 4: rgb = (rising, low, brightness)
        default: rgb = (brightness, low, falling)
        }
        return CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}
