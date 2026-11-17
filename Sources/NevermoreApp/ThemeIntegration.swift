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
        home.applyTheme()
        // Switching between two light (or two dark) themes changes no
        // appearance, so nothing invalidates views that resolved a dynamic
        // theme color; redraw them explicitly.
        window?.contentView?.markThemeSubtreeNeedsDisplay()
    }

    /// The pane without an account; with one, Home takes its place. The
    /// words are the same in every theme: a theme never puts its own
    /// phrase where the reader expects an instruction.
    private func updateEmptyState(for theme: Theme) {
        let color: NSColor = theme.isClassic ? .tertiaryLabelColor : .themeSecondaryText
        let title = NSTextField(labelWithString: ConversationWindow.noAccountTitle)
        title.font = .preferredFont(forTextStyle: .title2)
        title.textColor = color
        let detail = NSTextField(labelWithString: ConversationWindow.noAccountDetail)
        detail.textColor = color
        emptyConversation.setViews([title, detail], in: .center)
    }

    static let noAccountTitle = "No Account"
    static let noAccountDetail = "Add an account to read your conversations."

    static var transcriptLinkAttributes: [NSAttributedString.Key: Any] {
        [.foregroundColor: NSColor.themeLink, .underlineStyle: NSUnderlineStyle.single.rawValue, .cursor: NSCursor.pointingHand]
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
