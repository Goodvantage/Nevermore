import Foundation

/// The built-in themes, in gallery order. Each theme is a separate typed
/// constant: one large nested literal is slow for the CI runner's compiler.
/// `ThemeAudit` checks every palette in the unit tests.
public enum ThemeCatalog {
    public static let all: [Theme] = [
        classic, memphis, halloween, neonFun, bubblegum, nevermore, synthwave, vaporwave,
        underTheSea, meadow, cosmic, aurora, lemonade, peppermint, midnightCocoa, phosphor,
    ]

    public static func theme(_ id: ThemeID) -> Theme {
        all.first { $0.id == id } ?? classic
    }

    /// The theme for a stored preference; unknown or missing values (a
    /// theme removed in a later version, a hand-edited default) fall back
    /// to Classic.
    public static func theme(storedAs rawValue: String?) -> Theme {
        rawValue.flatMap(ThemeID.init(rawValue:)).map(theme(_:)) ?? classic
    }

    // MARK: Classic

    public static let classic = Theme(
        id: .classic, name: "Classic", tagline: "The native Mac look", tone: .system, palette: nil)

    // MARK: Memphis — the family's Memphis Group print (Invoque, Zap, Jetty)

    private static let memphisPalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0xFEFBEC), ThemeColor(0xFFF1D6)], gradientAngle: 90,
        sidebarTint: ThemeColor(0xFDE133), sidebarTintOpacity: 0.3, composerTint: ThemeColor(0x02FBF6),
        text: ThemeColor(0x000517), secondaryText: ThemeColor(0x3D3752), accent: ThemeColor(0xE0009F),
        link: ThemeColor(0x00507D), alert: ThemeColor(0xA30032),
        nameColors: [ThemeColor(0x9E0068), ThemeColor(0x004E87), ThemeColor(0x5A22A8), ThemeColor(0x843400), ThemeColor(0x005A45), ThemeColor(0x8F0030)])

    private static let memphisWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.triangle, [ThemeColor(0xFB04B5), ThemeColor(0x02FBF6), ThemeColor(0xFDE133)], weight: 3),
            MotifSpec(.squiggle, [ThemeColor(0x3A3F73), ThemeColor(0xFB04B5)], weight: 3),
            MotifSpec(.dot, [ThemeColor(0x3A3F73), ThemeColor(0xFB04B5), ThemeColor(0x02FBF6)], weight: 2),
            MotifSpec(.zigzag, [ThemeColor(0x02FBF6), ThemeColor(0x3A3F73)], weight: 2),
            MotifSpec(.halfCircle, [ThemeColor(0xFDE133), ThemeColor(0xFB04B5)], weight: 2),
            MotifSpec(.cross, [ThemeColor(0x3A3F73)], weight: 1),
            MotifSpec(.ring, [ThemeColor(0xFB04B5), ThemeColor(0x02FBF6)], style: .stroke, weight: 1),
        ],
        density: .medium, opacity: 0.28,
        ornaments: [OrnamentSpec(.cornerStripes, .topTrailing, [ThemeColor(0xFB04B5), ThemeColor(0x02FBF6), ThemeColor(0xFDE133)], opacity: 0.26)])

    public static let memphis = Theme(
        id: .memphis, name: "Memphis", tagline: "Loud geometry on cream paper", tone: .light, palette: memphisPalette,
        typography: ThemeTypography(displayFont: "Futura-Bold"), wallpaper: memphisWallpaper,
        celebration: .confetti)

    // MARK: Halloween

    private static let halloweenPalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0x1E0B33), ThemeColor(0x2D0F2A)], gradientAngle: 90,
        sidebarTint: ThemeColor(0x341450), sidebarTintOpacity: 0.55, composerTint: ThemeColor(0xFF7A1A),
        text: ThemeColor(0xFFF4E6), secondaryText: ThemeColor(0xDCCBEA), accent: ThemeColor(0xFF7A1A),
        link: ThemeColor(0xFFC27A), alert: ThemeColor(0xFF9DB2),
        nameColors: [ThemeColor(0xFFB066), ThemeColor(0xC4F77A), ThemeColor(0xD7B8FF), ThemeColor(0xFFE07A), ThemeColor(0x99ECE9), ThemeColor(0xFFA8C4)])

    private static let halloweenWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.bat, [ThemeColor(0x8A5CC7), ThemeColor(0x6E4AA8)], weight: 3),
            MotifSpec(.pumpkin, [ThemeColor(0xFF7A1A), ThemeColor(0x6FBF3A)], weight: 3),
            MotifSpec(.ghost, [ThemeColor(0xE8E0FF)], weight: 2),
            MotifSpec(.candyCorn, [ThemeColor(0xFFB000), ThemeColor(0xFF6A00), ThemeColor(0xFFF4E6)], weight: 2),
            MotifSpec(.star, [ThemeColor(0xFFD84D)], weight: 1),
            MotifSpec(.moon, [ThemeColor(0xFFE9A8)], weight: 1),
        ],
        density: .medium, opacity: 0.19,
        ornaments: [
            OrnamentSpec(.moonLarge, .topTrailing, [ThemeColor(0xFFE9A8)], opacity: 0.14),
            OrnamentSpec(.spiderWeb, .topLeading, [ThemeColor(0xCDB8E0)], opacity: 0.24),
        ])

    public static let halloween = Theme(
        id: .halloween, name: "Halloween", tagline: "Cute-spooky pumpkin night", tone: .dark, palette: halloweenPalette,
        typography: ThemeTypography(displayFont: "Chalkduster"), wallpaper: halloweenWallpaper,
        celebration: .bats)

    // MARK: Neon Fun

    private static let neonPalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0x0B0221), ThemeColor(0x14012E)], gradientAngle: 120,
        sidebarTint: ThemeColor(0x2A0850), sidebarTintOpacity: 0.55, composerTint: ThemeColor(0x7A00FF),
        text: ThemeColor(0xF7F3FF), secondaryText: ThemeColor(0xCBC6F2), accent: ThemeColor(0xFF2E97),
        link: ThemeColor(0x3DF5FF), alert: ThemeColor(0xFFA6B8),
        nameColors: [ThemeColor(0xFF9CE8), ThemeColor(0x3DF5FF), ThemeColor(0xB6FF3D), ThemeColor(0xFFE53D), ThemeColor(0xFF9E3D), ThemeColor(0xC7B6FF)],
        nameGlow: true)

    private static let neonWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.bolt, [ThemeColor(0xB6FF3D)], style: .glow, weight: 2),
            MotifSpec(.star, [ThemeColor(0xFFE53D)], style: .glow, weight: 2),
            MotifSpec(.squiggle, [ThemeColor(0xFF2E97)], style: .glow, weight: 3),
            MotifSpec(.ring, [ThemeColor(0x3DF5FF)], style: .glow, weight: 2),
            MotifSpec(.triangle, [ThemeColor(0xA88BFF)], style: .glow, weight: 2),
            MotifSpec(.heart, [ThemeColor(0xFF4FD8)], style: .glow, weight: 1),
            MotifSpec(.musicNote, [ThemeColor(0x3DF5FF)], style: .glow, weight: 1),
        ],
        density: .sparse, opacity: 0.23,
        ornaments: [
            OrnamentSpec(.skyline, .bottom, [ThemeColor(0x3A0F78)], opacity: 0.5),
            OrnamentSpec(.perspectiveGrid, .bottom, [ThemeColor(0xFF2E97), ThemeColor(0x3DF5FF)], opacity: 0.19),
        ])

    public static let neonFun = Theme(
        id: .neonFun, name: "Neon Fun", tagline: "Glow sticks at midnight", tone: .dark, palette: neonPalette,
        typography: ThemeTypography(displayFont: "AvenirNext-Heavy"), wallpaper: neonWallpaper,
        celebration: .sparkles)

    // MARK: Bubblegum

    private static let bubblegumPalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0xFFE3F1), ThemeColor(0xEBDDFF)], gradientAngle: 100,
        sidebarTint: ThemeColor(0xFFD1E8), sidebarTintOpacity: 0.4, composerTint: ThemeColor(0xFF8FC7),
        text: ThemeColor(0x3A1838), secondaryText: ThemeColor(0x6E4A6B), accent: ThemeColor(0xD63384),
        link: ThemeColor(0xA3005F), alert: ThemeColor(0xC8102E),
        nameColors: [ThemeColor(0xC2185B), ThemeColor(0x7B3FC4), ThemeColor(0x0A6F7A), ThemeColor(0xA34A00), ThemeColor(0x1F5FB8), ThemeColor(0x1E6B22)])

    private static let bubblegumWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.heart, [ThemeColor(0xFF8FC7), ThemeColor(0xC9A7FF)], weight: 3),
            MotifSpec(.sparkle, [ThemeColor(0xFFB3D9), ThemeColor(0xFFC94D)], weight: 3),
            MotifSpec(.star, [ThemeColor(0xFFC94D)], weight: 2),
            MotifSpec(.cloud, [ThemeColor(0xFFFFFF)], weight: 2),
            MotifSpec(.bubble, [ThemeColor(0x9FD8FF), ThemeColor(0xC9A7FF)], style: .stroke, weight: 2),
        ],
        density: .medium, opacity: 0.5,
        ornaments: [
            OrnamentSpec(.cloudBank, .top, [ThemeColor(0xFFFFFF)], opacity: 0.6),
            OrnamentSpec(.rainbowArc, .bottomTrailing, [ThemeColor(0xFF9EC7), ThemeColor(0xFFD08A), ThemeColor(0xFFF09A), ThemeColor(0xA8E6B0), ThemeColor(0x9FD8FF), ThemeColor(0xC9A7FF)], opacity: 0.4),
        ])

    public static let bubblegum = Theme(
        id: .bubblegum, name: "Bubblegum", tagline: "Pastel hearts and sparkles", tone: .light, palette: bubblegumPalette,
        typography: ThemeTypography(bodyDesign: .rounded), wallpaper: bubblegumWallpaper,
        celebration: .hearts)

    // MARK: Nevermore — the app's namesake: Poe's raven at midnight

    private static let nevermorePalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0x0F0C16), ThemeColor(0x1C1426)], gradientAngle: 90,
        sidebarTint: ThemeColor(0x261B36), sidebarTintOpacity: 0.55, composerTint: ThemeColor(0x5B3F7A),
        text: ThemeColor(0xEFE6D8), secondaryText: ThemeColor(0xB3A79A), accent: ThemeColor(0xD9A441),
        link: ThemeColor(0xE8B85C), alert: ThemeColor(0xF2998A),
        nameColors: [ThemeColor(0xE0B25E), ThemeColor(0xC79BD9), ThemeColor(0x8FC1C9), ThemeColor(0xE3907A), ThemeColor(0xA9C98F), ThemeColor(0xD9D0FF)])

    private static let nevermoreWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.raven, [ThemeColor(0x5A4B70)], weight: 3),
            MotifSpec(.feather, [ThemeColor(0x6B5A80), ThemeColor(0x4E4262)], weight: 3),
            MotifSpec(.star, [ThemeColor(0xA07C33)], weight: 1),
            MotifSpec(.sparkle, [ThemeColor(0xB8A57A)], weight: 1),
        ],
        density: .sparse, opacity: 0.32,
        ornaments: [OrnamentSpec(.moonLarge, .topTrailing, [ThemeColor(0xEFE6D8)], opacity: 0.11)])

    public static let nevermore = Theme(
        id: .nevermore, name: "Nevermore", tagline: "Ravens, candlelight and midnight ink", tone: .dark, palette: nevermorePalette,
        typography: ThemeTypography(displayFont: "Didot-Bold", bodyDesign: .serif), wallpaper: nevermoreWallpaper,
        celebration: .ravens)

    // MARK: Synthwave — the family's outrun sunset

    private static let synthwavePalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0x150D33), ThemeColor(0x341361)], gradientAngle: 90,
        sidebarTint: ThemeColor(0x3A1668), sidebarTintOpacity: 0.55, composerTint: ThemeColor(0xFB1A91),
        text: ThemeColor(0xF5F0FF), secondaryText: ThemeColor(0xD7CCF2), accent: ThemeColor(0xFB1A91),
        link: ThemeColor(0xFFB168), alert: ThemeColor(0xFFA9C3),
        nameColors: [ThemeColor(0xFFA8D5), ThemeColor(0xFFB168), ThemeColor(0x7FE8FF), ThemeColor(0xDDB3FF), ThemeColor(0xFFE08A), ThemeColor(0x9DFFC6)],
        nameGlow: true)

    private static let synthwaveWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.star, [ThemeColor(0xFFD35C), ThemeColor(0xFF9EDB)], weight: 2),
            MotifSpec(.sparkle, [ThemeColor(0xFFFFFF), ThemeColor(0x5CE1FF)], weight: 2),
            MotifSpec(.dot, [ThemeColor(0xC68BFF)], weight: 1),
        ],
        density: .sparse, opacity: 0.18,
        ornaments: [
            OrnamentSpec(.retroSun, .bottom, [ThemeColor(0xFFD35C), ThemeColor(0xFB1A91)], opacity: 0.15),
            OrnamentSpec(.perspectiveGrid, .bottom, [ThemeColor(0xFB1A91)], opacity: 0.18),
        ])

    public static let synthwave = Theme(
        id: .synthwave, name: "Synthwave", tagline: "Outrun sunset on a neon grid", tone: .dark, palette: synthwavePalette,
        typography: ThemeTypography(displayFont: "Futura-CondensedExtraBold"), wallpaper: synthwaveWallpaper,
        celebration: .stars)

    // MARK: Vaporwave

    private static let vaporwavePalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0xFFD6F5), ThemeColor(0xC8E7FF)], gradientAngle: 90,
        sidebarTint: ThemeColor(0xE7D3FF), sidebarTintOpacity: 0.4, composerTint: ThemeColor(0xC774E8),
        text: ThemeColor(0x2A1B4F), secondaryText: ThemeColor(0x55477A), accent: ThemeColor(0xB0369E),
        link: ThemeColor(0x5A2DB3), alert: ThemeColor(0xB3123E),
        nameColors: [ThemeColor(0xA8006F), ThemeColor(0x5A2DB3), ThemeColor(0x005E75), ThemeColor(0x9A2E14), ThemeColor(0x2A5C00), ThemeColor(0x6E3800)])

    private static let vaporwaveWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.triangle, [ThemeColor(0xFF6AD5), ThemeColor(0x94D0FF)], style: .stroke, weight: 3),
            MotifSpec(.diamond, [ThemeColor(0xAD8CFF), ThemeColor(0xFF6AD5)], weight: 2),
            MotifSpec(.sparkle, [ThemeColor(0xFFFFFF)], weight: 2),
            MotifSpec(.dot, [ThemeColor(0xC774E8), ThemeColor(0x8795E8)], weight: 2),
        ],
        density: .medium, opacity: 0.4,
        ornaments: [
            OrnamentSpec(.retroSun, .bottom, [ThemeColor(0xFF6AD5), ThemeColor(0xFFB8E8)], opacity: 0.24),
            OrnamentSpec(.perspectiveGrid, .bottom, [ThemeColor(0xC774E8)], opacity: 0.3),
        ])

    public static let vaporwave = Theme(
        id: .vaporwave, name: "Vaporwave", tagline: "Pastel dreams and endless grids", tone: .light, palette: vaporwavePalette,
        typography: ThemeTypography(displayFont: "Futura-Bold"), wallpaper: vaporwaveWallpaper,
        celebration: .notes)

    // MARK: Under the Sea

    private static let seaPalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0xDDF7FA), ThemeColor(0xA6E1EE)], gradientAngle: 90,
        sidebarTint: ThemeColor(0xBFEFF5), sidebarTintOpacity: 0.4, composerTint: ThemeColor(0x3AA9C4),
        text: ThemeColor(0x06303C), secondaryText: ThemeColor(0x24505C), accent: ThemeColor(0xB8352A),
        link: ThemeColor(0x004F73), alert: ThemeColor(0xA8221A),
        nameColors: [ThemeColor(0x92300F), ThemeColor(0x004F73), ThemeColor(0x5E2483), ThemeColor(0x005A47), ThemeColor(0x713E00), ThemeColor(0x930045)])

    private static let seaWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.bubble, [ThemeColor(0xFFFFFF)], style: .stroke, weight: 3),
            MotifSpec(.fish, [ThemeColor(0xFF8A5B), ThemeColor(0xFFC94D), ThemeColor(0x5B8DEF)], weight: 3),
            MotifSpec(.starfish, [ThemeColor(0xFF6F61)], weight: 1),
            MotifSpec(.shell, [ThemeColor(0xF7B7A3)], weight: 1),
            MotifSpec(.seaweed, [ThemeColor(0x2E9E6A)], weight: 2),
        ],
        density: .medium, opacity: 0.4,
        ornaments: [OrnamentSpec(.oceanWaves, .bottom, [ThemeColor(0x5FC4D9), ThemeColor(0x3AA9C4)], opacity: 0.38)])

    public static let underTheSea = Theme(
        id: .underTheSea, name: "Under the Sea", tagline: "Bubbles, fish and sea glass", tone: .light, palette: seaPalette,
        typography: ThemeTypography(displayFont: "ChalkboardSE-Bold", bodyDesign: .rounded), wallpaper: seaWallpaper,
        celebration: .bubbles)

    // MARK: Meadow

    private static let meadowPalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0xF7F5E6), ThemeColor(0xE4EFD2)], gradientAngle: 90,
        sidebarTint: ThemeColor(0xE9F0D6), sidebarTintOpacity: 0.45, composerTint: ThemeColor(0x9CC77A),
        text: ThemeColor(0x22301C), secondaryText: ThemeColor(0x45523C), accent: ThemeColor(0xB8455A),
        link: ThemeColor(0x2A6235), alert: ThemeColor(0xA8221A),
        nameColors: [ThemeColor(0x8C3B1F), ThemeColor(0x2A6235), ThemeColor(0x74368A), ThemeColor(0x1C5882), ThemeColor(0x982C64), ThemeColor(0x5C4C00)])

    private static let meadowWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.flower, [ThemeColor(0xF4A6C0), ThemeColor(0xF7D046)], weight: 3),
            MotifSpec(.leaf, [ThemeColor(0x7FB069), ThemeColor(0x9CC77A)], weight: 3),
            MotifSpec(.mushroom, [ThemeColor(0xE05A47), ThemeColor(0xF5E6C8)], weight: 2),
            MotifSpec(.dot, [ThemeColor(0xF7D046)], weight: 1),
        ],
        density: .medium, opacity: 0.42,
        ornaments: [
            OrnamentSpec(.rollingHills, .bottom, [ThemeColor(0xB9D99A), ThemeColor(0x9CC77A)], opacity: 0.42),
            OrnamentSpec(.vines, .topLeading, [ThemeColor(0x7FB069), ThemeColor(0xF4A6C0)], opacity: 0.4),
        ])

    public static let meadow = Theme(
        id: .meadow, name: "Meadow", tagline: "Wildflowers, mushrooms and sunshine", tone: .light, palette: meadowPalette,
        typography: ThemeTypography(displayFont: "Noteworthy-Bold", bodyDesign: .serif), wallpaper: meadowWallpaper,
        celebration: .leaves)

    // MARK: Cosmic Sprinkles

    private static let cosmicPalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0x0A0F2C), ThemeColor(0x1B0B3A)], gradientAngle: 135,
        sidebarTint: ThemeColor(0x1B2160), sidebarTintOpacity: 0.55, composerTint: ThemeColor(0x7C5CFF),
        text: ThemeColor(0xEEF0FF), secondaryText: ThemeColor(0xC2C6EC), accent: ThemeColor(0x8C6CFF),
        link: ThemeColor(0x8FD3FF), alert: ThemeColor(0xFF9AB0),
        nameColors: [ThemeColor(0xFFC75F), ThemeColor(0x8FD3FF), ThemeColor(0xFF8FD8), ThemeColor(0x9DFFB0), ThemeColor(0xC3A6FF), ThemeColor(0xFF9F6B)])

    private static let cosmicWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.star, [ThemeColor(0xFFF3B0), ThemeColor(0xBFD7FF)], weight: 3),
            MotifSpec(.sparkle, [ThemeColor(0xBFD7FF), ThemeColor(0xFFB3E6)], weight: 3),
            MotifSpec(.planet, [ThemeColor(0xFF9F6B), ThemeColor(0xFFD8A8)], weight: 2),
            MotifSpec(.rocket, [ThemeColor(0xE8ECFF), ThemeColor(0xFF6B6B)], weight: 1),
            MotifSpec(.comet, [ThemeColor(0x8FD3FF)], weight: 1),
            MotifSpec(.dot, [ThemeColor(0xFFFFFF), ThemeColor(0xFF8FD8), ThemeColor(0x9DFFB0)], weight: 2),
        ],
        density: .medium, opacity: 0.22,
        ornaments: [OrnamentSpec(.ringedPlanet, .topTrailing, [ThemeColor(0x7C5CFF), ThemeColor(0xFFC75F)], opacity: 0.18)])

    public static let cosmic = Theme(
        id: .cosmic, name: "Cosmic Sprinkles", tagline: "Planets, rockets and stardust", tone: .dark, palette: cosmicPalette,
        typography: ThemeTypography(displayFont: "AvenirNext-Heavy", bodyDesign: .rounded), wallpaper: cosmicWallpaper,
        celebration: .stars)

    // MARK: Aurora

    private static let auroraPalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0x071A2B), ThemeColor(0x0C2A33)], gradientAngle: 90,
        sidebarTint: ThemeColor(0x0D3444), sidebarTintOpacity: 0.55, composerTint: ThemeColor(0x2FB98A),
        text: ThemeColor(0xECFFF8), secondaryText: ThemeColor(0xBFDDD6), accent: ThemeColor(0x4CF2B5),
        link: ThemeColor(0xA6EAFF), alert: ThemeColor(0xFFB0BC),
        nameColors: [ThemeColor(0x86F7CF), ThemeColor(0xA6EAFF), ThemeColor(0xD2BCFF), ThemeColor(0xFFDDA0), ThemeColor(0xFFB5D4), ThemeColor(0xC8F59A)],
        nameGlow: true)

    private static let auroraWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.star, [ThemeColor(0xE6FFF7)], weight: 2),
            MotifSpec(.sparkle, [ThemeColor(0xB8F2FF), ThemeColor(0xC3A6FF)], weight: 2),
            MotifSpec(.snowflake, [ThemeColor(0xCFEFFF)], style: .stroke, weight: 2),
            MotifSpec(.dot, [ThemeColor(0xFFFFFF)], weight: 2),
        ],
        density: .sparse, opacity: 0.19,
        ornaments: [
            OrnamentSpec(.aurora, .top, [ThemeColor(0x4CF2B5), ThemeColor(0x8F7CFF), ThemeColor(0x3DD6F5)], opacity: 0.2),
            OrnamentSpec(.mountains, .bottom, [ThemeColor(0x0F3442), ThemeColor(0x04111A)], opacity: 0.8),
        ])

    public static let aurora = Theme(
        id: .aurora, name: "Aurora", tagline: "Northern lights over snowy peaks", tone: .dark, palette: auroraPalette,
        typography: ThemeTypography(displayFont: "Optima-Bold"), wallpaper: auroraWallpaper,
        celebration: .snow)

    // MARK: Lemonade

    private static let lemonadePalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0xFFFBD1), ThemeColor(0xFFE7A6)], gradientAngle: 90,
        sidebarTint: ThemeColor(0xFFF1A8), sidebarTintOpacity: 0.42, composerTint: ThemeColor(0xFFC23D),
        text: ThemeColor(0x3B2A00), secondaryText: ThemeColor(0x604A00), accent: ThemeColor(0xB85200),
        link: ThemeColor(0x0C5E51), alert: ThemeColor(0x8C1D18),
        nameColors: [ThemeColor(0x8F2E00), ThemeColor(0x0C5E51), ThemeColor(0x960055), ThemeColor(0x553C98), ThemeColor(0x285E00), ThemeColor(0x004D7A)])

    private static let lemonadeWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.lemon, [ThemeColor(0xFFD93B), ThemeColor(0xFFF6C2)], weight: 3),
            MotifSpec(.cherry, [ThemeColor(0xE53950), ThemeColor(0x4E8A2E)], weight: 2),
            MotifSpec(.sun, [ThemeColor(0xFFB300)], weight: 1),
            MotifSpec(.sparkle, [ThemeColor(0xFFFFFF), ThemeColor(0xFF9E3D)], weight: 2),
            MotifSpec(.dot, [ThemeColor(0xFF9E3D), ThemeColor(0x7CCB5C)], weight: 1),
        ],
        density: .medium, opacity: 0.48,
        ornaments: [OrnamentSpec(.retroSun, .topTrailing, [ThemeColor(0xFFB300), ThemeColor(0xFF7A00)], opacity: 0.26)])

    public static let lemonade = Theme(
        id: .lemonade, name: "Lemonade", tagline: "Citrus slices and summer sun", tone: .light, palette: lemonadePalette,
        typography: ThemeTypography(displayFont: "MarkerFelt-Wide", bodyDesign: .rounded), wallpaper: lemonadeWallpaper,
        celebration: .confetti)

    // MARK: Peppermint

    private static let peppermintPalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0xF5FBFF), ThemeColor(0xE2F0FA)], gradientAngle: 90,
        sidebarTint: ThemeColor(0xFFE3E6), sidebarTintOpacity: 0.4, composerTint: ThemeColor(0xD7263D),
        text: ThemeColor(0x14263A), secondaryText: ThemeColor(0x3F5164), accent: ThemeColor(0xD7263D),
        link: ThemeColor(0x0A5694), alert: ThemeColor(0xB3001B),
        nameColors: [ThemeColor(0xB3162B), ThemeColor(0x0A5694), ThemeColor(0x146534), ThemeColor(0x703A93), ThemeColor(0x924808), ThemeColor(0x005D6E)])

    private static let peppermintWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.snowflake, [ThemeColor(0x8FC3E6), ThemeColor(0xB7D9F0)], style: .stroke, weight: 3),
            MotifSpec(.star, [ThemeColor(0xF2C14E)], weight: 1),
            MotifSpec(.dot, [ThemeColor(0xFFFFFF), ThemeColor(0xB7D9F0)], weight: 3),
            MotifSpec(.heart, [ThemeColor(0xF28B9B)], weight: 1),
        ],
        density: .dense, opacity: 0.55,
        ornaments: [OrnamentSpec(.cornerStripes, .topTrailing, [ThemeColor(0xD7263D), ThemeColor(0xFFFFFF), ThemeColor(0x2E9E5B), ThemeColor(0xFFFFFF)], opacity: 0.32)])

    public static let peppermint = Theme(
        id: .peppermint, name: "Peppermint", tagline: "Snowflakes and candy stripes", tone: .light, palette: peppermintPalette,
        typography: ThemeTypography(displayFont: "SnellRoundhand-Bold"), wallpaper: peppermintWallpaper,
        celebration: .snow)

    // MARK: Midnight Cocoa

    private static let cocoaPalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0x2A1C14), ThemeColor(0x1B110B)], gradientAngle: 90,
        sidebarTint: ThemeColor(0x45291A), sidebarTintOpacity: 0.55, composerTint: ThemeColor(0xB0703A),
        text: ThemeColor(0xF5E8DC), secondaryText: ThemeColor(0xC9B2A1), accent: ThemeColor(0xE0A45E),
        link: ThemeColor(0x8FD3C7), alert: ThemeColor(0xFF9585),
        nameColors: [ThemeColor(0xE0A45E), ThemeColor(0xF2B8C6), ThemeColor(0x9FD8CB), ThemeColor(0xE6C27A), ThemeColor(0xC9B8FF), ThemeColor(0xF5A97F)])

    private static let cocoaWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.heart, [ThemeColor(0xC98A6B)], weight: 2),
            MotifSpec(.spiral, [ThemeColor(0xB07A55)], style: .stroke, weight: 2),
            MotifSpec(.cloud, [ThemeColor(0xF5E8DC)], weight: 2),
            MotifSpec(.star, [ThemeColor(0xE0A45E)], weight: 1),
            MotifSpec(.dot, [ThemeColor(0xF5E8DC), ThemeColor(0xC98A6B)], weight: 2),
        ],
        density: .sparse, opacity: 0.2)

    public static let midnightCocoa = Theme(
        id: .midnightCocoa, name: "Midnight Cocoa", tagline: "Marshmallows and quiet midnights", tone: .dark, palette: cocoaPalette,
        typography: ThemeTypography(displayFont: "AmericanTypewriter-Bold", bodyDesign: .serif), wallpaper: cocoaWallpaper,
        celebration: .hearts)

    // MARK: Phosphor — green-screen terminal

    private static let phosphorPalette: ThemePalette = ThemePalette(
        gradient: [ThemeColor(0x020A04), ThemeColor(0x05160B)], gradientAngle: 90,
        sidebarTint: ThemeColor(0x06240F), sidebarTintOpacity: 0.6, composerTint: ThemeColor(0x1F8F3A),
        text: ThemeColor(0x9CFFAE), secondaryText: ThemeColor(0x52C46B), accent: ThemeColor(0x39FF6A),
        link: ThemeColor(0xD2FFB8), alert: ThemeColor(0xFFB000),
        nameColors: [ThemeColor(0x39FF6A), ThemeColor(0xB8FF5C), ThemeColor(0x5CFFD6), ThemeColor(0xFFD24D), ThemeColor(0x8CF0FF), ThemeColor(0xE5FF8C)],
        nameGlow: true)

    private static let phosphorWallpaper: ThemeWallpaper = ThemeWallpaper(
        motifs: [
            MotifSpec(.pixelStar, [ThemeColor(0x39FF6A)], weight: 2),
            MotifSpec(.pixelHeart, [ThemeColor(0x39FF6A)], weight: 2),
            MotifSpec(.cross, [ThemeColor(0x2BB24C)], weight: 1),
        ],
        density: .sparse, opacity: 0.14,
        ornaments: [OrnamentSpec(.scanlines, .fill, [ThemeColor(0x000000)], opacity: 0.35)])

    public static let phosphor = Theme(
        id: .phosphor, name: "Phosphor", tagline: "Green-screen glow, scanlines included", tone: .dark, palette: phosphorPalette,
        typography: ThemeTypography(displayFont: "Menlo-Bold", bodyDesign: .monospaced), wallpaper: phosphorWallpaper,
        celebration: .stars)
}
