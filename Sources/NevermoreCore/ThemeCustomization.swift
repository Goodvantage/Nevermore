import Foundation

/// The user's changes to one preset theme. The catalog's themes are presets:
/// each field here replaces the matching preset value and `nil` keeps it, so
/// a preset improved in a later version still reaches every field the user
/// left alone, and "reset" is simply an empty customization.
///
/// Values arrive from user defaults, which can be hand-edited or written by
/// another version, so nothing here is trusted: decoding skips fields it
/// cannot read and `sanitized` drops values outside what the renderer
/// supports.
public struct ThemeCustomization: Sendable, Equatable, Codable {
    /// Bounds on what a stored customization may ask the renderer to draw.
    public enum Limit {
        public static let gradientStops = 2...4
        public static let nameColors = 1...12
        public static let colorsPerShape = 1...6
        public static let motifs = 12
        public static let ornaments = 6
        public static let fontNameLength = 128
    }

    /// Light or dark only: a palette theme cannot follow the system.
    public var tone: ThemeTone?
    public var gradient: [ThemeColor]?
    public var gradientAngle: Double?
    public var sidebarTint: ThemeColor?
    public var sidebarTintOpacity: Double?
    public var composerTint: ThemeColor?
    public var text: ThemeColor?
    public var secondaryText: ThemeColor?
    public var accent: ThemeColor?
    public var link: ThemeColor?
    public var alert: ThemeColor?
    public var nameColors: [ThemeColor]?
    public var nameGlow: Bool?
    /// A PostScript name. The empty string asks for the system font, which
    /// `nil` cannot say: `nil` keeps the preset's face.
    public var displayFont: String?
    public var bodyDesign: ThemeBodyDesign?
    public var motifs: [MotifSpec]?
    public var density: ThemeDensity?
    public var motifOpacity: Double?
    public var ornaments: [OrnamentSpec]?
    public var celebration: ThemeCelebration?

    public init() {}

    /// The spelling of "system font" in `displayFont`.
    public static let systemDisplayFont = ""

    public var isEmpty: Bool { self == ThemeCustomization() }

    /// Lenient per field: one unreadable value (a mistyped color) loses that
    /// field, not the whole customization. The motif and ornament lists are
    /// lenient per entry, so a shape a later version removed costs that
    /// shape and keeps the rest of the user's wallpaper.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys) -> T? { (try? container.decodeIfPresent(T.self, forKey: key)) ?? nil }
        func entries<T: Decodable>(_ key: CodingKeys) -> [T]? {
            guard let stored: [Lenient<T>] = value(key) else { return nil }
            return Self.usable(stored.compactMap(\.value), of: stored.count)
        }
        tone = value(.tone)
        gradient = value(.gradient)
        gradientAngle = value(.gradientAngle)
        sidebarTint = value(.sidebarTint)
        sidebarTintOpacity = value(.sidebarTintOpacity)
        composerTint = value(.composerTint)
        text = value(.text)
        secondaryText = value(.secondaryText)
        accent = value(.accent)
        link = value(.link)
        alert = value(.alert)
        nameColors = value(.nameColors)
        nameGlow = value(.nameGlow)
        displayFont = value(.displayFont)
        bodyDesign = value(.bodyDesign)
        motifs = entries(.motifs)
        density = value(.density)
        motifOpacity = value(.motifOpacity)
        ornaments = entries(.ornaments)
        celebration = value(.celebration)
    }

    /// This customization without the values the renderer cannot honor.
    /// Out-of-range numbers are clamped; anything else invalid is dropped,
    /// which falls back to the preset's value.
    public var sanitized: ThemeCustomization {
        var result = self
        if tone == .system { result.tone = nil }
        if let gradient, !Limit.gradientStops.contains(gradient.count) { result.gradient = nil }
        result.gradientAngle = gradientAngle.flatMap(Self.wrappedAngle)
        result.sidebarTintOpacity = sidebarTintOpacity.flatMap(Self.unitInterval)
        result.motifOpacity = motifOpacity.flatMap(Self.unitInterval)
        if let nameColors, !Limit.nameColors.contains(nameColors.count) { result.nameColors = nil }
        if let displayFont, displayFont.count > Limit.fontNameLength { result.displayFont = nil }
        result.motifs = motifs.flatMap { specs in
            let kept = specs.filter { !$0.colors.isEmpty }.prefix(Limit.motifs)
                .map { MotifSpec($0.motif, Array($0.colors.prefix(Limit.colorsPerShape.upperBound)), style: $0.style, weight: $0.weight) }
            return Self.usable(kept, of: specs.count)
        }
        result.ornaments = ornaments.flatMap { specs in
            let kept = specs.filter { !$0.colors.isEmpty && $0.opacity.isFinite }.prefix(Limit.ornaments)
                .map { OrnamentSpec($0.kind, $0.anchor, Array($0.colors.prefix(Limit.colorsPerShape.upperBound)), opacity: $0.opacity) }
            return Self.usable(kept, of: specs.count)
        }
        return result
    }

    /// The sanitized customization without the fields that only repeat
    /// `preset`, so an edit dragged back to the preset's value counts as no
    /// edit. Classic has no palette to customize and always yields none.
    public func normalized(for preset: Theme) -> ThemeCustomization {
        guard let palette = preset.palette else { return ThemeCustomization() }
        var result = sanitized
        func prune<Value: Equatable>(_ field: WritableKeyPath<ThemeCustomization, Value?>, _ presetValue: Value) {
            if result[keyPath: field] == presetValue { result[keyPath: field] = nil }
        }
        prune(\.tone, preset.tone)
        prune(\.gradient, palette.gradient)
        prune(\.gradientAngle, palette.gradientAngle)
        prune(\.sidebarTint, palette.sidebarTint)
        prune(\.sidebarTintOpacity, palette.sidebarTintOpacity)
        prune(\.composerTint, palette.composerTint)
        prune(\.text, palette.text)
        prune(\.secondaryText, palette.secondaryText)
        prune(\.accent, palette.accent)
        prune(\.link, palette.link)
        prune(\.alert, palette.alert)
        prune(\.nameColors, palette.nameColors)
        prune(\.nameGlow, palette.nameGlow)
        prune(\.displayFont, preset.typography.displayFont ?? Self.systemDisplayFont)
        prune(\.bodyDesign, preset.typography.bodyDesign)
        prune(\.motifs, preset.wallpaper.motifs)
        prune(\.density, preset.wallpaper.density)
        prune(\.motifOpacity, preset.wallpaper.opacity)
        prune(\.ornaments, preset.wallpaper.ornaments)
        prune(\.celebration, preset.celebration)
        return result
    }

    /// An empty list is the user's choice of no art. A list that lost every
    /// entry it had is damaged instead, and falls back to the preset.
    private static func usable<Entry>(_ kept: [Entry], of count: Int) -> [Entry]? {
        kept.isEmpty && count > 0 ? nil : kept
    }

    private static func unitInterval(_ value: Double) -> Double? {
        value.isFinite ? min(1, max(0, value)) : nil
    }

    /// Degrees in 0..<360.
    private static func wrappedAngle(_ degrees: Double) -> Double? {
        guard degrees.isFinite else { return nil }
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }
}

/// A stored value that may be unreadable, so one bad entry of a list or
/// dictionary does not fail the rest.
private struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? decoder.singleValueContainer().decode(Value.self)
    }
}

/// The stored form of every customization: one JSON object keyed by preset
/// identifier, kept as text so `defaults read` shows it.
public enum ThemeCustomizationArchive {
    /// Reads stored customizations. Recovery is deliberate and silent: text
    /// that is not a JSON object yields none, entries that are no
    /// customization or belong to presets this version does not ship are
    /// skipped, and each remaining entry is normalized against its preset. The stored text is replaced
    /// only by the next edit, so an older or newer version still finds it.
    public static func decode(_ text: String?) -> [ThemeID: ThemeCustomization] {
        guard let data = text?.data(using: .utf8), let stored = try? JSONDecoder().decode([String: Lenient<ThemeCustomization>].self, from: data) else { return [:] }
        var result: [ThemeID: ThemeCustomization] = [:]
        for (key, entry) in stored {
            guard let id = ThemeID(rawValue: key), let customization = entry.value else { continue }
            let normalized = customization.normalized(for: ThemeCatalog.theme(id))
            if !normalized.isEmpty { result[id] = normalized }
        }
        return result
    }

    /// `nil` when there is nothing to store.
    public static func encode(_ customizations: [ThemeID: ThemeCustomization]) -> String? {
        let stored = Dictionary(uniqueKeysWithValues: customizations.filter { !$0.value.isEmpty }.map { ($0.key.rawValue, $0.value) })
        guard !stored.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(stored)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

extension Theme {
    /// The plain text backgrounds a faded backdrop approaches: what Classic
    /// shows behind the transcript in light and in dark.
    public static let plainLightBackground = ThemeColor(0xFFFFFF)
    public static let plainDarkBackground = ThemeColor(0x1E1E1E)

    /// This preset with the user's changes. Classic keeps the system look
    /// and takes none.
    public func applying(_ customization: ThemeCustomization) -> Theme {
        guard let palette else { return self }
        let custom = customization.sanitized
        let displayFont: String? = switch custom.displayFont {
        case nil: typography.displayFont
        case ThemeCustomization.systemDisplayFont: nil
        case let name: name
        }
        return Theme(
            id: id, name: name, tagline: tagline, tone: custom.tone ?? tone,
            palette: ThemePalette(
                gradient: custom.gradient ?? palette.gradient, gradientAngle: custom.gradientAngle ?? palette.gradientAngle,
                sidebarTint: custom.sidebarTint ?? palette.sidebarTint, sidebarTintOpacity: custom.sidebarTintOpacity ?? palette.sidebarTintOpacity,
                composerTint: custom.composerTint ?? palette.composerTint, text: custom.text ?? palette.text,
                secondaryText: custom.secondaryText ?? palette.secondaryText, accent: custom.accent ?? palette.accent,
                link: custom.link ?? palette.link, alert: custom.alert ?? palette.alert,
                nameColors: custom.nameColors ?? palette.nameColors, nameGlow: custom.nameGlow ?? palette.nameGlow),
            typography: ThemeTypography(displayFont: displayFont, bodyDesign: custom.bodyDesign ?? typography.bodyDesign),
            wallpaper: ThemeWallpaper(motifs: custom.motifs ?? wallpaper.motifs, density: custom.density ?? wallpaper.density,
                                      opacity: custom.motifOpacity ?? wallpaper.opacity, ornaments: custom.ornaments ?? wallpaper.ornaments),
            celebration: custom.celebration ?? celebration)
    }

    /// This theme with its backdrops shown at `opacity`: the gradient fades
    /// toward the plain text background of the theme's tone, and the
    /// wallpaper art and the sidebar tint fade with it. The result is an
    /// ordinary theme, so the renderer, the gallery previews and
    /// `ThemeAudit` all see exactly what is drawn.
    public func fadingBackdrop(to opacity: Double) -> Theme {
        guard let palette, opacity.isFinite, opacity < 1 else { return self }
        let alpha = max(0, opacity)
        let plain = tone == .dark ? Self.plainDarkBackground : Self.plainLightBackground
        let faded = ThemePalette(
            gradient: palette.gradient.map { $0.blended(over: plain, opacity: alpha) }, gradientAngle: palette.gradientAngle,
            sidebarTint: palette.sidebarTint, sidebarTintOpacity: palette.sidebarTintOpacity * alpha, composerTint: palette.composerTint,
            text: palette.text, secondaryText: palette.secondaryText, accent: palette.accent, link: palette.link, alert: palette.alert,
            nameColors: palette.nameColors, nameGlow: palette.nameGlow)
        let art = alpha == 0 ? ThemeWallpaper.none : ThemeWallpaper(
            motifs: wallpaper.motifs, density: wallpaper.density, opacity: wallpaper.opacity * alpha,
            ornaments: wallpaper.ornaments.map { OrnamentSpec($0.kind, $0.anchor, $0.colors, opacity: $0.opacity * alpha) })
        return Theme(id: id, name: name, tagline: tagline, tone: tone, palette: faded, typography: typography, wallpaper: art,
                     celebration: celebration)
    }
}

extension ThemeAudit {
    /// The palette roles of `theme` that miss their contrast minimum
    /// somewhere on its backdrop, each once and in audit order ("text",
    /// "link", "name color 2"). A customized theme is not held to the
    /// catalog's rules; this tells its author which colors to look at.
    public static func lowContrastRoles(in theme: Theme) -> [String] {
        let suffix = overWallpaper
        var roles: [String] = []
        for violation in violations(in: theme) {
            let role = violation.role.hasSuffix(suffix) ? String(violation.role.dropLast(suffix.count)) : violation.role
            if !roles.contains(role) { roles.append(role) }
        }
        return roles
    }
}
