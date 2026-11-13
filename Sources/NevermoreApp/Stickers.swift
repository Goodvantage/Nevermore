import AppKit
import NevermoreCore
import RavenProtocol

/// Sizes and timings of reactions handled as stickers.
@MainActor enum Stickers {
    /// The quick reaction row draws its emoji at this size; a sticker in
    /// the hand is that glyph, enlarged.
    static let pointSize: CGFloat = 21
    static let liftScale: CGFloat = 1.6
    static let shadowDrop: CGFloat = 6
    static let shadowOpacity: Float = 0.32
    /// Vertical scale at the moment of landing.
    static let squash: CGFloat = 0.82
    static let landDuration: CFTimeInterval = 0.18
    static let tossDuration: CFTimeInterval = 0.22
    static let tossRise: CGFloat = 44
    static let flingDuration: CFTimeInterval = 0.42
    static let dropInDuration: CFTimeInterval = 0.26
    static let rollDuration: CFTimeInterval = 0.18
    static let fallDuration: CFTimeInterval = 0.5
    /// A landed sticker waits this long for its reaction to show before
    /// it lets go.
    static let patience: TimeInterval = 8

    static let isStaged = ProcessInfo.processInfo.arguments.contains("--self-check") || ProcessInfo.processInfo.arguments.contains("--performance-check")
    static var animates: Bool { !Ink.reducesMotion && !isStaged }
}

/// Makes reactions objects with weight.
///
/// An emoji pressed in the quick reaction row can be carried to any
/// message, where a slot opens for it, or thrown, in which case it sticks
/// to the message it comes to rest on. A click still reacts at once; the
/// emoji then travels from the row to its chip. Chips can be clicked to
/// add or remove the reader's reaction, and the reader's own can be
/// dragged off. Reactions that arrive while the conversation is open drop
/// in from the top of the pane, and changed counts roll.
///
/// Everything here is presentation. The reaction itself is one toggle sent
/// through `ConversationWindow.toggleReaction`, and the transcript shows
/// what the server answered. A sticker that lands before the answer waits
/// on its message and falls off if the reaction never appears.
@MainActor final class StickerController: NSObject {
    unowned let owner: ConversationWindow
    /// Covers the conversation pane, above the composer glass.
    let overlay = InkOverlayView()

    /// One reaction chip as laid out in the transcript.
    struct Chip {
        let message: RavenMessage
        let label: String
        let count: Int
        let mine: Bool
        /// The pill, in transcript coordinates.
        let rect: NSRect
        /// Center of the emoji inside the pill.
        let emojiCenter: NSPoint
        let labelRange: NSRange
        let countRange: NSRange
    }

    @MainActor private final class Sticker {
        let emoji: String
        let layer = CALayer()
        /// While carried: the hand's smoothed velocity and the lean it causes.
        var velocity = CGVector.zero
        var lean: CGFloat = 0
        /// Set once the sticker is on a message, in transcript coordinates,
        /// so it follows scrolling.
        var anchor: NSPoint?
        var messageID: String?
        var deadline: DispatchWorkItem?
        init(emoji: String) { self.emoji = emoji }
    }

    private var stuck: [Sticker] = []
    private var slot: CAShapeLayer?
    private var wash: CALayer?
    /// Continues the highlighted message under a new chip's place, so the
    /// place does not sit half over the next message's header.
    private var drawer: CALayer?
    /// The target the slot is showing, kept to follow scrolling.
    private var shown: Target?
    /// Reactions of the rendered messages, to see what changed.
    private var known: [String: [ReactionChip]] = [:]
    private var knownChannel: String?
    private var chipCache: [Chip]?
    private var rolls: [CALayer] = []
    private var hidden: [NSRange] = []
    private let undoManagers = NSHashTable<UndoManager>.weakObjects()
    private var images: [String: CGImage] = [:]

    init(owner: ConversationWindow) {
        self.owner = owner
        super.init()
    }

    private var transcript: TranscriptView { owner.transcript }
    private var scale: CGFloat { owner.window?.backingScaleFactor ?? 2 }
    private var landedScale: CGFloat { transcript.metrics.chipFont.pointSize / Stickers.pointSize }

    // MARK: Chips

    /// The chips on screen, laid out as the transcript draws them.
    private func visibleChips() -> [Chip] {
        if let chipCache { return chipCache }
        var result: [Chip] = []
        defer { chipCache = result }
        guard let storage = transcript.textStorage, storage.length > 0, let layout = transcript.layoutManager, let container = transcript.textContainer else { return result }
        let origin = transcript.textContainerOrigin
        let glyphs = layout.glyphRange(forBoundingRectWithoutAdditionalLayout: transcript.visibleRect.offsetBy(dx: -origin.x, dy: -origin.y), in: container)
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let text = storage.string as NSString
        let whole = NSRange(location: 0, length: storage.length)
        var seen = Set<Int>()
        storage.enumerateAttribute(.nevermoreReactionChip, in: characters) { value, range, _ in
            guard value is Bool else { return }
            // The visible range can cut a chip in two; take all of it.
            var full = NSRange()
            guard let mine = storage.attribute(.nevermoreReactionChip, at: range.location, longestEffectiveRange: &full, in: whole) as? Bool, seen.insert(full.location).inserted else { return }
            let string = text.substring(with: full)
            guard let space = string.lastIndex(of: " "), let count = Int(string[string.index(after: space)...]) else { return }
            let label = String(string[..<space])
            guard let rect = transcript.chipRects(for: full).first, let message = owner.messageRanges.first(where: { NSLocationInRange(full.location, $0.0) })?.1 else { return }
            let labelRange = NSRange(location: full.location, length: (label as NSString).length)
            let countRange = NSRange(location: NSMaxRange(labelRange) + 1, length: full.length - labelRange.length - 1)
            let emoji = layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: labelRange, actualCharacterRange: nil), in: container)
            result.append(Chip(message: message, label: label, count: count, mine: mine, rect: rect, emojiCenter: NSPoint(x: emoji.midX + origin.x, y: rect.midY), labelRange: labelRange, countRange: countRange))
        }
        return result
    }

    private func chip(_ label: String, on messageID: String) -> Chip? {
        visibleChips().first { $0.message.id == messageID && $0.label == label }
    }

    /// True when the pointer is over a chip that a click would toggle.
    func isOverChip(_ point: NSPoint) -> Bool {
        guard let session = owner.session, let chip = visibleChips().first(where: { $0.rect.contains(point) }) else { return false }
        return QuickReactions.isUnicodeReaction(chip.label) && owner.canReact(in: chip.message.channelID, session: session)
    }

    private func invalidateChips() { chipCache = nil }

    // MARK: Sticker layers

    private func image(for emoji: String) -> CGImage? {
        if let cached = images[emoji] { return cached }
        let ratio: CGFloat = 4
        let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: Stickers.pointSize * ratio)])
        let size = text.size()
        let width = Int(size.width.rounded(.up)), height = Int(size.height.rounded(.up))
        guard width > 0, height > 0, width <= 1024, height <= 1024, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        text.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        if images.count < 64 { images[emoji] = image }
        return image
    }

    /// A sticker at `point` (overlay coordinates), drawn at `scale` times
    /// the quick row's emoji size.
    private func makeSticker(_ emoji: String, at point: NSPoint, scale: CGFloat) -> Sticker? {
        guard let image = image(for: emoji), let host = overlay.layer else { return nil }
        let sticker = Sticker(emoji: emoji)
        let layer = sticker.layer
        layer.contents = image
        layer.bounds = CGRect(x: 0, y: 0, width: CGFloat(image.width) / 4, height: CGFloat(image.height) / 4)
        layer.position = point
        layer.setAffineTransform(CGAffineTransform(scaleX: scale, y: scale))
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowRadius = 5
        layer.shadowOpacity = 0
        // The overlay is unflipped: a negative height is below.
        layer.shadowOffset = CGSize(width: 0, height: -Stickers.shadowDrop)
        layer.actions = ["position": NSNull(), "transform": NSNull(), "shadowOpacity": NSNull(), "opacity": NSNull(), "bounds": NSNull(), "contents": NSNull()]
        host.addSublayer(layer)
        return sticker
    }

    private func overlayPoint(_ point: NSPoint) -> NSPoint { overlay.convert(point, from: transcript) }

    private func remove(_ sticker: Sticker) {
        sticker.deadline?.cancel()
        sticker.layer.removeFromSuperlayer()
        stuck.removeAll { $0 === sticker }
    }

    /// The sticker lets go and drops out of the window.
    private func fall(_ sticker: Sticker) {
        sticker.deadline?.cancel()
        stuck.removeAll { $0 === sticker }
        if let id = sticker.messageID, shown?.message.id == id { show(nil) }
        guard Stickers.animates else { sticker.layer.removeFromSuperlayer(); return }
        let layer = sticker.layer
        let from = layer.presentation()?.position ?? layer.position
        let spin: CGFloat = from.x.truncatingRemainder(dividingBy: 2) < 1 ? 0.7 : -0.7
        CATransaction.begin()
        CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
        let drop = CABasicAnimation(keyPath: "position.y")
        drop.fromValue = from.y; drop.toValue = -layer.bounds.height * 2
        drop.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 1, 0.6)
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.byValue = spin
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1; fade.toValue = 0.2
        for animation in [drop, turn, fade] {
            animation.duration = Stickers.fallDuration * Ink.timeScale
            animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
            layer.add(animation, forKey: nil)
        }
        CATransaction.commit()
    }

    // MARK: Targets

    private struct Target {
        let message: RavenMessage
        /// Where the emoji will sit, in transcript coordinates.
        let center: NSPoint
        /// The pill to show: an existing chip, or the place for a new one.
        let pill: NSRect
        let existing: Bool
    }

    /// Where `emoji` would land on the message under `point` (transcript
    /// coordinates). Nil when there is no message there, the conversation
    /// cannot take a reaction, or the reader already gave that one.
    private func target(for emoji: String, at point: NSPoint) -> Target? {
        guard let session = owner.session, owner.readableTranscriptRect.insetBy(dx: 0, dy: -8).contains(NSPoint(x: owner.readableTranscriptRect.midX, y: point.y)),
              let entry = owner.messageRange(at: point), owner.canReact(in: entry.1.channelID, session: session) else { return nil }
        return target(for: emoji, on: entry.1, range: entry.0)
    }

    private func target(for emoji: String, on message: RavenMessage, range: NSRange? = nil) -> Target? {
        guard let session = owner.session, !QuickReactions.reacted(by: session.account.user, in: message.raw["message_reactions"]).contains(emoji),
              let range = range ?? owner.messageRanges.first(where: { $0.1.id == message.id })?.0 else { return nil }
        let chips = visibleChips().filter { $0.message.id == message.id }
        if let same = chips.first(where: { $0.label == emoji }) { return Target(message: message, center: same.emojiCenter, pill: same.rect, existing: true) }
        let metrics = transcript.metrics
        let font = metrics.chipFont
        let width = NSAttributedString(string: "\(emoji) 1", attributes: [.font: font]).size().width + metrics.chipPadding * 2
        let height = font.ascender - font.descender + metrics.chipVerticalPadding * 2
        var pill: NSRect
        if let last = chips.max(by: { ($0.rect.minY, $0.rect.minX) < ($1.rect.minY, $1.rect.minX) }) {
            // After the last chip, at the spacing chips have.
            pill = NSRect(x: last.rect.maxX + metrics.chipPadding * 1.6 + 6, y: last.rect.minY, width: width, height: height)
        } else {
            // Where the first chip of a new row will appear: under the body.
            let body = owner.highlightRect(for: range)
            pill = NSRect(x: transcript.textContainerOrigin.x + (transcript.textContainer?.lineFragmentPadding ?? 5), y: body.maxY - 1, width: width, height: height)
        }
        pill.origin.x = min(pill.origin.x, transcript.bounds.width - transcript.readingColumnInset - width)
        let emojiWidth = NSAttributedString(string: emoji, attributes: [.font: font]).size().width
        return Target(message: message, center: NSPoint(x: pill.minX + metrics.chipPadding + emojiWidth / 2, y: pill.midY), pill: pill, existing: false)
    }

    private func show(_ target: Target?) {
        guard let host = overlay.layer else { return }
        guard let target, let range = owner.messageRanges.first(where: { $0.1.id == target.message.id })?.0 else {
            for layer in [slot, wash, drawer] { layer?.removeFromSuperlayer() }
            slot = nil; wash = nil; drawer = nil; shown = nil
            return
        }
        let isNew = shown == nil
        let moved = shown.map { $0.message.id != target.message.id || $0.pill != target.pill } ?? true
        shown = target
        let pill = overlay.convert(target.pill, from: transcript)
        let body = overlay.convert(owner.highlightRect(for: range), from: transcript)
        var accent = NSColor.controlAccentColor
        var paper = NSColor.textBackgroundColor
        overlay.effectiveAppearance.performAsCurrentDrawingAppearance {
            accent = NSColor.themeAccent.usingColorSpace(.sRGB) ?? .controlAccentColor
            // The first stop of a themed transcript, or the plain background.
            let ground = ActiveThemePalette.current?.gradient.first.map { NSColor(theme: $0) } ?? .textBackgroundColor
            paper = ground.usingColorSpace(.sRGB) ?? .textBackgroundColor
        }
        let washAlpha: CGFloat = 0.07
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let wash = self.wash ?? {
            let layer = CALayer(); layer.cornerRadius = 8
            host.insertSublayer(layer, at: 0); self.wash = layer
            return layer
        }()
        wash.frame = body
        wash.backgroundColor = accent.withAlphaComponent(washAlpha).cgColor
        // A new chip's place is below the message, where the next one
        // starts. The message grows an opaque drawer to hold it; a real
        // chip row will push the next message down the same way.
        let needsDrawer = !target.existing && pill.minY < body.minY
        if needsDrawer {
            let drawer = self.drawer ?? {
                let layer = CALayer(); layer.cornerRadius = 8
                layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                host.insertSublayer(layer, above: wash); self.drawer = layer
                return layer
            }()
            let bottom = pill.minY - 6
            drawer.frame = CGRect(x: body.minX, y: bottom, width: body.width, height: body.minY - bottom)
            drawer.backgroundColor = (paper.blended(withFraction: washAlpha, of: accent) ?? paper).cgColor
            wash.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        } else {
            drawer?.removeFromSuperlayer(); drawer = nil
            wash.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        }
        let slot = self.slot ?? {
            let layer = CAShapeLayer(); layer.lineWidth = 1.5
            host.addSublayer(layer); self.slot = layer
            return layer
        }()
        slot.frame = pill
        slot.path = CGPath(roundedRect: CGRect(origin: .zero, size: pill.size), cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil)
        // A new chip's place is dashed and lightly filled; an existing
        // chip only gets a ring.
        slot.fillColor = target.existing ? nil : accent.withAlphaComponent(0.14).cgColor
        slot.strokeColor = accent.withAlphaComponent(0.8).cgColor
        slot.lineDashPattern = target.existing ? nil : [4, 3]
        CATransaction.commit()
        if (isNew || moved), Stickers.animates {
            // The slot opens: 120 ms from 60 percent.
            let open = CASpringAnimation(keyPath: "transform.scale")
            open.fromValue = 0.6; open.toValue = 1
            open.stiffness = 520; open.damping = 26
            open.duration = 0.2 * Ink.timeScale
            slot.add(open, forKey: "open")
        }
    }

    // MARK: Carrying

    /// The reader pressed an emoji in the quick reaction row and moved it.
    /// Tracks the mouse until release: over a message a slot opens, a fast
    /// release throws the sticker, Escape or a release over nothing drops
    /// it. `origin` is the pressed button, in screen coordinates.
    func carry(_ emoji: String, from origin: NSRect) {
        guard let window = owner.window, owner.emojiSelectionTask == nil else { NSSound.beep(); return }
        func location() -> NSPoint { overlay.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) }
        let start = overlay.convert(window.convertPoint(fromScreen: NSPoint(x: origin.midX, y: origin.midY)), from: nil)
        guard let sticker = makeSticker(emoji, at: start, scale: 1) else { return }
        lift(sticker)
        InkSounds.play(.lift)

        var last = (point: location(), time: ProcessInfo.processInfo.systemUptime)
        var current: Target?
        // The lean follows the hand and settles when the hand stops, also
        // between mouse events.
        let settle = Timer(timeInterval: 1 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                sticker.velocity.dx *= 0.86; sticker.velocity.dy *= 0.86
                sticker.lean += (StickerRules.tilt(horizontalVelocity: sticker.velocity.dx) - sticker.lean) * 0.25
                sticker.layer.setAffineTransform(CGAffineTransform(scaleX: Stickers.liftScale, y: Stickers.liftScale).rotated(by: sticker.lean))
            }
        }
        RunLoop.main.add(settle, forMode: .common)
        defer { settle.invalidate() }

        var released = false
        tracking: while true {
            let step = PressTracking.next()
            if step == .cancelled { break tracking }
            let point = location(), now = ProcessInfo.processInfo.systemUptime
            let elapsed = now - last.time
            if elapsed > 0.001 {
                let instant = CGVector(dx: (point.x - last.point.x) / elapsed, dy: (point.y - last.point.y) / elapsed)
                sticker.velocity = CGVector(dx: sticker.velocity.dx * 0.5 + instant.dx * 0.5, dy: sticker.velocity.dy * 0.5 + instant.dy * 0.5)
                last = (point, now)
            }
            // The sticker rides above the pointer, so the slot stays visible.
            sticker.layer.position = NSPoint(x: point.x, y: point.y + 12)
            current = target(for: emoji, at: transcript.convert(point, from: overlay))
            show(current)
            if step == .released {
                // A hand that stopped before letting go did not throw.
                if elapsed > 0.09 { sticker.velocity = .zero }
                released = true
                break tracking
            }
        }
        settle.invalidate()
        guard released else { show(nil); fall(sticker); return }
        if let rest = StickerRules.rest(from: sticker.layer.position, velocity: sticker.velocity) { fling(sticker, to: rest); return }
        // The slot stays open under the sticker until its chip is there.
        guard let current else { show(nil); fall(sticker); return }
        land(sticker, on: current)
    }

    private func lift(_ sticker: Sticker) {
        sticker.layer.setAffineTransform(CGAffineTransform(scaleX: Stickers.liftScale, y: Stickers.liftScale))
        sticker.layer.shadowOpacity = Stickers.shadowOpacity
        guard Stickers.animates else { return }
        let grow = CASpringAnimation(keyPath: "transform.scale")
        grow.fromValue = 1; grow.toValue = Stickers.liftScale
        grow.stiffness = 480; grow.damping = 22
        grow.duration = 0.25 * Ink.timeScale
        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0; shadow.toValue = Stickers.shadowOpacity
        shadow.duration = 0.12 * Ink.timeScale
        sticker.layer.add(grow, forKey: "lift"); sticker.layer.add(shadow, forKey: "shadow")
    }

    /// A thrown sticker glides to `rest` (overlay coordinates), turning
    /// once, and sticks to the message it stops on.
    private func fling(_ sticker: Sticker, to rest: NSPoint) {
        let layer = sticker.layer
        let start = layer.position
        let destination = target(for: sticker.emoji, at: transcript.convert(rest, from: overlay))
        guard Stickers.animates else { if let destination { land(sticker, on: destination) } else { fall(sticker) }; return }
        // A throw aimed at a message ends in its slot; the slot shows at once.
        show(destination)
        let end = destination.map { overlayPoint($0.center) } ?? rest
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let destination { self.settleLanding(sticker, on: destination, thrown: true) } else { self.show(nil); self.fall(sticker) }
            }
        }
        let glide = CAKeyframeAnimation(keyPath: "position")
        glide.values = stride(from: 0.0, through: 1.0, by: 0.05).map { NSValue(point: StickerRules.glide(from: start, to: end, progress: $0)) }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0; turn.toValue = (end.x >= start.x ? -2 : 2) * CGFloat.pi
        turn.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = Stickers.liftScale; shrink.toValue = destination == nil ? 1 : landedScale
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        for animation in [glide, turn, shrink] as [CAAnimation] {
            animation.duration = Stickers.flingDuration * Ink.timeScale
            animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
        }
        layer.position = end
        layer.add(glide, forKey: "glide"); layer.add(turn, forKey: "turn"); layer.add(shrink, forKey: "shrink")
        CATransaction.commit()
    }

    /// The sticker drops into its slot with a squash and the reaction is sent.
    private func land(_ sticker: Sticker, on target: Target) {
        let layer = sticker.layer
        let end = overlayPoint(target.center)
        guard Stickers.animates else { settleLanding(sticker, on: target, thrown: false); return }
        let move = CASpringAnimation(keyPath: "position")
        move.fromValue = NSValue(point: layer.position); move.toValue = NSValue(point: end)
        move.stiffness = 520; move.damping = 34
        move.duration = Stickers.landDuration * Ink.timeScale
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = Stickers.liftScale; shrink.toValue = landedScale
        shrink.duration = Stickers.landDuration * 0.7 * Ink.timeScale
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        shrink.fillMode = .forwards; shrink.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.settleLanding(sticker, on: target, thrown: false) } }
        layer.position = end
        layer.add(move, forKey: "land"); layer.add(shrink, forKey: "shrink")
        CATransaction.commit()
    }

    /// The sticker is on its message: it squashes, makes its sound, sends
    /// the reaction and waits for the transcript to show it.
    private func settleLanding(_ sticker: Sticker, on target: Target, thrown: Bool) {
        guard let session = owner.session, owner.canReact(in: target.message.channelID, session: session), owner.emojiSelectionTask == nil else { NSSound.beep(); show(nil); fall(sticker); return }
        let layer = sticker.layer
        layer.removeAllAnimations()
        layer.position = overlayPoint(target.center)
        layer.shadowOpacity = 0
        let rest = CGAffineTransform(scaleX: landedScale, y: landedScale)
        layer.setAffineTransform(rest)
        if Stickers.animates {
            let squash = CASpringAnimation(keyPath: "transform.scale.y")
            squash.fromValue = landedScale * Stickers.squash; squash.toValue = landedScale
            squash.stiffness = 600; squash.damping = 16
            squash.duration = Stickers.landDuration * Ink.timeScale
            layer.add(squash, forKey: "squash")
        }
        InkSounds.play(.stick)
        sticker.anchor = target.center
        sticker.messageID = target.message.id
        stuck.append(sticker)
        let deadline = DispatchWorkItem { [weak self, weak sticker] in
            guard let self, let sticker, self.stuck.contains(where: { $0 === sticker }) else { return }
            self.fall(sticker)
        }
        sticker.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Stickers.patience * Ink.timeScale, execute: deadline)
        owner.toggleReaction(.unicode(sticker.emoji), on: target.message) { [weak self, weak sticker] accepted in
            guard let self, let sticker, !accepted, self.stuck.contains(where: { $0 === sticker }) else { return }
            self.fall(sticker)
        }
    }

    // MARK: Clicks

    /// The reader clicked `emoji` in the quick reaction row, whose button
    /// was at `origin` (screen coordinates). The emoji arcs to its chip,
    /// or, when the click takes the reaction back, peels off and falls.
    func toss(_ emoji: String, from origin: NSRect?, to message: RavenMessage) {
        guard let session = owner.session else { return }
        if QuickReactions.reacted(by: session.account.user, in: message.raw["message_reactions"]).contains(emoji) {
            if let chip = chip(emoji, on: message.id) { peelOff(chip) }
            owner.toggleReaction(.unicode(emoji), on: message)
            return
        }
        guard Stickers.animates, let window = owner.window, let origin, let target = target(for: emoji, on: message),
              owner.readableTranscriptRect.intersects(target.pill), owner.emojiSelectionTask == nil,
              let sticker = makeSticker(emoji, at: overlay.convert(window.convertPoint(fromScreen: NSPoint(x: origin.midX, y: origin.midY)), from: nil), scale: 1) else {
            owner.toggleReaction(.unicode(emoji), on: message)
            return
        }
        let layer = sticker.layer
        let start = layer.position, end = overlayPoint(target.center)
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: NSPoint(x: (start.x + end.x) / 2, y: max(start.y, end.y) + Stickers.tossRise))
        let arc = CAKeyframeAnimation(keyPath: "position")
        arc.path = path
        arc.timingFunction = CAMediaTimingFunction(name: .easeIn)
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1; shrink.toValue = landedScale
        for animation in [arc, shrink] as [CAAnimation] {
            animation.duration = Stickers.tossDuration * Ink.timeScale
            animation.fillMode = .forwards; animation.isRemovedOnCompletion = false
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in MainActor.assumeIsolated { self?.settleLanding(sticker, on: target, thrown: false) } }
        layer.position = end
        layer.add(arc, forKey: "arc"); layer.add(shrink, forKey: "shrink")
        CATransaction.commit()
    }

    /// A press on a chip in the transcript. A click toggles the reader's
    /// reaction; dragging the reader's own chip peels it off. Returns
    /// false when the press is not on a chip that can be toggled.
    func press(_ event: NSEvent) -> Bool {
        let start = transcript.convert(event.locationInWindow, from: nil)
        guard let session = owner.session, let chip = visibleChips().first(where: { $0.rect.contains(start) }),
              QuickReactions.isUnicodeReaction(chip.label), owner.canReact(in: chip.message.channelID, session: session) else { return false }
        guard owner.emojiSelectionTask == nil else { NSSound.beep(); return true }
        var peeled: Sticker?
        var point = start
        var moved = false
        var cancelled = false
        tracking: while true {
            let step = PressTracking.next()
            if step == .cancelled { cancelled = true; break tracking }
            if let window = transcript.window { point = transcript.convert(window.mouseLocationOutsideOfEventStream, from: nil) }
            if !moved, StickerRules.isDrag(from: start, to: point) {
                moved = true
                if chip.mine, let sticker = makeSticker(chip.label, at: overlayPoint(chip.emojiCenter), scale: landedScale) {
                    peeled = sticker
                    setGlyphs(shown: false, in: chip.labelRange)
                    sticker.layer.shadowOpacity = Stickers.shadowOpacity
                    InkSounds.play(.lift)
                }
            }
            if let peeled {
                // One corner lifts first: the sticker turns as it comes away.
                let distance = hypot(point.x - start.x, point.y - start.y)
                let away = min(1, distance / StickerRules.peelDistance)
                let size = landedScale + (1.2 - landedScale) * away
                peeled.layer.position = overlayPoint(NSPoint(x: chip.emojiCenter.x + point.x - start.x, y: chip.emojiCenter.y + point.y - start.y))
                peeled.layer.setAffineTransform(CGAffineTransform(scaleX: size, y: size).rotated(by: -StickerRules.maximumTilt * away))
            }
            if step == .released { break tracking }
        }
        if let peeled {
            let distance = hypot(point.x - start.x, point.y - start.y)
            if cancelled || distance < StickerRules.peelDistance {
                // Not far enough: it goes back on.
                remove(peeled)
                setGlyphs(shown: true, in: chip.labelRange)
            } else {
                fall(peeled)
                owner.toggleReaction(.unicode(chip.label), on: chip.message) { [weak self] accepted in if !accepted { self?.restoreHiddenGlyphs() } }
            }
            return true
        }
        guard !moved, !cancelled else { return true }
        click(chip)
        return true
    }

    /// Clicks the chip at `point` (transcript coordinates), as a press and
    /// release there would. False when no chip there can be toggled.
    @discardableResult func clickChip(at point: NSPoint) -> Bool {
        guard let session = owner.session, owner.emojiSelectionTask == nil, let chip = visibleChips().first(where: { $0.rect.contains(point) }),
              QuickReactions.isUnicodeReaction(chip.label), owner.canReact(in: chip.message.channelID, session: session) else { return false }
        click(chip)
        return true
    }

    /// The chips on screen: label and pill, in transcript coordinates.
    var chipFrames: [(messageID: String, label: String, rect: NSRect)] { visibleChips().map { ($0.message.id, $0.label, $0.rect) } }

    /// A click on a chip: the reader's reaction comes off, or goes on.
    private func click(_ chip: Chip) {
        if chip.mine {
            peelOff(chip)
            owner.toggleReaction(.unicode(chip.label), on: chip.message) { [weak self] accepted in if !accepted { self?.restoreHiddenGlyphs() } }
        } else if Stickers.animates, let target = target(for: chip.label, on: chip.message), let sticker = makeSticker(chip.label, at: overlayPoint(target.center), scale: Stickers.liftScale * landedScale) {
            // Pressed onto the chip in place.
            setGlyphs(shown: false, in: chip.labelRange)
            settleLanding(sticker, on: target, thrown: false)
        } else {
            owner.toggleReaction(.unicode(chip.label), on: chip.message)
        }
    }

    /// The reader's reaction comes off its chip and falls.
    private func peelOff(_ chip: Chip) {
        guard Stickers.animates, owner.readableTranscriptRect.intersects(chip.rect),
              let sticker = makeSticker(chip.label, at: overlayPoint(chip.emojiCenter), scale: landedScale) else { return }
        setGlyphs(shown: false, in: chip.labelRange)
        InkSounds.play(.lift)
        fall(sticker)
    }

    // MARK: Undo

    /// The reader added `emoji` to `message`; Edit ▸ Undo takes it back.
    func registerUndo(_ emoji: String, on message: RavenMessage) {
        guard let session = owner.session, let undo = owner.composer.undoManager else { return }
        let messageID = message.id, channelID = message.channelID
        undo.registerUndo(withTarget: self) { [weak session] stickers in
            MainActor.assumeIsolated {
                guard let session else { return }
                stickers.takeBack(emoji, from: messageID, in: session, channelID: channelID)
            }
        }
        undo.setActionName("Reaction")
        undoManagers.add(undo)
    }

    private func takeBack(_ emoji: String, from messageID: String, in session: AccountSession, channelID: String) {
        // Undo managers are shared across a conversation's windows, while
        // the registering window can now show another account on the same
        // site. Identical message IDs must never redirect the mutation.
        let focused = NSApp.keyWindow?.windowController as? ConversationWindow
        let target: ConversationWindow?
        if let focused, focused.isCurrent(session, channelID: channelID) { target = focused }
        else if owner.isCurrent(session, channelID: channelID) { target = owner }
        else { target = owner.app.windows.first { $0.isCurrent(session, channelID: channelID) } }
        guard let target, let message = target.messages.first(where: { $0.id == messageID && $0.channelID == channelID }),
              target.canReact(in: channelID, session: session),
              QuickReactions.reacted(by: session.account.user, in: message.raw["message_reactions"]).contains(emoji) else { NSSound.beep(); return }
        let stickers = target.stickers
        if let chip = stickers.chip(emoji, on: messageID) { stickers.peelOff(chip) }
        target.toggleReaction(.unicode(emoji), on: message, undoable: false) { [weak stickers] accepted in if !accepted { stickers?.restoreHiddenGlyphs() } }
    }

    // MARK: Rendering

    /// The transcript was rendered. Stickers waiting on a message settle
    /// onto their chip, reactions that are new since the last render drop
    /// in, and changed counts roll.
    func didRender() {
        invalidateChips()
        unveil()
        // The text may have moved under waiting stickers, and a slot that
        // was held open is now either a chip or not needed.
        follow()
        show(nil)
        for roll in rolls { roll.removeFromSuperlayer() }
        rolls.removeAll()
        guard let session = owner.session, let channel = owner.channel else { reset(); return }
        var current: [String: [ReactionChip]] = [:]
        for message in owner.messages {
            current[message.id] = ReactionChip.chips(message.raw["message_reactions"].nested, currentUser: session.account.user) ?? []
        }
        defer { known = current; knownChannel = channel.id }
        // A conversation just opened shows its reactions as they are.
        guard knownChannel == channel.id else { for sticker in stuck { remove(sticker) }; return }
        let readable = owner.readableTranscriptRect
        for (id, chips) in current {
            guard let before = known[id] else { continue }
            for change in StickerRules.changes(from: before, to: chips) {
                switch change {
                case .added(let label, _, _):
                    if let waiting = stuck.first(where: { $0.messageID == id && $0.emoji == label }) { settle(waiting) }
                    else if let chip = chip(label, on: id), readable.intersects(chip.rect) { dropIn(chip) }
                case .counted(let label, let from, let to):
                    guard let chip = chip(label, on: id), readable.intersects(chip.rect) else { continue }
                    if let waiting = stuck.first(where: { $0.messageID == id && $0.emoji == label }) { settle(waiting) }
                    else if to > from { dropIn(chip) }
                    roll(chip, from: from)
                case .removed: break
                }
            }
        }
        // A sticker whose message is gone has nothing to hold on to.
        for sticker in stuck where current[sticker.messageID ?? ""] == nil { fall(sticker) }
        follow()
    }

    /// A waiting sticker moves onto the chip that now shows its reaction
    /// and gives way to it.
    private func settle(_ sticker: Sticker) {
        sticker.deadline?.cancel()
        stuck.removeAll { $0 === sticker }
        guard let id = sticker.messageID, let chip = chip(sticker.emoji, on: id), Stickers.animates else { sticker.layer.removeFromSuperlayer(); return }
        let layer = sticker.layer
        let end = overlayPoint(chip.emojiCenter)
        setGlyphs(shown: false, in: chip.labelRange)
        let labelRange = chip.labelRange
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                layer.removeFromSuperlayer()
                self?.setGlyphs(shown: true, in: labelRange)
            }
        }
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: sticker.anchor.map(overlayPoint) ?? layer.position); move.toValue = NSValue(point: end)
        move.duration = 0.12 * Ink.timeScale
        move.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.position = end
        layer.add(move, forKey: "settle")
        CATransaction.commit()
    }

    /// Someone's reaction arrives: it falls from the top of the pane onto
    /// its chip and lands with a squash.
    private func dropIn(_ chip: Chip) {
        guard Stickers.animates, QuickReactions.isUnicodeReaction(chip.label) else { return }
        let end = overlayPoint(chip.emojiCenter)
        let top = overlay.convert(NSPoint(x: 0, y: owner.readableTranscriptRect.minY), from: transcript).y
        guard let sticker = makeSticker(chip.label, at: end, scale: landedScale) else { return }
        let layer = sticker.layer
        setGlyphs(shown: false, in: chip.labelRange)
        let labelRange = chip.labelRange
        let duration = Stickers.dropInDuration * Ink.timeScale
        let drop = CABasicAnimation(keyPath: "position.y")
        drop.fromValue = top + layer.bounds.height; drop.toValue = end.y
        drop.duration = duration
        drop.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 1, 0.75)
        let shrink = CABasicAnimation(keyPath: "transform.scale")
        shrink.fromValue = 1; shrink.toValue = landedScale
        shrink.duration = duration
        let squash = CASpringAnimation(keyPath: "transform.scale.y")
        squash.fromValue = landedScale * Stickers.squash; squash.toValue = landedScale
        squash.stiffness = 600; squash.damping = 16
        squash.beginTime = CACurrentMediaTime() + duration
        squash.duration = Stickers.landDuration * Ink.timeScale
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                layer.removeFromSuperlayer()
                self?.setGlyphs(shown: true, in: labelRange)
            }
        }
        layer.add(drop, forKey: "drop"); layer.add(shrink, forKey: "shrink"); layer.add(squash, forKey: "squash")
        CATransaction.commit()
    }

    /// The count turns over like an odometer digit: up for one more, down
    /// for one fewer.
    private func roll(_ chip: Chip, from old: Int) {
        guard Stickers.animates, chip.countRange.length > 0, let host = overlay.layer, let layout = transcript.layoutManager, let container = transcript.textContainer else { return }
        let origin = transcript.textContainerOrigin
        let glyphs = layout.glyphRange(forCharacterRange: chip.countRange, actualCharacterRange: nil)
        // As wide as the digits and as tall as the pill, so a digit on its
        // way in or out is cut off at the chip's edge. The glyphs' own
        // rectangle is a whole line and reaches past the pill.
        let glyphBox = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: origin.x, dy: origin.y)
        let rect = overlay.convert(NSRect(x: glyphBox.minX - 1, y: chip.rect.minY + 1, width: glyphBox.width + 2, height: chip.rect.height - 2), from: transcript)
        let font = transcript.metrics.chipFont
        let lineHeight = (font.ascender - font.descender).rounded(.up)
        var color = NSColor.secondaryLabelColor
        overlay.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = ((chip.mine ? NSColor.themeAccentText : NSColor.themeSecondaryText).usingColorSpace(.sRGB)) ?? .secondaryLabelColor
        }
        let window = CALayer()
        window.frame = rect
        window.masksToBounds = true
        func digits(_ value: Int) -> CATextLayer {
            let layer = CATextLayer()
            layer.string = NSAttributedString(string: String(value), attributes: [.font: font, .foregroundColor: color])
            layer.contentsScale = scale
            layer.alignmentMode = .center
            // The pill is built around the font's ascent and descent, so a
            // line centered in it sits on the real baseline.
            layer.frame = CGRect(x: 0, y: (rect.height - lineHeight) / 2, width: rect.width, height: lineHeight)
            return layer
        }
        let rising = chip.count > old
        let leaving = digits(old), arriving = digits(chip.count)
        window.addSublayer(leaving); window.addSublayer(arriving)
        host.addSublayer(window)
        rolls.append(window)
        setGlyphs(shown: false, in: chip.countRange)
        let countRange = chip.countRange
        let travel = rect.height * (rising ? 1 : -1)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.rolls.contains(where: { $0 === window }) else { return }
                window.removeFromSuperlayer()
                self.rolls.removeAll { $0 === window }
                self.setGlyphs(shown: true, in: countRange)
            }
        }
        for (layer, from, to) in [(leaving, 0, travel), (arriving, -travel, 0)] {
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = from; slide.toValue = to
            slide.duration = Stickers.rollDuration * Ink.timeScale
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            slide.fillMode = .both; slide.isRemovedOnCompletion = false
            layer.add(slide, forKey: "roll")
        }
        CATransaction.commit()
    }

    // MARK: Hiding glyphs under a sticker

    /// A sticker standing in for a glyph must not show it twice, so the
    /// transcript's layout manager skips the range when it draws. Layout
    /// is untouched. (The layout manager's own "not shown" flag is not
    /// used here: set and cleared on a single emoji it left a stray box
    /// beside it until the next render.) A render replaces the text and
    /// so shows everything.
    private func setGlyphs(shown: Bool, in range: NSRange) {
        guard let layout = transcript.layoutManager as? TranscriptLayoutManager, let storage = transcript.textStorage, NSMaxRange(range) <= storage.length else { return }
        if shown { hidden.removeAll { $0 == range } } else if !hidden.contains(range) { hidden.append(range) }
        layout.veiled = hidden
        layout.invalidateDisplay(forCharacterRange: range)
    }

    /// A reaction that was peeled off could not be removed after all.
    private func restoreHiddenGlyphs() {
        for range in hidden { setGlyphs(shown: true, in: range) }
    }

    /// The text changed under the veiled ranges; they mean nothing now.
    private func unveil() {
        hidden.removeAll()
        (transcript.layoutManager as? TranscriptLayoutManager)?.veiled = []
    }

    // MARK: Following the transcript

    /// Stickers waiting on a message move with it.
    private func follow() {
        guard !stuck.isEmpty else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for sticker in stuck { if let anchor = sticker.anchor { sticker.layer.position = overlayPoint(anchor) } }
        CATransaction.commit()
    }

    func transcriptDidScroll() {
        invalidateChips()
        follow()
        if let shown, !stuck.isEmpty { show(shown) }
        // A rolling count belongs to where its chip was; let the text show.
        if !rolls.isEmpty {
            for roll in rolls { roll.removeFromSuperlayer() }
            rolls.removeAll()
            restoreHiddenGlyphs()
        }
    }

    func transcriptDidLayout() {
        invalidateChips()
        follow()
    }

    // MARK: Lifetime

    /// The conversation changed; nothing in the air belongs to the new one.
    func reset() {
        show(nil)
        for sticker in stuck { sticker.deadline?.cancel() }
        stuck.removeAll()
        rolls.removeAll()
        unveil()
        transcript.needsDisplay = true
        overlay.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        known.removeAll(); knownChannel = nil
        invalidateChips()
    }

    /// The window is closing. Draft undo managers outlive it and do not
    /// keep their targets alive.
    func detach() {
        reset()
        for undo in undoManagers.allObjects { undo.removeAllActions(withTarget: self) }
        undoManagers.removeAllObjects()
    }
}

/// One step of a press the app is following by hand, from mouse down to
/// mouse up.
@MainActor enum PressTracking {
    enum Step { case moved, released, cancelled }

    /// Waits for the pointer to move, the button to come up or Escape.
    /// A mouse-up can be lost, for instance when the window that took the
    /// press goes away during it. The button's real state is therefore
    /// checked every 50 ms, so a sticker never stays glued to the pointer.
    static func next() -> Step {
        while true {
            guard let event = NSApp.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .keyDown], until: Date(timeIntervalSinceNow: 0.05), inMode: .eventTracking, dequeue: true) else {
                if NSEvent.pressedMouseButtons & 1 == 0 { return .released }
                continue
            }
            switch event.type {
            case .leftMouseUp: return .released
            case .keyDown: if event.keyCode == 53 { return .cancelled }
            default: return .moved
            }
        }
    }
}

/// The transcript's layout manager. It can leave character ranges undrawn
/// without changing layout, for glyphs that an animation is showing
/// somewhere else at the moment.
@MainActor final class TranscriptLayoutManager: NSLayoutManager {
    /// Character ranges not to draw. Only valid for the current text.
    var veiled: [NSRange] = []

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard !veiled.isEmpty, let length = textStorage?.length else { super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin); return }
        let gaps = veiled.filter { NSMaxRange($0) <= length }
            .map { glyphRange(forCharacterRange: $0, actualCharacterRange: nil) }
            .filter { NSIntersectionRange($0, glyphsToShow).length > 0 }
            .sorted { $0.location < $1.location }
        var cursor = glyphsToShow.location
        let end = NSMaxRange(glyphsToShow)
        for gap in gaps {
            if gap.location > cursor { super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: gap.location - cursor), at: origin) }
            cursor = max(cursor, min(end, NSMaxRange(gap)))
        }
        if cursor < end { super.drawGlyphs(forGlyphRange: NSRange(location: cursor, length: end - cursor), at: origin) }
    }
}
