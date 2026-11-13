import AppKit
import NevermoreCore

/// Theme checks on the demo window: every theme applies its appearance,
/// wallpaper, glass tint, fonts and transcript colors; Classic restores the
/// system look; the art draws; the composer never inherits a reading font.
/// The user's stored theme preferences are restored afterwards.
@MainActor enum ThemeSelfChecks {
    static func run(app: AppDelegate, owner: ConversationWindow) async -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        let keys = ThemeManager.DefaultsKey.all
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        let originalTheme = ThemeManager.shared.current.id
        defer {
            app.themeEditor?.close()
            ThemeManager.shared.select(originalTheme)
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
            }
            ThemeManager.shared.reloadStoredCustomizations()
            app.applyThemeEverywhere()
        }
        // The presets are checked as shipped: without the user's own
        // customizations and backdrop opacity.
        for id in ThemeID.allCases { ThemeManager.shared.setCustomization(ThemeCustomization(), for: id) }
        ThemeManager.shared.backdropOpacity = 1
        ThemeManager.shared.effectsEnabled = false
        ThemeManager.shared.decorationsEnabled = true
        app.selectTheme(.classic)
        app.applyThemeEverywhere()
        await owner.renderTask?.value
        owner.window?.contentView?.layoutSubtreeIfNeeded()

        check("Classic keeps the system appearance, opaque transcript and plain glass",
              NSApp.appearance == nil && owner.themeBackdrop.isHidden && owner.sidebarBackdrop.isHidden && owner.transcriptScroll.drawsBackground && owner.composerGlass.tintColor == nil)
        check("Classic keeps the original empty-state text",
              (owner.emptyConversation.views.first as? NSTextField)?.stringValue == "No Conversation Selected")
        check("Classic keeps the original empty-state layout", hasClassicEmptyLayout(owner))
        if let header = firstHeader(owner) {
            check("Classic sender names keep the label color", resolved(header.nameColor, in: owner) == resolved(.labelColor, in: owner))
        } else { check("transcript has a sender header to inspect", false) }
        let classicChips = chipColors(in: owner)
        check("Classic reaction chips keep the system colors",
              classicChips.mine == resolved(.controlAccentColor, in: owner) && classicChips.theirs == resolved(.secondaryLabelColor, in: owner))

        for theme in ThemeCatalog.all where !theme.isClassic {
            app.selectTheme(theme.id)
            await owner.renderTask?.value
            owner.window?.contentView?.layoutSubtreeIfNeeded()
            guard let palette = theme.palette else { continue }
            let tag = theme.name
            let dark = theme.tone == .dark
            check("\(tag) forces the \(dark ? "dark" : "light") appearance", NSApp.appearance?.name == (dark ? .darkAqua : .aqua))
            check("\(tag) is stored as the chosen theme", UserDefaults.standard.string(forKey: ThemeManager.DefaultsKey.theme) == theme.id.rawValue)
            check("\(tag) shows its wallpaper under a clear transcript",
                  !owner.themeBackdrop.isHidden && owner.themeBackdrop.isShowingDecorations == !theme.wallpaper.isEmpty && !owner.transcriptScroll.drawsBackground && !owner.sidebarBackdrop.isHidden)
            check("\(tag) tints the composer glass", owner.composerGlass.tintColor != nil)
            if let header = firstHeader(owner) {
                let expected = NSColor(theme: palette.nameColor(for: header.authorID))
                check("\(tag) colors each sender name from its palette", sameColor(resolved(header.nameColor, in: owner), expected))
                if let display = theme.typography.displayFont, NSFont(name: display, size: 12) != nil {
                    check("\(tag) sets sender names in \(display)", header.font?.fontName == display)
                }
                check("\(tag) glows sender names only when it asks to", (header.shadow != nil) == palette.nameGlow)
                check("\(tag) colors avatars like their sender's name",
                      header.avatar.map { sameColor(resolved($0.color, in: owner), expected) } ?? owner.transcript.metrics.compact)
            }
            let chips = chipColors(in: owner)
            // Your own count is text, so it takes the link color, which the
            // audit holds to text contrast; the accent is audited for shapes.
            check("\(tag) sets reaction counts in audited text colors",
                  sameColor(chips.mine, NSColor(theme: palette.link)) && sameColor(chips.theirs, NSColor(theme: palette.secondaryText)))
            if let body = firstBodyColor(owner) {
                check("\(tag) colors message text from its palette", sameColor(resolved(body, in: owner), NSColor(theme: palette.text)))
            } else { check("\(tag) transcript has body text to inspect", false) }
            if theme.emptyMotif != nil {
                check("\(tag) puts its art in the empty state", owner.emptyConversation.views.first is NSImageView)
            }
        }

        // Two light themes in a row change no appearance; the dynamic
        // colors must still follow.
        app.selectTheme(.memphis)
        await owner.renderTask?.value
        app.selectTheme(.bubblegum)
        await owner.renderTask?.value
        if let body = firstBodyColor(owner), let palette = ThemeCatalog.bubblegum.palette {
            check("switching between two light themes recolors the transcript", sameColor(resolved(body, in: owner), NSColor(theme: palette.text)))
        }

        // The composer and its HTML never take a theme's reading font.
        app.selectTheme(.phosphor)
        let document = RichDocument(nodes: [.element("p", [:], [.text("plain words")])], canEdit: true)
        let reading = NativeRichText.readingString(document: document, fontSize: 14)
        let editing = NativeRichText.attributedString(document: document, fontSize: 14)
        let readingFont = reading.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let editingFont = editing.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        check("a monospaced theme sets reading text in a fixed-pitch face", readingFont?.isFixedPitch == true)
        check("the composer keeps the proportional system font under a monospaced theme", editingFont?.isFixedPitch == false)
        check("composer text under a monospaced theme does not encode as code", !((try? RichTextCodec.html(NativeRichText.document(from: editing))) ?? "<code>").contains("<code>"))
        for themeID: ThemeID in [.bubblegum, .nevermore] {
            app.selectTheme(themeID)
            let body = ThemeFonts.readingBody(ofSize: 14)
            let bold = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
            check("\(ThemeCatalog.theme(themeID).name) body text still takes bold", NSFontManager.shared.traits(of: bold).contains(.boldFontMask))
        }

        // Wallpaper switch and Increase Contrast path.
        app.selectTheme(.halloween)
        ThemeManager.shared.decorationsEnabled = false
        app.applyThemeEverywhere()
        check("turning the wallpaper off keeps the theme's colors but drops its art", !owner.themeBackdrop.isHidden && !owner.themeBackdrop.isShowingDecorations && NSApp.appearance?.name == .darkAqua)
        ThemeManager.shared.decorationsEnabled = true
        app.applyThemeEverywhere()

        // Menu and Settings mirror the choice.
        if let menu = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu?.items.first(where: { $0.title == "Theme" })?.submenu {
            ThemeMenuController.shared.menuNeedsUpdate(menu)
            let checked = menu.items.filter { $0.state == .on && $0.representedObject != nil }.map(\.title)
            check("View ▸ Theme checks only the active theme", checked == ["Halloween"])
            check("View ▸ Theme lists every theme", menu.items.filter { $0.representedObject != nil }.count == ThemeCatalog.all.count)
        } else { check("View ▸ Theme menu exists", false) }
        app.showSettings(nil)
        if let gallery = app.settings?.themeSettings {
            let chosen = gallery.cards.filter(\.isChosen).map(\.theme.id)
            check("Settings marks the active theme's card", chosen == [.halloween])
            check("theme cards are accessible radio buttons", gallery.cards.allSatisfy { $0.accessibilityRole() == .radioButton && $0.accessibilityLabel() == $0.theme.name })
            check("theme cards report which one is chosen", gallery.cards.allSatisfy { ($0.accessibilityValue() as? Int) == ($0.isChosen ? 1 : 0) })
            let preview = ThemePoster.image(for: ThemeCatalog.memphis, size: ThemeCard.previewSize, appearance: NSAppearance(named: .aqua))
            app.selectTheme(.lemonade)
            check("switching themes keeps gallery previews cached",
                  ThemePoster.image(for: ThemeCatalog.memphis, size: ThemeCard.previewSize, appearance: NSAppearance(named: .aqua)) === preview)
            gallery.cards.first { $0.theme.id == .meadow }?.performClick(nil)
            check("clicking a card applies its theme", ThemeManager.shared.current.id == .meadow && NSApp.appearance?.name == .aqua)
        } else { check("Settings has an Appearance gallery", false) }
        app.settings?.window?.orderOut(nil)

        // Celebrations add a temporary overlay and leave nothing behind.
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let host = owner.contentController?.view {
            ThemeCelebrationPlayer.play(ThemeCatalog.memphis, over: host)
            check("a celebration plays above the conversation", host.subviews.last?.layer?.sublayers?.contains { $0 is CAEmitterLayer } == true)
            check("a celebration takes no clicks", host.subviews.last?.hitTest(NSPoint(x: 10, y: 10)) == nil)
            if let overlay = host.subviews.last {
                // The overlay resizes with the window; its emitter must too.
                overlay.setFrameSize(NSSize(width: overlay.bounds.width + 120, height: overlay.bounds.height + 60))
                check("a celebration follows a window resize", overlay.layer?.sublayers?.first { $0 is CAEmitterLayer }?.frame == overlay.bounds)
            }
            host.subviews.last.flatMap { $0.layer?.sublayers?.contains { $0 is CAEmitterLayer } == true ? $0 : nil }?.removeFromSuperview()
        }

        // Every motif and ornament draws something, inside its bounds.
        for motif in ThemeMotif.allCases {
            let coverage = inkCoverage(width: 64, height: 64) { context in
                MotifArt.draw(motif, in: CGRect(x: 8, y: 8, width: 48, height: 48), colors: [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor], style: .fill, context: context)
            }
            check("motif \(motif.rawValue) draws a visible shape", coverage.inside > 0.04 && coverage.outside < 0.01)
        }
        for kind in OrnamentKind.allCases {
            let coverage = inkCoverage(width: 400, height: 300) { context in
                OrnamentShapes.draw(kind, anchor: kind == .scanlines ? .fill : .bottom, in: CGRect(x: 0, y: 0, width: 400, height: 300), colors: [NSColor.black.cgColor, NSColor.black.cgColor], context: context)
            }
            check("ornament \(kind.rawValue) draws", coverage.inside > 0.005)
        }

        for kind in OrnamentKind.allCases {
            let drawn = OrnamentAnchor.allCases.allSatisfy { anchor in
                inkCoverage(width: 400, height: 300) { context in
                    OrnamentShapes.draw(kind, anchor: anchor, in: CGRect(x: 0, y: 0, width: 400, height: 300), colors: [NSColor.black.cgColor], context: context)
                }.inside > 0
            }
            check("ornament \(kind.rawValue) draws at every position, in one color", drawn)
        }

        for (label, result) in await ThemeEditorSelfChecks.run(app: app, owner: owner) { check(label, result) }

        app.selectTheme(.classic)
        await owner.renderTask?.value
        check("returning to Classic restores the system look",
              NSApp.appearance == nil && owner.themeBackdrop.isHidden && owner.transcriptScroll.drawsBackground && owner.composerGlass.tintColor == nil)
        check("returning to Classic restores the original empty-state layout", hasClassicEmptyLayout(owner))
        return checks
    }

    /// The empty state Nevermore had before themes: a title over one
    /// unwrapped line, six points apart.
    private static func hasClassicEmptyLayout(_ owner: ConversationWindow) -> Bool {
        let stack = owner.emptyConversation
        guard stack.views.count == 2, let detail = stack.views.last as? NSTextField else { return false }
        return detail.cell?.wraps == false && stack.spacing == 6 && stack.customSpacing(after: stack.views[0]) == NSStackView.useDefaultSpacing
    }

    struct Header { let authorID: String; let nameColor: NSColor; let font: NSFont?; let shadow: NSShadow?; let avatar: TranscriptAvatar? }

    /// The first sender name in the transcript and its author.
    static func firstHeader(_ owner: ConversationWindow) -> Header? {
        guard let storage = owner.transcript.textStorage else { return nil }
        for (range, message) in owner.messageRanges where range.length > 0 && range.location < storage.length {
            let name = owner.session?.authorName(message) ?? message.owner
            guard (storage.string as NSString).substring(with: range).hasPrefix(name) else { continue }
            let attributes = storage.attributes(at: range.location, effectiveRange: nil)
            guard let color = attributes[.foregroundColor] as? NSColor else { continue }
            return Header(authorID: message.authorID, nameColor: color, font: attributes[.font] as? NSFont, shadow: attributes[.shadow] as? NSShadow,
                          avatar: attributes[.nevermoreAvatar] as? TranscriptAvatar)
        }
        return nil
    }

    /// Text colors of a reaction that includes yours and one that does not.
    /// The demo transcript has no reactions under the self-check, so the
    /// chips are rendered directly.
    private static func chipColors(in owner: ConversationWindow) -> (mine: NSColor?, theirs: NSColor?) {
        let chips = TranscriptStyle.reactions([ReactionChip(label: "👍", count: 2, includesCurrentUser: true), ReactionChip(label: "🎉", count: 1, includesCurrentUser: false)],
                                              metrics: owner.transcript.metrics)
        var colors: [Bool: NSColor] = [:]
        chips.enumerateAttribute(.nevermoreReactionChip, in: NSRange(location: 0, length: chips.length)) { value, range, _ in
            guard let mine = value as? Bool else { return }
            colors[mine] = chips.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }
        return (colors[true].flatMap { resolved($0, in: owner) }, colors[false].flatMap { resolved($0, in: owner) })
    }

    /// The color of the first message's body text (the line after its header).
    static func firstBodyColor(_ owner: ConversationWindow) -> NSColor? {
        firstBodyAttribute(.foregroundColor, owner) as? NSColor
    }

    static func firstBodyAttribute(_ key: NSAttributedString.Key, _ owner: ConversationWindow) -> Any? {
        guard let storage = owner.transcript.textStorage, let (range, _) = owner.messageRanges.first(where: { $0.0.length > 0 }) else { return nil }
        let text = storage.string as NSString
        let newline = text.range(of: "\n", options: [], range: range)
        guard newline.location != NSNotFound, newline.location + 1 < NSMaxRange(range) else { return nil }
        return storage.attribute(key, at: newline.location + 1, effectiveRange: nil)
    }

    static func resolved(_ color: NSColor, in owner: ConversationWindow) -> NSColor? {
        var result: NSColor?
        (owner.window?.effectiveAppearance ?? NSApp.effectiveAppearance).performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB)
        }
        return result
    }

    static func sameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
        guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01 && abs(a.blueComponent - b.blueComponent) < 0.01
    }

    /// Fraction of pixels with ink inside the drawing and in a 4-pixel frame
    /// around the edge (motifs must keep their padding).
    private static func inkCoverage(width: Int, height: Int, draw: (CGContext) -> Void) -> (inside: Double, outside: Double) {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return (0, 1) }
        draw(context)
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var inside = 0, outside = 0, frame = 0
        for y in 0..<height {
            for x in 0..<width {
                let inked = pixels[(y * width + x) * 4 + 3] > 24
                let edge = x < 4 || y < 4 || x >= width - 4 || y >= height - 4
                if edge { frame += 1; if inked { outside += 1 } } else if inked { inside += 1 }
            }
        }
        return (Double(inside) / Double(width * height - frame), Double(outside) / Double(max(1, frame)))
    }
}
