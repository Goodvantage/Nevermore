import AppKit
import NevermoreCore
import Synchronization

extension NSColor {
    convenience init(theme color: ThemeColor, alpha: CGFloat = 1) {
        self.init(srgbRed: color.red, green: color.green, blue: color.blue, alpha: alpha)
    }
}

extension ThemeColor {
    /// An `NSColor` as an opaque theme color, rounded to the 8 bits per
    /// channel themes are stored at: a color well's value then compares
    /// equal to the same color read back from user defaults or a preset.
    init?(nsColor: NSColor) {
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> UInt32 { UInt32((min(1, max(0, component)) * 255).rounded()) }
        self.init(byte(rgb.redComponent) << 16 | byte(rgb.greenComponent) << 8 | byte(rgb.blueComponent))
    }
}

/// The active theme's palette, readable from any thread. Dynamic colors
/// resolve wherever AppKit draws or lays out text, which is not always the
/// main actor, so the palette lives behind a lock rather than on
/// `ThemeManager`.
enum ActiveThemePalette {
    private static let palette = Mutex<ThemePalette?>(nil)
    static var current: ThemePalette? { palette.withLock { $0 } }
    static func set(_ value: ThemePalette?) { palette.withLock { $0 = value } }
}

/// Transcript color roles. Under Classic each role is exactly the system
/// color Nevermore used before themes, so Classic renders as it always did.
/// Under a palette theme it is a dynamic color that reads the active palette
/// whenever it is drawn, so draw-time users follow a theme switch; views
/// that store a color (a button tint, link attributes) are re-applied by
/// `ConversationWindow.applyTheme()`.
enum ThemeRole {
    case text, secondaryText, tertiaryText, accent, accentText, link, alert, codeBackground

    var color: NSColor {
        guard ActiveThemePalette.current != nil else { return systemColor }
        return NSColor(name: nil) { _ in
            guard let palette = ActiveThemePalette.current else { return systemColor }
            return switch self {
            case .text: NSColor(theme: palette.text)
            case .secondaryText: NSColor(theme: palette.secondaryText)
            // Themes audit one secondary color; a translucent tertiary
            // would fall below the contrast `ThemeAudit` guarantees.
            case .tertiaryText: NSColor(theme: palette.secondaryText)
            case .accent: NSColor(theme: palette.accent)
            // Themes audit the accent for shapes (3:1), not text; the link
            // color is the accent hue they audit as text.
            case .accentText: NSColor(theme: palette.link)
            case .link: NSColor(theme: palette.link)
            case .alert: NSColor(theme: palette.alert)
            case .codeBackground: NSColor(theme: palette.codeBackground, alpha: palette.codeBackgroundOpacity)
            }
        }
    }

    private var systemColor: NSColor {
        switch self {
        case .text: .labelColor
        case .secondaryText: .secondaryLabelColor
        case .tertiaryText: .tertiaryLabelColor
        case .accent, .accentText: .controlAccentColor
        case .link: .linkColor
        case .alert: .systemRed
        case .codeBackground: .quaternaryLabelColor.withAlphaComponent(0.12)
        }
    }
}

extension NSColor {
    static var themeText: NSColor { ThemeRole.text.color }
    static var themeSecondaryText: NSColor { ThemeRole.secondaryText.color }
    static var themeTertiaryText: NSColor { ThemeRole.tertiaryText.color }
    static var themeAccent: NSColor { ThemeRole.accent.color }
    /// Text in the accent's place, such as your own reaction counts.
    static var themeAccentText: NSColor { ThemeRole.accentText.color }
    static var themeLink: NSColor { ThemeRole.link.color }
    static var themeAlert: NSColor { ThemeRole.alert.color }
    static var themeCodeBackground: NSColor { ThemeRole.codeBackground.color }

    /// A sender's name color: one per author under a palette theme, the
    /// label color under Classic.
    static func themeName(for userID: String) -> NSColor {
        guard ActiveThemePalette.current != nil else { return .labelColor }
        return NSColor(name: nil) { _ in
            guard let palette = ActiveThemePalette.current else { return .labelColor }
            return NSColor(theme: palette.nameColor(for: userID))
        }
    }
}

/// Theme fonts. Sizes and weights follow the caller; only the face changes.
@MainActor enum ThemeFonts {
    /// Sender names: the theme's display face, else the system font.
    static func senderName(ofSize size: CGFloat, weight: NSFont.Weight = .semibold) -> NSFont {
        if let name = ThemeManager.shared.current.typography.displayFont, let font = NSFont(name: name, size: size) { return font }
        return .systemFont(ofSize: size, weight: weight)
    }

    private struct ReadingFontKey: Hashable {
        let design: ThemeBodyDesign
        let size: CGFloat
    }

    /// Matching a system design is a font-descriptor lookup of about
    /// 10 µs, and a transcript render asks once per message, so the
    /// results are kept. Keys are the few designs times the few sizes in use.
    private static var readingFonts: [ReadingFontKey: NSFont] = [:]

    /// Message bodies in the transcript. Reading text only: the composer's
    /// HTML encoder turns a fixed-pitch font into inline code.
    static func readingBody(ofSize size: CGFloat) -> NSFont {
        let bodyDesign = ThemeManager.shared.current.typography.bodyDesign
        let key = ReadingFontKey(design: bodyDesign, size: size)
        if let font = readingFonts[key] { return font }
        let base = NSFont.systemFont(ofSize: size)
        let design: NSFontDescriptor.SystemDesign? = switch bodyDesign {
        case .standard: nil
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
        let font = design.flatMap { base.fontDescriptor.withDesign($0) }.flatMap { NSFont(descriptor: $0, size: size) } ?? base
        readingFonts[key] = font
        return font
    }

    /// Extra attributes for a sender name: a soft halo for glowing themes.
    static func senderNameAttributes(for userID: String) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.themeName(for: userID)]
        if let palette = ThemeManager.shared.current.palette, palette.nameGlow {
            let glow = NSShadow()
            glow.shadowBlurRadius = 7
            glow.shadowOffset = .zero
            glow.shadowColor = NSColor(theme: palette.nameColor(for: userID), alpha: 0.85)
            attributes[.shadow] = glow
        }
        return attributes
    }
}

/// Owns the chosen preset, the user's customizations of each preset and the
/// decoration preferences. Windows read `current` when they build or
/// re-apply their look; `AppDelegate` pushes changes to every window.
@MainActor final class ThemeManager {
    static let shared = ThemeManager()

    enum DefaultsKey {
        static let theme = "theme"
        static let decorations = "themeDecorations"
        static let effects = "themeEffects"
        /// `ThemeCustomizationArchive` text: the user's changes per preset.
        static let customizations = "themeCustomizations"
        static let backdropOpacity = "themeBackdropOpacity"
        static let all = [theme, decorations, effects, customizations, backdropOpacity]
    }

    /// What the windows draw: the chosen preset with the user's
    /// customization, its backdrops at the user's opacity.
    private(set) var current: Theme
    private var customizations: [ThemeID: ThemeCustomization]

    private init() {
        customizations = ThemeCustomizationArchive.decode(UserDefaults.standard.string(forKey: DefaultsKey.customizations))
        // Self-checks start from Classic so their pixel and attribute
        // expectations do not depend on the developer's own theme;
        // `ThemeSelfChecks` exercises every theme and restores the default.
        let checking = CommandLine.arguments.contains("--self-check") || CommandLine.arguments.contains("--check-rich-text")
        current = ThemeCatalog.classic
        if !checking { current = drawn(ThemeCatalog.theme(storedAs: UserDefaults.standard.string(forKey: DefaultsKey.theme)).id) }
        ActiveThemePalette.set(current.palette)
    }

    /// The user's wallpaper switch (on unless turned off).
    var decorationsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.decorations) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.decorations) }
    }

    /// The user's switch for the theme-change celebration (on unless turned off).
    var effectsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.effects) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.effects) }
    }

    /// How strongly every theme's backdrops show, 0...1 (1 unless changed):
    /// one preference for all themes, not part of any preset. See
    /// `Theme.fadingBackdrop(to:)`.
    var backdropOpacity: Double {
        get {
            guard let stored = UserDefaults.standard.object(forKey: DefaultsKey.backdropOpacity) as? Double, stored.isFinite else { return 1 }
            return min(1, max(0, stored))
        }
        set {
            UserDefaults.standard.set(newValue.isFinite ? min(1, max(0, newValue)) : 1, forKey: DefaultsKey.backdropOpacity)
            refreshCurrent()
        }
    }

    /// Wallpaper art is drawn only when the user wants it and Increase
    /// Contrast is off; colors and fonts still apply either way.
    var showsDecorations: Bool {
        decorationsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
    }

    /// Celebrations respect Reduce Motion.
    var playsEffects: Bool {
        effectsEnabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && current.celebration != .none
    }

    /// The forced appearance for the current theme; `nil` follows the system.
    var appearance: NSAppearance? {
        switch current.tone {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Stores and activates a preset. Returns `false` when it was already active.
    @discardableResult func select(_ id: ThemeID) -> Bool {
        guard id != current.id else { return false }
        UserDefaults.standard.set(id.rawValue, forKey: DefaultsKey.theme)
        current = drawn(id)
        ActiveThemePalette.set(current.palette)
        return true
    }

    // MARK: Customizations

    /// The user's changes to a preset; empty when it is untouched.
    func customization(for id: ThemeID) -> ThemeCustomization {
        customizations[id] ?? ThemeCustomization()
    }

    func isCustomized(_ id: ThemeID) -> Bool { customizations[id] != nil }

    /// A preset with the user's changes, backdrops at full strength: the
    /// values the theme editor shows.
    func customized(_ id: ThemeID) -> Theme {
        ThemeCatalog.theme(id).applying(customization(for: id))
    }

    /// A preset as the windows would draw it now.
    func drawn(_ id: ThemeID) -> Theme {
        customized(id).fadingBackdrop(to: backdropOpacity)
    }

    /// Stores the user's changes to a preset; an empty customization resets
    /// it. Returns `false` when nothing changed.
    @discardableResult func setCustomization(_ customization: ThemeCustomization, for id: ThemeID) -> Bool {
        let normalized = customization.normalized(for: ThemeCatalog.theme(id))
        guard normalized != self.customization(for: id) else { return false }
        customizations[id] = normalized.isEmpty ? nil : normalized
        if let text = ThemeCustomizationArchive.encode(customizations) {
            UserDefaults.standard.set(text, forKey: DefaultsKey.customizations)
        } else {
            UserDefaults.standard.removeObject(forKey: DefaultsKey.customizations)
        }
        if id == current.id { refreshCurrent() }
        return true
    }

    /// Re-reads the customizations after user defaults were replaced
    /// underneath the manager (the self-checks restoring the user's own).
    func reloadStoredCustomizations() {
        customizations = ThemeCustomizationArchive.decode(UserDefaults.standard.string(forKey: DefaultsKey.customizations))
        refreshCurrent()
    }

    private func refreshCurrent() {
        current = drawn(current.id)
        ActiveThemePalette.set(current.palette)
    }
}
