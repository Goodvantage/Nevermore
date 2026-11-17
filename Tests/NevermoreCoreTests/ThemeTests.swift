import XCTest
@testable import NevermoreCore

final class ThemeTests: XCTestCase {
    func testEveryThemeIDHasExactlyOneCatalogEntry() {
        XCTAssertEqual(ThemeCatalog.all.map(\.id), ThemeID.allCases)
        XCTAssertEqual(Set(ThemeCatalog.all.map(\.name)).count, ThemeCatalog.all.count, "theme names must be unique")
        XCTAssertEqual(ThemeCatalog.all.first?.id, .classic, "Classic leads the gallery")
    }

    func testEveryThemeMeetsContrastMinimums() {
        for theme in ThemeCatalog.all {
            let violations = ThemeAudit.violations(in: theme)
            XCTAssertTrue(violations.isEmpty, violations.map(\.description).joined(separator: "\n"))
        }
    }

    func testEveryThemeIsStructurallySound() {
        for theme in ThemeCatalog.all {
            let problems = ThemeAudit.problems(in: theme)
            XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n"))
        }
    }

    func testRequestedThemesShip() {
        let ids = Set(ThemeCatalog.all.map(\.id))
        for required: ThemeID in [.memphis, .halloween, .neonFun] { XCTAssertTrue(ids.contains(required), "\(required) is missing") }
    }

    func testClassicKeepsTheSystemLook() {
        let classic = ThemeCatalog.classic
        XCTAssertNil(classic.palette)
        XCTAssertEqual(classic.tone, .system)
        XCTAssertTrue(classic.wallpaper.isEmpty)
        XCTAssertNil(classic.typography.displayFont)
        XCTAssertEqual(classic.typography.bodyDesign, .standard)
    }

    func testStoredPreferenceFallsBackToClassic() {
        XCTAssertEqual(ThemeCatalog.theme(storedAs: nil).id, .classic)
        XCTAssertEqual(ThemeCatalog.theme(storedAs: "").id, .classic)
        XCTAssertEqual(ThemeCatalog.theme(storedAs: "a-theme-from-the-future").id, .classic)
        XCTAssertEqual(ThemeCatalog.theme(storedAs: "halloween").id, .halloween)
        for theme in ThemeCatalog.all { XCTAssertEqual(ThemeCatalog.theme(storedAs: theme.id.rawValue), theme) }
    }

    func testStoredRawValuesStayStable() {
        // Raw values are persisted in user defaults; renaming one silently
        // resets returning users to Classic. If adding a theme breaks the
        // count assertion, pin its raw value here too.
        XCTAssertEqual(ThemeID.allCases.count, 16, "pin the new theme's persisted raw value")
        XCTAssertEqual(ThemeID.classic.rawValue, "classic")
        XCTAssertEqual(ThemeID.memphis.rawValue, "memphis")
        XCTAssertEqual(ThemeID.halloween.rawValue, "halloween")
        XCTAssertEqual(ThemeID.neonFun.rawValue, "neonFun")
        XCTAssertEqual(ThemeID.bubblegum.rawValue, "bubblegum")
        XCTAssertEqual(ThemeID.nevermore.rawValue, "nevermore")
        XCTAssertEqual(ThemeID.synthwave.rawValue, "synthwave")
        XCTAssertEqual(ThemeID.vaporwave.rawValue, "vaporwave")
        XCTAssertEqual(ThemeID.underTheSea.rawValue, "underTheSea")
        XCTAssertEqual(ThemeID.meadow.rawValue, "meadow")
        XCTAssertEqual(ThemeID.cosmic.rawValue, "cosmic")
        XCTAssertEqual(ThemeID.aurora.rawValue, "aurora")
        XCTAssertEqual(ThemeID.lemonade.rawValue, "lemonade")
        XCTAssertEqual(ThemeID.peppermint.rawValue, "peppermint")
        XCTAssertEqual(ThemeID.midnightCocoa.rawValue, "midnightCocoa")
        XCTAssertEqual(ThemeID.phosphor.rawValue, "phosphor")
    }

    // MARK: Colors

    func testHexParsing() {
        XCTAssertEqual(ThemeColor(hex: "#FB04B5"), ThemeColor(0xFB04B5))
        XCTAssertEqual(ThemeColor(hex: "fb04b5"), ThemeColor(0xFB04B5))
        XCTAssertEqual(ThemeColor(0x02FBF6).hex, "#02FBF6")
        for bad in ["", "#", "#12345", "#1234567", "#GG0000", "red", "#12 456"] { XCTAssertNil(ThemeColor(hex: bad), bad) }
    }

    func testContrastMatchesWCAGReferenceValues() {
        let black = ThemeColor(0x000000), white = ThemeColor(0xFFFFFF)
        XCTAssertEqual(black.contrast(with: white), 21, accuracy: 0.001)
        XCTAssertEqual(white.contrast(with: white), 1, accuracy: 0.001)
        // #777777 on white is the classic 4.48:1 near-miss.
        XCTAssertEqual(ThemeColor(0x777777).contrast(with: white), 4.48, accuracy: 0.01)
        XCTAssertEqual(ThemeColor(0x767676).contrast(with: white), 4.54, accuracy: 0.01)
    }

    func testBlendingAndReadableForeground() {
        let red = ThemeColor(0xFF0000), white = ThemeColor(0xFFFFFF)
        XCTAssertEqual(red.blended(over: white, opacity: 0), white)
        XCTAssertEqual(red.blended(over: white, opacity: 1), red)
        XCTAssertEqual(red.blended(over: white, opacity: 0.5).hex, "#FF8080")
        XCTAssertEqual(ThemeColor(0xFDE133).readableForeground, ThemeColor(0x000000))
        XCTAssertEqual(ThemeColor(0x1E0B33).readableForeground, ThemeColor(0xFFFFFF))
    }

    func testAuditCatchesTextLostInTheWallpaper() {
        let palette = ThemePalette(gradient: [ThemeColor(0x101010), ThemeColor(0x101010)], sidebarTint: ThemeColor(0x101010), sidebarTintOpacity: 0.5,
                                   composerTint: ThemeColor(0x101010), text: ThemeColor(0xFFFFFF), secondaryText: ThemeColor(0xBBBBBB),
                                   accent: ThemeColor(0xFF2E97), link: ThemeColor(0x3DF5FF), alert: ThemeColor(0xFF6F8E),
                                   nameColors: [ThemeColor(0xFFFFFF), ThemeColor(0xEEEEEE), ThemeColor(0xDDDDDD), ThemeColor(0xCCCCCC)])
        let loud = ThemeWallpaper(motifs: [MotifSpec(.dot, [ThemeColor(0xFFFFFF)])], opacity: 0.9)
        let theme = Theme(id: .neonFun, name: "Test", tagline: "", tone: .dark, palette: palette, wallpaper: loud)
        XCTAssertTrue(ThemeAudit.violations(in: theme).contains { $0.role == "text" }, "white motifs at 90% hide white text")
        let quiet = Theme(id: .neonFun, name: "Test", tagline: "", tone: .dark, palette: palette, wallpaper: ThemeWallpaper(motifs: loud.motifs, opacity: 0.1))
        XCTAssertFalse(ThemeAudit.violations(in: quiet).contains { $0.role == "text" })
    }

    func testBackdropSamplesCoverAdjacentGradientStops() throws {
        let palette = ThemePalette(gradient: [ThemeColor(0x000000), ThemeColor(0x808080), ThemeColor(0xFFFFFF)],
                                   sidebarTint: ThemeColor(0x101010), sidebarTintOpacity: 0.5, composerTint: ThemeColor(0x101010),
                                   text: ThemeColor(0xFFFFFF), secondaryText: ThemeColor(0xBBBBBB), accent: ThemeColor(0xFF2E97),
                                   link: ThemeColor(0x3DF5FF), alert: ThemeColor(0xFF6F8E),
                                   nameColors: [ThemeColor(0xFFFFFF), ThemeColor(0xEEEEEE), ThemeColor(0xDDDDDD), ThemeColor(0xCCCCCC)])
        // Three stops plus the two adjacent midpoints.
        XCTAssertEqual(ThemeAudit.backdropSamples(palette).count, 5)
        // A two-stop gradient keeps its three samples.
        XCTAssertEqual(ThemeAudit.backdropSamples(try XCTUnwrap(ThemeCatalog.memphis.palette)).count, 3)
    }

    func testAuditFlagsToneMismatch() {
        let light = ThemeCatalog.memphis
        let mislabeled = Theme(id: light.id, name: light.name, tagline: light.tagline, tone: .dark, palette: light.palette)
        XCTAssertTrue(ThemeAudit.problems(in: mislabeled).contains { $0.contains("dark tone over a light backdrop") })
    }

    func testAuditReportsEachStructuralProblem() throws {
        let dark = try XCTUnwrap(ThemeCatalog.nevermore.palette)
        let light = try XCTUnwrap(ThemeCatalog.memphis.palette)
        func palette(_ base: ThemePalette, gradient: [ThemeColor]? = nil, sidebarTint: ThemeColor? = nil, names: [ThemeColor]? = nil) -> ThemePalette {
            ThemePalette(gradient: gradient ?? base.gradient, sidebarTint: sidebarTint ?? base.sidebarTint, sidebarTintOpacity: base.sidebarTintOpacity,
                         composerTint: base.composerTint, text: base.text, secondaryText: base.secondaryText, accent: base.accent,
                         link: base.link, alert: base.alert, nameColors: names ?? base.nameColors)
        }
        func theme(_ tone: ThemeTone, _ palette: ThemePalette?, wallpaper: ThemeWallpaper = .none) -> Theme {
            Theme(id: .memphis, name: "Test", tagline: "", tone: tone, palette: palette, wallpaper: wallpaper)
        }
        let cases: [(Theme, String)] = [
            (theme(.dark, nil), "must follow the system tone"),
            (theme(.system, nil, wallpaper: ThemeWallpaper(motifs: [MotifSpec(.dot, [ThemeColor(0x000000)])], opacity: 0.2)), "draws no wallpaper"),
            (theme(.system, light), "must force light or dark"),
            (theme(.light, palette(light, gradient: [light.gradient[0]])), "two stops"),
            (theme(.light, palette(light, names: Array(light.nameColors.prefix(3)))), "at least four name colors"),
            (theme(.light, palette(light, names: [light.nameColors[0]] + light.nameColors.dropLast())), "duplicate name colors"),
            (theme(.light, dark), "light tone over a dark backdrop"),
            (theme(.dark, palette(dark, sidebarTint: ThemeColor(0xFFFFFF))), "dark tone with a light sidebar tint"),
            (theme(.light, palette(light, sidebarTint: ThemeColor(0x000000))), "light tone with a dark sidebar tint"),
            (theme(.light, light, wallpaper: ThemeWallpaper(motifs: [MotifSpec(.dot, [])], opacity: 0.2)), "dot has no colors"),
            (theme(.light, light, wallpaper: ThemeWallpaper(motifs: [], opacity: 0.2, ornaments: [OrnamentSpec(.scanlines, .fill, [], opacity: 0.2)])), "scanlines has no colors"),
            (theme(.light, light, wallpaper: ThemeWallpaper(motifs: [MotifSpec(.dot, [ThemeColor(0x000000)])], opacity: 0)), "motifs at zero opacity"),
        ]
        for (theme, expected) in cases {
            let problems = ThemeAudit.problems(in: theme)
            XCTAssertTrue(problems.contains { $0.contains(expected) }, "expected \"\(expected)\" in \(problems)")
        }
    }

    func testOnlyOrnamentsSharingAnAnchorStack() {
        let sun = OrnamentSpec(.retroSun, .bottom, [ThemeColor(0xFFD35C)], opacity: 0.2)
        let grid = OrnamentSpec(.perspectiveGrid, .bottom, [ThemeColor(0xFB1A91)], opacity: 0.2)
        let moon = OrnamentSpec(.moonLarge, .topTrailing, [ThemeColor(0xFFE9A8)], opacity: 0.2)
        let lines = OrnamentSpec(.scanlines, .fill, [ThemeColor(0x000000)], opacity: 0.2)
        XCTAssertEqual(ThemeAudit.overlappingOrnaments([sun, moon, grid]), [[sun, grid], [moon]])
        XCTAssertEqual(ThemeAudit.overlappingOrnaments([lines, moon]), [[lines, moon]])
        XCTAssertEqual(ThemeAudit.overlappingOrnaments([lines]), [[lines]])
        XCTAssertEqual(ThemeAudit.overlappingOrnaments([]), [])
    }

    func testAuditChecksCodeTextOnItsWash() throws {
        // Light text gets a darkening wash, which can only raise its contrast.
        let neon = try XCTUnwrap(ThemeCatalog.neonFun.palette)
        XCTAssertEqual(neon.codeBackground, ThemeColor(0x000000))
        let backdrop = neon.gradient[0]
        XCTAssertGreaterThanOrEqual(neon.text.contrast(with: neon.codeBackground.blended(over: backdrop, opacity: neon.codeBackgroundOpacity)),
                                    neon.text.contrast(with: backdrop))
        // A wash as strong as the text itself hides the code.
        let memphis = ThemeCatalog.memphis
        let hidden = try XCTUnwrap(memphis.palette)
        let washedOut = ThemePalette(gradient: hidden.gradient, sidebarTint: hidden.sidebarTint, sidebarTintOpacity: hidden.sidebarTintOpacity,
                                     composerTint: hidden.composerTint, text: ThemeColor(0x777777), secondaryText: hidden.secondaryText,
                                     accent: hidden.accent, link: hidden.link, alert: hidden.alert, nameColors: hidden.nameColors)
        let flagged = ThemeAudit.violations(in: Theme(id: .memphis, name: "Test", tagline: "", tone: .light, palette: washedOut))
        XCTAssertTrue(flagged.contains { $0.role == "code text" })
    }

    // MARK: Name colors

    func testNameColorsAreStablePerAuthor() throws {
        let palette = try XCTUnwrap(ThemeCatalog.neonFun.palette)
        XCTAssertEqual(palette.nameColor(for: "lenore@example.com"), palette.nameColor(for: "lenore@example.com"))
        // FNV-1a is fixed across launches, unlike `hashValue`.
        XCTAssertEqual(ThemePalette.stableIndex(for: "a", count: 6), Int(UInt64(0xaf63_dc4c_8601_ec8c) % 6))
        XCTAssertEqual(ThemePalette.stableIndex(for: "anything", count: 0), 0)
        let spread = Set((0..<60).map { palette.nameColor(for: "user\($0)@example.com") })
        XCTAssertEqual(spread.count, palette.nameColors.count, "sixty authors use every name color")
    }

    // MARK: Wallpaper layout

    func testWallpaperLayoutIsDeterministic() throws {
        let wallpaper = ThemeCatalog.memphis.wallpaper
        let seed = WallpaperLayout.seed(for: .memphis)
        XCTAssertEqual(WallpaperLayout.scatter(wallpaper, seed: seed), WallpaperLayout.scatter(wallpaper, seed: seed))
        XCTAssertNotEqual(WallpaperLayout.scatter(wallpaper, seed: seed), WallpaperLayout.scatter(wallpaper, seed: seed &+ 1))
        XCTAssertNotEqual(WallpaperLayout.seed(for: .memphis), WallpaperLayout.seed(for: .halloween))
    }

    func testWallpaperLayoutKeepsSpacingAcrossTileEdges() {
        for theme in ThemeCatalog.all where !theme.wallpaper.motifs.isEmpty {
            let tile = WallpaperLayout.tileSize
            let placements = WallpaperLayout.scatter(theme.wallpaper, seed: WallpaperLayout.seed(for: theme.id))
            XCTAssertGreaterThan(placements.count, 8, "\(theme.id) wallpaper is too empty")
            let spacing = theme.wallpaper.density.spacing
            for (index, a) in placements.enumerated() {
                XCTAssertTrue((0..<tile).contains(a.x) && (0..<tile).contains(a.y))
                XCTAssertLessThan(a.size, spacing, "motifs must not touch")
                XCTAssertLessThanOrEqual(abs(a.rotation), theme.wallpaper.motifs[a.specIndex].motif.maximumTilt + 1e-9)
                XCTAssertTrue(theme.wallpaper.motifs[a.specIndex].colors.indices.contains(a.colorIndex))
                for b in placements[(index + 1)...] {
                    let dx = WallpaperLayout.wrappedDistance(a.x, b.x, tile), dy = WallpaperLayout.wrappedDistance(a.y, b.y, tile)
                    XCTAssertGreaterThanOrEqual((dx * dx + dy * dy).squareRoot(), spacing - 1e-9, "\(theme.id) motifs crowd across a tile edge")
                }
            }
        }
    }

    func testWallpaperLayoutFollowsWeights() {
        let wallpaper = ThemeWallpaper(motifs: [MotifSpec(.dot, [ThemeColor(0)], weight: 5), MotifSpec(.star, [ThemeColor(0)], weight: 1)], density: .dense, opacity: 0.3)
        var dots = 0, stars = 0
        for seed: UInt64 in 1...20 {
            for placement in WallpaperLayout.scatter(wallpaper, seed: seed) { if placement.specIndex == 0 { dots += 1 } else { stars += 1 } }
        }
        XCTAssertGreaterThan(stars, 0)
        XCTAssertGreaterThan(Double(dots) / Double(stars), 3, "weight 5 against weight 1")
    }

    func testMultiPartMotifsKeepTheirColorOrder() {
        let wallpaper = ThemeWallpaper(motifs: [MotifSpec(.pumpkin, [ThemeColor(0xFF7A1A), ThemeColor(0x6FBF3A)])], opacity: 0.3)
        XCTAssertTrue(WallpaperLayout.scatter(wallpaper, seed: 7).allSatisfy { $0.colorIndex == 0 })
        XCTAssertEqual(ThemeWallpaper.none.isEmpty, true)
        XCTAssertTrue(WallpaperLayout.scatter(.none, seed: 1).isEmpty)
    }
}
