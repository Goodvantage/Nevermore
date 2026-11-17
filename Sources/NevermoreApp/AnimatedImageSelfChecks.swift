import AppKit
import ImageIO
import NevermoreCore
import RavenProtocol
import UniformTypeIdentifiers

/// GIFs in the transcript: an animated image plays over its first frame,
/// exactly where the attachment is drawn, without taking its clicks.
@MainActor enum AnimatedImageSelfChecks {
    /// An animated GIF of `frames` solid frames, alternating two colors.
    static func gif(width: Int = 64, height: Int = 48, frames: Int = 4, delay: Double = 0.1) -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames, nil) else { return Data() }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for index in 0..<frames {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
            context.setFillColor(index.isMultiple(of: 2) ? CGColor(red: 0.9, green: 0.2, blue: 0.1, alpha: 1) : CGColor(red: 0.1, green: 0.3, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else { return Data() }
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        return CGImageDestinationFinalize(destination) ? data as Data : Data()
    }

    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreGIFCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "reader@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        defer { session.stop(); try? FileManager.default.removeItem(at: directory) }
        let channel = RavenChannel(raw: .object(["name": .string("gif-fixture"), "channel_name": .string("GIF fixture")]))
        session.channels = [channel]
        session.userNames = ["alice@example.invalid": "Alice Example"]
        func row(_ id: String, _ creation: String, _ html: String, type: String = "Text", extra: [String: JSONValue] = [:]) -> RavenMessage {
            var fields: [String: JSONValue] = ["name": .string(id), "channel_id": .string(channel.id), "owner": .string("alice@example.invalid"), "creation": .string(creation), "text": .string(html), "message_type": .string(type)]
            fields.merge(extra) { _, new in new }
            return RavenMessage(raw: .object(fields))
        }
        try await session.store.cacheMessages([
            row("before", "2026-11-06 09:00:00.000000", "<p>Look at this.</p>"),
            row("upload", "2026-11-06 09:01:00.000000", "", type: "Image", extra: ["file": .string("/files/dance.gif")]),
            row("after", "2026-11-06 09:02:00.000000", "<p>Nice.</p>"),
            row("embedded", "2026-11-06 09:03:00.000000", #"<p>Ha</p><p><img src="https://media.tenor.com/fixture/dance.gif" alt="Dancing raven"></p>"#),
            row("tracker", "2026-11-06 09:04:00.000000", #"<p>Pixel <img src="https://tracker.example/p.gif" alt="pixel-fallback"></p>"#),
            row("broken", "2026-11-06 09:05:00.000000", #"<p><img src="https://media.giphy.com/fixture/broken.gif" alt="broken-fallback"></p>"#),
            row("twice", "2026-11-06 09:06:00.000000", #"<p><img src="https://media.tenor.com/fixture/dance.gif" alt="Again"><img src="https://media.tenor.com/fixture/dance.gif" alt="Again"></p>"#),
        ])
        let media = FixtureGIFMedia(data: gif(width: 120, height: 90))
        session.gifMedia = media
        let defaults = UserDefaults.standard
        let savedPreference = defaults.object(forKey: GIFPreferences.showsInMessagesKey)
        defaults.removeObject(forKey: GIFPreferences.showsInMessagesKey)
        defer { if let savedPreference { defaults.set(savedPreference, forKey: GIFPreferences.showsInMessagesKey) } else { defaults.removeObject(forKey: GIFPreferences.showsInMessagesKey) } }

        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }

        guard let decoded = AnimatedImageDecoder.decode(gif(), maxPixelSide: AccountSession.animatedPixelSide), decoded.frames.count == 4,
              let still = AnimatedImageCache.still(decoded, maxSide: 512) else { return [("GIF fixture decodes", false)] }
        let key = AnimatedImageKey.message("upload")
        session.thumbnails["upload"] = still
        session.animatedSources[key] = URL(string: "https://demo.invalid/files/dance.gif")
        session.animatedImages.insert(decoded, for: key)

        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close() }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.select(channel)
        session.recordTranscriptVisit(.timestamp("2026-11-06 23:00:00"), channelID: channel.id)
        await controller.loadTask?.value; await controller.renderTask?.value
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        let transcript = controller.transcript
        guard let storage = transcript.textStorage, let layout = transcript.layoutManager, let container = transcript.textContainer else { return [("GIF fixture has a text system", false)] }
        var marked: [NSRange] = []
        storage.enumerateAttribute(.nevermoreAnimatedImage, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value as? String == key { marked.append(range) }
        }
        check("a GIF upload's thumbnail is marked as animated", marked.count == 1 && marked.first?.length == 1 && storage.attribute(.attachment, at: marked.first?.location ?? 0, effectiveRange: nil) is NSTextAttachment)

        let overlay = controller.animatedImages
        overlay.animates = { true }
        overlay.update()
        let view = marked.first.flatMap { overlay.views[$0.location] }
        check("an animated image view is placed over the GIF in view", view != nil && view?.superview === transcript)
        if let view, let range = marked.first {
            // The still drawn by the attachment must fill the view's frame
            // exactly: red inside, nothing red just above or beside it.
            func redShare(in rect: NSRect) -> Double {
                guard let rep = transcript.bitmapImageRepForCachingDisplay(in: rect) else { return -1 }
                transcript.cacheDisplay(in: rect, to: rep)
                var red = 0, total = 0
                for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh {
                    total += 1
                    if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), color.redComponent > 0.7, color.blueComponent < 0.4 { red += 1 }
                } }
                return total == 0 ? -1 : Double(red) / Double(total)
            }
            view.isHidden = true
            let inside = redShare(in: view.frame.insetBy(dx: 1, dy: 1))
            let above = redShare(in: NSRect(x: view.frame.minX, y: view.frame.minY - 3, width: view.frame.width, height: 2))
            let right = redShare(in: NSRect(x: view.frame.maxX + 1, y: view.frame.minY, width: 2, height: view.frame.height))
            view.isHidden = false
            let aligned = inside > 0.95 && above == 0 && right == 0
            check("the animated view covers the attachment exactly", aligned)
            if !aligned { print("DIAGNOSTIC GIF overlay frame \(view.frame) red inside \(inside) above \(above) right \(right) range \(range) layout \(layout.boundingRect(forGlyphRange: layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container))") }
            check("the GIF plays through Core Animation", view.isPlaying && view.image.frames.count == 4)
            let center = NSPoint(x: view.frame.midX, y: view.frame.midY)
            let hit = transcript.hitTest(transcript.convert(center, to: transcript.superview))
            check("clicks on a playing GIF reach the transcript and its preview link", hit === transcript && storage.attribute(.link, at: range.location, effectiveRange: nil) != nil)
            overlay.animates = { false }
            overlay.refreshPlayback()
            check("Reduce Motion leaves the first frame still", !view.isPlaying && view.layer?.contents != nil)
            overlay.animates = { true }
            overlay.refreshPlayback()
            controller.render(); await controller.renderTask?.value
            check("a render keeps the same playing view over the GIF", overlay.views[range.location] === view && view.isPlaying)
        }

        // A GIF in view keeps playing after the cache lets it go, so GIFs in
        // view cannot push each other out and load in turn.
        let placedView = marked.first.flatMap { overlay.views[$0.location] }
        session.animatedImages.removeAll()
        controller.render(); await controller.renderTask?.value
        check("a GIF in view keeps playing after the cache lets it go", placedView != nil && marked.first.map { overlay.views[$0.location] } == placedView && placedView?.isPlaying == true)
        // A width change, as when a legacy scroller comes or goes, lays the
        // text out again after AppKit reports the new frame. Seen on CI.
        let width = transcript.frame.width
        transcript.setFrameSize(NSSize(width: width - 17, height: transcript.frame.height))
        let keptThroughRelayout = marked.first.map { overlay.views[$0.location] } == placedView && placedView?.isPlaying == true
        transcript.setFrameSize(NSSize(width: width, height: transcript.frame.height))
        for _ in 0..<5 { await Task.yield() }
        check("a GIF in view keeps playing while its text is laid out again", keptThroughRelayout && marked.first.map { overlay.views[$0.location] } == placedView && placedView?.superview === transcript)
        // Placed again, it shows its still and asks to be decoded again;
        // the demo session has nowhere to fetch it from.
        transcript.layoutManager?.ensureLayout(for: container)
        overlay.removeAll(); overlay.update()
        check("a forgotten GIF placed again shows its still without a view", marked.first.map { overlay.views[$0.location] == nil } == true)
        session.animatedImages.insert(decoded, for: key)
        controller.render(); await controller.renderTask?.value
        // A GIF fetch from the renders above may start one more render.
        for _ in 0..<100 where marked.first.map({ overlay.views[$0.location]?.key == key }) != true {
            try? await Task.sleep(for: .milliseconds(20)); await controller.renderTask?.value
        }
        check("a decoded GIF plays again", marked.first.map { overlay.views[$0.location]?.key == key } == true)

        // GIFs embedded in message bodies, as Raven's GIF picker sends them.
        let embeddedKey = AnimatedImageKey.remote(URL(string: "https://media.tenor.com/fixture/dance.gif")!)
        let loadDeadline = Date(timeIntervalSinceNow: 5)
        while (!session.animatedImages.contains(embeddedKey) || session.animatedRequests.count > 0), Date() < loadDeadline { try? await Task.sleep(for: .milliseconds(20)) }
        controller.render(); await controller.renderTask?.value
        let requested = await media.requested
        check("only GIF service images are fetched, never other remote images", requested.contains { $0.host == "media.tenor.com" } && requested.allSatisfy(GIFMediaPolicy.isServiceMedia))
        func attachmentRange(in id: String) -> NSRange? {
            guard let range = controller.messageRanges.first(where: { $0.1.id == id })?.0 else { return nil }
            var found: NSRange?
            storage.enumerateAttribute(.attachment, in: range) { value, attachmentRange, stop in if value != nil { found = attachmentRange; stop.pointee = true } }
            return found
        }
        let messageText = { (id: String) in controller.messageRanges.first { $0.1.id == id }.map { (storage.string as NSString).substring(with: $0.0) } ?? "" }
        if let embedded = attachmentRange(in: "embedded"), let attachment = storage.attribute(.attachment, at: embedded.location, effectiveRange: nil) as? NSTextAttachment {
            check("an embedded GIF shows at its own size in place of its text", attachment.bounds.size == NSSize(width: 120, height: 90) && !messageText("embedded").contains("Dancing raven") && storage.attribute(.toolTip, at: embedded.location, effectiveRange: nil) as? String == "Dancing raven")
            check("an embedded GIF plays like an uploaded one", storage.attribute(.nevermoreAnimatedImage, at: embedded.location, effectiveRange: nil) as? String == embeddedKey && overlay.views[embedded.location]?.isPlaying == true)
        } else { check("an embedded GIF becomes an attachment", false) }
        check("a remote image outside GIF services stays text", attachmentRange(in: "tracker") == nil && messageText("tracker").contains("pixel-fallback"))
        check("a GIF that fails to load falls back to its text", attachmentRange(in: "broken") == nil && messageText("broken").contains("broken-fallback"))
        // The same GIF twice side by side is two images, each playing.
        var playingTwice = 0
        if let twice = controller.messageRanges.first(where: { $0.1.id == "twice" })?.0 {
            storage.enumerateAttribute(.attachment, in: twice) { value, range, _ in
                if value != nil, overlay.views[range.location]?.isPlaying == true { playingTwice += 1 }
            }
        }
        check("the same GIF twice in a row shows and plays twice", playingTwice == 2 && !messageText("twice").contains("Again"))

        // Embedding only marks a GIF; it loads once the overlay sees it in view.
        let offscreen = URL(string: "https://media.tenor.com/fixture/offscreen.gif")!
        let marker = InlineImagePresentation.embed(NSAttributedString(string: "offscreen-fallback", attributes: [.nevermoreInlineImage: InlineImageSource(offscreen.absoluteString)]), session: session, enabled: true)
        let requestsAfterEmbed = await media.requested
        check("an embedded GIF is not fetched until it comes into view",
              marker.attribute(.nevermoreAnimatedImage, at: 0, effectiveRange: nil) as? String == AnimatedImageKey.remote(offscreen)
                && !session.animatedRequests.contains(AnimatedImageKey.remote(offscreen)) && !requestsAfterEmbed.contains(offscreen))
        let crowded = NSMutableAttributedString()
        for index in 0..<(InlineImagePresentation.maximumPerMessage + 5) {
            crowded.append(NSAttributedString(string: "gif-\(index)", attributes: [.nevermoreInlineImage: InlineImageSource("https://media.tenor.com/fixture/crowd-\(index).gif")]))
            crowded.append(NSAttributedString(string: " "))
        }
        let embeddedCrowd = InlineImagePresentation.embed(crowded, session: session, enabled: true)
        var crowdAttachments = 0
        embeddedCrowd.enumerateAttribute(.attachment, in: NSRange(location: 0, length: embeddedCrowd.length)) { value, _, _ in if value != nil { crowdAttachments += 1 } }
        check("a message shows a bounded number of GIFs; the rest keep their text", crowdAttachments == InlineImagePresentation.maximumPerMessage && embeddedCrowd.string.contains("gif-\(InlineImagePresentation.maximumPerMessage)"))
        defaults.set(false, forKey: GIFPreferences.showsInMessagesKey)
        controller.render(); await controller.renderTask?.value
        check("with GIFs turned off, embedded GIFs stay text", attachmentRange(in: "embedded") == nil && messageText("embedded").contains("Dancing raven"))
        defaults.removeObject(forKey: GIFPreferences.showsInMessagesKey)
        controller.render(); await controller.renderTask?.value

        // A fetch that finishes after its source was forgotten, as when
        // access to the conversation is lost, keeps nothing.
        let late = URL(string: "https://media.tenor.com/fixture/late.gif")!
        let lateKey = AnimatedImageKey.remote(late)
        await media.hold()
        session.noteInlineImage(late); session.requestAnimatedImage(lateKey)
        let lateStarted = session.animatedRequests.contains(lateKey)
        session.forgetAnimatedImages()
        await media.release()
        let lateDeadline = Date(timeIntervalSinceNow: 5)
        while session.animatedRequests.contains(lateKey), Date() < lateDeadline { try? await Task.sleep(for: .milliseconds(20)) }
        check("a GIF fetched after its source was forgotten is not kept", lateStarted && !session.animatedRequests.contains(lateKey) && !session.animatedImages.contains(lateKey))

        // A view given new frames plays those, not the ones it was playing.
        let player = AnimatedImageView(key: "", image: decoded, frame: NSRect(x: 0, y: 0, width: 64, height: 48))
        transcript.addSubview(player)
        player.setPlaying(true)
        let replacement = AnimatedImageDecoder.decode(gif(width: 32, height: 24, frames: 3), maxPixelSide: 64)
        if let replacement { player.show(replacement, animates: true) }
        let played = (player.layer?.animation(forKey: AnimatedImageView.animationKey) as? CAKeyframeAnimation)?.values?.count
        check("a view shown new frames plays them, not the old ones", replacement?.frames.count == 3 && played == 3)
        player.removeFromSuperview()

        transcript.clearText(); overlay.removeAll()
        check("clearing the transcript removes animated views", overlay.views.isEmpty && !transcript.subviews.contains { $0 is AnimatedImageView })

        // The cache keeps to its byte budget, forgetting the oldest first.
        let small = AnimatedImageCache(budget: decoded.decodedBytes * 2)
        small.insert(decoded, for: "a"); small.insert(decoded, for: "b")
        _ = small["a"]
        small.insert(decoded, for: "c")
        check("the animated image cache forgets the least recently shown image", small.contains("a") && !small.contains("b") && small.contains("c"))
        check("a forgotten image keeps its size for its placeholder", small.sourceSize("b") == decoded.sourcePixelSize)
        return checks
    }
}

/// Serves the fixture GIF for any GIF address except `broken.gif`, and
/// records what was asked for. While held, answers wait for `release()`.
private actor FixtureGIFMedia: GIFMediaLoading {
    let data: Data
    private(set) var requested: [URL] = []
    private var holding = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(data: Data) { self.data = data }
    func hold() { holding = true }
    func release() { holding = false; for waiter in waiting { waiter.resume() }; waiting.removeAll() }
    func mediaData(for url: URL) async -> Data? {
        requested.append(url)
        if holding { await withCheckedContinuation { waiting.append($0) } }
        return url.lastPathComponent == "broken.gif" ? nil : data
    }
}
