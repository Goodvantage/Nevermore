import CoreGraphics

// Nature and food motifs: sea, meadow, lemonade, winter.
extension MotifShapes {
    static func bubble() -> [MotifPart] {
        // One circle: a thin ring in the outline styles the wallpapers use,
        // a disc with a glint when filled.
        let highlight = path { path in
            path.move(to: CGPoint(x: 0.3, y: 0.6))
            path.addQuadCurve(to: CGPoint(x: 0.44, y: 0.73), control: CGPoint(x: 0.32, y: 0.71))
        }
        return [MotifPart(circle(CGPoint(x: 0.5, y: 0.5), 0.38)), MotifPart(highlight, .line)]
    }

    static func fish() -> [MotifPart] {
        // Tail and fin overlap the body and are merged into it, so filling
        // never cancels the joins; only the eye is a hole.
        let tail = path { path in
            path.addLines(between: [CGPoint(x: 0.27, y: 0.50), CGPoint(x: 0.07, y: 0.67), CGPoint(x: 0.07, y: 0.33)])
            path.closeSubpath()
        }
        let fin = path { path in
            path.addLines(between: [CGPoint(x: 0.40, y: 0.62), CGPoint(x: 0.34, y: 0.84), CGPoint(x: 0.60, y: 0.64)])
            path.closeSubpath()
        }
        let body = CGPath(ellipseIn: CGRect(x: 0.22, y: 0.30, width: 0.56, height: 0.40), transform: nil)
            .union(tail).union(fin)
            .subtracting(circle(CGPoint(x: 0.64, y: 0.53), 0.045))
        return [MotifPart(body, .area, evenOdd: true)]
    }

    static func starfish() -> [MotifPart] {
        let points = 5
        let center = CGPoint(x: 0.5, y: 0.5)
        let outer: CGFloat = 0.42
        let inner: CGFloat = 0.20
        let star = path { path in
            for index in 0..<(points * 2) {
                let angle = .pi / 2 + CGFloat(index) * .pi / CGFloat(points)
                let radius = index.isMultiple(of: 2) ? outer : inner
                let point = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if index == 0 {
                    path.move(to: point)
                } else if index.isMultiple(of: 2) {
                    let prevAngle = .pi / 2 + CGFloat(index - 1) * .pi / CGFloat(points)
                    let nextAngle = .pi / 2 + CGFloat(index + 1) * .pi / CGFloat(points)
                    let prev = CGPoint(x: center.x + cos(prevAngle) * inner, y: center.y + sin(prevAngle) * inner)
                    let next = CGPoint(x: center.x + cos(nextAngle) * inner, y: center.y + sin(nextAngle) * inner)
                    path.addQuadCurve(to: point, control: CGPoint(x: (prev.x + point.x) / 2 + cos(angle) * 0.02, y: (prev.y + point.y) / 2 + sin(angle) * 0.02))
                    path.addQuadCurve(to: next, control: CGPoint(x: (next.x + point.x) / 2 + cos(angle) * 0.02, y: (next.y + point.y) / 2 + sin(angle) * 0.02))
                } else {
                    path.addLine(to: point)
                }
            }
            path.closeSubpath()
        }
        return [MotifPart(star)]
    }

    static func shell() -> [MotifPart] {
        // A scallop: a fan from the hinge with a scalloped rim, grooves cut
        // between the ribs, and the two small ears at the hinge.
        let hinge = CGPoint(x: 0.5, y: 0.18)
        let radius: CGFloat = 0.56
        func point(_ degrees: CGFloat, _ distance: CGFloat) -> CGPoint {
            let angle = degrees * .pi / 180
            return CGPoint(x: hinge.x + distance * cos(angle), y: hinge.y + distance * sin(angle))
        }
        let ribs = 5
        let first: CGFloat = 140, last: CGFloat = 40
        let step = (first - last) / CGFloat(ribs)
        // The fan narrows to a short base, not a point, so it joins the ears.
        let fan = path { path in
            path.move(to: CGPoint(x: hinge.x - 0.06, y: hinge.y + 0.02))
            path.addLine(to: point(first, radius))
            for rib in 0..<ribs {
                let from = first - CGFloat(rib) * step
                path.addQuadCurve(to: point(from - step, radius), control: point(from - step / 2, radius * 1.13))
            }
            path.addLine(to: CGPoint(x: hinge.x + 0.06, y: hinge.y + 0.02))
            path.closeSubpath()
        }
        let ears = CGPath(roundedRect: CGRect(x: 0.34, y: 0.10, width: 0.32, height: 0.12), cornerWidth: 0.03, cornerHeight: 0.03, transform: nil)
        let grooves = path { path in
            for rib in 1..<ribs {
                let angle = first - CGFloat(rib) * step
                path.move(to: point(angle, 0.17))
                path.addLine(to: point(angle, radius * 0.9))
            }
        }
        let shell = fan.union(ears)
            .subtracting(grooves.copy(strokingWithWidth: 0.035, lineCap: .round, lineJoin: .round, miterLimit: 1))
        return [MotifPart(shell, .area, evenOdd: true)]
    }

    static func seaweed() -> [MotifPart] {
        func frond(baseX: CGFloat, width: CGFloat, height: CGFloat, lean: CGFloat) -> MotifPart {
            let baseY: CGFloat = 0.08
            let topY = baseY + height
            let frondPath = path { path in
                path.move(to: CGPoint(x: baseX - width / 2, y: baseY))
                path.addCurve(
                    to: CGPoint(x: baseX + lean, y: topY),
                    control1: CGPoint(x: baseX - width / 2 - 0.08, y: baseY + height * 0.35),
                    control2: CGPoint(x: baseX + lean - 0.10, y: baseY + height * 0.72)
                )
                path.addCurve(
                    to: CGPoint(x: baseX + width / 2, y: baseY),
                    control1: CGPoint(x: baseX + lean + 0.10, y: baseY + height * 0.72),
                    control2: CGPoint(x: baseX + width / 2 + 0.08, y: baseY + height * 0.35)
                )
                path.closeSubpath()
            }
            return MotifPart(frondPath)
        }
        return [
            frond(baseX: 0.34, width: 0.16, height: 0.74, lean: -0.04),
            frond(baseX: 0.54, width: 0.18, height: 0.84, lean: 0.02),
            frond(baseX: 0.72, width: 0.14, height: 0.66, lean: 0.05),
        ]
    }

    static func flower() -> [MotifPart] {
        let petals = path { path in
            let center = CGPoint(x: 0.5, y: 0.5)
            for index in 0..<5 {
                let angle = .pi / 2 + CGFloat(index) * (.pi * 2 / 5)
                let petalCenter = CGPoint(x: center.x + cos(angle) * 0.22, y: center.y + sin(angle) * 0.22)
                path.addEllipse(in: CGRect(x: petalCenter.x - 0.17, y: petalCenter.y - 0.17, width: 0.34, height: 0.34))
            }
        }
        let center = path { path in
            path.addEllipse(in: CGRect(x: 0.36, y: 0.36, width: 0.28, height: 0.28))
        }
        return [MotifPart(petals, .area, slot: 0), MotifPart(center, .area, slot: 1)]
    }

    static func leaf() -> [MotifPart] {
        let body = path { path in
            path.move(to: CGPoint(x: 0.18, y: 0.18))
            path.addQuadCurve(to: CGPoint(x: 0.82, y: 0.82), control: CGPoint(x: 0.34, y: 0.72))
            path.addQuadCurve(to: CGPoint(x: 0.18, y: 0.18), control: CGPoint(x: 0.70, y: 0.30))
            path.closeSubpath()
        }
        let veins = path { path in
            path.move(to: CGPoint(x: 0.22, y: 0.22))
            path.addLine(to: CGPoint(x: 0.78, y: 0.78))
            path.move(to: CGPoint(x: 0.14, y: 0.12))
            path.addLine(to: CGPoint(x: 0.22, y: 0.22))
        }
        return [MotifPart(body), MotifPart(veins, .line)]
    }

    static func mushroom() -> [MotifPart] {
        let cap = path { path in
            path.move(to: CGPoint(x: 0.14, y: 0.42))
            path.addQuadCurve(to: CGPoint(x: 0.86, y: 0.42), control: CGPoint(x: 0.50, y: 0.98))
            path.addQuadCurve(to: CGPoint(x: 0.14, y: 0.42), control: CGPoint(x: 0.50, y: 0.34))
            path.closeSubpath()
            for (x, y, r) in [(0.36, 0.64, 0.065), (0.56, 0.72, 0.055), (0.66, 0.54, 0.06)] as [(CGFloat, CGFloat, CGFloat)] {
                path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }
        let stem = path { path in
            path.addRoundedRect(in: CGRect(x: 0.38, y: 0.10, width: 0.24, height: 0.38), cornerWidth: 0.10, cornerHeight: 0.10)
        }
        return [MotifPart(cap, .area, slot: 0, evenOdd: true), MotifPart(stem, .area, slot: 1)]
    }

    static func cloud() -> [MotifPart] {
        let cloudPath = path { path in
            path.addRoundedRect(in: CGRect(x: 0.10, y: 0.22, width: 0.80, height: 0.26), cornerWidth: 0.13, cornerHeight: 0.13)
            path.addEllipse(in: CGRect(x: 0.16, y: 0.34, width: 0.34, height: 0.34))
            path.addEllipse(in: CGRect(x: 0.38, y: 0.40, width: 0.38, height: 0.38))
            path.addEllipse(in: CGRect(x: 0.58, y: 0.32, width: 0.28, height: 0.28))
        }
        return [MotifPart(cloudPath)]
    }

    static func lemon() -> [MotifPart] {
        let peel = path { path in
            path.addEllipse(in: CGRect(x: 0.10, y: 0.10, width: 0.80, height: 0.80))
        }
        let segments = path { path in
            let center = CGPoint(x: 0.5, y: 0.5)
            let outer: CGFloat = 0.32
            let inner: CGFloat = 0.06
            let wedgeCount = 7
            let gap: CGFloat = 0.055
            for index in 0..<wedgeCount {
                let startAngle = CGFloat(index) * (.pi * 2 / CGFloat(wedgeCount)) + gap
                let endAngle = CGFloat(index + 1) * (.pi * 2 / CGFloat(wedgeCount)) - gap
                path.move(to: CGPoint(x: center.x + cos(startAngle) * inner, y: center.y + sin(startAngle) * inner))
                path.addLine(to: CGPoint(x: center.x + cos(startAngle) * outer, y: center.y + sin(startAngle) * outer))
                path.addArc(center: center, radius: outer, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                path.addLine(to: CGPoint(x: center.x + cos(endAngle) * inner, y: center.y + sin(endAngle) * inner))
                path.addArc(center: center, radius: inner, startAngle: endAngle, endAngle: startAngle, clockwise: true)
                path.closeSubpath()
            }
        }
        return [MotifPart(peel, .area, slot: 0), MotifPart(segments, .area, slot: 1)]
    }

    static func cherry() -> [MotifPart] {
        let cherries = path { path in
            path.addEllipse(in: CGRect(x: 0.10, y: 0.12, width: 0.34, height: 0.34))
            path.addEllipse(in: CGRect(x: 0.52, y: 0.12, width: 0.34, height: 0.34))
        }
        let stems = path { path in
            path.move(to: CGPoint(x: 0.27, y: 0.44))
            path.addQuadCurve(to: CGPoint(x: 0.50, y: 0.88), control: CGPoint(x: 0.34, y: 0.72))
            path.move(to: CGPoint(x: 0.69, y: 0.44))
            path.addQuadCurve(to: CGPoint(x: 0.50, y: 0.88), control: CGPoint(x: 0.64, y: 0.72))
        }
        let leafPart = path { path in
            path.move(to: CGPoint(x: 0.50, y: 0.82))
            path.addQuadCurve(to: CGPoint(x: 0.80, y: 0.90), control: CGPoint(x: 0.64, y: 0.94))
            path.addQuadCurve(to: CGPoint(x: 0.50, y: 0.82), control: CGPoint(x: 0.68, y: 0.78))
            path.closeSubpath()
        }
        return [MotifPart(cherries, .area, slot: 0), MotifPart(stems, .line, slot: 1), MotifPart(leafPart, .area, slot: 1)]
    }

    static func sun() -> [MotifPart] {
        let sunPath = path { path in
            path.addEllipse(in: CGRect(x: 0.31, y: 0.31, width: 0.38, height: 0.38))
            let center = CGPoint(x: 0.5, y: 0.5)
            for index in 0..<8 {
                let angle = CGFloat(index) * (.pi / 4)
                let inner: CGFloat = 0.23
                let outer: CGFloat = 0.40
                let rayWidth: CGFloat = 0.045
                let dx = cos(angle), dy = sin(angle)
                let px = -sin(angle) * rayWidth, py = cos(angle) * rayWidth
                let start = CGPoint(x: center.x + dx * inner, y: center.y + dy * inner)
                let end = CGPoint(x: center.x + dx * outer, y: center.y + dy * outer)
                path.move(to: CGPoint(x: start.x + px, y: start.y + py))
                path.addLine(to: CGPoint(x: end.x + px, y: end.y + py))
                path.addArc(center: end, radius: rayWidth, startAngle: angle + .pi / 2, endAngle: angle - .pi / 2, clockwise: true)
                path.addLine(to: CGPoint(x: start.x - px, y: start.y - py))
                path.closeSubpath()
            }
        }
        return [MotifPart(sunPath)]
    }

    static func snowflake() -> [MotifPart] {
        let center = CGPoint(x: 0.5, y: 0.5)
        var parts: [MotifPart] = []
        for index in 0..<6 {
            let angle = CGFloat(index) * (.pi / 3)
            let dx = cos(angle), dy = sin(angle)
            let px = -sin(angle), py = cos(angle)
            let arm = path { path in
                path.move(to: center)
                path.addLine(to: CGPoint(x: center.x + dx * 0.40, y: center.y + dy * 0.40))
                let branchBase = CGPoint(x: center.x + dx * 0.24, y: center.y + dy * 0.24)
                path.move(to: branchBase)
                path.addLine(to: CGPoint(x: branchBase.x + (dx + px) * 0.12, y: branchBase.y + (dy + py) * 0.12))
                path.move(to: branchBase)
                path.addLine(to: CGPoint(x: branchBase.x + (dx - px) * 0.12, y: branchBase.y + (dy - py) * 0.12))
            }
            parts.append(MotifPart(arm, .line))
        }
        return parts
    }
}
