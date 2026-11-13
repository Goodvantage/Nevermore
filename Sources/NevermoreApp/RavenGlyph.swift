import AppKit

/// The raven that marks an unread conversation: a silhouette of vector
/// paths in a 16 x 14 point box, facing left, feet on the bottom edge.
///
/// It has two poses. Perched, the head is a separate layer that turns on
/// the neck. Flying, the legs are gone, the body lies level and one wing
/// beats. Hosts must be unflipped views, so y runs up.
@MainActor final class RavenFigure {
    enum Pose { case perched, flying }

    static let size = CGSize(width: 16, height: 14)
    /// Where the head turns, in the box.
    private static let neck = CGPoint(x: 6.2, y: 9.0)
    /// A head turn is a quick step, as birds make them, not a glide.
    private static let glanceStep: CGFloat = .pi / 12
    private static let glanceDuration: CFTimeInterval = 0.09
    static let wingBeat: CFTimeInterval = 0.12

    /// Add this to a host layer and move it; the figure owns the parts.
    let layer = CALayer()
    private let body = CAShapeLayer()
    private let legs = CAShapeLayer()
    private let head = CAShapeLayer()
    private let eye = CAShapeLayer()
    private let wing = CAShapeLayer()
    private(set) var pose: Pose = .perched
    private var glance: CGFloat = 0

    init() {
        let bounds = CGRect(origin: .zero, size: Self.size)
        layer.bounds = bounds
        for part in [legs, body, wing, head] { part.frame = bounds; layer.addSublayer(part) }
        head.anchorPoint = CGPoint(x: Self.neck.x / Self.size.width, y: Self.neck.y / Self.size.height)
        head.position = Self.neck
        eye.frame = bounds
        head.addSublayer(eye)
        legs.fillColor = nil
        legs.lineWidth = 0.7
        legs.lineCap = .round
        head.path = Self.headPath
        legs.path = Self.legsPath
        eye.path = Self.eyePath(lit: false)
        setPose(.perched)
        // Appearance changes must not animate; only poses and glances do.
        layer.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull(), "transform": NSNull(), "opacity": NSNull()]
        for part in [legs, body, wing, head, eye] { part.actions = ["fillColor": NSNull(), "strokeColor": NSNull(), "path": NSNull(), "hidden": NSNull(), "transform": NSNull()] }
    }

    /// `lit` is the eye of a conversation that mentions the reader.
    func setColors(ink: NSColor, eye eyeColor: NSColor, lit: Bool) {
        let fill = ink.cgColor
        body.fillColor = fill; head.fillColor = fill; wing.fillColor = fill; legs.strokeColor = fill
        eye.fillColor = eyeColor.cgColor
        eye.path = Self.eyePath(lit: lit)
    }

    /// Changes the ink over `duration`, for a bird that lands somewhere
    /// with a color of its own.
    func fade(to ink: NSColor, duration: CFTimeInterval) {
        for (part, key) in [(body, "fillColor"), (head, "fillColor"), (wing, "fillColor"), (legs, "strokeColor")] {
            let fade = CABasicAnimation(keyPath: key)
            fade.fromValue = part.value(forKey: key); fade.toValue = ink.cgColor
            fade.duration = duration
            part.add(fade, forKey: "ink")
        }
        body.fillColor = ink.cgColor; head.fillColor = ink.cgColor; wing.fillColor = ink.cgColor; legs.strokeColor = ink.cgColor
    }

    func setPose(_ pose: Pose) {
        self.pose = pose
        wing.removeAnimation(forKey: "beat")
        switch pose {
        case .perched:
            body.path = Self.perchedBody
            legs.isHidden = false
            wing.isHidden = true
            head.setAffineTransform(CGAffineTransform(rotationAngle: glance))
        case .flying:
            body.path = Self.flyingBody
            legs.isHidden = true
            wing.isHidden = false
            wing.path = Self.wingUp
            // Level with the body, looking where it goes.
            head.setAffineTransform(CGAffineTransform(translationX: -1.1, y: -3.3))
            guard !Ink.reducesMotion else { return }
            let beat = CABasicAnimation(keyPath: "path")
            beat.fromValue = Self.wingUp; beat.toValue = Self.wingDown
            beat.duration = Self.wingBeat * Ink.timeScale
            beat.autoreverses = true; beat.repeatCount = .infinity
            beat.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            wing.add(beat, forKey: "beat")
        }
    }

    /// Turns the head toward `point` (in this layer's coordinates). The
    /// angle moves in steps of 15 degrees and never past what a neck allows.
    func look(at point: CGPoint?) {
        guard pose == .perched else { return }
        var angle: CGFloat = 0
        if let point {
            // At rest the beak points left and a little down.
            let raw = atan2(point.y - Self.neck.y, point.x - Self.neck.x) - .pi
            let wrapped = atan2(sin(raw), cos(raw))
            angle = (max(-.pi / 3, min(.pi / 4, wrapped)) / Self.glanceStep).rounded() * Self.glanceStep
        }
        guard angle != glance else { return }
        let previous = glance
        glance = angle
        head.setAffineTransform(CGAffineTransform(rotationAngle: angle))
        guard !Ink.reducesMotion else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = previous; turn.toValue = angle
        turn.duration = Self.glanceDuration * Ink.timeScale
        turn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        head.add(turn, forKey: "glance")
    }

    // MARK: Paths

    private static let perchedBody: CGPath = {
        let path = CGMutablePath()
        // Chest, up over the shoulder, down the back to the tail tip,
        // back along the belly.
        path.move(to: CGPoint(x: 4.7, y: 7.0))
        path.addCurve(to: CGPoint(x: 7.7, y: 9.7), control1: CGPoint(x: 4.9, y: 8.7), control2: CGPoint(x: 6.2, y: 9.7))
        path.addCurve(to: CGPoint(x: 12.1, y: 6.0), control1: CGPoint(x: 9.6, y: 9.7), control2: CGPoint(x: 11.0, y: 7.6))
        path.addLine(to: CGPoint(x: 15.9, y: 2.7))
        path.addLine(to: CGPoint(x: 15.1, y: 1.7))
        path.addCurve(to: CGPoint(x: 9.0, y: 3.2), control1: CGPoint(x: 12.9, y: 3.0), control2: CGPoint(x: 10.8, y: 3.2))
        path.addCurve(to: CGPoint(x: 4.7, y: 7.0), control1: CGPoint(x: 6.6, y: 3.2), control2: CGPoint(x: 4.5, y: 4.6))
        path.closeSubpath()
        return path
    }()

    private static let headPath: CGPath = {
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: 3.5, y: 8.5, width: 4.3, height: 4.1))
        // A heavy bill with a curved upper edge: what makes it a raven
        // and not a blackbird.
        path.move(to: CGPoint(x: 4.3, y: 12.1))
        path.addCurve(to: CGPoint(x: 0.5, y: 9.8), control1: CGPoint(x: 2.9, y: 12.0), control2: CGPoint(x: 1.4, y: 11.1))
        path.addLine(to: CGPoint(x: 3.8, y: 9.2))
        path.closeSubpath()
        return path
    }()

    private static func eyePath(lit: Bool) -> CGPath {
        let radius: CGFloat = lit ? 0.8 : 0.5
        return CGPath(ellipseIn: CGRect(x: 4.9 - radius, y: 11.0 - radius, width: radius * 2, height: radius * 2), transform: nil)
    }

    private static let legsPath: CGPath = {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 7.6, y: 3.5)); path.addLine(to: CGPoint(x: 7.3, y: 0.35)); path.addLine(to: CGPoint(x: 6.2, y: 0.35))
        path.move(to: CGPoint(x: 9.3, y: 3.4)); path.addLine(to: CGPoint(x: 9.2, y: 0.35)); path.addLine(to: CGPoint(x: 8.1, y: 0.35))
        return path
    }()

    private static let flyingBody: CGPath = {
        let path = CGMutablePath()
        // A level spindle from the breast to a wedge of tail.
        path.move(to: CGPoint(x: 3.8, y: 7.1))
        path.addCurve(to: CGPoint(x: 11.0, y: 7.7), control1: CGPoint(x: 5.4, y: 8.5), control2: CGPoint(x: 8.8, y: 8.3))
        path.addLine(to: CGPoint(x: 16.0, y: 8.1))
        path.addLine(to: CGPoint(x: 15.7, y: 6.2))
        path.addCurve(to: CGPoint(x: 3.8, y: 7.1), control1: CGPoint(x: 10.6, y: 5.9), control2: CGPoint(x: 5.6, y: 5.2))
        path.closeSubpath()
        return path
    }()

    /// Both wing shapes have the same segments, so one animates into the other.
    private static func wingPath(tip: CGPoint, lead: CGPoint, trail: CGPoint) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 5.8, y: 7.4))
        path.addQuadCurve(to: tip, control: lead)
        path.addQuadCurve(to: CGPoint(x: 11.2, y: 7.2), control: trail)
        path.closeSubpath()
        return path
    }
    private static let wingUp = wingPath(tip: CGPoint(x: 12.2, y: 13.8), lead: CGPoint(x: 7.0, y: 12.4), trail: CGPoint(x: 11.4, y: 10.2))
    private static let wingDown = wingPath(tip: CGPoint(x: 12.4, y: 0.8), lead: CGPoint(x: 7.2, y: 2.6), trail: CGPoint(x: 11.6, y: 4.6))
}
