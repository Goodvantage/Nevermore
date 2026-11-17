import AppKit
import RavenProtocol

/// Real source-list cells, with disposable accounts and an in-memory photo.
@MainActor enum SidebarAvatarSelfChecks {
    static func run(app: AppDelegate) throws -> [(String, Bool)] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NevermoreSidebarAvatarCheck-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let account = Account(origin: URL(string: "https://demo.invalid")!, user: "self", siteName: "Fixture", clientID: "demo")
        let session = try AccountSession(account: account, directory: root.appendingPathComponent("first"), demo: true)
        defer { session.stop() }
        func dm(_ id: String, peer: String) -> RavenChannel {
            RavenChannel(raw: .object(["name": .string(id), "channel_name": .string(id), "is_direct_message": .bool(true), "peer_user_id": .string(peer)]))
        }
        let direct = dm("direct", peer: "peer"), own = dm("You", peer: "self"), missing = dm("missing", peer: "no-photo")
        let channel = RavenChannel(raw: .object(["name": .string("channel"), "channel_name": .string("channel"), "peer_user_id": .string("peer")]))
        session.channels = [direct, own, missing, channel]
        session.activeUsers = ["peer"]
        let photo = stripedPhoto()
        session.avatars = ["peer": photo, "self": photo]
        let controller = ConversationWindow(app: app, session: session)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        func cell(_ channel: RavenChannel) -> SidebarConversationCell? {
            guard let row = controller.sidebarItems.firstIndex(where: { $0.channel?.id == channel.id }) else { return nil }
            let cell = controller.sidebar.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarConversationCell
            cell?.layoutSubtreeIfNeeded()
            return cell
        }
        var results: [(String, Bool)] = []
        guard let directCell = cell(direct), let icon = directCell.imageView else { return [("the sidebar creates its DM cell", false)] }
        results.append(("DM and self-message rows show their peer's cached profile photo", icon.image === photo && cell(own)?.imageView?.image === photo))
        let generated = cell(missing)?.imageView?.image
        results.append(("photo-less DMs get ravens and channels get separate generated tiles", generated != nil && generated?.isTemplate == false && cell(channel)?.imageView?.image === session.channelAvatarImage(for: channel) && cell(channel)?.imageView?.image !== photo))
        results.append(("the sidebar and transcript share the same generated user image", generated != nil && controller.transcript.avatarImage?("no-photo") === generated && session.avatars["no-photo"] == nil))
        session.userNames["no-photo"] = "A changed display name"
        results.append(("display-name changes and unread counts do not reshuffle generated ravens", controller.sidebarModel(for: missing, unread: 7).photo === generated))
        for field in ["is_archived", "is_thread"] {
            let typedDM = RavenChannel(raw: .object(["name": .string(field), "is_direct_message": .bool(true), "peer_user_id": .string("no-photo"), field: .bool(true)]))
            results.append(("\(field) DMs retain their type icon instead of a generated portrait", controller.sidebarModel(for: typedDM, unread: 0).photo == nil))
        }
        session.avatars.removeValue(forKey: "self")
        NotificationCenter.default.post(name: .sessionAvatarsChanged, object: session)
        results.append(("self-message portraits use the username rather than the You label", cell(own)?.imageView?.image === session.avatarImage(for: "self") && cell(own)?.imageView?.image !== session.avatarImage(for: "You")))
        results.append(("a profile photo keeps the presence label and dot", directCell.accessibilityLabel()?.contains("Active") == true && directCell.subviews.contains { !$0.isHidden && $0.layer?.cornerRadius == 3.5 }))
        directCell.backgroundStyle = .emphasized
        icon.cell?.backgroundStyle = .emphasized
        // Compare with an independent, ordinary AppKit image view in the same
        // window. Native color management need not preserve literal RGB bytes;
        // selection must preserve the colors a normal image view would show.
        let reference = NSImageView(frame: icon.bounds)
        reference.image = stripedPhoto()
        reference.imageScaling = .scaleAxesIndependently
        controller.contentController.view.addSubview(reference)
        controller.window?.displayIfNeeded()
        icon.display(); reference.display(); CATransaction.flush()
        if let bitmap = icon.bitmapImageRepForCachingDisplay(in: icon.bounds),
           let plain = reference.bitmapImageRepForCachingDisplay(in: reference.bounds) {
            icon.cacheDisplay(in: icon.bounds, to: bitmap)
            reference.cacheDisplay(in: reference.bounds, to: plain)
            let expected = plain.colorAt(x: plain.pixelsWide / 2, y: plain.pixelsHigh / 2)?.usingColorSpace(.sRGB)
            let center = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
            let corner = bitmap.colorAt(x: 0, y: 0)
            let sameColors = [bitmap.pixelsWide / 4, bitmap.pixelsWide / 2, bitmap.pixelsWide * 3 / 4].allSatisfy { x in
                guard let expected, let color = bitmap.colorAt(x: x, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) else { return false }
                return abs(color.redComponent - expected.redComponent) < 0.04 && abs(color.greenComponent - expected.greenComponent) < 0.04 && abs(color.blueComponent - expected.blueComponent) < 0.04 && color.alphaComponent > 0.95
            }
            let greenReference = expected.map { $0.greenComponent > $0.redComponent + 0.3 && $0.greenComponent > $0.blueComponent + 0.3 && $0.alphaComponent > 0.95 } == true
            let correct = greenReference && abs(icon.bounds.width - icon.bounds.height) < 0.1 && (corner?.alphaComponent ?? 1) < 0.1 && sameColors
            if !correct { print("DIAGNOSTIC sidebar photo bounds=\(icon.bounds) center=\(String(describing: center)) reference=\(String(describing: expected)) corner=\(String(describing: corner)) vibrant=\(icon.allowsVibrancy)") }
            results.append(("selected sidebar photos are circular, center-cropped and retain their colors", correct))
        } else { results.append(("a sidebar profile photo can be drawn", false)) }
        reference.removeFromSuperview()
        // This point lies inside a rounded tile but outside a circular photo.
        // Exercise the actual view across reuse, including selected rows.
        func outerCoverage() -> CGFloat {
            icon.display()
            guard let bitmap = icon.bitmapImageRepForCachingDisplay(in: icon.bounds) else { return -1 }
            icon.cacheDisplay(in: icon.bounds, to: bitmap)
            return bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * 0.12),
                                  y: Int(Double(bitmap.pixelsHigh) * 0.12))?.alphaComponent ?? -1
        }
        let originalPhotoCoverage = outerCoverage()
        directCell.configure(controller.sidebarModel(for: channel, unread: 0), fontSize: controller.sidebarFontSize)
        results.append(("a selected photo row reused for a channel preserves the square tile outline", outerCoverage() > 0.95))
        directCell.configure(controller.sidebarModel(for: direct, unread: 0), fontSize: controller.sidebarFontSize)
        let photoCoverage = outerCoverage()
        // The circle's antialiased border varies with the row's fractional
        // position. Compare with this same view before reuse, not a fixed alpha.
        results.append(("a channel row reused for an uploaded photo restores the circular crop", originalPhotoCoverage >= 0 && originalPhotoCoverage < 0.9 && abs(photoCoverage - originalPhotoCoverage) < 0.02))
        directCell.configure(controller.sidebarModel(for: missing, unread: 0), fontSize: controller.sidebarFontSize)
        results.append(("reusing a photo row restores the correct generated raven", icon.image === generated && icon.image !== photo))
        directCell.configure(controller.sidebarModel(for: direct, unread: 0), fontSize: controller.sidebarFontSize)
        session.avatars.removeValue(forKey: "peer")
        session.notify()
        results.append(("directory invalidation replaces a stale photo with that user's raven", cell(direct)?.imageView?.image === session.avatarImage(for: "peer") && cell(direct)?.imageView?.image !== photo))
        session.avatars["peer"] = photo
        let waitingCell = cell(direct)
        NotificationCenter.default.post(name: .sessionAvatarsChanged, object: session)
        results.append(("an avatar arrival updates an existing sidebar cell without opening the DM", waitingCell?.imageView?.image === photo && controller.channel == nil))

        session.channels = (0..<120).map { dm("scroll-\($0)", peer: "peer-\($0)") }
        controller.refreshSidebar()
        if let row = controller.sidebarItems.firstIndex(where: { $0.channel?.id == "scroll-80" }) {
            _ = controller.sidebar.rowView(atRow: row, makeIfNecessary: true)
            _ = controller.sidebar.view(atColumn: 0, row: row, makeIfNecessary: true)
            session.avatars["peer-80"] = photo
            NotificationCenter.default.post(name: .sessionAvatarsChanged, object: session)
            controller.sidebar.scrollRowToVisible(row)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let revealed = controller.sidebar.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarConversationCell
            results.append(("a prefetched offscreen row shows its loaded photo when scrolled into view", revealed?.imageView?.image === photo))
        } else { results.append(("the scrolling fixture creates its distant DM", false)) }

        let otherAccount = Account(origin: URL(string: "https://other.invalid")!, user: "other-self", siteName: "Other fixture", clientID: "demo")
        let second = try AccountSession(account: otherAccount, directory: root.appendingPathComponent("second"), demo: true)
        defer { second.stop() }
        second.channels = [direct]
        controller.use(second)
        NotificationCenter.default.post(name: .sessionAvatarsChanged, object: session)
        results.append(("switching accounts cannot show the previous account's peer photo", cell(direct)?.imageView?.image === second.avatarImage(for: "peer") && cell(direct)?.imageView?.image !== photo))
        results.append(("unknown usernames have no fabricated identity", second.avatarImage(for: "") == nil))
        second.stop()
        results.append(("stopped accounts cannot regenerate cached avatars", second.avatarImage(for: "peer") == nil))
        return results
    }

    private static func stripedPhoto() -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        // Explicit RGBA samples: named NSColors are not necessarily in the
        // bitmap's device color space, and setColor can leave pixels empty.
        for y in 0..<20 { for x in 0..<60 {
            var pixel = x < 20 ? [255, 0, 0, 255] : x < 40 ? [0, 255, 0, 255] : [0, 0, 255, 255]
            bitmap.setPixel(&pixel, atX: x, y: y)
        } }
        // A known source profile and sRGB assertions avoid comparing unrelated
        // device RGB values on different displays (including the CI Mac).
        let image = NSImage(size: NSSize(width: 60, height: 20)); image.addRepresentation(bitmap.retagging(with: .sRGB)!)
        return image
    }
}
