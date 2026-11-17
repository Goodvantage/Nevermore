import AppKit
import NevermoreCore
import RavenProtocol

/// Timings and distances of the ravens. A group of ravens is an unkindness.
@MainActor enum Unkindness {
    /// The pointer turns heads within this distance.
    static let gazeRadius: CGFloat = 120
    /// How far a row sinks under a landing bird.
    static let dipDepth: CGFloat = 2
    static let dipDuration: CFTimeInterval = 0.2
    static let hopHeight: CGFloat = 3
    static let hopDuration: CFTimeInterval = 0.18
    /// Points per second; flights take between the two durations below.
    static let flightSpeed: CGFloat = 620
    static let shortestFlight: CFTimeInterval = 0.3
    static let longestFlight: CFTimeInterval = 0.6
    /// Automated runs measure a still window.
    static let isStaged = ProcessInfo.processInfo.arguments.contains("--self-check") || ProcessInfo.processInfo.arguments.contains("--performance-check")
}

/// One standing raven on a sidebar row. The view is the bird's box; its feet are on the
/// bottom edge. It never takes a click and is not an accessibility
/// element: the row's label already says "3 unread".
@MainActor final class RavenPerchView: NSView {
    let figure = RavenFigure()
    /// The bird is in the air; its place stays.
    var isAway = false { didSet { figure.layer.isHidden = isAway } }
    private var ink: NSColor = .secondaryLabelColor
    private var eye: NSColor?
    private var lit = false

    init() {
        super.init(frame: NSRect(origin: .zero, size: RavenFigure.size))
        wantsLayer = true
        layer?.masksToBounds = false
        // Hops and landings move the bird from its feet.
        figure.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(figure.layer)
        setAccessibilityElement(false)
        apply()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        figure.layer.position = CGPoint(x: bounds.midX, y: 0)
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); apply() }

    /// `eye` nil picks a pupil that shows against the ink.
    func tint(ink: NSColor, eye: NSColor? = nil, lit: Bool) {
        self.ink = ink; self.eye = eye; self.lit = lit
        apply()
    }
    private func apply() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let resolved = ink.usingColorSpace(.sRGB) ?? ink
            let pupil = eye ?? (Ink.isLight(resolved) ? NSColor.black.withAlphaComponent(0.8) : NSColor.white.withAlphaComponent(0.9))
            figure.setColors(ink: resolved, eye: pupil.usingColorSpace(.sRGB) ?? pupil, lit: lit)
        }
    }

    /// The feet, in window coordinates.
    var feet: NSPoint { convert(NSPoint(x: bounds.midX, y: 0), to: nil) }

    /// Turns the head toward a point in window coordinates when it is
    /// near, and back to rest when it is not.
    func look(atWindowPoint point: NSPoint?) {
        guard let point, window != nil, !isHidden, !isAway else { figure.look(at: nil); return }
        let local = convert(point, from: nil)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        guard hypot(local.x - center.x, local.y - center.y) <= Unkindness.gazeRadius else { figure.look(at: nil); return }
        figure.look(at: CGPoint(x: local.x - (bounds.midX - RavenFigure.size.width / 2), y: local.y))
    }

    func hop() {
        guard !Ink.reducesMotion, !Unkindness.isStaged else { return }
        let hop = CAKeyframeAnimation(keyPath: "transform.translation.y")
        hop.values = [0, Unkindness.hopHeight, 0]
        hop.keyTimes = [0, 0.45, 1]
        hop.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeIn)]
        hop.duration = Unkindness.hopDuration * Ink.timeScale
        figure.layer.add(hop, forKey: "hop")
    }
}

/// The air over one pane of the window. Birds in flight are layers here,
/// clipped to the pane; the view also reports the pointer, so perched
/// birds can look at it. It never takes a click.
@MainActor final class AviaryView: NSView {
    var onPointer: ((NSPoint?) -> Void)?
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        guard !Unkindness.isStaged else { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) { onPointer?(event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { onPointer?(event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { onPointer?(nil) }
}

/// Runs a closure when an animation stops, finished or not.
/// Core Animation calls its delegates on the main thread.
@MainActor final class AnimationEnd: NSObject, CAAnimationDelegate {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    nonisolated func animationDidStop(_ animation: CAAnimation, finished: Bool) {
        MainActor.assumeIsolated { self.handler() }
    }
}

/// Moves the ravens of one window.
///
/// A raven stands on the sidebar row of every unread conversation that
/// calls for attention. One flies in when a conversation becomes unread.
/// It stays on that row while the conversation is opened, then leaves
/// once through the top of the sidebar when the conversation is read.
/// There are no flights into the transcript or extra all-read farewells.
///
/// The birds follow the server's unread counts and carry no state of
/// their own beyond where they are. Reduce Motion shows them standing
/// still; counts, titles and VoiceOver labels are unchanged.
@MainActor final class UnkindnessController {
    unowned let owner: ConversationWindow
    let sidebarAir = AviaryView()

    private weak var observedSession: AccountSession?
    private var counts: [String: Int] = [:]
    private var primed = false
    /// Conversations whose bird is arriving in the sidebar.
    private var away = Set<String>()
    /// Each bird's feet, measured from the trailing edge of its row, kept
    /// so a bird can leave from where it stood after its row lost it.
    private var perchOffsets: [String: CGFloat] = [:]
    /// Read while their bird was still in the air.
    private var leavesOnLanding = Set<String>()
    private var airborne: [UUID: [RavenFigure]] = [:]
    private var pointer: NSPoint?

    init(owner: ConversationWindow) {
        self.owner = owner
        sidebarAir.onPointer = { [weak self] point in self?.pointerMoved(point) }
    }

    private var sidebar: NSTableView { owner.sidebar }
    private var animates: Bool {
        guard !Ink.reducesMotion, !Unkindness.isStaged, let window = owner.window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    // MARK: Sidebar rows

    /// The bird on `channel`'s row, if it has one.
    func bird(for channel: RavenChannel) -> SidebarConversationCell.Bird? {
        guard let session = owner.session, owner.unreadCount(channel.id) > 0, !channel.raw["muted"].bool, !channel.raw["is_archived"].bool else { return nil }
        return .init(lit: channel.isDM || session.mentionedChannels.contains(channel.id), away: away.contains(channel.id))
    }

    private func row(of channelID: String) -> Int? { owner.sidebarItems.firstIndex { $0.channel?.id == channelID } }

    /// The row's cell when it is on screen.
    private func cell(for channelID: String) -> SidebarConversationCell? {
        guard let row = row(of: channelID), sidebar.rows(in: sidebar.visibleRect).contains(row),
              let cell = sidebar.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarConversationCell else { return nil }
        cell.layoutSubtreeIfNeeded()
        return cell
    }

    private func setAway(_ channelID: String, _ isAway: Bool) {
        if isAway { away.insert(channelID) } else { away.remove(channelID) }
        cell(for: channelID)?.perch.isAway = isAway
    }

    /// The sidebar was rebuilt, which happens on every account change.
    func sidebarDidReload() {
        guard let session = owner.session, !session.stopped else { reset(); return }
        let now = UnreadFlock.perching(channels: session.channels, unread: session.unread)
        guard primed, observedSession === session else {
            // The first look at an account: birds are already where they are.
            reset()
            observedSession = session; counts = now; primed = true
            measurePerches()
            return
        }
        let before = counts
        counts = now
        for change in UnreadFlock.changes(from: before, to: now) {
            switch change {
            case .arrived(let id): arrive(id)
            case .grew(let id): cell(for: id)?.perch.hop()
            case .left(let id): leave(id)
            }
        }
        measurePerches()
        applyGaze()
    }

    private func measurePerches() {
        for id in counts.keys where !away.contains(id) {
            guard let cell = cell(for: id), !cell.perch.isHidden else { continue }
            perchOffsets[id] = cell.bounds.maxX - cell.perch.frame.midX
        }
        perchOffsets = perchOffsets.filter { counts[$0.key] != nil }
    }

    private func arrive(_ id: String) {
        // A message in the conversation being read is seen at once; a bird
        // would land only to leave.
        if id == owner.channel?.id, owner.isFollowing, owner.window?.isKeyWindow == true, NSApp.isActive { return }
        guard animates, let cell = cell(for: id) else { return }
        setAway(id, true)
        let target = cell.perch.feet
        let top = sidebarAir.convert(NSPoint(x: 0, y: sidebarAir.bounds.maxY), to: nil).y
        // Down from the top edge, curling left onto the row it faces.
        let start = NSPoint(x: target.x + 18, y: top + RavenFigure.size.height)
        let control = NSPoint(x: target.x + 30, y: target.y + 26)
        fly(from: start, control: control, to: target, timing: .easeOut, in: [sidebarAir]) { [weak self] in
            guard let self else { return }
            self.setAway(id, false)
            if let landed = self.cell(for: id) { self.dip(landed) }
            if self.leavesOnLanding.remove(id) != nil { self.leaveRow(id) }
            self.applyGaze()
        }
    }

    private func leave(_ id: String) {
        defer { perchOffsets.removeValue(forKey: id) }
        if away.contains(id) {
            // Still in the air; it leaves once it has landed.
            leavesOnLanding.insert(id)
            return
        }
        leaveRow(id)
    }

    private func leaveRow(_ id: String) {
        away.remove(id)
        guard animates, let row = row(of: id), sidebar.rows(in: sidebar.visibleRect).contains(row),
              let cell = sidebar.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarConversationCell else { return }
        cell.layoutSubtreeIfNeeded()
        let offset = perchOffsets[id] ?? (cell.bounds.maxX - cell.perch.frame.midX)
        let from = cell.convert(NSPoint(x: cell.bounds.maxX - offset, y: cell.perch.frame.minY), to: nil)
        takeOff(from: from, towardTrailing: false, in: sidebarAir)
    }

    /// Up and out through the top of a pane.
    private func takeOff(from: NSPoint, towardTrailing: Bool, in air: AviaryView, ink: NSColor = .secondaryLabelColor) {
        let top = air.convert(NSPoint(x: 0, y: air.bounds.maxY), to: nil).y
        let drift: CGFloat = towardTrailing ? 110 : -46
        let to = NSPoint(x: from.x + drift, y: top + RavenFigure.size.height)
        let control = NSPoint(x: from.x + drift * 0.15, y: from.y + (to.y - from.y) * 0.75)
        fly(from: from, control: control, to: to, timing: .easeIn, in: [air], ink: ink) {}
    }

    private func dip(_ view: NSView) {
        guard animates else { return }
        view.wantsLayer = true
        let dip = CAKeyframeAnimation(keyPath: "transform.translation.y")
        dip.values = [0, -Unkindness.dipDepth, Unkindness.dipDepth * 0.3, 0]
        dip.keyTimes = [0, 0.3, 0.72, 1]
        dip.duration = Unkindness.dipDuration * Ink.timeScale
        view.layer?.add(dip, forKey: "ravenLanding")
    }

    // MARK: Flight

    /// Flies one bird along a curve given in window coordinates. Each
    /// pane draws the part of the flight that crosses it.
    private func fly(from: NSPoint, control: NSPoint, to: NSPoint, timing: CAMediaTimingFunctionName, in airs: [AviaryView], ink: NSColor = .secondaryLabelColor, landingInk: NSColor? = nil, then completion: @escaping () -> Void) {
        let id = UUID()
        let distance = hypot(to.x - from.x, to.y - from.y)
        let duration = min(Unkindness.longestFlight, max(Unkindness.shortestFlight, Double(distance / Unkindness.flightSpeed))) * Ink.timeScale
        var figures: [RavenFigure] = []
        // The wings beat without end, so a transaction's completion block
        // would never run; the flight ends when its travel does.
        let end = AnimationEnd { [weak self] in
            // Nil: the flight was cancelled, or its other pane ended it.
            guard let self, let landed = self.airborne.removeValue(forKey: id) else { return }
            for figure in landed { figure.layer.removeFromSuperlayer() }
            completion()
        }
        for air in airs {
            guard let host = air.layer else { continue }
            let figure = RavenFigure()
            air.effectiveAppearance.performAsCurrentDrawingAppearance {
                let start = ink.usingColorSpace(.sRGB) ?? .gray
                figure.setColors(ink: start, eye: Ink.isLight(start) ? .black : .white, lit: false)
                if let end = landingInk?.usingColorSpace(.sRGB) { figure.fade(to: end, duration: duration) }
            }
            figure.setPose(.flying)
            figure.layer.anchorPoint = CGPoint(x: 0.5, y: 0)
            // The figure faces left; turn it to face where it is going.
            if to.x > from.x { figure.layer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1)) }
            let path = CGMutablePath()
            path.move(to: air.convert(from, from: nil))
            path.addQuadCurve(to: air.convert(to, from: nil), control: air.convert(control, from: nil))
            figure.layer.position = air.convert(to, from: nil)
            let travel = CAKeyframeAnimation(keyPath: "position")
            travel.path = path
            travel.duration = duration
            travel.timingFunction = CAMediaTimingFunction(name: timing)
            travel.fillMode = .both
            travel.delegate = end
            host.addSublayer(figure.layer)
            figure.layer.add(travel, forKey: "flight")
            figures.append(figure)
        }
        airborne[id] = figures
    }

    private func groundFlights() {
        for figures in airborne.values { for figure in figures { figure.layer.removeFromSuperlayer() } }
        airborne.removeAll()
    }

    // MARK: Gaze

    private func pointerMoved(_ point: NSPoint?) {
        pointer = point
        applyGaze()
    }

    private func applyGaze() {
        guard !Unkindness.isStaged else { return }
        for row in sidebar.rows(in: sidebar.visibleRect).lowerBound..<sidebar.rows(in: sidebar.visibleRect).upperBound {
            guard let cell = sidebar.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarConversationCell, !cell.perch.isHidden else { continue }
            cell.perch.look(atWindowPoint: pointer)
        }
    }

    // MARK: Lifetime

    /// The window shows another account, or none.
    func reset() {
        groundFlights()
        away.removeAll(); leavesOnLanding.removeAll(); perchOffsets.removeAll()
        counts = [:]; primed = false; observedSession = nil
    }
}
