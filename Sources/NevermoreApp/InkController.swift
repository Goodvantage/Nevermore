import AppKit
import RavenProtocol
import NevermoreCore

/// Wet Ink: what a conversation window does with a message between Return
/// and the server's acknowledgement.
///
///     composer ──lift──▶ flight ──land──▶ wet ──acknowledged──▶ dry
///         ▲                                 │
///         └────────────── take back ────────┘
///
/// The transcript owns the text. This controller only decorates it: wet
/// color is a temporary layout attribute (never copied or exported),
/// flying words are layers above the pane, and sweeps are short-lived
/// views inside the transcript. `didRender` re-derives everything from the
/// outbox after each render, so no state here can outlive the store's.
@MainActor final class InkController: NSObject {
    /// An accepted, unacknowledged send as the transcript shows it.
    struct Pending {
        let operation: SendOperation
        /// The message text, without its header or status line.
        let body: NSRange
    }

    /// Glyphs cut out of a text view: one image plus where each word sits.
    private struct Capture {
        let image: CGImage
        /// Word rectangles in overlay coordinates.
        let frames: [CGRect]
        /// The part of `image` showing each word, in unit coordinates.
        let units: [CGRect]
        var bounds: CGRect { frames.reduce(CGRect.null) { $0.union($1) } }
    }

    private final class Flight {
        let channelID: String
        let text: String
        let capture: Capture
        var layers: [CALayer]
        var operationID: UUID?
        var launched = false
        var expiry: Task<Void, Never>?
        init(channelID: String, text: String, capture: Capture, layers: [CALayer]) {
            self.channelID = channelID; self.text = text; self.capture = capture; self.layers = layers
        }
    }

    unowned let owner: ConversationWindow
    let overlay = InkOverlayView()
    /// Holds the words in the air. It shifts with the transcript when that
    /// scrolls during a flight, so words still land on their text.
    private let airspace = CALayer()
    private var launchOrigin: CGFloat?
    private(set) var pending: [Pending] = []
    /// Body ranges of rendered messages, by message ID.
    private var bodies: [String: NSRange] = [:]
    private var messageForOperation: [UUID: String] = [:]
    private var flight: Flight?
    /// Sends whose words are in the air; their text stays hidden.
    private var flying = Set<UUID>()
    private var blots: [UUID: InkBlot] = [:]
    private var renderedChannel: String?
    /// The conversation the ink state describes.
    var renderedConversation: String? { renderedChannel }
    private var renderedMessages = Set<String>()
    private var wetOperations = Set<UUID>()
    /// Undo managers holding an Undo Send entry that targets this object.
    private let undoManagers = NSHashTable<UndoManager>.weakObjects()
    /// Drying sweeps in progress, by message ID.
    private var sweeps: [String: InkEffectView] = [:]

    init(owner: ConversationWindow) {
        self.owner = owner
        super.init()
        overlay.layer?.addSublayer(airspace)
    }

    /// The transcript scrolled, by hand or because a message arrived.
    func transcriptDidScroll() {
        guard let launchOrigin, flight?.launched == true else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Scrolling down moves text up the screen; the overlay is unflipped.
        airspace.sublayerTransform = CATransform3DMakeTranslation(0, owner.transcriptScroll.contentView.bounds.origin.y - launchOrigin, 0)
        CATransaction.commit()
    }

    private func clearAirspace() {
        launchOrigin = nil
        airspace.removeAnimation(forKey: "inkSlide")
        CATransaction.begin(); CATransaction.setDisableActions(true)
        airspace.sublayerTransform = CATransform3DIdentity
        CATransaction.commit()
    }

    private var transcript: TranscriptView { owner.transcript }
    private var scale: CGFloat { owner.window?.backingScaleFactor ?? 2 }

    // MARK: Capturing glyphs

    /// Cuts `words` (character ranges) out of a text view. `region` is the
    /// character range to draw; it must contain every word.
    private func capture(_ view: NSTextView, words: [NSRange], region: NSRange) -> Capture? {
        guard let layout = view.layoutManager, let container = view.textContainer, !words.isEmpty else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: region, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).insetBy(dx: -3, dy: 0)
        guard rect.width > 0, rect.height > 0, let image = Ink.snapshot(layout, glyphs: glyphs, rect: rect, scale: scale) else { return nil }
        let origin = view.textContainerOrigin
        var frames: [CGRect] = [], units: [CGRect] = []
        for word in words {
            let wordGlyphs = layout.glyphRange(forCharacterRange: word, actualCharacterRange: nil)
            // Italics and emoji overhang their advance; keep a margin.
            let box = layout.boundingRect(forGlyphRange: wordGlyphs, in: container).insetBy(dx: -2, dy: 0).intersection(rect)
            guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
            frames.append(view.convert(box.offsetBy(dx: origin.x, dy: origin.y), to: overlay))
            // Text rectangles count down from the top of `rect`; a layer's
            // contents rectangle counts up from the bottom of its image.
            units.append(CGRect(x: (box.minX - rect.minX) / rect.width, y: (rect.maxY - box.maxY) / rect.height, width: box.width / rect.width, height: box.height / rect.height))
        }
        return Capture(image: image, frames: frames, units: units)
    }

    private func makeLayers(_ capture: Capture) -> [CALayer] {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        return zip(capture.frames, capture.units).map { frame, unit in
            let word = CALayer()
            word.frame = frame
            word.shadowColor = NSColor.black.cgColor
            word.shadowOpacity = 0; word.shadowRadius = 2.5; word.shadowOffset = CGSize(width: 0, height: -2)
            word.addSublayer(face(capture.image, unit: unit, in: word.bounds))
            airspace.addSublayer(word)
            return word
        }
    }

    private func face(_ image: CGImage, unit: CGRect, in bounds: CGRect) -> CALayer {
        let face = CALayer()
        face.frame = bounds
        face.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        face.contents = image; face.contentsRect = unit; face.contentsGravity = .resize
        face.contentsScale = scale
        return face
    }

    private func add(_ animation: CAAnimation, to layer: CALayer, delay: CFTimeInterval = 0) {
        animation.beginTime = CACurrentMediaTime() + delay * Ink.timeScale
        animation.speed = Float(1 / Ink.timeScale)
        animation.fillMode = .backwards
        layer.add(animation, forKey: nil)
    }

    private func after(_ seconds: CFTimeInterval, _ work: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds * Ink.timeScale))
            work()
        }
    }

    // MARK: Lift

    /// Called on Return, before the draft is accepted: the words leave the
    /// glass at once, so the send answers the key press, not the disk.
    func lift() {
        abandonFlight()
        let composer = owner.composer
        guard !Ink.reducesMotion, owner.editing == nil, let channel = owner.channel, let window = owner.window, window.isVisible, !window.isMiniaturized else { return }
        pressSendButton()
        let text = composer.string
        let words = InkFlightPlan.wordRanges(in: text)
        guard !words.isEmpty, words.count <= InkFlightPlan.wordLimit, let layout = composer.layoutManager, let container = composer.textContainer else { return }
        layout.ensureLayout(for: container)
        // A message taller than the composer would start outside the glass.
        guard layout.usedRect(for: container).height <= owner.composerScroll.contentSize.height + 1,
              let capture = capture(composer, words: words, region: NSRange(location: 0, length: (text as NSString).length)) else { return }
        let layers = makeLayers(capture)
        let flight = Flight(channelID: channel.id, text: text, capture: capture, layers: layers)
        self.flight = flight
        // The layers now show the text; the editor beneath would double it.
        composer.alphaValue = 0
        for (index, layer) in layers.enumerated() {
            let rise = CASpringAnimation(keyPath: "transform.translation.y")
            rise.fromValue = 0; rise.toValue = Ink.liftHeight
            rise.stiffness = 520; rise.damping = 30; rise.duration = rise.settlingDuration
            let shadow = CABasicAnimation(keyPath: "shadowOpacity")
            shadow.fromValue = 0; shadow.toValue = 0.22; shadow.duration = 0.12
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.setValue(Ink.liftHeight, forKeyPath: "transform.translation.y"); layer.shadowOpacity = 0.22
            CATransaction.commit()
            let delay = stagger(index, of: layers.count) * 0.5
            add(rise, to: layer, delay: delay); add(shadow, to: layer, delay: delay)
        }
        InkSounds.play(.lift)
        flight.expiry = Task { @MainActor [weak self, weak flight] in
            try? await Task.sleep(for: .seconds(1.5 * Ink.timeScale))
            guard let self, let flight, self.flight === flight, !flight.launched else { return }
            self.abandonFlight()
        }
    }

    /// The button gives under the send, whether Return or a click sent it.
    private func pressSendButton() {
        guard let layer = owner.sendButton.layer else { return }
        let bounds = layer.bounds
        // A view's layer scales about its corner; scale about the center.
        func scaled(_ factor: CGFloat) -> NSValue {
            var transform = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
            transform = CATransform3DScale(transform, factor, factor, 1)
            return NSValue(caTransform3D: CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0))
        }
        let press = CAKeyframeAnimation(keyPath: "transform")
        press.values = [scaled(1), scaled(0.8), scaled(1.07), scaled(1)]
        press.keyTimes = [0, 0.25, 0.7, 1]
        press.duration = 0.3 * Ink.timeScale
        layer.add(press, forKey: "inkPress")
    }

    private func stagger(_ index: Int, of count: Int) -> CFTimeInterval {
        Double(index) * min(Ink.staggerPerWord, Ink.staggerLimit / Double(max(count, 1)))
    }

    /// The outbox has the message. Its words are still in the air.
    func accepted(_ operation: SendOperation) {
        owner.composer.alphaValue = 1
        if let flight, !flight.launched {
            flight.operationID = operation.id
            if let rendered = pending.first(where: { $0.operation.id == operation.id }) {
                // The render that shows it came first; there is no slide left.
                launch(flight, to: rendered, slideFrom: owner.transcriptScroll.contentView.bounds.origin)
            } else {
                flying.insert(operation.id)
            }
        }
        guard let session = owner.session, let undo = session.draftUndoManagers[operation.channelID] else { return }
        let id = operation.id, channelID = operation.channelID
        undo.registerUndo(withTarget: self) { [weak session] ink in
            MainActor.assumeIsolated {
                guard let session else { return }
                ink.takeBack(id, in: session, channelID: channelID)
            }
        }
        undo.setActionName("Send")
        undoManagers.add(undo)
    }

    /// The window is closing. Draft undo managers belong to the account
    /// and outlive it, and an undo manager does not keep its targets alive.
    func detach() {
        reset()
        for undo in undoManagers.allObjects { undo.removeAllActions(withTarget: self) }
        undoManagers.removeAllObjects()
    }

    /// The send was refused; the draft is still in the composer.
    func sendFailed() { abandonFlight() }

    private func abandonFlight() {
        guard let flight else { return }
        self.flight = nil
        flight.expiry?.cancel()
        owner.composer.alphaValue = 1
        if let id = flight.operationID, flying.remove(id) != nil { reveal(id) }
        for layer in flight.layers { layer.removeFromSuperlayer() }
        clearAirspace()
    }

    // MARK: Render

    /// Called at the end of every transcript render.
    func didRender(pending: [Pending], bodies: [String: NSRange], messages: [RavenMessage], following: Bool, previousOrigin: NSPoint) {
        guard let session = owner.session, let channel = owner.channel else { return }
        self.pending = pending
        self.bodies = bodies
        messageForOperation = [:]
        for message in messages { if let batch = message.batchID, let id = UUID(uuidString: batch) { messageForOperation[id] = message.id } }
        let sameConversation = renderedChannel == channel.id

        let wet = Ink.color(blend: Ink.wetBlend, in: transcript)
        for entry in pending {
            if flying.contains(entry.operation.id) { setGlyphs(shown: false, in: entry.body) }
            else { transcript.layoutManager?.addTemporaryAttribute(.foregroundColor, value: wet, forCharacterRange: entry.body) }
        }
        // Acknowledged while its words were still in the air.
        for id in flying { if let message = messageForOperation[id], let body = bodies[message] { setGlyphs(shown: false, in: body) } }

        // A render replaced the text under sweeps still running: hide it
        // again and keep each sweep on its message.
        for (id, view) in sweeps {
            guard sameConversation, let body = bodies[id], let (rect, _) = frame(of: body) else { view.removeFromSuperview(); sweeps[id] = nil; continue }
            setGlyphs(shown: false, in: body)
            let origin = transcript.textContainerOrigin
            view.setFrameOrigin(rect.offsetBy(dx: origin.x, dy: origin.y).origin)
        }
        if sameConversation {
            // A send that arrives without a flight (too long to lift, or
            // sent from another window) still gets its landing.
            for entry in pending where !wetOperations.contains(entry.operation.id) && !flying.contains(entry.operation.id) && flight == nil { glint(over: entry.body) }
            var dried = Set<String>()
            for id in wetOperations.subtracting(flying) {
                guard let message = messageForOperation[id], bodies[message] != nil else { continue }
                dried.insert(message)
                dry(message, from: Ink.wetBlend, fresh: false)
                InkSounds.play(.dry)
                owner.composer.undoManager?.removeAllActions(withTarget: self)
            }
            // Only a tail that grew while being watched counts as arriving.
            if following, !renderedMessages.isEmpty {
                let arrivals = messages.reversed().prefix { !renderedMessages.contains($0.id) }.prefix(4)
                for message in arrivals where message.owner != session.account.user && !dried.contains(message.id) && message.messageType != "System" {
                    dry(message.id, from: Ink.freshBlend, fresh: true)
                }
            }
        } else {
            for view in transcript.subviews where view is InkEffectView { view.removeFromSuperview() }
            sweeps.removeAll()
        }
        wetOperations = Set(pending.map(\.operation.id))
        renderedMessages = Set(messages.map(\.id))
        renderedChannel = channel.id
        layoutBlots()

        // Only the send this window's flight lifted: another window's send
        // to the same conversation must not be flown to.
        if let flight, !flight.launched, flight.channelID == channel.id, let id = flight.operationID,
           let target = pending.first(where: { $0.operation.id == id }) {
            launch(flight, to: target, slideFrom: previousOrigin)
        }
    }

    /// The window moved to another conversation or account.
    func reset() {
        abandonFlight()
        flying.removeAll(); pending = []; bodies = [:]; wetOperations = []; renderedMessages = []; renderedChannel = nil
        for blot in blots.values { blot.removeFromSuperview() }
        blots.removeAll()
        for view in transcript.subviews where view is InkEffectView { view.removeFromSuperview() }
        sweeps.removeAll()
        airspace.sublayers?.forEach { $0.removeFromSuperlayer() }
        clearAirspace()
    }

    // MARK: Hiding text in flight

    /// Words in the air must not also show where they will land. Marking
    /// glyphs "not shown" hides them, emoji included, without changing
    /// layout; a transparent color would leave color glyphs visible.
    private func setGlyphs(shown: Bool, in range: NSRange) {
        guard let layout = transcript.layoutManager, let storage = transcript.textStorage, NSMaxRange(range) <= storage.length else { return }
        let text = (storage.string as NSString).substring(with: range)
        for word in InkFlightPlan.wordRanges(in: text) {
            let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: range.location + word.location, length: word.length), actualCharacterRange: nil)
            for glyph in glyphs.location..<NSMaxRange(glyphs) { layout.setNotShownAttribute(!shown, forGlyphAt: glyph) }
        }
        layout.invalidateDisplay(forCharacterRange: range)
    }

    /// Where a send's text is now: still pending, or already a message.
    private func currentBody(of id: UUID) -> (range: NSRange, acknowledged: Bool)? {
        if let entry = pending.first(where: { $0.operation.id == id }) { return (entry.body, false) }
        if let message = messageForOperation[id], let body = bodies[message] { return (body, true) }
        return nil
    }

    private func reveal(_ id: UUID) {
        guard let (range, acknowledged) = currentBody(of: id) else { return }
        setGlyphs(shown: true, in: range)
        if !acknowledged { transcript.layoutManager?.addTemporaryAttribute(.foregroundColor, value: Ink.color(blend: Ink.wetBlend, in: transcript), forCharacterRange: range) }
    }

    // MARK: Flight

    private func launch(_ flight: Flight, to target: Pending, slideFrom previousOrigin: NSPoint) {
        flight.launched = true
        flight.expiry?.cancel()
        let id = target.operation.id
        // Recorded on the flight, so abandoning it reveals this text again.
        flight.operationID = id
        flying.insert(id)
        // The draft was emptied when the send was accepted.
        owner.composer.alphaValue = 1
        guard let layout = transcript.layoutManager, let storage = transcript.textStorage, NSMaxRange(target.body) <= storage.length, target.body.length > 0 else { abandonFlight(); return }
        // Cut the destination in wet ink, then hide it until the words land.
        setGlyphs(shown: true, in: target.body)
        layout.addTemporaryAttribute(.foregroundColor, value: Ink.color(blend: Ink.wetBlend, in: transcript), forCharacterRange: target.body)
        let text = (storage.string as NSString).substring(with: target.body)
        let plan = InkFlightPlan.plan(source: flight.text, destination: text)
        let destinationWords = InkFlightPlan.wordRanges(in: text).map { NSRange(location: target.body.location + $0.location, length: $0.length) }
        let destination = capture(transcript, words: destinationWords, region: target.body)
        setGlyphs(shown: false, in: target.body)
        launchOrigin = owner.transcriptScroll.contentView.bounds.origin.y
        // The airspace starts the slide this far down; words start that
        // much higher in it, which is where they are on screen now.
        let slide = slideTranscript(from: previousOrigin)

        let count = flight.layers.count
        var landing: CFTimeInterval = 0
        if case .words = plan, let destination, destination.frames.count == count {
            for (index, layer) in flight.layers.enumerated() {
                let duration = travel(layer, from: flight.capture.frames[index].offsetBy(dx: 0, dy: slide), to: destination.frames[index], arriving: face(destination.image, unit: destination.units[index], in: layer.bounds), index: index, delay: stagger(index, of: count))
                landing = max(landing, stagger(index, of: count) + duration)
            }
        } else {
            // Different words (lists, mentions, code): the message moves as
            // one block to where its text begins, and the text takes over.
            let from = flight.capture.bounds
            let to = destination?.bounds ?? transcript.convert(owner.rect(for: target.body), to: overlay)
            let delta = CGPoint(x: to.minX - from.minX, y: to.maxY - from.maxY)
            for (index, layer) in flight.layers.enumerated() {
                let start = flight.capture.frames[index]
                let duration = travel(layer, from: start.offsetBy(dx: 0, dy: slide), to: start.offsetBy(dx: delta.x, dy: delta.y), arriving: nil, index: index, delay: 0)
                landing = max(landing, duration * 0.8)
            }
        }
        // Land a little before the springs are fully at rest; the last
        // fraction of a point is not worth a visible wait.
        after(landing * 0.92) { [weak self] in self?.land(flight, id: id, image: destination?.image, region: target.body) }
    }

    /// Moves one word along its flight. Returns the flight's duration.
    private func travel(_ layer: CALayer, from: CGRect, to: CGRect, arriving: CALayer?, index: Int, delay: CFTimeInterval) -> CFTimeInterval {
        let horizontal = CABasicAnimation(keyPath: "position.x")
        horizontal.fromValue = from.midX; horizontal.toValue = to.midX
        horizontal.duration = 0.34
        horizontal.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
        let vertical = CASpringAnimation(keyPath: "position.y")
        vertical.fromValue = from.midY + Ink.liftHeight; vertical.toValue = to.midY
        vertical.stiffness = Ink.flightStiffness; vertical.damping = Ink.flightDamping
        let duration = min(vertical.settlingDuration, 0.6)
        vertical.duration = duration
        let width = CABasicAnimation(keyPath: "transform.scale.x")
        width.fromValue = from.width / max(to.width, 1); width.toValue = 1; width.duration = 0.3
        let height = CABasicAnimation(keyPath: "transform.scale.y")
        height.fromValue = from.height / max(to.height, 1); height.toValue = 1; height.duration = 0.3
        let flutter = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        let angle = Ink.flutterDegrees * .pi / 180 * (index.isMultiple(of: 2) ? 1 : -1)
        flutter.values = [0, angle, -angle * 0.3, 0]; flutter.keyTimes = [0, 0.3, 0.7, 1]; flutter.duration = duration
        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0.22; shadow.toValue = 0; shadow.duration = duration
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.setValue(0, forKeyPath: "transform.translation.y")
        layer.frame = to
        layer.shadowOpacity = 0
        if let arriving {
            // The same word as the transcript will draw it, fading in over
            // the word as it was typed: fonts and colors change in the air.
            arriving.frame = layer.bounds
            layer.addSublayer(arriving)
            if let leaving = layer.sublayers?.first, leaving !== arriving {
                let out = CABasicAnimation(keyPath: "opacity"); out.fromValue = 1; out.toValue = 0; out.duration = duration * 0.5
                leaving.opacity = 0; add(out, to: leaving, delay: delay)
            }
            let `in` = CABasicAnimation(keyPath: "opacity"); `in`.fromValue = 0; `in`.toValue = 1; `in`.duration = duration * 0.5
            add(`in`, to: arriving, delay: delay)
        } else {
            let out = CABasicAnimation(keyPath: "opacity"); out.fromValue = 1; out.toValue = 0; out.duration = duration * 0.8
            layer.opacity = 0; add(out, to: layer, delay: delay)
        }
        CATransaction.commit()
        for animation in [horizontal, vertical, width, height, flutter, shadow] as [CAAnimation] { add(animation, to: layer, delay: delay) }
        return duration
    }

    /// A new message pushes the transcript up by its height. Slide that
    /// distance instead of jumping, on the layer only: the scroll position
    /// itself is already final, so reading state never sees a mid-way
    /// offset. The words in the air ride the same slide, so they close in
    /// on their slot as the transcript sees it and never cross the older
    /// messages moving out of the way. Returns the distance slid.
    private func slideTranscript(from previousOrigin: NSPoint) -> CGFloat {
        let distance = owner.transcriptScroll.contentView.bounds.origin.y - previousOrigin.y
        guard distance > 0.5, distance < 2000, let layer = transcript.layer else { return 0 }
        func slide(from offset: CGFloat) -> CASpringAnimation {
            let slide = CASpringAnimation(keyPath: "transform.translation.y")
            slide.fromValue = offset; slide.toValue = 0
            slide.stiffness = 340; slide.damping = 32; slide.duration = min(slide.settlingDuration, 0.5)
            slide.speed = Float(1 / Ink.timeScale)
            return slide
        }
        // The transcript is a flipped view: its layer's y axis points
        // down, so a positive offset is where the text was a moment ago.
        // The overlay is unflipped, so the same place is a negative one.
        layer.add(slide(from: distance), forKey: "inkSlide")
        airspace.add(slide(from: -distance), forKey: "inkSlide")
        return distance
    }

    private func land(_ flight: Flight, id: UUID, image: CGImage?, region: NSRange) {
        guard flying.remove(id) != nil else { return }
        reveal(id)
        // The real text is on screen first; the layers leave a turn later,
        // so there is never a frame with neither.
        let layers = flight.layers
        Task { @MainActor [weak self] in
            for layer in layers { layer.removeFromSuperlayer() }
            if self?.flight == nil { self?.clearAirspace() }
        }
        if self.flight === flight { self.flight = nil }
        InkSounds.play(.land)
        layoutBlots()
        guard let (range, acknowledged) = currentBody(of: id) else { return }
        if acknowledged, let message = messageForOperation[id] {
            // A fast server answered mid-flight: land wet, then dry.
            dry(message, from: Ink.wetBlend, fresh: false)
            InkSounds.play(.dry)
            owner.composer.undoManager?.removeAllActions(withTarget: self)
        } else if let image, range == region {
            glint(over: range, image: image)
        }
    }

    // MARK: Glint and drying

    private func frame(of range: NSRange) -> (rect: NSRect, glyphs: NSRange)? {
        guard let layout = transcript.layoutManager, let container = transcript.textContainer, let storage = transcript.textStorage,
              range.length > 0, NSMaxRange(range) <= storage.length else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).insetBy(dx: -3, dy: 0)
        return rect.width > 0 && rect.height > 0 ? (rect, glyphs) : nil
    }

    /// One highlight across the letterforms of a message that just landed.
    private func glint(over range: NSRange, image supplied: CGImage? = nil) {
        guard !Ink.reducesMotion, let (rect, glyphs) = frame(of: range), let layout = transcript.layoutManager,
              let image = supplied ?? Ink.snapshot(layout, glyphs: glyphs, rect: rect, scale: scale) else { return }
        let origin = transcript.textContainerOrigin
        let view = InkEffectView(frame: rect.offsetBy(dx: origin.x, dy: origin.y))
        transcript.addSubview(view)
        let shine = CALayer(); shine.frame = view.bounds
        let letters = CALayer(); letters.frame = view.bounds; letters.contents = image; letters.contentsGravity = .resize
        shine.mask = letters
        let band = CAGradientLayer()
        // On a dark transcript the ink is light and a strong highlight
        // reads as a glint. On a light one the same white would erase the
        // letters for a moment, so it stays translucent.
        let peak = NSColor.white.withAlphaComponent(Ink.isLight(Ink.color(blend: Ink.wetBlend, in: transcript)) ? 0.85 : 0.5).cgColor
        band.colors = [NSColor.white.withAlphaComponent(0).cgColor, peak, NSColor.white.withAlphaComponent(0).cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5); band.endPoint = CGPoint(x: 1, y: 0.5)
        band.bounds = CGRect(x: 0, y: 0, width: Ink.glintWidth, height: view.bounds.height * 3 + 40)
        band.position = CGPoint(x: view.bounds.width + Ink.glintWidth, y: view.bounds.midY)
        band.transform = CATransform3DMakeRotation(-0.35, 0, 0, 1)
        shine.addSublayer(band)
        view.layer?.addSublayer(shine)
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -Ink.glintWidth; sweep.toValue = view.bounds.width + Ink.glintWidth
        // Moving from the first frame: the glint belongs to the landing,
        // and it must not linger at the end of the line while the ink dries.
        sweep.duration = Ink.glintDuration * max(1, min(1.2, Double(view.bounds.width) / 520))
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.5, 0.6, 1)
        add(sweep, to: band)
        after(sweep.duration + 0.05) { [weak view] in view?.removeFromSuperview() }
    }

    /// Dries a message: its text goes from wet to its final color in a
    /// soft-edged sweep per line, in the order the lines were written.
    ///
    /// The real glyphs are hidden for the sweep and two copies stand in,
    /// one wet and one dry, masked by complementary gradients. Each pixel
    /// then holds exactly one layer of ink; drawing a wet copy over the dry
    /// text would thicken every letter.
    private func dry(_ messageID: String, from blend: CGFloat, fresh: Bool) {
        guard !Ink.reducesMotion, owner.window?.isVisible == true, let layout = transcript.layoutManager, let range = bodies[messageID] else { return }
        finishSweep(messageID)
        setGlyphs(shown: true, in: range)
        guard let (rect, glyphs) = frame(of: range) else { return }
        let origin = transcript.textContainerOrigin
        // Only what is on screen needs to be seen drying.
        guard transcript.visibleRect.insetBy(dx: 0, dy: -200).intersects(rect.offsetBy(dx: origin.x, dy: origin.y)) else { return }
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        let dryImage = Ink.snapshot(layout, glyphs: glyphs, rect: rect, scale: scale)
        layout.addTemporaryAttribute(.foregroundColor, value: Ink.color(blend: blend, in: transcript), forCharacterRange: range)
        let wetImage = Ink.snapshot(layout, glyphs: glyphs, rect: rect, scale: scale)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        guard let dryImage, let wetImage else { return }
        setGlyphs(shown: false, in: range)
        let view = InkEffectView(frame: rect.offsetBy(dx: origin.x, dy: origin.y))
        transcript.addSubview(view)
        sweeps[messageID] = view

        var lines: [NSRect] = []
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in lines.append(fragment) }
        let width = rect.width, edge = Ink.dryEdge, total = width * 2 + edge
        let perLine = fresh ? Ink.freshDryDuration : Ink.dryDurationPerLine * max(0.6, min(1.6, Double(width) / 480))
        let step = fresh ? 0.03 : Ink.dryLineStagger
        let clear = NSColor.black.withAlphaComponent(0).cgColor, solid = NSColor.black.cgColor
        for (image, colors) in [(dryImage, [solid, solid, clear, clear]), (wetImage, [clear, clear, solid, solid])] {
            let copy = CALayer(); copy.frame = view.bounds; copy.contents = image; copy.contentsGravity = .resize
            let mask = CALayer(); mask.frame = view.bounds
            for (index, line) in lines.enumerated() {
                let band = CAGradientLayer()
                band.startPoint = CGPoint(x: 0, y: 0.5); band.endPoint = CGPoint(x: 1, y: 0.5)
                band.colors = colors
                band.locations = [0, NSNumber(value: Double(width / total)), NSNumber(value: Double((width + edge) / total)), 1]
                // The effect view is unflipped; line rectangles count from the top.
                band.frame = CGRect(x: 0, y: view.bounds.height - (line.maxY - rect.minY), width: total, height: line.height)
                mask.addSublayer(band)
                // The band's soft edge starts left of the line and ends
                // right of it: dry grows from the left.
                let sweep = CABasicAnimation(keyPath: "position.x")
                sweep.fromValue = total / 2 - (width + edge); sweep.toValue = total / 2
                sweep.duration = perLine
                sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                add(sweep, to: band, delay: Double(index) * step)
            }
            copy.mask = mask
            view.layer?.addSublayer(copy)
        }
        after(perLine + Double(lines.count - 1) * step) { [weak self, weak view] in
            guard let self, let view, self.sweeps[messageID] === view else { return }
            self.finishSweep(messageID)
        }
    }

    /// Puts the real text back under a sweep and removes the sweep a turn
    /// later, so no frame shows neither.
    private func finishSweep(_ messageID: String) {
        guard let view = sweeps.removeValue(forKey: messageID) else { return }
        if let range = bodies[messageID] { setGlyphs(shown: true, in: range) }
        Task { @MainActor in view.removeFromSuperview() }
    }

    // MARK: Blots

    /// Puts a drop after the last word of every pending message. Called
    /// after renders and whenever the pane's layout changes.
    func layoutBlots() {
        guard let layout = transcript.layoutManager, let container = transcript.textContainer, let storage = transcript.textStorage else { return }
        var live = Set<UUID>()
        let color = Ink.color(blend: Ink.wetBlend, in: transcript)
        for entry in pending where !flying.contains(entry.operation.id) {
            guard let wetness = InkWetness(entry.operation.state), entry.body.length > 0, NSMaxRange(entry.body) <= storage.length else { continue }
            let id = entry.operation.id
            live.insert(id)
            let blot = blots[id] ?? {
                let blot = InkBlot(operationID: id)
                blot.onClick = { [weak self] blot in self?.showMenu(for: blot) }
                transcript.addSubview(blot); blots[id] = blot
                return blot
            }()
            let last = layout.glyphRange(forCharacterRange: NSRange(location: NSMaxRange(entry.body) - 1, length: 1), actualCharacterRange: nil)
            let glyph = layout.boundingRect(forGlyphRange: last, in: container)
            let origin = transcript.textContainerOrigin
            let x = min(glyph.maxX + origin.x + 4, transcript.bounds.width - transcript.readingColumnInset - InkBlot.size.width + 14)
            blot.frame = NSRect(x: x, y: glyph.midY + origin.y - InkBlot.size.height / 2, width: InkBlot.size.width, height: InkBlot.size.height)
            blot.update(wetness: wetness, label: entry.operation.state.localizedLabel(), canTakeBack: InkRules.canTakeBack(entry.operation), color: color, alert: .themeAlert)
        }
        for (id, blot) in blots where !live.contains(id) { blot.removeFromSuperview(); blots[id] = nil }
    }

    private func showMenu(for blot: InkBlot) {
        guard let entry = pending.first(where: { $0.operation.id == blot.operationID }) else { return }
        let menu = NSMenu()
        let state = menu.addItem(withTitle: "Not sent yet · \(entry.operation.state.localizedLabel())", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(.separator())
        let back = menu.addItem(withTitle: "Take Back", action: #selector(takeBackFromMenu(_:)), keyEquivalent: "")
        back.target = self; back.representedObject = entry.operation.id
        if !InkRules.canTakeBack(entry.operation) { back.action = nil }
        menu.addItem(withTitle: "Show Outbox", action: #selector(ConversationWindow.outbox), keyEquivalent: "").target = owner
        menu.autoenablesItems = false
        for item in menu.items where item.action == nil && item !== state { item.isEnabled = false }
        // Below the drop (the blot view is unflipped), so the message stays readable.
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: blot)
    }

    @objc private func takeBackFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        takeBack(id)
    }

    // MARK: Take back

    /// Returns a queued message to the composer: the reverse of a send.
    /// A GIF is only cancelled.
    func takeBack(_ id: UUID) {
        guard let session = owner.session, let operation = pending.first(where: { $0.operation.id == id })?.operation else { return }
        takeBack(id, in: session, channelID: operation.channelID)
    }

    private func takeBack(_ id: UUID, in session: AccountSession, channelID: String) {
        // The undo entry belongs to its original account and conversation,
        // not whichever draft its originating window happens to show now.
        let window = owner
        let showing = window.isCurrent(session, channelID: channelID)
        func report(_ message: String) {
            let target = window.isCurrent(session, channelID: channelID) ? window : window.app.windows.first { $0.isCurrent(session, channelID: channelID) }
            if let target { target.status.stringValue = message }
            else { session.fail(AppError.message(message)) }
            NSSound.beep()
        }
        // A GIF never was the draft, so whatever the composer holds stays
        // and nothing flies into it.
        if pending.first(where: { $0.operation.id == id })?.operation.isGIF == true {
            Task { @MainActor in
                do {
                    guard try await session.takeBackGIF(id: id) != nil else { report("That message has already left."); return }
                    InkSounds.play(.takeBack)
                } catch { report(error.localizedDescription) }
            }
            return
        }
        let composing = window.app.windows.contains { $0.isCurrent(session, channelID: channelID) && $0.composer.hasMarkedText() }
        if composing || (showing && (!window.composer.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !window.attachments.isEmpty || window.replyTo != nil || window.editing != nil || window.isAcceptingSend)) {
            report("Send or clear this draft before taking a message back.")
            return
        }
        if showing, flight?.operationID == id { abandonFlight() }
        var leaving: (capture: Capture, text: String)?
        if showing, !Ink.reducesMotion, let entry = pending.first(where: { $0.operation.id == id }), let storage = transcript.textStorage, NSMaxRange(entry.body) <= storage.length {
            let text = (storage.string as NSString).substring(with: entry.body)
            let words = InkFlightPlan.wordRanges(in: text).map { NSRange(location: entry.body.location + $0.location, length: $0.length) }
            if words.count <= InkFlightPlan.wordLimit, let capture = capture(transcript, words: words, region: entry.body) { leaving = (capture, text) }
        }
        Task { @MainActor [self] in
            do {
                guard try await session.takeBack(id: id, channelID: channelID) != nil else {
                    report("That message has already left.")
                    return
                }
                session.draftUndoManagers[channelID]?.removeAllActions(withTarget: self)
                guard window.isCurrent(session, channelID: channelID) else { return }
                InkSounds.play(.takeBack)
                guard let leaving else { return }
                let layers = makeLayers(leaving.capture)
                if !layers.isEmpty { window.composer.alphaValue = 0 }
                await fall(layers, leaving: leaving.capture, text: leaving.text, session: session, channelID: channelID)
            } catch { report(error.localizedDescription) }
        }
    }

    /// Flies words taken off the transcript down to where the restored
    /// draft lays them out in the composer.
    private func fall(_ layers: [CALayer], leaving: Capture, text: String, session: AccountSession, channelID: String) async {
        let composer = owner.composer
        defer { composer.alphaValue = 1; for layer in layers { layer.removeFromSuperlayer() } }
        // The draft returns through the shared draft store; wait for it.
        var waited = 0
        while composer.string.isEmpty, waited < 40, owner.isCurrent(session, channelID: channelID) { try? await Task.sleep(for: .milliseconds(15)); waited += 1 }
        guard owner.isCurrent(session, channelID: channelID) else { return }
        let restored = composer.string
        let words = InkFlightPlan.wordRanges(in: restored)
        composer.layoutManager.map { layout in composer.textContainer.map { layout.ensureLayout(for: $0) } }
        owner.contentController?.view.layoutSubtreeIfNeeded()
        guard case .words = InkFlightPlan.plan(source: text, destination: restored), words.count == layers.count,
              let arriving = capture(composer, words: words, region: NSRange(location: 0, length: (restored as NSString).length)) else {
            for layer in layers { layer.removeFromSuperlayer() }
            return
        }
        var landing: CFTimeInterval = 0
        for (index, layer) in layers.enumerated() {
            let delay = stagger(index, of: layers.count)
            // Start level: `travel` assumes a lifted word.
            let start = leaving.frames[index].offsetBy(dx: 0, dy: -Ink.liftHeight)
            landing = max(landing, delay + travel(layer, from: start, to: arriving.frames[index], arriving: face(arriving.image, unit: arriving.units[index], in: layer.bounds), index: index, delay: delay))
        }
        try? await Task.sleep(for: .seconds(landing * 0.92 * Ink.timeScale))
        guard owner.isCurrent(session, channelID: channelID) else { return }
        composer.alphaValue = 1
        owner.window?.makeFirstResponder(composer)
        composer.setSelectedRange(NSRange(location: (composer.string as NSString).length, length: 0))
        await Task.yield()
        for layer in layers { layer.removeFromSuperlayer() }
    }
}
