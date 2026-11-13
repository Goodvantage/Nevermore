import Foundation

/// An opaque sRGB color. Themes are plain data so their palettes can be
/// audited for contrast without AppKit; the app converts them to `NSColor`.
public struct ThemeColor: Sendable, Hashable, CustomStringConvertible {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = min(1, max(0, red))
        self.green = min(1, max(0, green))
        self.blue = min(1, max(0, blue))
    }

    /// `ThemeColor(0xFB04B5)`: catalog colors are integer literals, so a
    /// malformed hex string cannot reach a shipped theme.
    public init(_ rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
    }

    /// Parses `#RRGGBB` or `RRGGBB`; anything else is rejected.
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), let value = UInt32(digits, radix: 16) else { return nil }
        self.init(value)
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    public var description: String { hex }

    /// WCAG 2.x relative luminance.
    public var relativeLuminance: Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// WCAG 2.x contrast ratio, 1...21.
    public func contrast(with other: ThemeColor) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// This color painted at `opacity` over `background` (source-over in sRGB,
    /// as Core Graphics composites non-linear sRGB layers).
    public func blended(over background: ThemeColor, opacity: Double) -> ThemeColor {
        let alpha = min(1, max(0, opacity))
        return ThemeColor(red: red * alpha + background.red * (1 - alpha),
                          green: green * alpha + background.green * (1 - alpha),
                          blue: blue * alpha + background.blue * (1 - alpha))
    }

    /// Black or white, whichever reads better on this color.
    public var readableForeground: ThemeColor {
        let black = ThemeColor(0x000000), white = ThemeColor(0xFFFFFF)
        return contrast(with: black) >= contrast(with: white) ? black : white
    }
}

/// Stored as `#RRGGBB`, so a saved customization stays readable and a
/// malformed value is rejected rather than clamped into some other color.
extension ThemeColor: Codable {
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let color = ThemeColor(hex: text) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Expected a #RRGGBB color, got \(text.prefix(16))"))
        }
        self = color
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// Whether a theme forces a light or dark window appearance. Classic follows
/// the system setting.
public enum ThemeTone: String, Sendable, CaseIterable, Codable {
    case system, light, dark
}

/// The system font design used for message bodies in the transcript. Never
/// applied to the composer: its HTML encoder reads a fixed-pitch font as
/// inline code.
public enum ThemeBodyDesign: String, Sendable, CaseIterable, Codable {
    case standard, rounded, serif, monospaced
}

/// How densely wallpaper motifs are scattered.
public enum ThemeDensity: String, Sendable, CaseIterable, Codable {
    case sparse, medium, dense

    /// Minimum distance between motif centers in points.
    public var spacing: Double {
        switch self {
        case .sparse: 92
        case .medium: 70
        case .dense: 54
        }
    }
}

/// A small wallpaper shape. The app draws each one; this enum only names them.
public enum ThemeMotif: String, Sendable, CaseIterable, Codable {
    case dot, ring, triangle, squiggle, zigzag, halfCircle, cross, star, sparkle, heart, bolt, diamond, spiral
    case bat, pumpkin, ghost, candyCorn, moon, raven, feather
    case bubble, fish, starfish, shell, seaweed
    case flower, leaf, mushroom, cloud, planet, rocket, comet, snowflake
    case pixelHeart, pixelStar, musicNote, lemon, cherry, sun

    /// Shapes that read as creatures or objects stay roughly upright; pure
    /// geometry may spin freely.
    public var maximumTilt: Double {
        switch self {
        case .dot, .ring, .triangle, .squiggle, .zigzag, .halfCircle, .cross, .star, .sparkle, .diamond, .spiral, .snowflake, .pixelStar, .bolt, .comet, .leaf, .feather, .starfish, .shell:
            return .pi
        case .pixelHeart:
            return 0
        default:
            return 0.3
        }
    }
}

public enum MotifStyle: String, Sendable, CaseIterable, Codable {
    /// Solid silhouette.
    case fill
    /// Outline only.
    case stroke
    /// Outline with a soft halo in the same color, for neon looks.
    case glow
}

/// One weighted entry of a theme's wallpaper.
public struct MotifSpec: Sendable, Equatable {
    public let motif: ThemeMotif
    /// The instance color is chosen from these; motifs with a second part
    /// (a pumpkin's stem, a cherry's stalk) use the second color for it.
    public let colors: [ThemeColor]
    public let style: MotifStyle
    /// Relative frequency, 1...5.
    public let weight: Int

    public init(_ motif: ThemeMotif, _ colors: [ThemeColor], style: MotifStyle = .fill, weight: Int = 2) {
        self.motif = motif
        self.colors = colors
        self.style = style
        self.weight = min(5, max(1, weight))
    }
}

/// Decodes through the clamping initializer: a stored weight outside 1...5
/// must not reach the wallpaper layout.
extension MotifSpec: Codable {
    private enum CodingKeys: String, CodingKey { case motif, colors, style, weight }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode(ThemeMotif.self, forKey: .motif), try container.decode([ThemeColor].self, forKey: .colors),
                  style: try container.decode(MotifStyle.self, forKey: .style), weight: try container.decode(Int.self, forKey: .weight))
    }
}

/// A large decoration anchored to the conversation pane.
public enum OrnamentKind: String, Sendable, CaseIterable, Codable {
    case moonLarge, spiderWeb, retroSun, perspectiveGrid, cornerStripes, mountains, oceanWaves, rollingHills
    case ringedPlanet, scanlines, rainbowArc, skyline, cloudBank, vines, aurora
}

public enum OrnamentAnchor: String, Sendable, CaseIterable, Codable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing, top, bottom, fill
}

public struct OrnamentSpec: Sendable, Equatable {
    public let kind: OrnamentKind
    public let anchor: OrnamentAnchor
    public let colors: [ThemeColor]
    public let opacity: Double

    public init(_ kind: OrnamentKind, _ anchor: OrnamentAnchor, _ colors: [ThemeColor], opacity: Double) {
        self.kind = kind
        self.anchor = anchor
        self.colors = colors
        self.opacity = min(1, max(0, opacity))
    }
}

/// Decodes through the clamping initializer, like `MotifSpec`.
extension OrnamentSpec: Codable {
    private enum CodingKeys: String, CodingKey { case kind, anchor, colors, opacity }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode(OrnamentKind.self, forKey: .kind), try container.decode(OrnamentAnchor.self, forKey: .anchor),
                  try container.decode([ThemeColor].self, forKey: .colors), opacity: try container.decode(Double.self, forKey: .opacity))
    }
}

/// The scattered motifs and anchored ornaments behind the transcript.
public struct ThemeWallpaper: Sendable, Equatable {
    public let motifs: [MotifSpec]
    public let density: ThemeDensity
    /// Opacity of every motif; the contrast audit checks text against motif
    /// colors blended at this opacity.
    public let opacity: Double
    public let ornaments: [OrnamentSpec]

    public init(motifs: [MotifSpec], density: ThemeDensity = .medium, opacity: Double, ornaments: [OrnamentSpec] = []) {
        self.motifs = motifs
        self.density = density
        self.opacity = min(1, max(0, opacity))
        self.ornaments = ornaments
    }

    public static let none = ThemeWallpaper(motifs: [], density: .sparse, opacity: 0)

    public var isEmpty: Bool { motifs.isEmpty && ornaments.isEmpty }
}

/// The one-shot particle burst played when a theme is chosen.
public enum ThemeCelebration: String, Sendable, CaseIterable, Codable {
    case none, confetti, bats, ravens, sparkles, bubbles, leaves, snow, stars, hearts, notes
}

/// Colors for a theme that replaces the system look.
public struct ThemePalette: Sendable, Equatable {
    /// Backdrop gradient, top stop first.
    public let gradient: [ThemeColor]
    /// Degrees; 90 runs top to bottom.
    public let gradientAngle: Double
    public let sidebarTint: ThemeColor
    public let sidebarTintOpacity: Double
    public let composerTint: ThemeColor
    public let text: ThemeColor
    public let secondaryText: ThemeColor
    /// Selection, send button, own reactions and focus rings.
    public let accent: ThemeColor
    public let link: ThemeColor
    /// Unread dividers and failures.
    public let alert: ThemeColor
    /// Sender names; each author keeps one color, see `nameColor(for:)`.
    public let nameColors: [ThemeColor]
    /// Draws a soft halo in the name's color behind each sender name.
    public let nameGlow: Bool

    /// The wash behind inline code and code blocks. Light text gets a dark
    /// wash and dark text a tint of itself, so code stands apart without
    /// losing contrast against its own background.
    public var codeBackground: ThemeColor { isTextLight ? ThemeColor(0x000000) : text }
    public var codeBackgroundOpacity: Double { isTextLight ? 0.28 : 0.1 }
    private var isTextLight: Bool { text.relativeLuminance > 0.5 }

    public init(gradient: [ThemeColor], gradientAngle: Double = 90, sidebarTint: ThemeColor, sidebarTintOpacity: Double, composerTint: ThemeColor,
                text: ThemeColor, secondaryText: ThemeColor, accent: ThemeColor, link: ThemeColor, alert: ThemeColor,
                nameColors: [ThemeColor], nameGlow: Bool = false) {
        self.gradient = gradient
        self.gradientAngle = gradientAngle
        self.sidebarTint = sidebarTint
        self.sidebarTintOpacity = min(1, max(0, sidebarTintOpacity))
        self.composerTint = composerTint
        self.text = text
        self.secondaryText = secondaryText
        self.accent = accent
        self.link = link
        self.alert = alert
        self.nameColors = nameColors
        self.nameGlow = nameGlow
    }

    /// The same author gets the same color in every window and on every
    /// launch: FNV-1a over the user ID's UTF-8 bytes, not `hashValue`, which
    /// Swift seeds per process.
    public func nameColor(for userID: String) -> ThemeColor {
        guard !nameColors.isEmpty else { return text }
        return nameColors[Self.stableIndex(for: userID, count: nameColors.count)]
    }

    public static func stableIndex(for key: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return Int(hash % UInt64(count))
    }
}

/// Fonts a theme asks for. Missing fonts fall back to the system font.
public struct ThemeTypography: Sendable, Equatable {
    /// PostScript name for sender names and the empty-state title.
    public let displayFont: String?
    public let bodyDesign: ThemeBodyDesign

    public init(displayFont: String? = nil, bodyDesign: ThemeBodyDesign = .standard) {
        self.displayFont = displayFont
        self.bodyDesign = bodyDesign
    }

    public static let system = ThemeTypography()
}

/// Persisted theme identifiers. Raw values are stored in user defaults:
/// renaming a case changes what returning users see.
public enum ThemeID: String, Sendable, CaseIterable, Identifiable {
    case classic, memphis, halloween, neonFun, bubblegum, nevermore, synthwave, vaporwave, underTheSea, meadow, cosmic, aurora, lemonade, peppermint, midnightCocoa, phosphor
    public var id: String { rawValue }
}

public struct Theme: Sendable, Identifiable, Equatable {
    public let id: ThemeID
    public let name: String
    public let tagline: String
    public let tone: ThemeTone
    /// `nil` keeps the system's semantic colors (the Classic look).
    public let palette: ThemePalette?
    public let typography: ThemeTypography
    public let wallpaper: ThemeWallpaper
    public let emptyTitle: String
    public let emptyDetail: String
    /// Drawn large above the empty-state text; `nil` shows none.
    public let emptyMotif: ThemeMotif?
    public let celebration: ThemeCelebration

    public init(id: ThemeID, name: String, tagline: String, tone: ThemeTone, palette: ThemePalette?, typography: ThemeTypography = .system,
                wallpaper: ThemeWallpaper = .none, emptyTitle: String, emptyDetail: String, emptyMotif: ThemeMotif? = nil, celebration: ThemeCelebration = .none) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.tone = tone
        self.palette = palette
        self.typography = typography
        self.wallpaper = wallpaper
        self.emptyTitle = emptyTitle
        self.emptyDetail = emptyDetail
        self.emptyMotif = emptyMotif
        self.celebration = celebration
    }

    /// Classic keeps the system look and draws nothing extra.
    public var isClassic: Bool { palette == nil }
}
