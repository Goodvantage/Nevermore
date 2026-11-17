import Foundation
import XCTest
@testable import NevermoreCore

final class ThemeCustomizationTests: XCTestCase {

    // MARK: Applying

    func testEmptyCustomizationLeavesEveryCatalogThemeUnchanged() {
        let empty = ThemeCustomization()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertFalse(fullCustomization().isEmpty)
        for theme in ThemeCatalog.all {
            XCTAssertEqual(theme.applying(empty), theme, theme.id.rawValue)
        }
    }

    func testApplyingCustomizationReplacesEveryFieldOfHalloween() throws {
        let halloween = ThemeCatalog.halloween
        let preset = try XCTUnwrap(halloween.palette)
        let custom = fullCustomization()
        let applied = halloween.applying(custom)
        let palette = try XCTUnwrap(applied.palette)

        XCTAssertEqual(applied.id, halloween.id)
        XCTAssertEqual(applied.name, halloween.name)
        XCTAssertEqual(applied.tagline, halloween.tagline)

        XCTAssertEqual(applied.tone, .light)
        XCTAssertEqual(palette.gradient, custom.gradient)
        XCTAssertEqual(palette.gradientAngle, 137)
        XCTAssertEqual(palette.sidebarTint, ThemeColor(0x222222))
        XCTAssertEqual(palette.sidebarTintOpacity, 0.25)
        XCTAssertEqual(palette.composerTint, ThemeColor(0x333333))
        XCTAssertEqual(palette.text, ThemeColor(0x444444))
        XCTAssertEqual(palette.secondaryText, ThemeColor(0x555555))
        XCTAssertEqual(palette.accent, ThemeColor(0x666666))
        XCTAssertEqual(palette.link, ThemeColor(0x777777))
        XCTAssertEqual(palette.alert, ThemeColor(0x888888))
        XCTAssertEqual(palette.nameColors, custom.nameColors)
        XCTAssertEqual(palette.nameGlow, true)
        XCTAssertEqual(applied.typography.displayFont, "Custom-Font")
        XCTAssertEqual(applied.typography.bodyDesign, .serif)
        XCTAssertEqual(applied.wallpaper.motifs, custom.motifs)
        XCTAssertEqual(applied.wallpaper.density, .dense)
        XCTAssertEqual(applied.wallpaper.opacity, 0.42)
        XCTAssertEqual(applied.wallpaper.ornaments, custom.ornaments)
        XCTAssertEqual(applied.celebration, .stars)

        // The preset values really are different, so each assertion above is a replacement.
        XCTAssertNotEqual(preset.gradient, try XCTUnwrap(custom.gradient))
        XCTAssertNotEqual(preset.text, try XCTUnwrap(custom.text))
        XCTAssertNotEqual(preset.nameColors, try XCTUnwrap(custom.nameColors))
        XCTAssertNotEqual(halloween.typography.displayFont, try XCTUnwrap(custom.displayFont))
        XCTAssertNotEqual(halloween.wallpaper.motifs, try XCTUnwrap(custom.motifs))
        XCTAssertNotEqual(halloween.wallpaper.ornaments, try XCTUnwrap(custom.ornaments))
    }

    func testDisplayFontNilKeepsPresetEmptyStringAsksForSystemAndNameSetsIt() {
        let halloween = ThemeCatalog.halloween
        XCTAssertEqual(halloween.typography.displayFont, "Chalkduster")

        var customization = ThemeCustomization()
        customization.displayFont = nil
        XCTAssertEqual(halloween.applying(customization).typography.displayFont, "Chalkduster")

        customization.displayFont = ThemeCustomization.systemDisplayFont
        XCTAssertNil(halloween.applying(customization).typography.displayFont)

        customization.displayFont = "Custom-Font"
        XCTAssertEqual(halloween.applying(customization).typography.displayFont, "Custom-Font")

        // A preset with no face of its own stays on the system font either way.
        let bubblegum = ThemeCatalog.bubblegum
        XCTAssertNil(bubblegum.typography.displayFont)
        customization.displayFont = nil
        XCTAssertNil(bubblegum.applying(customization).typography.displayFont)
        customization.displayFont = ThemeCustomization.systemDisplayFont
        XCTAssertNil(bubblegum.applying(customization).typography.displayFont)
    }

    func testClassicIgnoresCustomizationAndNormalizesToEmpty() {
        let classic = ThemeCatalog.classic
        let custom = fullCustomization()
        XCTAssertEqual(classic.applying(custom), classic)
        XCTAssertTrue(custom.normalized(for: classic).isEmpty)
    }

    // MARK: Sanitizing

    func testSanitizedDropsSystemToneAndInvalidGradientStopCounts() {
        var customization = ThemeCustomization()
        customization.tone = .system
        XCTAssertNil(customization.sanitized.tone)
        customization.tone = .light
        XCTAssertEqual(customization.sanitized.tone, .light)
        customization.tone = .dark
        XCTAssertEqual(customization.sanitized.tone, .dark)

        customization.gradient = [ThemeColor(0x000000)]
        XCTAssertNil(customization.sanitized.gradient)
        customization.gradient = [ThemeColor(0x000000), ThemeColor(0xFFFFFF)]
        XCTAssertEqual(customization.sanitized.gradient, [ThemeColor(0x000000), ThemeColor(0xFFFFFF)])
        customization.gradient = [ThemeColor(0x000000), ThemeColor(0x333333), ThemeColor(0x666666), ThemeColor(0xFFFFFF)]
        XCTAssertEqual(customization.sanitized.gradient?.count, 4)
        customization.gradient = [ThemeColor(0x000000), ThemeColor(0x333333), ThemeColor(0x666666), ThemeColor(0x999999), ThemeColor(0xFFFFFF)]
        XCTAssertNil(customization.sanitized.gradient)
    }

    func testSanitizedWrapsAnglesAndClampsOpacities() {
        var customization = ThemeCustomization()
        customization.gradientAngle = -90
        XCTAssertEqual(customization.sanitized.gradientAngle, 270)
        customization.gradientAngle = 450
        XCTAssertEqual(customization.sanitized.gradientAngle, 90)
        customization.gradientAngle = 360
        XCTAssertEqual(customization.sanitized.gradientAngle, 0)
        customization.gradientAngle = .infinity
        XCTAssertNil(customization.sanitized.gradientAngle)
        customization.gradientAngle = .nan
        XCTAssertNil(customization.sanitized.gradientAngle)

        customization.sidebarTintOpacity = 1.5
        XCTAssertEqual(customization.sanitized.sidebarTintOpacity, 1)
        customization.sidebarTintOpacity = -0.2
        XCTAssertEqual(customization.sanitized.sidebarTintOpacity, 0)
        customization.sidebarTintOpacity = .nan
        XCTAssertNil(customization.sanitized.sidebarTintOpacity)

        customization.motifOpacity = 1.5
        XCTAssertEqual(customization.sanitized.motifOpacity, 1)
        customization.motifOpacity = -0.2
        XCTAssertEqual(customization.sanitized.motifOpacity, 0)
        customization.motifOpacity = .nan
        XCTAssertNil(customization.sanitized.motifOpacity)
    }

    func testSanitizedDropsInvalidNameColorsAndOverlongFontNames() {
        var customization = ThemeCustomization()
        customization.nameColors = []
        XCTAssertNil(customization.sanitized.nameColors)
        customization.nameColors = Array(repeating: ThemeColor(0x123456), count: 13)
        XCTAssertNil(customization.sanitized.nameColors)
        customization.nameColors = Array(repeating: ThemeColor(0x123456), count: 12)
        XCTAssertEqual(customization.sanitized.nameColors?.count, 12)
        customization.nameColors = [ThemeColor(0x123456)]
        XCTAssertEqual(customization.sanitized.nameColors, [ThemeColor(0x123456)])

        customization.displayFont = String(repeating: "A", count: 129)
        XCTAssertNil(customization.sanitized.displayFont)
        customization.displayFont = String(repeating: "A", count: 128)
        XCTAssertEqual(customization.sanitized.displayFont, String(repeating: "A", count: 128))
    }

    func testSanitizedFiltersMotifsAndOrnaments() {
        var customization = ThemeCustomization()
        let uncolored = MotifSpec(.star, [])
        let colored = MotifSpec(.dot, [ThemeColor(0x000000)])
        customization.motifs = [uncolored, colored]
        XCTAssertEqual(customization.sanitized.motifs, [colored])

        let manyMotifs = (0..<15).map { MotifSpec(ThemeMotif.allCases[$0], [ThemeColor(0x000000)]) }
        customization.motifs = manyMotifs
        XCTAssertEqual(customization.sanitized.motifs, Array(manyMotifs.prefix(12)))

        let eightColors = (0..<8).map { ThemeColor(UInt32($0) * 0x111111) }
        customization.motifs = [MotifSpec(.dot, eightColors)]
        XCTAssertEqual(customization.sanitized.motifs?.first?.colors, Array(eightColors.prefix(6)))

        let noColors = OrnamentSpec(.scanlines, .fill, [], opacity: 0.5)
        let ornament = OrnamentSpec(.moonLarge, .top, [ThemeColor(0x000000)], opacity: 0.5)
        customization.ornaments = [noColors, ornament]
        XCTAssertEqual(customization.sanitized.ornaments, [ornament])

        let manyOrnaments = (0..<8).map { OrnamentSpec(OrnamentKind.allCases[$0], .top, [ThemeColor(0x000000)], opacity: 0.5) }
        customization.ornaments = manyOrnaments
        XCTAssertEqual(customization.sanitized.ornaments, Array(manyOrnaments.prefix(6)))
    }

    /// Earlier versions stored an empty-window title and art per theme.
    /// Home replaced that pane, so the fields are gone; a stored
    /// customization that still has them keeps everything else.
    func testRetiredEmptyStateFieldsAreIgnored() throws {
        let json = ##"{"emptyTitle":"ＡＥＳＴＨＥＴＩＣ ＳＩＬＥＮＣＥ","emptyMotif":"ghost","link":"#112233"}"##
        let decoded = try JSONDecoder().decode(ThemeCustomization.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.link, ThemeColor(0x112233))
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(encoded.contains("empty"))
    }

    // MARK: Normalizing

    func testNormalizedForMemphisRemovesEveryFieldSetToThePresetValue() throws {
        let memphis = ThemeCatalog.memphis
        let preset = try XCTUnwrap(memphis.palette)
        var customization = ThemeCustomization()
        customization.tone = memphis.tone
        customization.gradient = preset.gradient
        customization.gradientAngle = preset.gradientAngle
        customization.sidebarTint = preset.sidebarTint
        customization.sidebarTintOpacity = preset.sidebarTintOpacity
        customization.composerTint = preset.composerTint
        customization.text = preset.text
        customization.secondaryText = preset.secondaryText
        customization.accent = preset.accent
        customization.link = preset.link
        customization.alert = preset.alert
        customization.nameColors = preset.nameColors
        customization.nameGlow = preset.nameGlow
        customization.displayFont = memphis.typography.displayFont
        customization.bodyDesign = memphis.typography.bodyDesign
        customization.motifs = memphis.wallpaper.motifs
        customization.density = memphis.wallpaper.density
        customization.motifOpacity = memphis.wallpaper.opacity
        customization.ornaments = memphis.wallpaper.ornaments
        customization.celebration = memphis.celebration

        XCTAssertTrue(customization.normalized(for: memphis).isEmpty, "every field repeats the preset")
    }

    func testNormalizedForBubblegumTreatsSystemDisplayFontAsThePresetFace() {
        let bubblegum = ThemeCatalog.bubblegum
        XCTAssertNil(bubblegum.typography.displayFont)

        var customization = ThemeCustomization()
        customization.displayFont = ThemeCustomization.systemDisplayFont
        XCTAssertTrue(customization.normalized(for: bubblegum).isEmpty)

        customization.displayFont = "Futura-Bold"
        XCTAssertEqual(customization.normalized(for: bubblegum).displayFont, "Futura-Bold")
    }

    func testNormalizedKeepsFieldsThatDifferFromThePreset() throws {
        let memphis = ThemeCatalog.memphis
        let preset = try XCTUnwrap(memphis.palette)
        var customization = ThemeCustomization()
        customization.tone = .dark
        customization.text = ThemeColor(0x123456)
        customization.nameGlow = !preset.nameGlow

        let normalized = customization.normalized(for: memphis)
        XCTAssertEqual(normalized.tone, .dark)
        XCTAssertEqual(normalized.text, ThemeColor(0x123456))
        XCTAssertEqual(normalized.nameGlow, !preset.nameGlow)
    }

    // MARK: Codable

    func testCustomizationRoundTripsThroughJSON() throws {
        let customization = fullCustomization()
        let data = try JSONEncoder().encode(customization)
        let decoded = try JSONDecoder().decode(ThemeCustomization.self, from: data)
        XCTAssertEqual(decoded, customization)
    }

    func testThemeColorEncodesAsHexString() throws {
        let data = try JSONEncoder().encode([ThemeColor(0xFB04B5)])
        XCTAssertEqual(String(data: data, encoding: .utf8), "[\"#FB04B5\"]")
    }

    func testLenientDecodingDropsUnreadableFields() throws {
        let json = """
        {"accent":"not-a-color","link":"#112233","emptyMotif":"unicorn","motifs":[{"motif":"unicorn","colors":["#000000"],"style":"fill","weight":2}],"density":"dense","futureField":1}
        """
        let decoded = try JSONDecoder().decode(ThemeCustomization.self, from: Data(json.utf8))
        XCTAssertNil(decoded.accent)
        XCTAssertEqual(decoded.link, ThemeColor(0x112233))
        XCTAssertNil(decoded.motifs)
        XCTAssertEqual(decoded.density, .dense)
    }

    func testDecodingClampsMotifWeightAndOrnamentOpacity() throws {
        let heavyMotif = try JSONDecoder().decode(MotifSpec.self, from: Data(##"{"motif":"dot","colors":["#000000"],"style":"fill","weight":99}"##.utf8))
        XCTAssertEqual(heavyMotif.weight, 5)
        let lightMotif = try JSONDecoder().decode(MotifSpec.self, from: Data(##"{"motif":"dot","colors":["#000000"],"style":"fill","weight":-3}"##.utf8))
        XCTAssertEqual(lightMotif.weight, 1)

        let brightOrnament = try JSONDecoder().decode(OrnamentSpec.self, from: Data(##"{"kind":"moonLarge","anchor":"top","colors":["#000000"],"opacity":7}"##.utf8))
        XCTAssertEqual(brightOrnament.opacity, 1)
    }

    // MARK: Fading the backdrop

    func testFadingBackdropReturnsTheThemeUnchangedAtFullOpacityAndNaN() {
        let halloween = ThemeCatalog.halloween
        XCTAssertEqual(halloween.fadingBackdrop(to: 1), halloween)
        XCTAssertEqual(halloween.fadingBackdrop(to: 2), halloween)
        XCTAssertEqual(halloween.fadingBackdrop(to: .infinity), halloween)
        XCTAssertEqual(halloween.fadingBackdrop(to: .nan), halloween)
    }

    func testClassicIsUnchangedByFadingBackdropAtAnyOpacity() {
        let classic = ThemeCatalog.classic
        for opacity in [1.0, 2.0, 0.75, 0.5, 0.25, 0.0, -1.0, .nan] {
            XCTAssertEqual(classic.fadingBackdrop(to: opacity), classic, "\(opacity)")
        }
    }

    func testFadingBackdropAtHalfOpacityOnHalloween() throws {
        let halloween = ThemeCatalog.halloween
        let preset = try XCTUnwrap(halloween.palette)
        let faded = halloween.fadingBackdrop(to: 0.5)
        let palette = try XCTUnwrap(faded.palette)

        for (index, stop) in preset.gradient.enumerated() {
            XCTAssertEqual(palette.gradient[index], stop.blended(over: Theme.plainDarkBackground, opacity: 0.5))
        }
        XCTAssertEqual(palette.sidebarTintOpacity, preset.sidebarTintOpacity * 0.5, accuracy: 1e-9)
        XCTAssertEqual(faded.wallpaper.opacity, halloween.wallpaper.opacity * 0.5, accuracy: 1e-9)
        XCTAssertEqual(faded.wallpaper.ornaments.count, halloween.wallpaper.ornaments.count)
        for (index, ornament) in halloween.wallpaper.ornaments.enumerated() {
            XCTAssertEqual(faded.wallpaper.ornaments[index].opacity, ornament.opacity * 0.5, accuracy: 1e-9)
        }
        XCTAssertEqual(palette.text, preset.text)
        XCTAssertEqual(palette.accent, preset.accent)
        XCTAssertEqual(faded.wallpaper.motifs, halloween.wallpaper.motifs)
        XCTAssertEqual(faded.tone, halloween.tone)
        XCTAssertEqual(faded.id, halloween.id)
        XCTAssertEqual(faded.name, halloween.name)
        XCTAssertEqual(faded.tagline, halloween.tagline)
        XCTAssertEqual(faded.celebration, halloween.celebration)
        XCTAssertEqual(faded.typography, halloween.typography)
    }

    func testFadingBackdropLightThemeBlendsTowardPlainLightBackground() throws {
        let memphis = ThemeCatalog.memphis
        let preset = try XCTUnwrap(memphis.palette)
        let faded = memphis.fadingBackdrop(to: 0.5)
        let palette = try XCTUnwrap(faded.palette)

        for (index, stop) in preset.gradient.enumerated() {
            XCTAssertEqual(palette.gradient[index], stop.blended(over: Theme.plainLightBackground, opacity: 0.5))
        }
        XCTAssertEqual(palette.text, preset.text)
    }

    func testFadingBackdropAtZeroOpacityReachesThePlainBackground() throws {
        let halloween = ThemeCatalog.halloween
        let dark = halloween.fadingBackdrop(to: 0)
        let darkPalette = try XCTUnwrap(dark.palette)
        XCTAssertEqual(darkPalette.gradient, [Theme.plainDarkBackground, Theme.plainDarkBackground])
        XCTAssertTrue(dark.wallpaper.isEmpty)
        XCTAssertEqual(darkPalette.sidebarTintOpacity, 0, accuracy: 1e-9)
        XCTAssertEqual(dark.wallpaper.opacity, 0, accuracy: 1e-9)

        let memphis = ThemeCatalog.memphis
        let light = memphis.fadingBackdrop(to: 0)
        let lightPalette = try XCTUnwrap(light.palette)
        XCTAssertEqual(lightPalette.gradient, [Theme.plainLightBackground, Theme.plainLightBackground])
        XCTAssertTrue(light.wallpaper.isEmpty)
    }

    func testFadingBackdropWithNegativeOpacityBehavesLikeZero() {
        let halloween = ThemeCatalog.halloween
        XCTAssertEqual(halloween.fadingBackdrop(to: -0.25), halloween.fadingBackdrop(to: 0))
        XCTAssertEqual(halloween.fadingBackdrop(to: -100), halloween.fadingBackdrop(to: 0))
    }

    func testEveryCatalogThemeKeepsTextReadableWhenFaded() {
        for theme in ThemeCatalog.all {
            for opacity in [0.75, 0.5, 0.25, 0.0] {
                let faded = theme.fadingBackdrop(to: opacity)
                let violations = ThemeAudit.violations(in: faded).filter { $0.role == "text" }
                XCTAssertTrue(violations.isEmpty, "\(theme.id.rawValue) at \(opacity): \(violations.map(\.description).joined(separator: "\n"))")
            }
        }
    }

    // MARK: Low contrast roles

    func testLowContrastRolesIsEmptyForEveryCatalogTheme() {
        for theme in ThemeCatalog.all {
            XCTAssertTrue(ThemeAudit.lowContrastRoles(in: theme).isEmpty, theme.id.rawValue)
        }
    }

    func testLowContrastRolesFlagsTextMatchingTheBackdropOnce() {
        let memphis = ThemeCatalog.memphis
        var customization = ThemeCustomization()
        customization.text = ThemeColor(0xFEFBEC)
        let roles = ThemeAudit.lowContrastRoles(in: memphis.applying(customization))
        XCTAssertEqual(roles.filter { $0 == "text" }.count, 1, roles.joined(separator: ", "))
        XCTAssertFalse(roles.contains { $0.hasSuffix(ThemeAudit.overWallpaper) }, roles.joined(separator: ", "))
    }
}

private func fullCustomization() -> ThemeCustomization {
    var customization = ThemeCustomization()
    customization.tone = .light
    customization.gradient = [ThemeColor(0x123456), ThemeColor(0xABCDEF)]
    customization.gradientAngle = 137
    customization.sidebarTint = ThemeColor(0x222222)
    customization.sidebarTintOpacity = 0.25
    customization.composerTint = ThemeColor(0x333333)
    customization.text = ThemeColor(0x444444)
    customization.secondaryText = ThemeColor(0x555555)
    customization.accent = ThemeColor(0x666666)
    customization.link = ThemeColor(0x777777)
    customization.alert = ThemeColor(0x888888)
    customization.nameColors = [ThemeColor(0x999999), ThemeColor(0xAAAAAA)]
    customization.nameGlow = true
    customization.displayFont = "Custom-Font"
    customization.bodyDesign = .serif
    customization.motifs = [MotifSpec(.bat, [ThemeColor(0xBBBBBB), ThemeColor(0xCCCCCC)], style: .glow, weight: 4)]
    customization.density = .dense
    customization.motifOpacity = 0.42
    customization.ornaments = [OrnamentSpec(.moonLarge, .top, [ThemeColor(0xDDDDDD)], opacity: 0.33)]
    customization.celebration = .stars
    return customization
}
