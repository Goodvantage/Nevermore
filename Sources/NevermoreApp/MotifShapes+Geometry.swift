import CoreGraphics

// Geometric and pixel motifs: Memphis, neon, terminal.
extension MotifShapes {
    static func dot() -> [MotifPart] {
        [MotifPart(circle(CGPoint(x: 0.5, y: 0.5), 0.3))]
    }

    static func ring() -> [MotifPart] {
        [
            MotifPart(
                path { p in
                    p.addEllipse(in: CGRect(x: 0.12, y: 0.12, width: 0.76, height: 0.76))
                    p.addEllipse(in: CGRect(x: 0.26, y: 0.26, width: 0.48, height: 0.48))
                },
                .area,
                evenOdd: true
            )
        ]
    }

    static func triangle() -> [MotifPart] {
        [
            MotifPart(
                path { p in
                    let top = CGPoint(x: 0.5, y: 0.9)
                    let right = CGPoint(x: 0.9, y: 0.14)
                    let left = CGPoint(x: 0.1, y: 0.14)
                    let r: CGFloat = 0.08
                    func inset(_ a: CGPoint, toward b: CGPoint, by d: CGFloat) -> CGPoint {
                        let dx = b.x - a.x, dy = b.y - a.y
                        let len = sqrt(dx * dx + dy * dy)
                        return CGPoint(x: a.x + dx / len * d, y: a.y + dy / len * d)
                    }
                    p.move(to: inset(top, toward: right, by: r))
                    p.addArc(tangent1End: top, tangent2End: left, radius: r)
                    p.addArc(tangent1End: left, tangent2End: right, radius: r)
                    p.addArc(tangent1End: right, tangent2End: top, radius: r)
                    p.closeSubpath()
                }
            )
        ]
    }

    static func squiggle() -> [MotifPart] {
        [
            MotifPart(
                path { p in
                    p.move(to: CGPoint(x: 0.08, y: 0.5))
                    p.addCurve(to: CGPoint(x: 0.36, y: 0.5),
                               control1: CGPoint(x: 0.12, y: 0.88),
                               control2: CGPoint(x: 0.32, y: 0.88))
                    p.addCurve(to: CGPoint(x: 0.64, y: 0.5),
                               control1: CGPoint(x: 0.40, y: 0.12),
                               control2: CGPoint(x: 0.60, y: 0.12))
                    p.addCurve(to: CGPoint(x: 0.92, y: 0.5),
                               control1: CGPoint(x: 0.68, y: 0.88),
                               control2: CGPoint(x: 0.88, y: 0.88))
                },
                .line
            )
        ]
    }

    static func zigzag() -> [MotifPart] {
        [
            MotifPart(
                path { p in
                    let points = [
                        CGPoint(x: 0.08, y: 0.25),
                        CGPoint(x: 0.29, y: 0.78),
                        CGPoint(x: 0.50, y: 0.22),
                        CGPoint(x: 0.71, y: 0.78),
                        CGPoint(x: 0.92, y: 0.25)
                    ]
                    p.addLines(between: points)
                },
                .line
            )
        ]
    }

    static func halfCircle() -> [MotifPart] {
        [
            MotifPart(
                path { p in
                    p.move(to: CGPoint(x: 0.1, y: 0.18))
                    p.addLine(to: CGPoint(x: 0.9, y: 0.18))
                    p.addArc(center: CGPoint(x: 0.5, y: 0.18), radius: 0.4,
                             startAngle: 0, endAngle: .pi, clockwise: false)
                    p.closeSubpath()
                }
            )
        ]
    }

    static func cross() -> [MotifPart] {
        [
            MotifPart(
                path { p in
                    let t: CGFloat = 0.11
                    let c: CGFloat = 0.06
                    let l: CGFloat = 0.08, r: CGFloat = 0.92
                    let b: CGFloat = 0.08, top: CGFloat = 0.92
                    let xl = 0.5 - t, xr = 0.5 + t
                    let yb = 0.5 - t, yt = 0.5 + t
                    p.move(to: CGPoint(x: xl + c, y: top))
                    p.addLine(to: CGPoint(x: xr - c, y: top))
                    p.addQuadCurve(to: CGPoint(x: xr, y: top - c), control: CGPoint(x: xr, y: top))
                    p.addLine(to: CGPoint(x: xr, y: yt))
                    p.addLine(to: CGPoint(x: r - c, y: yt))
                    p.addQuadCurve(to: CGPoint(x: r, y: yt - c), control: CGPoint(x: r, y: yt))
                    p.addLine(to: CGPoint(x: r, y: yb + c))
                    p.addQuadCurve(to: CGPoint(x: r - c, y: yb), control: CGPoint(x: r, y: yb))
                    p.addLine(to: CGPoint(x: xr, y: yb))
                    p.addLine(to: CGPoint(x: xr, y: b + c))
                    p.addQuadCurve(to: CGPoint(x: xr - c, y: b), control: CGPoint(x: xr, y: b))
                    p.addLine(to: CGPoint(x: xl + c, y: b))
                    p.addQuadCurve(to: CGPoint(x: xl, y: b + c), control: CGPoint(x: xl, y: b))
                    p.addLine(to: CGPoint(x: xl, y: yb))
                    p.addLine(to: CGPoint(x: l + c, y: yb))
                    p.addQuadCurve(to: CGPoint(x: l, y: yb + c), control: CGPoint(x: l, y: yb))
                    p.addLine(to: CGPoint(x: l, y: yt - c))
                    p.addQuadCurve(to: CGPoint(x: l + c, y: yt), control: CGPoint(x: l, y: yt))
                    p.addLine(to: CGPoint(x: xl, y: yt))
                    p.addLine(to: CGPoint(x: xl, y: top - c))
                    p.addQuadCurve(to: CGPoint(x: xl + c, y: top), control: CGPoint(x: xl, y: top))
                    p.closeSubpath()
                }
            )
        ]
    }

    static func star() -> [MotifPart] {
        [MotifPart(starPolygon(points: 5, center: CGPoint(x: 0.5, y: 0.5), outer: 0.42, inner: 0.20))]
    }

    static func sparkle() -> [MotifPart] {
        [
            MotifPart(
                path { p in
                    let c = CGPoint(x: 0.5, y: 0.5)
                    let r: CGFloat = 0.38
                    let pinch: CGFloat = 0.09
                    let up = CGPoint(x: c.x, y: c.y + r)
                    let right = CGPoint(x: c.x + r, y: c.y)
                    let down = CGPoint(x: c.x, y: c.y - r)
                    let left = CGPoint(x: c.x - r, y: c.y)
                    let q1 = CGPoint(x: c.x + pinch, y: c.y + pinch)
                    let q2 = CGPoint(x: c.x + pinch, y: c.y - pinch)
                    let q3 = CGPoint(x: c.x - pinch, y: c.y - pinch)
                    let q4 = CGPoint(x: c.x - pinch, y: c.y + pinch)
                    p.move(to: up)
                    p.addQuadCurve(to: right, control: q1)
                    p.addQuadCurve(to: down, control: q2)
                    p.addQuadCurve(to: left, control: q3)
                    p.addQuadCurve(to: up, control: q4)
                    p.closeSubpath()
                }
            ),
            MotifPart(circle(CGPoint(x: 0.82, y: 0.82), 0.06))
        ]
    }

    static func heart() -> [MotifPart] {
        // Two round lobes with a cleft on top, meeting in a soft point.
        [
            MotifPart(
                path { p in
                    p.move(to: CGPoint(x: 0.5, y: 0.12))
                    p.addCurve(to: CGPoint(x: 0.07, y: 0.6),
                               control1: CGPoint(x: 0.33, y: 0.27),
                               control2: CGPoint(x: 0.07, y: 0.41))
                    p.addCurve(to: CGPoint(x: 0.5, y: 0.7),
                               control1: CGPoint(x: 0.07, y: 0.92),
                               control2: CGPoint(x: 0.43, y: 0.94))
                    p.addCurve(to: CGPoint(x: 0.93, y: 0.6),
                               control1: CGPoint(x: 0.57, y: 0.94),
                               control2: CGPoint(x: 0.93, y: 0.92))
                    p.addCurve(to: CGPoint(x: 0.5, y: 0.12),
                               control1: CGPoint(x: 0.93, y: 0.41),
                               control2: CGPoint(x: 0.67, y: 0.27))
                    p.closeSubpath()
                }
            )
        ]
    }

    static func bolt() -> [MotifPart] {
        [
            MotifPart(
                polygon([
                    CGPoint(x: 0.58, y: 0.94),
                    CGPoint(x: 0.22, y: 0.50),
                    CGPoint(x: 0.46, y: 0.50),
                    CGPoint(x: 0.38, y: 0.06),
                    CGPoint(x: 0.78, y: 0.54),
                    CGPoint(x: 0.54, y: 0.54)
                ])
            )
        ]
    }

    static func diamond() -> [MotifPart] {
        // A cut gem: one outline, with the girdle and crown facets drawn
        // as lines so a filled gem stays one solid shape.
        let crownLeft = CGPoint(x: 0.32, y: 0.86), crownRight = CGPoint(x: 0.68, y: 0.86)
        let girdleLeft = CGPoint(x: 0.08, y: 0.66), girdleRight = CGPoint(x: 0.92, y: 0.66)
        let tip = CGPoint(x: 0.5, y: 0.1)
        return [
            MotifPart(polygon([crownLeft, crownRight, girdleRight, tip, girdleLeft])),
            MotifPart(path { p in
                p.move(to: CGPoint(x: 0.17, y: 0.66)); p.addLine(to: CGPoint(x: 0.83, y: 0.66))
                p.move(to: CGPoint(x: 0.4, y: 0.66)); p.addLine(to: CGPoint(x: 0.5, y: 0.22))
                p.move(to: CGPoint(x: 0.6, y: 0.66)); p.addLine(to: CGPoint(x: 0.5, y: 0.22))
            }, .line),
        ]
    }

    static func spiral() -> [MotifPart] {
        [
            MotifPart(
                path { p in
                    let center = CGPoint(x: 0.5, y: 0.5)
                    let turns: CGFloat = 2.5
                    let maxRadius: CGFloat = 0.4
                    let steps = 120
                    for i in 0...steps {
                        let t = CGFloat(i) / CGFloat(steps)
                        let angle = t * turns * 2 * .pi - .pi / 2
                        let radius = 0.04 + t * (maxRadius - 0.04)
                        let point = CGPoint(x: center.x + cos(angle) * radius,
                                            y: center.y + sin(angle) * radius)
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                },
                .line
            )
        ]
    }

    static func musicNote() -> [MotifPart] {
        [
            MotifPart(
                path { p in
                    let head = CGPoint(x: 0.36, y: 0.24)
                    p.addEllipse(in: CGRect(x: head.x - 0.16, y: head.y - 0.11, width: 0.32, height: 0.22))
                    let stemX = head.x + 0.14
                    p.addRoundedRect(in: CGRect(x: stemX - 0.035, y: 0.26, width: 0.07, height: 0.56),
                                     cornerWidth: 0.035, cornerHeight: 0.035)
                    p.move(to: CGPoint(x: stemX + 0.035, y: 0.82))
                    p.addCurve(to: CGPoint(x: 0.74, y: 0.50),
                               control1: CGPoint(x: 0.70, y: 0.84),
                               control2: CGPoint(x: 0.82, y: 0.70))
                    p.addCurve(to: CGPoint(x: stemX + 0.035, y: 0.66),
                               control1: CGPoint(x: 0.70, y: 0.60),
                               control2: CGPoint(x: 0.62, y: 0.68))
                    p.closeSubpath()
                }
            )
        ]
    }

    static func pixelHeart() -> [MotifPart] {
        [
            MotifPart(
                pixels([
                    ".##.##.",
                    "#######",
                    "#######",
                    ".#####.",
                    "..###..",
                    "...#...",
                    "......."
                ])
            )
        ]
    }

    static func pixelStar() -> [MotifPart] {
        [
            MotifPart(
                pixels([
                    "...#...",
                    "..###..",
                    ".#####.",
                    "#######",
                    ".#####.",
                    "..###..",
                    "...#..."
                ])
            )
        ]
    }
}
