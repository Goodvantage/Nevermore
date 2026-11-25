import AppKit
import NevermoreCore
import RavenProtocol

/// Link previews, pictures and files in a disposable transcript: one
/// preview per message, for its first link and never one the sender hid;
/// cards that are one click target each and fit the column; pictures that
/// keep their box while they load, with no file name line under them; and
/// copies that name files but leave previews out.
///
/// With `NEVERMORE_MEDIA_SNAPSHOTS=1` the fixture is also drawn under three
/// themes into PNGs in the app's temporary folder, for a person to look at.
@MainActor enum TranscriptMediaSelfChecks {
    static func run(app: AppDelegate) async throws -> [(String, Bool)] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreMediaCheck-\(UUID())")
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "reader@example.invalid", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: directory, demo: true)
        let channel = RavenChannel(raw: .object(["name": .string("media-fixture"), "channel_name": .string("Media fixture")]))
        session.channels = [channel]
        session.userNames = ["lukas@example.invalid": "Lukas", "bene@example.invalid": "Benedikt"]
        func row(_ id: String, _ owner: String, _ time: String, _ html: String, type: String = "Text", extra: [String: JSONValue] = [:]) -> RavenMessage {
            var fields: [String: JSONValue] = ["name": .string(id), "channel_id": .string(channel.id), "owner": .string(owner), "creation": .string("2026-11-24 \(time).000000"), "text": .string(html), "message_type": .string(type)]
            fields.merge(extra) { _, new in new }
            return RavenMessage(raw: .object(fields))
        }
        let forge = "https://forge.example.com/Goodvantage/GoodVault", story = "https://news.example.com/story", second = "https://second.example.com/", hidden = "https://forge.example.com/hidden", docs = "https://docs.example.com/"
        let screenshot = "CleanShot 2026-11-24 at 17.33.59.png", report = "Quarterly report final.pdf"
        let rows = [
            row("linked", "lukas@example.invalid", "17:25:00", #"<p>GoodVault ist am implementieren.</p><p><a href="\#(forge)">\#(forge)</a></p>"#),
            row("photo", "lukas@example.invalid", "17:26:00", "", type: "Image", extra: ["file": .string("/files/\(screenshot)"), "thumbnail_width": .number(480), "thumbnail_height": .string("320")]),
            row("caption", "lukas@example.invalid", "17:26:10", "<p>Hier pagebreak einfügen, damit das Icon von Good Learn auf der nächsten Seite erscheint.</p>"),
            row("twoLinks", "bene@example.invalid", "17:37:00", #"<p>Read <a href="mailto:press@example.com">the press desk</a>, then <a href="\#(story)">this story</a> and <a href="\#(second)">that one</a>.</p>"#),
            row("hidden", "bene@example.invalid", "17:38:00", #"<p>No card for <a href="\#(hidden)">this</a>.</p>"#, extra: ["hide_link_preview": .number(1)]),
            row("plain", "bene@example.invalid", "17:39:00", #"<p>Docs: <a href="\#(docs)">\#(docs)</a></p>"#),
            row("later", "bene@example.invalid", "17:40:00", "", type: "Image", extra: ["file": .string("/files/later.jpg"), "thumbnail_width": .number(240), "thumbnail_height": .number(480)]),
            row("report", "bene@example.invalid", "17:41:00", "", type: "File", extra: ["file": .string("/files/\(report.replacingOccurrences(of: " ", with: "%20"))"), "file_size": .number(2_400_000)]),
        ]
        try await session.store.cacheMessages(rows)
        func preview(_ title: String, _ description: String, site: String, image: String?, width: JSONValue = .null, height: JSONValue = .null) -> JSONValue {
            var fields: [String: JSONValue] = ["title": .string(title), "description": .string(description), "site_name": .string(site), "image_width": width, "image_height": height]
            if let image { fields["image"] = .string(image) }
            return .object(fields)
        }
        session.sentLinkPreviews.ingest(.object([
            forge: preview("Sign in", "Forgejo is a self-hosted lightweight software forge. Easy to install and low maintenance, it just does the job.", site: "Forgejo: Beyond coding. We Forge.", image: "https://forge.example.com/assets/img/logo.png", width: .number(512), height: .number(512)),
            story: preview("Ravens solve puzzles that stump most birds", "Researchers found that ravens plan ahead, trade favours and remember faces for years, which puts them among the cleverest animals studied so far.", site: "Example News", image: "https://news.example.com/cover.jpg", width: .string("1200"), height: .number(630)),
            second: preview("Second page", "Never shown: only a message's first link gets a card.", site: "Second", image: nil),
            hidden: preview("Hidden page", "Never shown: the sender hid the preview.", site: "Forge", image: nil),
            docs: preview("Documentation", "", site: "", image: nil),
        ]))
        if let logo = picture(width: 512, height: 512, draw: drawLogo) { session.sentLinkPreviews.storeImage(logo, for: forge) }
        if let cover = picture(width: 1024, height: 538, draw: drawBanner) { session.sentLinkPreviews.storeImage(cover, for: story) }
        if let page = picture(width: 640, height: 427, draw: drawScreenshot) { session.thumbnails["photo"] = NSImage(cgImage: page, size: NSSize(width: page.width, height: page.height)) }

        let defaults = UserDefaults.standard
        let savedCompact = defaults.object(forKey: "compactMessages"), savedSize = defaults.object(forKey: "fontSize")
        defaults.set(false, forKey: "compactMessages"); defaults.removeObject(forKey: "fontSize")
        let controller = ConversationWindow(app: app, session: session)
        defer {
            if let savedCompact { defaults.set(savedCompact, forKey: "compactMessages") } else { defaults.removeObject(forKey: "compactMessages") }
            if let savedSize { defaults.set(savedSize, forKey: "fontSize") } else { defaults.removeObject(forKey: "fontSize") }
            controller.close(); session.stop(); try? FileManager.default.removeItem(at: directory)
        }
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.select(channel)
        session.recordTranscriptVisit(.timestamp("2026-11-25 23:00:00"), channelID: channel.id)
        await controller.loadTask?.value; await controller.renderTask?.value
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        var checks: [(String, Bool)] = []
        // Geometry differs on CI's Mac (classic scroll bars narrow the
        // column), so a failing measurement prints what it measured.
        func check(_ label: String, _ value: Bool, _ measured: @autoclosure () -> String = "") {
            checks.append((label, value))
            if !value, case let detail = measured(), !detail.isEmpty { print("DIAGNOSTIC \(label): \(detail)") }
        }
        let transcript = controller.transcript
        guard let storage = transcript.textStorage, let layout = transcript.layoutManager, let container = transcript.textContainer else { return [("media fixture has a text system", false)] }
        layout.ensureLayout(for: container)
        func range(_ id: String) -> NSRange? { controller.messageRanges.first { $0.1.id == id }?.0 }
        func text(_ id: String) -> String { range(id).map { (storage.string as NSString).substring(with: $0) } ?? "" }
        func attachments(_ id: String) -> [(location: Int, attachment: NSTextAttachment)] {
            guard let range = range(id) else { return [] }
            var found: [(Int, NSTextAttachment)] = []
            storage.enumerateAttribute(.attachment, in: range) { value, run, _ in if let attachment = value as? NSTextAttachment { found.append((run.location, attachment)) } }
            return found
        }
        func cards<Cell: TranscriptCardCell>(_ type: Cell.Type, in id: String) -> [(location: Int, cell: Cell)] {
            attachments(id).compactMap { entry in (entry.attachment.attachmentCell as? Cell).map { (entry.location, $0) } }
        }
        func frame(_ location: Int) -> NSRect? { AnimatedImageOverlay.attachmentFrame(at: location, layout: layout, origin: transcript.textContainerOrigin) }
        func link(at location: Int) -> URL? { storage.attribute(.link, at: location, effectiveRange: nil) as? URL }
        check("all media fixture messages render", controller.messageRanges.count == rows.count)

        // Link previews.
        let forgeCard = cards(LinkPreviewCardCell.self, in: "linked").first
        let storyCards = cards(LinkPreviewCardCell.self, in: "twoLinks")
        check("a message previews only its first web link", storyCards.count == 1 && storyCards.first.map { link(at: $0.location) == URL(string: story) } == true && session.sentLinkPreviews.preview(for: second) != nil)
        check("a preview its sender hid stays hidden", cards(LinkPreviewCardCell.self, in: "hidden").isEmpty && session.sentLinkPreviews.preview(for: hidden) != nil)
        if let forgeCard {
            let location = forgeCard.location
            check("a link preview is one click target that copies and printouts leave out",
                  link(at: location) == URL(string: forge) && storage.attribute(.nevermoreReadingControl, at: location, effectiveRange: nil) as? Bool == true
                    && !text("linked").contains("Forgejo is a self-hosted") && (storage.attribute(.toolTip, at: location, effectiveRange: nil) as? String) == forge)
            check("a square preview picture sits beside the text", forgeCard.cell.placement == .thumbnail(CGSize(width: TranscriptMedia.linkThumbnailHeight, height: TranscriptMedia.linkThumbnailHeight)))
            check("a link card names the site with the address's host, then the title and description",
                  forgeCard.cell.siteText.text.string == "Forgejo: Beyond coding. We Forge. · forge.example.com" && forgeCard.cell.titleText.text.string == "Sign in" && forgeCard.cell.summaryText.text.string.hasPrefix("Forgejo is a self-hosted"))
            if let card = frame(location) {
                let available = container.size.width - container.lineFragmentPadding * 2
                check("a preview card fills the column up to 512 points", abs(card.width - min(TranscriptMedia.linkCardMaximumWidth, available.rounded(.down))) < 1, "card \(card), container \(container.size), padding \(container.lineFragmentPadding)")
                check("a preview card is tall enough for its picture and padding", card.height >= TranscriptMedia.linkThumbnailHeight + TranscriptMedia.linkCardPadding * 2, "card \(card)")
                let narrow = forgeCard.cell.cellFrame(for: container, proposedLineFragment: NSRect(x: 0, y: 0, width: 300, height: 20), glyphPosition: NSPoint(x: container.lineFragmentPadding, y: 0), characterIndex: location)
                check("a narrow column narrows the card with it", narrow.width == 300 - container.lineFragmentPadding * 2 && (card.width <= 300 || narrow.height >= card.height), "narrow \(narrow), card \(card)")
                let center = NSPoint(x: card.midX, y: card.midY)
                let found = transcript.cardLocation(at: center)
                transcript.hoveredCardLocation = found
                let marked = forgeCard.cell.isHovered
                transcript.hoveredCardLocation = nil
                check("the pointer marks the card under it, and leaving clears the mark", found == location && marked && !forgeCard.cell.isHovered)
                transcript.hoveredCardLocation = found
                controller.transcriptDidScroll()
                check("scrolling clears the mark, since another card may now be under the pointer", transcript.hoveredCardLocation == nil && !forgeCard.cell.isHovered)
                // Links draw underlined; a card is not text and must not be.
                let below = NSRect(x: card.minX, y: card.maxY + 0.5, width: card.width, height: 3)
                let underline = opaquePixels(in: transcript, rect: below)
                check("no link underline is drawn under a card", underline == 0, "\(underline) pixels in \(below)")
            } else { check("the link card is laid out", false) }
            check("a link card speaks its title and site to VoiceOver", forgeCard.cell.accessibilityLabel() == "Link preview: Sign in, Forgejo: Beyond coding. We Forge. · forge.example.com")
        } else { check("the first link of a message gets a preview card", false) }
        if case .banner = storyCards.first?.cell.placement, let location = storyCards.first?.location, let card = frame(location) {
            let banner = TranscriptMediaLayout.bannerSize(heightRatio: 630.0 / 1200.0, width: card.width - TranscriptMedia.linkCardPadding * 2, maximumHeight: TranscriptMedia.linkBannerMaximumHeight)
            check("a landscape banner goes under the preview's text, at its own shape", banner.height > 100 && card.height > banner.height + TranscriptMedia.linkCardPadding * 2 + 30, "banner \(banner), card \(card)")
        } else { check("a landscape banner goes under the preview's text, at its own shape", false) }
        check("a preview without a picture is a text card", cards(LinkPreviewCardCell.self, in: "plain").first?.cell.placement == nil)
        check("Raven's measured picture size reaches the preview, in numbers or text", session.sentLinkPreviews.preview(for: story)?.imagePixelWidth == 1200 && session.sentLinkPreviews.preview(for: story)?.imagePixelHeight == 630)
        if let document = try? RichTextCodec.parse(#"<p><a href="mailto:a@example.com">mail</a> <a href="\#(docs)">docs</a></p>"#) {
            check("mail links never get a preview card", SentLinkPreviewPresentation.previewedLink(of: rows[0], in: document) == docs)
        }

        // Pictures.
        let photo = attachments("photo")
        let stored = TranscriptMediaLayout.fit(CGSize(width: 480, height: 320), maximumSide: TranscriptMedia.pictureMaximumSide)
        check("an image message shows its picture alone, without a file name line", photo.count == 1 && !text("photo").contains("CleanShot") && !text("photo").contains("Quick Look"))
        if let picture = photo.first {
            let tooltip = storage.attribute(.toolTip, at: picture.location, effectiveRange: nil) as? String ?? ""
            check("a picture's tooltip names its file and how to open it", tooltip.hasPrefix(screenshot) && tooltip.contains("Quick Look") && link(at: picture.location) == TranscriptStyle.attachmentLink(for: "photo"))
            check("a picture is described to VoiceOver by its file name", picture.attachment.image?.accessibilityDescription == "Image, \(screenshot)")
            check("a loaded picture keeps the box Raven stored for it", picture.attachment.bounds.size == stored)
            // In the light appearance, where a white screenshot needs its edge.
            if let image = picture.attachment.image, let pixels = NSAppearance(named: .aqua).flatMap({ light in var rep: NSBitmapImageRep?; light.performAsCurrentDrawingAppearance { rep = rasterize(image) }; return rep }) {
                let interior = pixels.colorAt(x: pixels.pixelsWide / 2, y: pixels.pixelsHigh / 2 + 20)?.alphaComponent ?? 0
                let corner = pixels.colorAt(x: 0, y: 0)?.alphaComponent ?? 1
                let edge = pixels.colorAt(x: pixels.pixelsWide / 2, y: 0)?.usingColorSpace(.sRGB)
                let inside = pixels.colorAt(x: pixels.pixelsWide / 2, y: 3)?.usingColorSpace(.sRGB)
                check("pictures have rounded corners and a hairline edge", interior > 0.99 && corner < 0.05 && (edge?.brightnessComponent ?? 1) < (inside?.brightnessComponent ?? 0) - 0.02)
            } else { check("pictures have rounded corners and a hairline edge", false) }
            check("small pictures get smaller corners, so they never turn round",
                  TranscriptMedia.cornerRadius(for: NSSize(width: 16, height: 16)) == 4 && TranscriptMedia.cornerRadius(for: NSSize(width: 320, height: 213)) == TranscriptMedia.cornerRadius)
        } else { check("the image message has a picture", false) }
        let loadedHeight = range("photo").map { controller.rect(for: $0).height }
        session.thumbnails.removeValue(forKey: "photo"); session.pictureSizes.removeValue(forKey: "photo")
        controller.render(); await controller.renderTask?.value
        layout.ensureLayout(for: container)
        let waiting = attachments("photo").first
        let waitingHeight = range("photo").map { controller.rect(for: $0).height }
        check("a picture that has not loaded keeps its box, so loading moves nothing",
              waiting?.attachment.bounds.size == stored && waitingHeight == loadedHeight, "box \(String(describing: waiting?.attachment.bounds.size)), height \(String(describing: waitingHeight)) then \(String(describing: loadedHeight))")
        if let later = attachments("later").first {
            check("a picture that cannot load yet takes the shape Raven stored and draws a placeholder",
                  later.attachment.bounds.size == CGSize(width: 160, height: 320) && (later.attachment.image.flatMap(rasterize)?.colorAt(x: 80, y: 160)?.alphaComponent ?? 0) > 0.05)
        } else { check("a picture that cannot load yet takes the shape Raven stored and draws a placeholder", false) }

        // Files.
        let file = cards(FileCardCell.self, in: "report")
        if let card = file.first, file.count == 1 {
            let detail = AttachmentDetails.summary(filename: report, byteCount: 2_400_000)
            check("a file is one card with its name, kind and size", card.cell.nameText.text.string == report && card.cell.detailText.text.string == detail && card.cell.accessibilityLabel() == "File: \(report), \(detail)")
            check("a file card opens the file and tells how in its tooltip",
                  link(at: card.location) == TranscriptStyle.attachmentLink(for: "report") && (storage.attribute(.toolTip, at: card.location, effectiveRange: nil) as? String)?.contains("Quick Look") == true)
            check("a file card is at most 280 points wide", (frame(card.location)?.width ?? .infinity) <= TranscriptMedia.fileCardWidth, "card \(String(describing: frame(card.location)))")
        } else { check("a file is one card with its name, kind and size", false) }
        let staged = TranscriptMedia.fileCard(filename: "draft.pdf", detail: "PDF document", link: nil, metrics: TranscriptMetrics(size: 14, compact: false), newLine: false, afterText: false)
        check("a file not sent yet is a card that opens nothing", staged.attribute(.link, at: 0, effectiveRange: nil) == nil && staged.attribute(.toolTip, at: 0, effectiveRange: nil) as? String == "draft.pdf")

        // Copies.
        if let first = range("linked"), let last = range("report") {
            transcript.setSelectedRange(NSRange(location: first.location, length: NSMaxRange(last) - first.location))
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("NevermoreMediaCheck-\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            pasteboard.clearContents()
            let plain = transcript.writeSelection(to: pasteboard, type: .string) ? pasteboard.string(forType: .string) ?? "" : ""
            pasteboard.clearContents()
            let rich = transcript.writeSelection(to: pasteboard, type: .rtf) ? String(decoding: pasteboard.data(forType: .rtf) ?? Data(), as: UTF8.self) : ""
            transcript.setSelectedRange(NSRange(location: 0, length: 0))
            check("copies name pictures and files and leave preview cards out",
                  plain.contains(screenshot) && plain.contains(report) && plain.contains("GoodVault ist am implementieren.") && plain.contains(forge)
                    && !plain.contains("Forgejo is a self-hosted") && !plain.contains("\u{FFFC}") && !rich.contains("nevermore-attachment"))
        } else { check("copies name pictures and files and leave preview cards out", false) }
        let printed = NSMutableAttributedString(attributedString: storage)
        TranscriptView.prepareForExport(printed, for: .print)
        var pictureCount = 0, printedPictures = 0
        storage.enumerateAttribute(.nevermorePictureName, in: NSRange(location: 0, length: storage.length)) { value, _, _ in if value != nil { pictureCount += 1 } }
        printed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: printed.length)) { value, _, _ in if (value as? NSTextAttachment)?.image != nil { printedPictures += 1 } }
        check("printouts keep pictures, name files and leave preview cards out",
              pictureCount == 2 && printedPictures == pictureCount && printed.string.contains(report) && !printed.string.contains("Forgejo is a self-hosted"))

        // Preview pictures load for cards in view and are kept under a byte
        // budget, the least recently shown let go first.
        let budgetCache = SentLinkPreviews(imageBudget: 3 * 64 * 64 * 4)
        let shown = ["a", "b", "c", "d"].map { "https://\($0).example.com/" }
        budgetCache.ingest(.object(Dictionary(uniqueKeysWithValues: shown.map { ($0, preview("Page", "", site: "", image: "https://images.example.com/tile.png")) })))
        for raw in shown.prefix(3) { if let tile = picture(width: 64, height: 64, draw: drawLogo) { budgetCache.storeImage(tile, for: raw) } }
        budgetCache.loadImage(shown[0], session: session)
        if let tile = picture(width: 64, height: 64, draw: drawLogo) { budgetCache.storeImage(tile, for: shown[3]) }
        check("the preview picture budget lets go of the least recently shown picture first",
              budgetCache.image(for: shown[0]) != nil && budgetCache.image(for: shown[1]) == nil && budgetCache.image(for: shown[2]) != nil && budgetCache.image(for: shown[3]) != nil)
        if let storyPreview = session.sentLinkPreviews.preview(for: story), let forgePreview = session.sentLinkPreviews.preview(for: forge) {
            check("preview pictures decode for the box they are drawn in",
                  SentLinkPreviews.pictureBox(for: storyPreview) == CGSize(width: 488, height: 256) && SentLinkPreviews.pictureBox(for: forgePreview) == CGSize(width: 72, height: 72))
            func placement(failed: Bool) -> TranscriptMediaLayout.PreviewPicture? {
                let card = TranscriptMedia.linkCard(storyPreview, image: nil, imageFailed: failed, metrics: TranscriptMetrics(size: 14, compact: false), afterText: true)
                return ((card.attribute(.attachment, at: card.length - 1, effectiveRange: nil) as? NSTextAttachment)?.attachmentCell as? LinkPreviewCardCell)?.placement
            }
            check("a preview picture on its way keeps its box, and one that failed leaves a text card", placement(failed: false) != nil && placement(failed: true) == nil)
        } else { check("the fixture's previews are stored", false) }

        if ProcessInfo.processInfo.environment["NEVERMORE_MEDIA_SNAPSHOTS"] == "1" {
            if let page = picture(width: 640, height: 427, draw: drawScreenshot) { session.thumbnails["photo"] = NSImage(cgImage: page, size: NSSize(width: page.width, height: page.height)) }
            await snapshots(of: controller, app: app)
        }
        return checks
    }

    /// The fixture under Classic, a light and a dark theme, as PNGs.
    private static func snapshots(of controller: ConversationWindow, app: AppDelegate) async {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreMediaSnapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let defaults = UserDefaults.standard
        let savedTheme = defaults.object(forKey: ThemeManager.DefaultsKey.theme)
        defer {
            ThemeManager.shared.select(.classic); app.applyThemeEverywhere()
            if let savedTheme { defaults.set(savedTheme, forKey: ThemeManager.DefaultsKey.theme) } else { defaults.removeObject(forKey: ThemeManager.DefaultsKey.theme) }
        }
        let shots: [(ThemeID, NSAppearance.Name?)] = [(.classic, .aqua), (.classic, .darkAqua), (.vaporwave, nil), (.synthwave, nil)]
        for (theme, forced) in shots {
            ThemeManager.shared.select(theme); app.applyThemeEverywhere()
            controller.window?.appearance = forced.flatMap { NSAppearance(named: $0) }
            controller.render(); await controller.renderTask?.value
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let transcript = controller.transcript
            transcript.hoverMessageLocation = controller.messageRanges.first { $0.1.id == "photo" }?.0.location
            transcript.layoutManager?.ensureLayout(for: transcript.textContainer!)
            let bounds = transcript.bounds
            guard let rep = transcript.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
            // The backdrop is a layer behind the transcript, which caching
            // skips: paint its top color first.
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            transcript.effectiveAppearance.performAsCurrentDrawingAppearance {
                let backdrop = ThemeManager.shared.current.palette.map { NSColor(theme: $0.gradient[0]) } ?? NSColor.textBackgroundColor
                backdrop.setFill(); NSRect(origin: .zero, size: bounds.size).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            transcript.effectiveAppearance.performAsCurrentDrawingAppearance { transcript.cacheDisplay(in: bounds, to: rep) }
            let url = folder.appendingPathComponent("media-\(theme.rawValue)\(forced == .darkAqua ? "-dark" : "").png")
            if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: url, options: .atomic)) != nil { print("MEDIA SNAPSHOT \(url.path)") }
            transcript.hoverMessageLocation = nil
            controller.window?.appearance = nil
        }
    }

    // MARK: Fixture pictures

    private static func picture(width: Int, height: Int, draw: (CGContext, CGFloat, CGFloat) -> Void) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(context, CGFloat(width), CGFloat(height))
        return context.makeImage()
    }

    /// A white document page, as a screenshot of one is.
    private static func drawScreenshot(_ context: CGContext, _ width: CGFloat, _ height: CGFloat) {
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 0.15, alpha: 1)); context.fill(CGRect(x: 0, y: height * 0.42, width: width, height: 14))
        context.setFillColor(CGColor(srgbRed: 0.55, green: 0.33, blue: 0.2, alpha: 1)); context.fill(CGRect(x: 44, y: height - 110, width: 56, height: 56))
        context.setFillColor(CGColor(gray: 0.55, alpha: 1))
        for line in 0..<6 { context.fill(CGRect(x: 44, y: height * 0.35 - CGFloat(line) * 26, width: width - 88 - CGFloat(line % 3) * 60, height: 9)) }
    }

    /// A logo on a transparent background, as many sites' preview picture is.
    private static func drawLogo(_ context: CGContext, _ width: CGFloat, _ height: CGFloat) {
        context.setLineWidth(width * 0.09); context.setLineCap(.round)
        context.setStrokeColor(CGColor(srgbRed: 1, green: 0.4, blue: 0.1, alpha: 1))
        context.addArc(center: CGPoint(x: width * 0.62, y: height * 0.72), radius: width * 0.2, startAngle: .pi, endAngle: .pi * 0.25, clockwise: true); context.strokePath()
        context.setStrokeColor(CGColor(srgbRed: 0.83, green: 0.1, blue: 0.15, alpha: 1))
        context.move(to: CGPoint(x: width * 0.3, y: height * 0.15)); context.addLine(to: CGPoint(x: width * 0.3, y: height * 0.72)); context.strokePath()
    }

    /// A landscape cover, as an article's preview picture is.
    private static func drawBanner(_ context: CGContext, _ width: CGFloat, _ height: CGFloat) {
        let colors = [CGColor(srgbRed: 0.36, green: 0.18, blue: 0.7, alpha: 1), CGColor(srgbRed: 0.2, green: 0.6, blue: 0.85, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        }
        context.setFillColor(CGColor(gray: 1, alpha: 0.85)); context.fillEllipse(in: CGRect(x: width * 0.62, y: height * 0.3, width: height * 0.4, height: height * 0.4))
    }

    // MARK: Pixels

    /// `image` drawn at its size into a bitmap.
    private static func rasterize(_ image: NSImage) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width), pixelsHigh: Int(image.size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// Pixels of `view` inside `rect` that something drew on.
    private static func opaquePixels(in view: NSView, rect: NSRect) -> Int {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return -1 }
        view.cacheDisplay(in: rect, to: rep)
        var count = 0
        for x in 0..<rep.pixelsWide { for y in 0..<rep.pixelsHigh where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 { count += 1 } }
        return count
    }
}
