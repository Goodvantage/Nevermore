import CoreGraphics

// Night-sky and spooky motifs: Halloween, Nevermore, Cosmic.
extension MotifShapes {
    static func bat() -> [MotifPart] {
        // Ears, a wing swept up to its tip, then the trailing edge scalloped
        // between finger tips down to the tail.
        let outline = symmetric(from: CGPoint(x: 0.5, y: 0.60), [
            .line(CGPoint(x: 0.53, y: 0.62)),
            .line(CGPoint(x: 0.565, y: 0.73)),
            .line(CGPoint(x: 0.59, y: 0.60)),
            .quad(CGPoint(x: 0.63, y: 0.56), control: CGPoint(x: 0.60, y: 0.57)),
            .quad(CGPoint(x: 0.96, y: 0.71), control: CGPoint(x: 0.79, y: 0.73)),
            .quad(CGPoint(x: 0.86, y: 0.40), control: CGPoint(x: 0.86, y: 0.58)),
            .quad(CGPoint(x: 0.74, y: 0.41), control: CGPoint(x: 0.80, y: 0.49)),
            .quad(CGPoint(x: 0.62, y: 0.35), control: CGPoint(x: 0.68, y: 0.46)),
            .quad(CGPoint(x: 0.5, y: 0.29), control: CGPoint(x: 0.57, y: 0.29)),
        ])
        return [MotifPart(outline)]
    }

    static func pumpkin() -> [MotifPart] {
        // Three overlapping lobes merged into one outline, so the face can
        // cut clean holes with even-odd filling.
        let lobes = CGPath(ellipseIn: CGRect(x: 0.30, y: 0.10, width: 0.40, height: 0.64), transform: nil)
            .union(CGPath(ellipseIn: CGRect(x: 0.08, y: 0.13, width: 0.48, height: 0.57), transform: nil))
            .union(CGPath(ellipseIn: CGRect(x: 0.44, y: 0.13, width: 0.48, height: 0.57), transform: nil))
        let face = path { path in
            path.addLines(between: [CGPoint(x: 0.31, y: 0.47), CGPoint(x: 0.43, y: 0.47), CGPoint(x: 0.37, y: 0.58)])
            path.closeSubpath()
            path.addLines(between: [CGPoint(x: 0.57, y: 0.47), CGPoint(x: 0.69, y: 0.47), CGPoint(x: 0.63, y: 0.58)])
            path.closeSubpath()
            // A grin with one tooth notched into its top edge.
            path.move(to: CGPoint(x: 0.26, y: 0.37))
            path.addQuadCurve(to: CGPoint(x: 0.74, y: 0.37), control: CGPoint(x: 0.5, y: 0.10))
            path.addQuadCurve(to: CGPoint(x: 0.55, y: 0.30), control: CGPoint(x: 0.66, y: 0.30))
            path.addLine(to: CGPoint(x: 0.55, y: 0.27))
            path.addLine(to: CGPoint(x: 0.47, y: 0.27))
            path.addLine(to: CGPoint(x: 0.47, y: 0.30))
            path.addQuadCurve(to: CGPoint(x: 0.26, y: 0.37), control: CGPoint(x: 0.34, y: 0.30))
            path.closeSubpath()
        }
        let body = path { $0.addPath(lobes); $0.addPath(face) }
        let stem = polygon([CGPoint(x: 0.45, y: 0.70), CGPoint(x: 0.46, y: 0.86), CGPoint(x: 0.55, y: 0.89), CGPoint(x: 0.55, y: 0.70)])
        let curl = path { path in
            path.move(to: CGPoint(x: 0.55, y: 0.82))
            path.addQuadCurve(to: CGPoint(x: 0.74, y: 0.84), control: CGPoint(x: 0.64, y: 0.95))
            path.addQuadCurve(to: CGPoint(x: 0.69, y: 0.77), control: CGPoint(x: 0.76, y: 0.76))
        }
        return [MotifPart(body, slot: 0, evenOdd: true), MotifPart(stem, slot: 1), MotifPart(curl, .line, slot: 1)]
    }

    static func ghost() -> [MotifPart] {
        let sheet = path { path in
            path.addArc(center: CGPoint(x: 0.5, y: 0.58), radius: 0.30, startAngle: .pi, endAngle: 0, clockwise: true)
            path.addLine(to: CGPoint(x: 0.83, y: 0.16))
            // Three rounded hems along the bottom.
            let hems: [CGFloat] = [0.83, 0.61, 0.39, 0.17]
            for index in 1..<hems.count {
                path.addQuadCurve(to: CGPoint(x: hems[index], y: 0.16), control: CGPoint(x: (hems[index - 1] + hems[index]) / 2, y: 0.03))
            }
            path.closeSubpath()
            path.addEllipse(in: CGRect(x: 0.35, y: 0.55, width: 0.09, height: 0.13))
            path.addEllipse(in: CGRect(x: 0.56, y: 0.55, width: 0.09, height: 0.13))
            path.addEllipse(in: CGRect(x: 0.46, y: 0.38, width: 0.08, height: 0.10))
        }
        return [MotifPart(sheet, evenOdd: true)]
    }

    static func candyCorn() -> [MotifPart] {
        let kernel = path { path in
            path.move(to: CGPoint(x: 0.5, y: 0.92))
            path.addQuadCurve(to: CGPoint(x: 0.81, y: 0.21), control: CGPoint(x: 0.69, y: 0.62))
            path.addQuadCurve(to: CGPoint(x: 0.70, y: 0.10), control: CGPoint(x: 0.84, y: 0.10))
            path.addLine(to: CGPoint(x: 0.30, y: 0.10))
            path.addQuadCurve(to: CGPoint(x: 0.19, y: 0.21), control: CGPoint(x: 0.16, y: 0.10))
            path.addQuadCurve(to: CGPoint(x: 0.5, y: 0.92), control: CGPoint(x: 0.31, y: 0.62))
            path.closeSubpath()
        }
        // Base, middle and tip bands, bottom up, in the spec's color order.
        let cuts: [CGFloat] = [0, 0.37, 0.65, 1]
        return (0..<3).map { band in
            let slab = CGPath(rect: CGRect(x: 0, y: cuts[band], width: 1, height: cuts[band + 1] - cuts[band]), transform: nil)
            return MotifPart(kernel.intersection(slab), slot: band)
        }
    }

    static func moon() -> [MotifPart] {
        let crescent = circle(CGPoint(x: 0.5, y: 0.5), 0.40).subtracting(circle(CGPoint(x: 0.67, y: 0.61), 0.33))
        return [MotifPart(crescent)]
    }

    static func raven() -> [MotifPart] {
        // In profile facing right: beak, crown, a back sloping to a long
        // tail, then the belly back up to the throat. The eye is a hole.
        let body = path { path in
            path.move(to: CGPoint(x: 0.95, y: 0.66))
            path.addQuadCurve(to: CGPoint(x: 0.79, y: 0.79), control: CGPoint(x: 0.86, y: 0.77))
            path.addCurve(to: CGPoint(x: 0.61, y: 0.79), control1: CGPoint(x: 0.75, y: 0.86), control2: CGPoint(x: 0.65, y: 0.86))
            path.addCurve(to: CGPoint(x: 0.30, y: 0.55), control1: CGPoint(x: 0.53, y: 0.73), control2: CGPoint(x: 0.42, y: 0.63))
            path.addLine(to: CGPoint(x: 0.05, y: 0.33))
            path.addLine(to: CGPoint(x: 0.11, y: 0.27))
            path.addCurve(to: CGPoint(x: 0.50, y: 0.30), control1: CGPoint(x: 0.24, y: 0.31), control2: CGPoint(x: 0.37, y: 0.25))
            path.addCurve(to: CGPoint(x: 0.79, y: 0.60), control1: CGPoint(x: 0.66, y: 0.34), control2: CGPoint(x: 0.79, y: 0.46))
            path.addQuadCurve(to: CGPoint(x: 0.95, y: 0.66), control: CGPoint(x: 0.86, y: 0.63))
            path.closeSubpath()
            path.addEllipse(in: CGRect(x: 0.72, y: 0.715, width: 0.045, height: 0.045))
        }
        let legs = path { path in
            path.move(to: CGPoint(x: 0.47, y: 0.29))
            path.addLine(to: CGPoint(x: 0.45, y: 0.11))
            path.addLine(to: CGPoint(x: 0.52, y: 0.10))
            path.move(to: CGPoint(x: 0.56, y: 0.31))
            path.addLine(to: CGPoint(x: 0.57, y: 0.11))
            path.addLine(to: CGPoint(x: 0.64, y: 0.10))
        }
        return [MotifPart(body, evenOdd: true), MotifPart(legs, .line)]
    }

    static func feather() -> [MotifPart] {
        // An upright vane, split by its shaft and notched where barbs part;
        // the bare quill shows below.
        let vane = path { path in
            path.move(to: CGPoint(x: 0.5, y: 0.94))
            path.addCurve(to: CGPoint(x: 0.52, y: 0.22), control1: CGPoint(x: 0.71, y: 0.78), control2: CGPoint(x: 0.68, y: 0.34))
            path.addCurve(to: CGPoint(x: 0.5, y: 0.94), control1: CGPoint(x: 0.34, y: 0.30), control2: CGPoint(x: 0.28, y: 0.74))
            path.closeSubpath()
        }
        let shaft = path { path in
            path.move(to: CGPoint(x: 0.5, y: 0.06))
            path.addQuadCurve(to: CGPoint(x: 0.5, y: 0.84), control: CGPoint(x: 0.53, y: 0.45))
        }
        let notches = path { path in
            path.addLines(between: [CGPoint(x: 0.70, y: 0.62), CGPoint(x: 0.55, y: 0.52), CGPoint(x: 0.70, y: 0.56)])
            path.closeSubpath()
            path.addLines(between: [CGPoint(x: 0.28, y: 0.44), CGPoint(x: 0.46, y: 0.36), CGPoint(x: 0.30, y: 0.38)])
            path.closeSubpath()
        }
        let split = vane
            .subtracting(shaft.copy(strokingWithWidth: 0.035, lineCap: .round, lineJoin: .round, miterLimit: 1))
            .subtracting(notches)
        let quill = path { path in
            path.move(to: CGPoint(x: 0.5, y: 0.06))
            path.addQuadCurve(to: CGPoint(x: 0.51, y: 0.26), control: CGPoint(x: 0.505, y: 0.16))
        }
        return [MotifPart(split), MotifPart(quill, .line)]
    }

    static func planet() -> [MotifPart] {
        let center = CGPoint(x: 0.5, y: 0.5)
        let tilt = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: 0.35).translatedBy(x: -center.x, y: -center.y)
        let ring = path { path in
            path.addEllipse(in: CGRect(x: 0.03, y: 0.36, width: 0.94, height: 0.28), transform: tilt)
            path.addEllipse(in: CGRect(x: 0.15, y: 0.43, width: 0.70, height: 0.14), transform: tilt)
        }.normalized(using: .evenOdd)
        let globe = circle(center, 0.27)
        // The ring passes behind the globe above its axis and in front below.
        let farSide = path { $0.addRect(CGRect(x: -1, y: 0.5, width: 3, height: 2), transform: tilt) }
        let frontRing = ring.subtracting(farSide)
        return [
            MotifPart(globe.subtracting(frontRing), slot: 0),
            MotifPart(ring.subtracting(globe.intersection(farSide)), slot: 1),
        ]
    }

    static func rocket() -> [MotifPart] {
        let hull = symmetric(from: CGPoint(x: 0.5, y: 0.94), [
            .cubic(CGPoint(x: 0.64, y: 0.52), control1: CGPoint(x: 0.61, y: 0.86), control2: CGPoint(x: 0.66, y: 0.68)),
            .line(CGPoint(x: 0.61, y: 0.27)),
            .line(CGPoint(x: 0.5, y: 0.27)),
        ])
        let body = path { path in
            path.addPath(hull)
            path.addPath(circle(CGPoint(x: 0.5, y: 0.62), 0.065))
        }
        let trim = path { path in
            path.addLines(between: [CGPoint(x: 0.37, y: 0.47), CGPoint(x: 0.21, y: 0.28), CGPoint(x: 0.22, y: 0.15), CGPoint(x: 0.39, y: 0.29)])
            path.closeSubpath()
            path.addLines(between: [CGPoint(x: 0.63, y: 0.47), CGPoint(x: 0.79, y: 0.28), CGPoint(x: 0.78, y: 0.15), CGPoint(x: 0.61, y: 0.29)])
            path.closeSubpath()
            // Exhaust flame.
            path.move(to: CGPoint(x: 0.42, y: 0.25))
            path.addQuadCurve(to: CGPoint(x: 0.5, y: 0.04), control: CGPoint(x: 0.40, y: 0.12))
            path.addQuadCurve(to: CGPoint(x: 0.58, y: 0.25), control: CGPoint(x: 0.60, y: 0.12))
            path.closeSubpath()
        }
        return [MotifPart(body, slot: 0, evenOdd: true), MotifPart(trim, slot: 1)]
    }

    static func comet() -> [MotifPart] {
        let head = CGPoint(x: 0.70, y: 0.70), tip = CGPoint(x: 0.08, y: 0.10)
        let length = hypot(head.x - tip.x, head.y - tip.y)
        // Unit normal to the tail's axis: the tail leaves the head at its widest.
        let normal = CGPoint(x: (head.y - tip.y) / length, y: -(head.x - tip.x) / length)
        let radius: CGFloat = 0.15
        let tail = polygon([
            CGPoint(x: head.x + normal.x * radius, y: head.y + normal.y * radius),
            tip,
            CGPoint(x: head.x - normal.x * radius, y: head.y - normal.y * radius),
        ])
        let streaks = path { path in
            path.move(to: CGPoint(x: 0.66, y: 0.50))
            path.addLine(to: CGPoint(x: 0.30, y: 0.12))
            path.move(to: CGPoint(x: 0.50, y: 0.66))
            path.addLine(to: CGPoint(x: 0.12, y: 0.30))
        }
        return [MotifPart(circle(head, radius).union(tail)), MotifPart(streaks, .line)]
    }

    // MARK: Mirrored outlines

    private enum Segment {
        case line(CGPoint)
        case quad(CGPoint, control: CGPoint)
        case cubic(CGPoint, control1: CGPoint, control2: CGPoint)

        var end: CGPoint {
            switch self {
            case .line(let end), .quad(let end, _), .cubic(let end, _, _): end
            }
        }
    }

    /// A closed outline symmetric about x = 0.5: `start` and `rightHalf`
    /// trace the right side from the top of the axis down to the bottom of
    /// it; the left side retraces them mirrored.
    private static func symmetric(from start: CGPoint, _ rightHalf: [Segment]) -> CGPath {
        func mirrored(_ point: CGPoint) -> CGPoint { CGPoint(x: 1 - point.x, y: point.y) }
        return path { path in
            path.move(to: start)
            for segment in rightHalf {
                switch segment {
                case .line(let end): path.addLine(to: end)
                case .quad(let end, let control): path.addQuadCurve(to: end, control: control)
                case .cubic(let end, let control1, let control2): path.addCurve(to: end, control1: control1, control2: control2)
                }
            }
            let starts = [start] + rightHalf.map(\.end)
            for index in rightHalf.indices.reversed() {
                let back = mirrored(starts[index])
                switch rightHalf[index] {
                case .line: path.addLine(to: back)
                case .quad(_, let control): path.addQuadCurve(to: back, control: mirrored(control))
                case .cubic(_, let control1, let control2): path.addCurve(to: back, control1: mirrored(control2), control2: mirrored(control1))
                }
            }
            path.closeSubpath()
        }
    }
}
