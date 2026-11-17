import Foundation

// MARK: - Contrast audit

/// A theme color that fails its minimum contrast against a backdrop pixel.
public struct ContrastViolation: Sendable, Equatable, CustomStringConvertible {
    public let theme: ThemeID
    public let role: String
    public let foreground: ThemeColor
    public let background: ThemeColor
    public let ratio: Double
    public let minimum: Double

    public var description: String {
        "\(theme.rawValue): \(role) \(foreground) on \(background) is \(String(format: "%.2f", ratio)):1, needs \(minimum):1"
    }
}

/// WCAG 2.x checks every shipped theme must pass. The wallpaper sits under
/// the transcript, so text is checked against the bare gradient and against
/// every motif and ornament color composited at its opacity, alone and
/// stacked where they can overlap: the worst pixel a glyph can land on.
/// Code text is also checked on its code background over each of those.
public enum ThemeAudit {
    /// Body text, sender names, links, timestamps and alerts on the bare backdrop.
    public static let textMinimum = 4.5
    /// Non-text UI (accent fills, the send button glyph).
    public static let componentMinimum = 3.0
    /// Secondary roles where they cross wallpaper art. Body text keeps 4.5.
    public static let decoratedMinimum = 3.0
    /// Appended to a role's name where it is checked against wallpaper art.
    static let overWallpaper = " over wallpaper"

    public static func violations(in theme: Theme) -> [ContrastViolation] {
        guard let palette = theme.palette else { return [] }
        var found: [ContrastViolation] = []
        func require(_ role: String, _ foreground: ThemeColor, on backgrounds: [ThemeColor], minimum: Double) {
            for background in backgrounds {
                let ratio = foreground.contrast(with: background)
                if ratio + 1e-9 < minimum {
                    found.append(ContrastViolation(theme: theme.id, role: role, foreground: foreground, background: background, ratio: ratio, minimum: minimum))
                }
            }
        }
        let bare = backdropSamples(palette)
        let decorated = decoratedSamples(palette, wallpaper: theme.wallpaper)
        require("text", palette.text, on: bare + decorated, minimum: textMinimum)
        let code = (bare + decorated).map { palette.codeBackground.blended(over: $0, opacity: palette.codeBackgroundOpacity) }
        require("code text", palette.text, on: code, minimum: textMinimum)
        for (role, color) in [("secondary text", palette.secondaryText), ("link", palette.link), ("alert", palette.alert)] {
            require(role, color, on: bare, minimum: textMinimum)
            require(role + overWallpaper, color, on: decorated, minimum: decoratedMinimum)
        }
        for (index, color) in palette.nameColors.enumerated() {
            require("name color \(index + 1)", color, on: bare, minimum: textMinimum)
            require("name color \(index + 1)" + overWallpaper, color, on: decorated, minimum: decoratedMinimum)
        }
        require("accent", palette.accent, on: bare, minimum: componentMinimum)
        return found
    }

    /// Structural rules the contrast math cannot see.
    public static func problems(in theme: Theme) -> [String] {
        var problems: [String] = []
        let tag = theme.id.rawValue
        if theme.name.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(tag): empty name") }
        guard let palette = theme.palette else {
            if theme.tone != .system { problems.append("\(tag): a system-colored theme must follow the system tone") }
            if !theme.wallpaper.isEmpty { problems.append("\(tag): a system-colored theme draws no wallpaper") }
            return problems
        }
        if theme.tone == .system { problems.append("\(tag): a palette theme must force light or dark") }
        if palette.gradient.count < 2 { problems.append("\(tag): the gradient needs two stops") }
        if palette.nameColors.count < 4 { problems.append("\(tag): at least four name colors keep authors apart") }
        if Set(palette.nameColors).count != palette.nameColors.count { problems.append("\(tag): duplicate name colors") }
        // The forced appearance decides system control and label colors, so
        // it must agree with the backdrop's lightness.
        let backdrop = palette.gradient.map(\.relativeLuminance).reduce(0, +) / Double(max(1, palette.gradient.count))
        if theme.tone == .dark && backdrop > 0.18 { problems.append("\(tag): dark tone over a light backdrop") }
        if theme.tone == .light && backdrop < 0.35 { problems.append("\(tag): light tone over a dark backdrop") }
        if theme.tone == .dark && palette.sidebarTint.relativeLuminance > 0.2 { problems.append("\(tag): dark tone with a light sidebar tint") }
        if theme.tone == .light && palette.sidebarTint.relativeLuminance < 0.3 { problems.append("\(tag): light tone with a dark sidebar tint") }
        for spec in theme.wallpaper.motifs where spec.colors.isEmpty { problems.append("\(tag): \(spec.motif.rawValue) has no colors") }
        for spec in theme.wallpaper.ornaments where spec.colors.isEmpty { problems.append("\(tag): \(spec.kind.rawValue) has no colors") }
        if !theme.wallpaper.motifs.isEmpty && theme.wallpaper.opacity <= 0 { problems.append("\(tag): motifs at zero opacity") }
        return problems
    }

    /// The gradient's stops and the midpoint of every pair of adjacent
    /// stops. A three-stop gradient also shows the two adjacent blends on
    /// screen, so the audit has to check them, not just the end stops.
    static func backdropSamples(_ palette: ThemePalette) -> [ThemeColor] {
        palette.gradient + zip(palette.gradient, palette.gradient.dropFirst()).map { $0.1.blended(over: $0.0, opacity: 0.5) }
    }

    static func decoratedSamples(_ palette: ThemePalette, wallpaper: ThemeWallpaper) -> [ThemeColor] {
        let bare = backdropSamples(palette)
        var underOrnaments = bare
        for group in overlappingOrnaments(wallpaper.ornaments) {
            // Each ornament in a group lands on every pixel the earlier ones left.
            var stack = bare
            for ornament in group {
                let below = stack
                for color in ornament.colors {
                    stack += below.map { color.blended(over: $0, opacity: ornament.opacity) }
                }
            }
            underOrnaments += stack.dropFirst(bare.count)
        }
        var samples = Array(underOrnaments.dropFirst(bare.count))
        for spec in wallpaper.motifs {
            for color in spec.colors {
                samples += underOrnaments.map { color.blended(over: $0, opacity: wallpaper.opacity) }
            }
        }
        return samples
    }

    /// Ornaments that can cover the same pixel, in drawing order. Ornaments
    /// pinned to one anchor overlap (a sun behind a grid) and a pane-filling
    /// one overlaps all; ornaments pinned to different anchors are sized to
    /// stay apart (a moon top right, a web top left), so they never stack.
    static func overlappingOrnaments(_ ornaments: [OrnamentSpec]) -> [[OrnamentSpec]] {
        var anchors: [OrnamentAnchor] = []
        for ornament in ornaments where ornament.anchor != .fill && !anchors.contains(ornament.anchor) {
            anchors.append(ornament.anchor)
        }
        guard !anchors.isEmpty else { return ornaments.isEmpty ? [] : [ornaments] }
        return anchors.map { anchor in ornaments.filter { $0.anchor == anchor || $0.anchor == .fill } }
    }
}

// MARK: - Wallpaper layout

/// One motif instance on a wallpaper tile, in tile points with a top-left origin.
public struct MotifPlacement: Sendable, Equatable {
    public let specIndex: Int
    public let colorIndex: Int
    public let x: Double
    public let y: Double
    public let size: Double
    public let rotation: Double
}

/// Scatters a theme's motifs over a square tile that repeats seamlessly.
/// Pure and deterministic: the same theme always gets the same wallpaper, so
/// it does not reshuffle on resize, relaunch or across windows.
public enum WallpaperLayout {
    public static let tileSize: Double = 420

    public static func scatter(_ wallpaper: ThemeWallpaper, tileSize: Double = tileSize, seed: UInt64) -> [MotifPlacement] {
        guard !wallpaper.motifs.isEmpty, tileSize > 0 else { return [] }
        var random = SplitMix64(seed: seed)
        let spacing = wallpaper.density.spacing
        let weights = wallpaper.motifs.map(\.weight)
        let totalWeight = weights.reduce(0, +)
        var placements: [MotifPlacement] = []
        var misses = 0
        // Dart throwing with a toroidal distance check: a candidate near one
        // edge is compared with motifs near the opposite edge, so the tile
        // repeats without visible seams or clumps.
        while misses < 400 && placements.count < 400 {
            let x = random.unit() * tileSize, y = random.unit() * tileSize
            let clear = placements.allSatisfy { placed in
                let dx = wrappedDistance(placed.x, x, tileSize), dy = wrappedDistance(placed.y, y, tileSize)
                return dx * dx + dy * dy >= spacing * spacing
            }
            guard clear else { misses += 1; continue }
            misses = 0
            var pick = Int(random.unit() * Double(totalWeight))
            var specIndex = 0
            for (index, weight) in weights.enumerated() {
                if pick < weight { specIndex = index; break }
                pick -= weight
            }
            let spec = wallpaper.motifs[specIndex]
            let colorIndex = spec.motif.partCount > 1 ? 0 : Int(random.unit() * Double(spec.colors.count)) % max(1, spec.colors.count)
            let size = spacing * (0.30 + random.unit() * 0.16)
            let rotation = (random.unit() * 2 - 1) * spec.motif.maximumTilt
            placements.append(MotifPlacement(specIndex: specIndex, colorIndex: colorIndex, x: x, y: y, size: size, rotation: rotation))
        }
        return placements
    }

    /// A stable seed for a theme's wallpaper.
    public static func seed(for id: ThemeID) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.rawValue.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
        return hash
    }

    static func wrappedDistance(_ a: Double, _ b: Double, _ period: Double) -> Double {
        let direct = abs(a - b)
        return min(direct, period - direct)
    }
}

extension ThemeMotif {
    /// Motifs drawn in several colors take them in order from their spec
    /// (body first) instead of picking one color per instance.
    public var partCount: Int {
        switch self {
        case .pumpkin, .cherry, .mushroom, .rocket, .flower, .planet, .lemon: 2
        case .candyCorn: 3
        default: 1
        }
    }
}

/// Small deterministic generator; `SystemRandomNumberGenerator` cannot be seeded.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
