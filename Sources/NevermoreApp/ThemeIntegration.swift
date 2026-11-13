import AppKit
import NevermoreCore

// MARK: - Choosing a theme

extension AppDelegate {
    /// Activates a theme in every window and plays its celebration.
    func selectTheme(_ id: ThemeID) {
        guard ThemeManager.shared.select(id) else { return }
        applyThemeEverywhere()
        guard ThemeManager.shared.playsEffects else { return }
        for window in windows where !window.isClosed && window.window?.isVisible == true {
            ThemeCelebrationPlayer.play(ThemeManager.shared.current, over: window.contentController?.view)
        }
    }

    /// Re-applies the current theme: after a choice, an edit, a decorations
    /// switch or an accessibility display change.
    func applyThemeEverywhere(transcripts: ThemeTranscriptRefresh = .now) {
        NSApp.appearance = ThemeManager.shared.appearance
        for window in windows where !window.isClosed { window.applyTheme() }
        switch transcripts {
        case .now:
            cancelPendingTranscriptRender()
            renderThemedTranscripts()
        case .coalesced:
            cancelPendingTranscriptRender()
            // Common modes: a dragged slider or color wheel runs the loop in
            // event tracking mode, and a pause in the drag counts too.
            perform(#selector(renderThemedTranscripts), with: nil, afterDelay: ThemeTranscriptRefresh.coalescingDelay, inModes: [.common])
        case .unchanged:
            // An earlier edit's pending re-render still has text to rebuild.
            break
        }
        settings?.reloadThemeControls()
        themeEditor?.reload()
    }

    private func cancelPendingTranscriptRender() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(renderThemedTranscripts), object: nil)
    }

    /// Fonts and name glows are baked into the attributed transcript.
    @objc private func renderThemedTranscripts() {
        for window in windows where !window.isClosed {
            window.render()
            window.threadInspector?.render()
        }
    }

    /// Stores the user's changes to a preset and shows them: in every
    /// window when it is the active theme, on its gallery card either way.
    func customizeTheme(_ id: ThemeID, _ customization: ThemeCustomization, transcripts: ThemeTranscriptRefresh = .coalesced) {
        guard ThemeManager.shared.setCustomization(customization, for: id) else { return }
        guard id == ThemeManager.shared.current.id else { settings?.reloadThemeControls(); return }
        applyThemeEverywhere(transcripts: transcripts)
    }

    /// Fades every theme's backdrops; the transcript's text is untouched.
    func setThemeBackdropOpacity(_ opacity: Double) {
        ThemeManager.shared.backdropOpacity = opacity
        applyThemeEverywhere(transcripts: .unchanged)
    }

    /// Opens the Customize Theme window for the active theme.
    @objc func showThemeEditor(_ sender: Any?) {
        guard !ThemeManager.shared.current.isClassic else { return }
        if themeEditor == nil { themeEditor = ThemeEditorController(app: self) }
        themeEditor?.showWindow(nil)
    }

    /// Increase Contrast hides the wallpaper and Reduce Motion skips
    /// celebrations, so follow those settings while running.
    func observeThemeAccessibility() {
        NSApp.appearance = ThemeManager.shared.appearance
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyThemeEverywhere() }
        }
    }

    @objc func chooseTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = ThemeID(rawValue: raw) else { return }
        selectTheme(id)
    }

    @objc func toggleThemeDecorations(_ sender: Any?) {
        ThemeManager.shared.decorationsEnabled.toggle()
        applyThemeEverywhere()
    }
}

/// When the transcripts are rebuilt after a theme change. Building one
/// reads the conversation from its store, which a slider or color well
/// dragged in the theme editor would otherwise start dozens of times.
enum ThemeTranscriptRefresh {
    /// Rebuild at once: a theme was chosen.
    case now
    /// Rebuild once the edits pause.
    case coalesced
    /// The change touches nothing baked into the transcript.
    case unchanged

    static let coalescingDelay: TimeInterval = 0.15
}

// MARK: - Window

extension ConversationWindow {
    /// Applies the current theme's chrome. The transcript's colors are
    /// dynamic and follow on their own; its fonts need `render()`.
    func applyTheme() {
        let manager = ThemeManager.shared
        let theme = manager.current
        themeBackdrop.apply(theme, decorations: manager.showsDecorations)
        sidebarBackdrop.apply(theme, decorations: manager.showsDecorations)
        // Classic keeps the opaque text background it always had; themes
        // let the wallpaper show through the transcript.
        transcriptScroll.drawsBackground = theme.isClassic
        composerGlass.tintColor = theme.palette.map { NSColor(theme: $0.composerTint, alpha: 0.22) }
        sendButton.contentTintColor = .themeAccent
        transcript.linkTextAttributes = Self.transcriptLinkAttributes
        updateEmptyState(for: theme)
        // Switching between two light (or two dark) themes changes no
        // appearance, so nothing invalidates views that resolved a dynamic
        // theme color; redraw them explicitly.
        window?.contentView?.markThemeSubtreeNeedsDisplay()
    }

    private func updateEmptyState(for theme: Theme) {
        let title = NSTextField(labelWithString: theme.emptyTitle)
        guard !theme.isClassic else {
            // Exactly the empty state Nevermore had before themes.
            title.font = .preferredFont(forTextStyle: .title2)
            title.textColor = .tertiaryLabelColor
            let detail = NSTextField(labelWithString: theme.emptyDetail)
            detail.textColor = .tertiaryLabelColor
            emptyConversation.setViews([title, detail], in: .center)
            return
        }
        let detail = NSTextField(wrappingLabelWithString: theme.emptyDetail)
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 320
        let titleSize = NSFont.preferredFont(forTextStyle: .title2).pointSize + 2
        title.font = ThemeFonts.senderName(ofSize: titleSize, weight: .bold)
        title.textColor = .themeText
        detail.textColor = .themeSecondaryText
        var views: [NSView] = [title, detail]
        if let motif = theme.emptyMotif {
            let art = NSImageView(image: MotifArt.image(motif, colors: Self.emptyMotifColors(theme, motif), style: Self.emptyMotifStyle(theme, motif), size: 84))
            art.imageScaling = .scaleProportionallyUpOrDown
            art.setAccessibilityElement(false)
            views.insert(art, at: 0)
        }
        emptyConversation.setViews(views, in: .center)
        emptyConversation.setCustomSpacing(12, after: views[0])
    }

    static var transcriptLinkAttributes: [NSAttributedString.Key: Any] {
        [.foregroundColor: NSColor.themeLink, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
    }

    /// The empty-state motif in the colors the wallpaper gives it.
    private static func emptyMotifColors(_ theme: Theme, _ motif: ThemeMotif) -> [ThemeColor] {
        if let spec = theme.wallpaper.motifs.first(where: { $0.motif == motif }) { return spec.colors }
        guard let palette = theme.palette else { return [] }
        return [palette.accent] + palette.nameColors
    }

    private static func emptyMotifStyle(_ theme: Theme, _ motif: ThemeMotif) -> MotifStyle {
        theme.wallpaper.motifs.first { $0.motif == motif }?.style == .glow ? .glow : .fill
    }
}

extension NSView {
    func markThemeSubtreeNeedsDisplay() {
        needsDisplay = true
        for subview in subviews { subview.markThemeSubtreeNeedsDisplay() }
    }
}

// MARK: - View ▸ Theme menu

/// Keeps the View ▸ Theme submenu's check mark on the active theme.
@MainActor final class ThemeMenuController: NSObject, NSMenuDelegate {
    static let shared = ThemeMenuController()

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Theme")
        menu.delegate = self
        for theme in ThemeCatalog.all {
            let item = NSMenuItem(title: theme.name, action: #selector(AppDelegate.chooseTheme(_:)), keyEquivalent: "")
            item.representedObject = theme.id.rawValue
            menu.addItem(item)
            if theme.isClassic { menu.addItem(.separator()) }
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Show Theme Wallpaper", action: #selector(AppDelegate.toggleThemeDecorations(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Customize Theme…", action: #selector(AppDelegate.showThemeEditor(_:)), keyEquivalent: ""))
        menuNeedsUpdate(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let current = ThemeManager.shared.current.id.rawValue
        for item in menu.items {
            if let raw = item.representedObject as? String { item.state = raw == current ? .on : .off }
            if item.action == #selector(AppDelegate.toggleThemeDecorations(_:)) { item.state = ThemeManager.shared.decorationsEnabled ? .on : .off }
        }
    }
}
