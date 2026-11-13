import AppKit
import NevermoreCore

/// Checks on customized themes: a preset takes the user's changes and keeps
/// them apart from other presets, the backdrop opacity fades what is drawn,
/// and the Customize Theme window edits, warns and resets. Runs inside
/// `ThemeSelfChecks`, which restores the user's own preferences afterwards.
@MainActor enum ThemeEditorSelfChecks {
    /// Runs the main run loop the way a mouse drag does. Synchronous, so the
    /// caller sees what happened during the drag and nothing after it.
    private static func trackEvents(for seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(mode: .eventTracking, before: end) }
    }

    static func run(app: AppDelegate, owner: ConversationWindow) async -> [(String, Bool)] {
        var checks: [(String, Bool)] = []
        func check(_ label: String, _ value: Bool) { checks.append((label, value)) }
        let manager = ThemeManager.shared
        let preset = ThemeCatalog.halloween
        guard let presetPalette = preset.palette else { return [("Halloween has a palette to customize", false)] }
        app.selectTheme(.halloween)

        // A customization applies to its preset only and is stored.
        let ink = ThemeColor(0xA0E0FF)
        var custom = ThemeCustomization()
        custom.text = ink
        custom.nameGlow = true
        custom.displayFont = ThemeCustomization.systemDisplayFont
        custom.gradient = [ThemeColor(0x102040), ThemeColor(0x401020)]
        custom.gradientAngle = 90
        custom.motifs = []
        custom.ornaments = []
        custom.emptyTitle = "Boo"
        app.customizeTheme(.halloween, custom, transcripts: .now)
        await owner.renderTask?.value
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        check("a customized text color reaches the transcript",
              ThemeSelfChecks.firstBodyColor(owner).map { ThemeSelfChecks.sameColor(ThemeSelfChecks.resolved($0, in: owner), NSColor(theme: ink)) } ?? false)
        if let header = ThemeSelfChecks.firstHeader(owner) {
            check("a customized theme can glow its sender names in the system font", header.shadow != nil && header.font?.fontName != preset.typography.displayFont)
        } else { check("the customized transcript has a sender header", false) }
        check("a customized empty-window title is shown", owner.emptyConversation.views.contains { ($0 as? NSTextField)?.stringValue == "Boo" })
        check("a customization is stored under its preset",
              ThemeCustomizationArchive.decode(UserDefaults.standard.string(forKey: ThemeManager.DefaultsKey.customizations)) == [.halloween: manager.customization(for: .halloween)]
                && manager.isCustomized(.halloween) && !manager.isCustomized(.memphis))
        check("a customized backdrop draws its own gradient",
              backdropMatches(owner, top: ThemeColor(0x102040), bottom: ThemeColor(0x401020)) && !owner.themeBackdrop.isShowingDecorations)

        // Backdrop opacity fades what every theme draws, not the theme itself.
        app.setThemeBackdropOpacity(0.5)
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        check("backdrop opacity fades the gradient toward the plain background",
              backdropMatches(owner, top: ThemeColor(0x102040).blended(over: Theme.plainDarkBackground, opacity: 0.5), bottom: ThemeColor(0x401020).blended(over: Theme.plainDarkBackground, opacity: 0.5)))
        check("backdrop opacity leaves the theme's own settings alone",
              manager.customized(.halloween).palette?.gradient == custom.gradient && manager.current.palette?.text == ink)
        check("backdrop opacity is stored", UserDefaults.standard.double(forKey: ThemeManager.DefaultsKey.backdropOpacity) == 0.5)
        app.selectTheme(.memphis)
        await owner.renderTask?.value
        owner.window?.contentView?.layoutSubtreeIfNeeded()
        if let memphis = ThemeCatalog.memphis.palette {
            check("another preset keeps its own colors and takes the same backdrop opacity",
                  manager.current.palette?.text == memphis.text
                    && manager.current.palette?.gradient == memphis.gradient.map { $0.blended(over: Theme.plainLightBackground, opacity: 0.5) }
                    && abs(manager.current.wallpaper.opacity - ThemeCatalog.memphis.wallpaper.opacity * 0.5) < 1e-9)
        }
        app.setThemeBackdropOpacity(0)
        check("a backdrop at zero opacity keeps the theme's colors and drops its art",
              !owner.themeBackdrop.isHidden && !owner.themeBackdrop.isShowingDecorations && manager.current.palette?.text == ThemeCatalog.memphis.palette?.text)
        app.setThemeBackdropOpacity(1)
        check("full backdrop opacity draws the preset unchanged", manager.current == ThemeCatalog.memphis && owner.themeBackdrop.isShowingDecorations)
        app.selectTheme(.halloween)
        await owner.renderTask?.value
        check("returning to a customized preset restores its changes", manager.current.palette?.text == ink && manager.current.emptyTitle == "Boo")

        // Edits from the editor reach the transcript once they pause.
        custom.bodyDesign = .monospaced
        app.customizeTheme(.halloween, custom)
        let chrome = manager.current.typography.bodyDesign == .monospaced && (ThemeSelfChecks.firstBodyAttribute(.font, owner) as? NSFont)?.isFixedPitch == false
        try? await Task.sleep(for: .seconds(ThemeTranscriptRefresh.coalescingDelay * 3))
        await owner.renderTask?.value
        let reading = ThemeSelfChecks.firstBodyAttribute(.font, owner) as? NSFont
        check("a coalesced edit applies at once and re-renders the transcript after a pause", chrome && reading?.isFixedPitch == true)

        // A backdrop fade leaves the transcript's text alone, so it must not
        // drop the re-render an edit is still waiting for.
        custom.bodyDesign = .serif
        app.customizeTheme(.halloween, custom)
        app.setThemeBackdropOpacity(0.9)
        try? await Task.sleep(for: .seconds(ThemeTranscriptRefresh.coalescingDelay * 3))
        await owner.renderTask?.value
        check("fading the backdrop keeps an edit's pending transcript re-render",
              (ThemeSelfChecks.firstBodyAttribute(.font, owner) as? NSFont)?.isFixedPitch == false)
        app.setThemeBackdropOpacity(1)

        // A dragged slider or color wheel runs the loop in event tracking
        // mode; a pause in the drag has to re-render there too.
        custom.bodyDesign = .monospaced
        app.customizeTheme(.halloween, custom)
        let waiting = owner.renderTask
        trackEvents(for: ThemeTranscriptRefresh.coalescingDelay * 3)
        check("an edit paused in mid-drag re-renders the transcript", owner.renderTask != waiting)
        await owner.renderTask?.value

        // Renderer caches follow the customized content, not the preset's name.
        let plain = manager.drawn(.memphis)
        var louder = ThemeCustomization()
        louder.motifOpacity = min(1, ThemeCatalog.memphis.wallpaper.opacity + 0.2)
        let sameShapes = ThemeCatalog.memphis.applying(louder)
        var starry = ThemeCustomization()
        starry.motifs = [MotifSpec(.star, [ThemeColor(0x3A3F73)])]
        let otherShapes = ThemeCatalog.memphis.applying(starry)
        let tile = WallpaperRenderer.tile(for: plain, scale: 2)
        check("a wallpaper tile is reused when only its opacity changes", tile != nil && WallpaperRenderer.tile(for: sameShapes, scale: 2) === tile)
        check("a wallpaper tile is redrawn when its motifs change", WallpaperRenderer.tile(for: otherShapes, scale: 2) !== tile)
        let light = NSAppearance(named: .aqua)
        let poster = ThemePoster.image(for: plain, size: ThemeCard.previewSize, appearance: light)
        check("a customized preset gets its own gallery poster", ThemePoster.image(for: otherShapes, size: ThemeCard.previewSize, appearance: light) !== poster)

        // The Customize Theme window.
        app.showThemeEditor(nil)
        guard let editor = app.themeEditor else { return checks + [("Customize Theme opens the editor", false)] }
        defer { editor.close() }
        check("the editor opens on the active theme", editor.window?.title == "Customize Halloween" && editor.themeID == .halloween)
        check("the editor shows the theme's current values",
              (editor.control(labeled: "Message text") as? NSColorWell).flatMap { ThemeColor(nsColor: $0.color) } == ink
                && (editor.control(labeled: "Message text design") as? NSPopUpButton)?.titleOfSelectedItem == "Monospaced"
                && (editor.control(labeled: "Empty window title") as? NSTextField)?.stringValue == "Boo")

        func choose(_ label: String, _ color: ThemeColor) {
            guard let well = editor.control(labeled: label) as? NSColorWell else { return }
            well.color = NSColor(theme: color)
            well.sendAction(well.action, to: well.target)
        }
        let accent = ThemeColor(0x33DD88)
        choose("Accent", accent)
        check("a color well edits its field of the customization",
              manager.customization(for: .halloween).accent == accent && ThemeSelfChecks.sameColor(owner.sendButton.contentTintColor.flatMap { ThemeSelfChecks.resolved($0, in: owner) }, NSColor(theme: accent)))
        choose("Sender name color 1", ThemeColor(0xFFEEDD))
        choose("Sender name color 2", ThemeColor(0xDDEEFF))
        check("two wells of one color list keep both edits",
              manager.current.palette.map { Array($0.nameColors.prefix(2)) == [ThemeColor(0xFFEEDD), ThemeColor(0xDDEEFF)] && $0.nameColors.count == presetPalette.nameColors.count } ?? false)
        if let count = editor.control(labeled: "Sender name color count") as? NSSegmentedControl {
            count.selectedSegment = 1
            count.sendAction(count.action, to: count.target)
            check("adding a name color extends the list and its wells",
                  manager.current.palette?.nameColors.count == presetPalette.nameColors.count + 1 && editor.control(labeled: "Sender name color \(presetPalette.nameColors.count + 1)") != nil)
        } else { check("the editor lists the name colors", false) }

        (editor.control(labeled: "Add Motif") as? NSButton)?.performClick(nil)
        check("Add Motif adds a wallpaper motif with its own row",
              manager.current.wallpaper.motifs.count == 1 && editor.control(labeled: "Motif 1") != nil && owner.themeBackdrop.isShowingDecorations)
        if let style = editor.control(labeled: "Motif 1 style") as? NSPopUpButton {
            style.selectItem(withTitle: "Glow")
            style.sendAction(style.action, to: style.target)
            check("a motif row edits its motif", manager.current.wallpaper.motifs.first?.style == .glow)
        } else { check("a motif row has a style control", false) }
        (editor.control(labeled: "Add Ornament") as? NSButton)?.performClick(nil)
        check("Add Ornament adds an ornament at its usual position",
              manager.current.wallpaper.ornaments.map(\.anchor) == manager.current.wallpaper.ornaments.map { OrnamentArt.usualAnchor(for: $0.kind) } && manager.current.wallpaper.ornaments.count == 1)
        (editor.control(labeled: "Remove motif 1") as? NSButton)?.performClick(nil)
        check("removing a motif removes its row", manager.current.wallpaper.motifs.isEmpty && editor.control(labeled: "Motif 1") == nil)
        if let opacity = editor.control(labeled: "Sidebar tint opacity") as? NSSlider {
            opacity.doubleValue = 0.123
            opacity.sendAction(opacity.action, to: opacity.target)
            check("an opacity slider stores hundredths", manager.customization(for: .halloween).sidebarTintOpacity == 0.12)
        } else { check("the editor has a sidebar tint opacity slider", false) }

        choose("Message text", ThemeColor(0x102040))
        check("the editor warns when text is hard to read on the backdrop", editor.warningText.contains("message text"))
        choose("Message text", ink)
        check("the warning clears when the text is readable again", !editor.warningText.contains("message text"))

        app.showSettings(nil)
        if let gallery = app.settings?.themeSettings {
            check("the gallery marks a customized preset", gallery.cards.filter(\.isCustomized).map(\.theme.id) == [.halloween] && gallery.customize.isEnabled)
            gallery.backdropOpacity.doubleValue = 0.4
            gallery.backdropOpacity.sendAction(gallery.backdropOpacity.action, to: gallery.backdropOpacity.target)
            check("the Settings slider sets the backdrop opacity", manager.backdropOpacity == 0.4 && gallery.cards.first { $0.theme.id == .memphis }?.theme == manager.drawn(.memphis))
            app.setThemeBackdropOpacity(1)
        } else { check("Settings has an Appearance gallery", false) }

        check("Reset to Preset is offered for a customized theme", editor.resetButton.isEnabled)
        editor.resetToPreset()
        await owner.renderTask?.value
        check("resetting restores the preset everywhere",
              manager.current == preset && !manager.isCustomized(.halloween) && UserDefaults.standard.string(forKey: ThemeManager.DefaultsKey.customizations) == nil)
        check("resetting updates the editor's controls",
              (editor.control(labeled: "Accent") as? NSColorWell).flatMap { ThemeColor(nsColor: $0.color) } == presetPalette.accent
                && !editor.resetButton.isEnabled && editor.control(labeled: "Sender name color \(presetPalette.nameColors.count + 1)") == nil
                && editor.control(labeled: "Motif \(preset.wallpaper.motifs.count)") != nil)

        // Classic has nothing to customize.
        let customizeItem = NSMenuItem(title: "Customize Theme…", action: #selector(AppDelegate.showThemeEditor(_:)), keyEquivalent: "")
        check("Customize Theme is available under a palette theme", app.validateMenuItem(customizeItem))
        app.selectTheme(.classic)
        check("choosing Classic closes the editor and disables customizing",
              app.themeEditor == nil && !app.validateMenuItem(customizeItem) && app.settings?.themeSettings.customize.isEnabled == false
                && app.settings?.themeSettings.backdropOpacity.isEnabled == false)
        app.showThemeEditor(nil)
        check("Classic cannot be customized", app.themeEditor == nil && ThemeCatalog.classic.applying(custom) == ThemeCatalog.classic)
        app.settings?.window?.orderOut(nil)
        app.selectTheme(.halloween)
        return checks
    }

    /// Whether the conversation backdrop's top and bottom pixels are the
    /// given colors: the gradient as Core Animation draws it.
    private static func backdropMatches(_ owner: ConversationWindow, top: ThemeColor, bottom: ThemeColor) -> Bool {
        guard let layer = owner.themeBackdrop.layer, layer.bounds.width >= 1, layer.bounds.height >= 4 else { return false }
        let width = 4, height = Int(layer.bounds.height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return false }
        layer.render(in: context)
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        func matches(row: Int, _ color: ThemeColor) -> Bool {
            let offset = row * width * 4
            let expected = [color.red, color.green, color.blue]
            // A row one pixel inside the edge is already a step into the gradient.
            return (0..<3).allSatisfy { abs(Double(pixels[offset + $0]) / 255 - expected[$0]) < 0.03 }
        }
        // Bitmap memory starts at the top row.
        return matches(row: 0, top) && matches(row: height - 1, bottom)
    }
}
